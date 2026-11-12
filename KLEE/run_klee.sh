#!/usr/bin/env bash
# ==============================================================================
# run_klee.sh  -  One-shot KLEE pipeline
#
#   1. One-time setup (auto-skipped if already installed)
#   2. Compile .c -> LLVM bitcode
#   3. Run KLEE (default max 3600 s)
#   4. Export .ktest -> testcases.csv  (export_ktests_fast.py)
#
# Usage (run from WSL; this ONE file is enough, Python exporter is embedded at the bottom):
#   cd <ProgramFolder> && ../run_klee.sh            # run for the folder you are standing in
#   ./run_klee.sh Prob11-REACH-P-SEQ-B2            # one program (from the tool folder)
#   ./run_klee.sh Prob11-REACH-P-SEQ-B2 600        # custom time limit (sec)
#   ./run_klee.sh --all                            # every sub-folder having a .c file
#   ./run_klee.sh --all 1800
# ==============================================================================
set -uo pipefail

INVOKE_DIR="$PWD"                                  # folder the script was started from
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="$BASE_DIR/$(basename "${BASH_SOURCE[0]}")"   # absolute path (script may be started as ../run_klee.sh)
cd "$BASE_DIR"

LLVM_DIR="$BASE_DIR/llvm13"
LLVM_ARCHIVE="clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04.tar.xz"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-13.0.1/${LLVM_ARCHIVE}"
KLEE_INCLUDE="/snap/klee/current/usr/local/include"
# Arguments:  (none | <seconds>)  -> use the CURRENT program folder (run from inside it)
#             <ProgramFolder|--all> [seconds]  -> run by name from the tool folder
ARG1="${1:-}"
if [ -z "$ARG1" ] || [[ "$ARG1" =~ ^[0-9]+$ ]]; then
  CWD_MODE=1; TIME_LIMIT="${ARG1:-3600}"
else
  CWD_MODE=0; TIME_LIMIT="${2:-3600}"
fi
PY_DIR="$(mktemp -d /tmp/klee_helpers_XXXXXX)"   # temp copies of embedded Python helpers
trap 'rm -rf "$PY_DIR"' EXIT
XLSX="$BASE_DIR/KLEE_Coverage_Summary.xlsx"       # master Excel summary (one row per program)
MUTANTS="${MUTANTS:-200}"                         # mutants sampled per program (0 = skip mutation score)
MUT_TESTS="${MUT_TESTS:-3000}"                    # max test cases used per mutant (random, fixed seed; 0 = all)
MUT_TIME="${MUT_TIME:-1800}"                      # max seconds spent on mutation per program
KLEE_OPTS="${KLEE_OPTS:-}"                        # extra KLEE options, e.g. KLEE_OPTS="--max-memory=8000"
MUT_ONLY="${MUT_ONLY:-0}"                         # 1 = only redo mutation score + Excel from an earlier finished run
SKIP_COVERAGE="${SKIP_COVERAGE:-0}"               # SKIP_COVERAGE=1 -> stop after CSV export
BENCH_TYPE="${BENCH_TYPE:-}"                      # RERS / SLR / Coreutils (auto: Prob* -> RERS, else SLR)

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# ONE-TIME SETUP (each part runs only if something is missing)
# ------------------------------------------------------------------------------
setup_once() {
  # --- system packages -------------------------------------------------------
  local missing=0
  for cmd in gcc g++ make cmake python3 git wget curl gcov gcovr lcov; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  if [ "$missing" -eq 1 ]; then
    log "Installing apt dependencies (one-time)..."
    sudo apt update
    sudo apt install -y build-essential python3 python3-pip python3-venv \
      git wget curl xz-utils tar unzip time coreutils \
      gcc g++ make cmake ninja-build gcovr lcov
    sudo apt install -y libtinfo5 2>/dev/null || true   # not available on newer Ubuntu; harmless
    sudo apt install -y libtinfo6 2>/dev/null || true
  fi

  # --- KLEE ------------------------------------------------------------------
  if ! command -v klee >/dev/null 2>&1; then
    log "Installing KLEE via snap (one-time)..."
    sudo snap install klee || die "KLEE install failed"
  fi
  [ -f "$KLEE_INCLUDE/klee/klee.h" ] || die "klee.h not found at $KLEE_INCLUDE/klee/"

  # --- LLVM 13 ---------------------------------------------------------------
  if [ ! -x "$LLVM_DIR/bin/clang" ]; then
    log "Setting up LLVM 13 (one-time)..."
    mkdir -p "$LLVM_DIR"
    if [ ! -f "$LLVM_DIR/$LLVM_ARCHIVE" ]; then
      wget -O "$LLVM_DIR/$LLVM_ARCHIVE" "$LLVM_URL" || die "LLVM download failed"
    fi
    tar -xf "$LLVM_DIR/$LLVM_ARCHIVE" -C "$LLVM_DIR" --strip-components=1 \
      || die "LLVM extract failed"
  fi
  # LLVM 13 binaries need the REAL libtinfo.so.5 (a symlink to .6 does NOT work: symbol
  # versions differ). Newer Ubuntu no longer ships it, so extract it from the old
  # Ubuntu package into llvm13/lib (no system change, no sudo needed).
  if ! "$LLVM_DIR/bin/clang" --version >/dev/null 2>&1; then
    log "Fixing missing libtinfo.so.5 (one-time)..."
    rm -f "$LLVM_DIR/lib/libtinfo.so.5"          # remove any broken symlink from earlier attempts
    local DEB="libtinfo5_6.3-2ubuntu0.3_amd64.deb" TMPD
    TMPD="$(mktemp -d)"
    wget -q -O "$TMPD/$DEB" "http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/$DEB" \
      || die "Could not download $DEB"
    dpkg -x "$TMPD/$DEB" "$TMPD/x"
    cp -a "$TMPD"/x/lib/x86_64-linux-gnu/libtinfo.so.5* "$LLVM_DIR/lib/"
    rm -rf "$TMPD"
  fi
  "$LLVM_DIR/bin/clang" --version | head -n 1 || die "LLVM clang still not runnable"

  # --- helper script ---------------------------------------------------------
  # Extract the embedded Python helpers (bottom of this file) into a temp dir (auto-deleted on exit)
  local p
  for p in export replay mutate report; do
    awk -v name="$p" '/^__PAYLOAD:/{f=($0=="__PAYLOAD:" name "__"); next} f' "$SCRIPT_FILE" > "$PY_DIR/$p.py"
    [ -s "$PY_DIR/$p.py" ] || die "Could not extract embedded helper: $p"
  done
  # openpyxl is needed only for the Excel summary
  python3 -c 'import openpyxl' 2>/dev/null || \
    python3 -m pip install --user --break-system-packages -q openpyxl 2>/dev/null || \
    python3 -m pip install --user -q openpyxl || true
}

# ------------------------------------------------------------------------------
# PER-PROGRAM PIPELINE
# ------------------------------------------------------------------------------
run_program() {
  local PROGRAM="$1"
  local RESULT="${PROGRAM}"   # all outputs are saved directly inside the program folder
  local SRC

  log "=============== $PROGRAM ==============="

  # Locate the .c file: prefer <folder>/<PROGRAM>.c, else first *.c in the folder
  if   [ -f "$PROGRAM/$PROGRAM.c" ]; then SRC="$PROGRAM/$PROGRAM.c"
  elif [ -d "$PROGRAM" ];            then SRC="$(find "$PROGRAM" -maxdepth 1 -name '*.c' | sort | head -n 1)"
  elif [ -f "$PROGRAM" ];            then SRC="$PROGRAM"; PROGRAM="$(basename "${PROGRAM%.c}")"; RESULT="$(dirname "$SRC")/results/${PROGRAM}"
  fi
  [ -n "${SRC:-}" ] && [ -f "$SRC" ] || { echo "[SKIP] No .c file found for $PROGRAM"; return 1; }
  echo "Source : $SRC"

  mkdir -p "$RESULT"/{gcov,logs,merged,mutation,preprocessing}

  if [ "$MUT_ONLY" = "1" ]; then       # redo only mutation + Excel from an earlier finished run
    [ -f "$RESULT/testcases.csv" ] && [ -f "$RESULT/gcov/coverage_summary.json" ] \
      && [ -f "$RESULT/gcov/replay-source/klee/klee.h" ] \
      || { echo "[SKIP] MUT_ONLY needs a finished earlier run of $PROGRAM"; return 1; }
    mutation_and_report "$PROGRAM" "$SRC" "$RESULT"
    return $?
  fi

  # --- compile to bitcode ----------------------------------------------------
  log "Compiling to LLVM bitcode..."
  "$LLVM_DIR/bin/clang" \
    -I"$KLEE_INCLUDE" -emit-llvm -c -g -O0 -Xclang -disable-O0-optnone \
    "$SRC" -o "$RESULT/preprocessing/${PROGRAM}.bc" \
    2> "$RESULT/logs/compile.log"
  if [ ! -f "$RESULT/preprocessing/${PROGRAM}.bc" ]; then
    cat "$RESULT/logs/compile.log"
    echo "[SKIP] Compile failed for $PROGRAM"
    return 1
  fi

  # --- run KLEE --------------------------------------------------------------
  local OUT="$RESULT/merged/klee-out"
  if [ -e "$OUT" ]; then          # never overwrite / reuse old output
    local OLD="${OUT}_old_$(date +%Y%m%d_%H%M%S)"
    echo "Existing KLEE output moved to: $OLD"
    mv "$OUT" "$OLD"
  fi

  log "Running KLEE (limit ${TIME_LIMIT}s)..."
  /usr/bin/time -f '%e' -o "$RESULT/logs/runtime_seconds.txt" \
    timeout --signal=INT --kill-after=30s "${TIME_LIMIT}s" \
    klee $KLEE_OPTS --output-dir="$OUT" "$RESULT/preprocessing/${PROGRAM}.bc" \
    > "$RESULT/logs/klee.log" 2>&1
  echo "$?" > "$RESULT/logs/exit_status.txt"      # 124 = stopped by time limit (normal)

  local N_TESTS N_ERRS
  N_TESTS=$(find "$OUT" -type f -name '*.ktest' 2>/dev/null | wc -l)
  N_ERRS=$(find "$OUT" -type f -name '*.err'   2>/dev/null | wc -l)
  echo "Exit status : $(cat "$RESULT/logs/exit_status.txt")"
  echo "Runtime (s) : $(cat "$RESULT/logs/runtime_seconds.txt" 2>/dev/null)"
  echo ".ktest files: $N_TESTS   |   .err files: $N_ERRS"
  tail -n 8 "$RESULT/logs/klee.log"

  [ "$N_TESTS" -gt 0 ] || { echo "[SKIP] No test cases generated for $PROGRAM"; return 1; }

  # --- export CSV ------------------------------------------------------------
  log "Exporting test cases to CSV..."
  python3 "$PY_DIR/export.py" "$OUT" "$RESULT/testcases.csv" || return 1
  echo "CSV rows: $(( $(wc -l < "$RESULT/testcases.csv") - 1 ))"

  if [ "$SKIP_COVERAGE" != "1" ]; then
    coverage_phase "$PROGRAM" "$SRC" "$RESULT" || echo "[WARN] Coverage phase failed for $PROGRAM"
  fi

  log "DONE: $PROGRAM  ->  $RESULT/"
}


# ------------------------------------------------------------------------------
# COVERAGE PHASE: replay every KLEE test natively under gcov, then summarise
# ------------------------------------------------------------------------------
coverage_phase() {
  local PROGRAM="$1" SRC="$2" RESULT="$3"
  local GC="$RESULT/gcov" REPL="$RESULT/gcov/replay-source"
  local CSV="$RESULT/testcases.csv"
  local BIN="$GC/${PROGRAM}_replay"

  log "Coverage: building native gcov replay binary..."
  rm -rf "$REPL"; mkdir -p "$REPL/klee"
  rm -f "$GC"/*.gcda "$GC"/*.gcno "$GC"/*.gcov "$GC"/*.o

  # Replay shim: a native klee/klee.h whose klee_make_symbolic() reads the NEXT value
  # from stdin instead of making memory symbolic (same order as the .ktest objects).
  cat > "$REPL/klee/klee.h" <<'SHIM'
#ifndef REPLAY_KLEE_H
#define REPLAY_KLEE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Replay: fill 'addr' with the next value from stdin. */
static inline void klee_make_symbolic(void *addr, unsigned long nbytes, const char *name) {
    (void)name;
    if (nbytes == 1 || nbytes == 2 || nbytes == 4 || nbytes == 8) {
        long long v;
        if (scanf("%lld", &v) != 1) exit(0);      /* no more values: stop this run */
        memcpy(addr, &v, nbytes);                 /* little-endian host */
    } else {
        char tok[8192];
        if (scanf("%8191s", tok) != 1) exit(0);
        const char *h = tok + (strncmp(tok, "0x", 2) == 0 ? 2 : 0);
        for (unsigned long i = 0; i < nbytes && h[2*i] && h[2*i+1]; i++) {
            unsigned int b; sscanf(h + 2*i, "%2x", &b);
            ((unsigned char *)addr)[i] = (unsigned char)b;
        }
    }
}
static inline void klee_assume(unsigned long c) { if (!c) exit(0); }
#endif
SHIM

  # Original source is kept untouched; the shim header supplies klee_make_symbolic.
  cp "$SRC" "$REPL/${PROGRAM}_replay.c"

  ( cd "$GC" && \
    gcc --coverage -O0 -g -w -I"replay-source" -c "replay-source/${PROGRAM}_replay.c" -o "${PROGRAM}_replay.o" && \
    gcc --coverage "${PROGRAM}_replay.o" -o "${PROGRAM}_replay" -lm ) 2> "$RESULT/logs/gcov_compile.log" \
    || { cat "$RESULT/logs/gcov_compile.log"; return 1; }

  log "Coverage: replaying test cases..."
  python3 "$PY_DIR/replay.py" "$BIN" "$CSV" | tee "$RESULT/logs/replay.log"

  log "Coverage: generating gcov / gcovr reports..."
  local GCOVR=(gcovr --root "$GC" --object-directory "$GC" --gcov-executable gcov
               --filter ".*${PROGRAM}_replay\.c" --exclude-throw-branches)
  "${GCOVR[@]}" --txt "$GC/line_coverage.txt"
  "${GCOVR[@]}" --txt --txt-metric branch --output "$GC/branch_coverage.txt" 2>/dev/null \
    || "${GCOVR[@]}" --txt --branches --output "$GC/branch_coverage.txt"
  "${GCOVR[@]}" --json-summary "$GC/coverage_summary.json" --txt "$GC/coverage_summary.txt"
  local LOGS_ABS; LOGS_ABS="$(cd "$RESULT/logs" && pwd)"
  ( cd "$GC" && gcov -b -c "${PROGRAM}_replay.o" > "$LOGS_ABS/gcov_raw.log" 2>&1 || true )   # raw .gcov files

  mutation_and_report "$PROGRAM" "$SRC" "$RESULT" || return 1
}


# ------------------------------------------------------------------------------
# MUTATION SCORE + EXCEL ROW (needs a finished coverage phase)
# ------------------------------------------------------------------------------
mutation_and_report() {
  local PROGRAM="$1" SRC="$2" RESULT="$3"
  local GC="$RESULT/gcov" REPL="$RESULT/gcov/replay-source" CSV="$RESULT/testcases.csv"
  local MUT_JSON="$RESULT/mutation/mutation_summary.json"
  rm -f "$MUT_JSON"
  if [ "$MUTANTS" != "0" ]; then
    log "Mutation: sampling $MUTANTS mutants, up to ${MUT_TESTS} tests each (max ${MUT_TIME}s)..."
    mkdir -p "$RESULT/mutation"
    python3 "$PY_DIR/mutate.py" "$SRC" "$REPL" "$CSV" "$RESULT/mutation" \
      "$MUTANTS" "$(nproc)" "$MUT_TIME" "$MUT_TESTS" | tee "$RESULT/logs/mutation.log" \
      || echo "[WARN] Mutation phase failed"
  fi

  log "Coverage: updating Excel summary..."
  local TYPE="$BENCH_TYPE"
  if [ -z "$TYPE" ]; then
    case "$PROGRAM" in Prob*) TYPE="RERS" ;; *) TYPE="SLR" ;; esac
  fi
  python3 "$PY_DIR/report.py" "$XLSX" "$PROGRAM" "$TYPE" \
    "$RESULT/logs/runtime_seconds.txt" "$GC/coverage_summary.json" "$CSV" "$MUT_JSON" || return 1
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
setup_once

if [ "$CWD_MODE" = 1 ]; then
  # Started from inside a program folder: ../run_klee.sh   (or ../run_klee.sh 600)
  [ "$INVOKE_DIR" != "$BASE_DIR" ] && ls "$INVOKE_DIR"/*.c >/dev/null 2>&1 \
    || die "Go inside a program folder (with a .c file) and run: ../run_klee.sh
       or from this folder run: ./run_klee.sh <ProgramFolder> | --all"
  cd "$(dirname "$INVOKE_DIR")"
  run_program "$(basename "$INVOKE_DIR")"
elif [ "$1" = "--all" ]; then
  for d in */; do
    d="${d%/}"
    case "$d" in results|llvm13|extracted) continue ;; esac
    ls "$d"/*.c >/dev/null 2>&1 || continue
    run_program "$d" || true
  done
else
  run_program "$1"
fi

exit 0

__PAYLOAD:export__
#!/usr/bin/env python3
"""
export_ktests_fast.py
=====================
Fast, parallel converter: KLEE `.ktest` files  ->  a single CSV file.

Usage
-----
    python3 export_ktests_fast.py <klee-out-dir> <output.csv> [options]

    python3 export_ktests_fast.py \
        results/Vp2-B100/merged/klee-out \
        results/Vp2-B100/testcases.csv

Options
-------
    --workers N      Number of worker processes (default: CPU count)
    --chunk-size N   .ktest files handled per task (default: 200)
    --buffer-rows N  Rows buffered in memory before each disk write (default: 5000)
    --skip-model     Skip the internal 'model_version' object KLEE adds

Design notes
------------
* Parsing is done directly on the binary KTEST format (pure Python, no
  dependency on klee.ktest-tool or the `ktest` python module). The format is:

      magic        : 5 bytes  -> b"KTEST" (or legacy b"BOUT\\n")
      version      : uint32 big-endian
      numArgs      : uint32, then numArgs * (uint32 len + bytes)
      [version>=2] : symArgvs uint32, symArgvLen uint32
      numObjects   : uint32
      per object   : name (uint32 len + bytes),
                     numBytes uint32, raw bytes

* Files are processed in parallel with multiprocessing.Pool, in chunks, so
  inter-process overhead stays small. `imap` keeps the output in the original
  (naturally sorted) test-case order.
* Rows are buffered in memory and flushed in large batches; the output file
  uses a big write buffer to minimise disk I/O.
* A corrupt / unreadable .ktest file is logged to stderr and skipped; the
  script never crashes because of a single bad file.

CSV columns
-----------
    test_case      file stem, e.g. test000001
    ktest_file     path of the .ktest relative to the KLEE output directory
    num_args       number of recorded command-line args
    num_objects    number of symbolic objects
    object_names   object names joined with ';'
    object_sizes   object sizes in bytes joined with ';'
    values         decoded values, SPACE-separated, in original order
                   (1/2/4/8-byte objects -> signed little-endian integers,
                    other sizes -> 0x<hex>). This is the sequence a replay
                    harness should feed to the program, in order.
    raw_hex        hex of every object's raw bytes joined with ';'
"""

import argparse
import csv
import multiprocessing as mp
import os
import re
import struct
import sys
import time
from typing import List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
MAGIC_NEW = b"KTEST"
MAGIC_OLD = b"BOUT\n"
MAX_SUPPORTED_VERSION = 4          # KLEE currently writes version 3; be lenient.
CSV_HEADER = [
    "test_case", "ktest_file", "num_args", "num_objects",
    "object_names", "object_sizes", "values", "raw_hex",
]
_U32 = struct.Struct(">I")
_INT_FORMATS = {1: "<b", 2: "<h", 4: "<i", 8: "<q"}   # signed little-endian


class KTestError(Exception):
    """Raised when a .ktest file is malformed."""


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
class _Reader:
    """Tiny bounds-checked sequential reader over an in-memory bytes object."""

    __slots__ = ("buf", "pos", "end")

    def __init__(self, buf: bytes):
        self.buf = buf
        self.pos = 0
        self.end = len(buf)

    def read(self, n: int) -> bytes:
        if n < 0 or self.pos + n > self.end:
            raise KTestError("unexpected end of file / corrupt length field")
        chunk = self.buf[self.pos:self.pos + n]
        self.pos += n
        return chunk

    def u32(self) -> int:
        return _U32.unpack(self.read(4))[0]

    def string(self) -> bytes:
        return self.read(self.u32())


def parse_ktest(path: str):
    """
    Parse one .ktest file.

    Returns (num_args, [(name:str, data:bytes), ...]).
    Raises KTestError / OSError on failure.
    """
    with open(path, "rb") as fh:
        data = fh.read()

    r = _Reader(data)
    magic = r.read(5)
    if magic not in (MAGIC_NEW, MAGIC_OLD):
        raise KTestError("bad magic number %r" % magic)

    version = r.u32()
    if version > MAX_SUPPORTED_VERSION:
        raise KTestError("unsupported ktest version %d" % version)

    num_args = r.u32()
    for _ in range(num_args):          # args are skipped, only counted
        r.string()

    if version >= 2:
        r.u32()                        # symArgvs
        r.u32()                        # symArgvLen

    num_objects = r.u32()
    objects = []
    for _ in range(num_objects):
        name = r.string().decode("utf-8", errors="replace")
        size = r.u32()
        objects.append((name, r.read(size)))

    return num_args, objects


def decode_value(raw: bytes) -> str:
    """Decode an object's bytes into a printable integer (or hex fallback)."""
    fmt = _INT_FORMATS.get(len(raw))
    if fmt is not None:
        return str(struct.unpack(fmt, raw)[0])
    return "0x" + raw.hex() if raw else ""


# --------------------------------------------------------------------------- #
# Worker (runs in child processes)
# --------------------------------------------------------------------------- #
def _convert_chunk(task: Tuple[Sequence[str], str, bool]):
    """
    Convert a chunk of .ktest paths into CSV rows.

    Returns (rows, errors) where errors is a list of (path, message).
    Never raises for per-file problems.
    """
    paths, root, skip_model = task
    rows: List[list] = []
    errors: List[Tuple[str, str]] = []

    for path in paths:
        try:
            num_args, objects = parse_ktest(path)
            if skip_model:
                objects = [o for o in objects if o[0] != "model_version"]

            names = ";".join(n for n, _ in objects)
            sizes = ";".join(str(len(d)) for _, d in objects)
            values = " ".join(decode_value(d) for _, d in objects)
            raw_hex = ";".join(d.hex() for _, d in objects)

            rows.append([
                os.path.splitext(os.path.basename(path))[0],
                os.path.relpath(path, root),
                num_args, len(objects), names, sizes, values, raw_hex,
            ])
        except Exception as exc:       # noqa: BLE001 - deliberately broad
            errors.append((path, "%s: %s" % (type(exc).__name__, exc)))

    return rows, errors


# --------------------------------------------------------------------------- #
# Discovery helpers
# --------------------------------------------------------------------------- #
def _natural_key(path: str):
    """Sort test000002 before test000010 (and handle mixed digit widths)."""
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", path)]


def find_ktests(root: str) -> List[str]:
    found = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith(".ktest"):
                found.append(os.path.join(dirpath, f))
    found.sort(key=_natural_key)
    return found


def _chunked(items: Sequence[str], size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def parse_args(argv: Optional[Sequence[str]] = None):
    p = argparse.ArgumentParser(
        description="Convert KLEE .ktest files to a CSV file (parallel, buffered).")
    p.add_argument("klee_out", help="KLEE output directory (contains *.ktest)")
    p.add_argument("output_csv", nargs="?", default=None,
                   help="Output CSV path (default: <klee_out>/../testcases.csv)")
    p.add_argument("--workers", type=int, default=os.cpu_count() or 1,
                   help="worker processes (default: CPU count)")
    p.add_argument("--chunk-size", type=int, default=200,
                   help=".ktest files per task (default: 200)")
    p.add_argument("--buffer-rows", type=int, default=5000,
                   help="rows buffered before a disk write (default: 5000)")
    p.add_argument("--skip-model", action="store_true",
                   help="drop the internal 'model_version' object")
    return p.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    root = os.path.abspath(args.klee_out)

    if not os.path.isdir(root):
        print("[ERROR] KLEE output directory not found: %s" % root, file=sys.stderr)
        return 1

    out_csv = args.output_csv or os.path.join(os.path.dirname(root), "testcases.csv")
    os.makedirs(os.path.dirname(os.path.abspath(out_csv)), exist_ok=True)

    t0 = time.time()
    ktests = find_ktests(root)
    if not ktests:
        print("[ERROR] No .ktest files found in %s" % root, file=sys.stderr)
        return 1

    workers = max(1, min(args.workers, len(ktests)))
    chunk_size = max(1, args.chunk_size)
    buffer_rows = max(1, args.buffer_rows)
    print("[INFO] %d .ktest files | %d workers | chunk=%d"
          % (len(ktests), workers, chunk_size))

    tasks = [(c, root, args.skip_model) for c in _chunked(ktests, chunk_size)]
    written = 0
    failed = 0
    buffer: List[list] = []

    # newline="" is required by the csv module; 4 MiB buffer reduces syscalls.
    with open(out_csv, "w", newline="", encoding="utf-8", buffering=4 * 1024 * 1024) as fh:
        writer = csv.writer(fh)
        writer.writerow(CSV_HEADER)

        def flush():
            nonlocal buffer, written
            if buffer:
                writer.writerows(buffer)
                written += len(buffer)
                buffer = []

        def consume(rows, errors):
            nonlocal failed, buffer
            for path, msg in errors:
                failed += 1
                print("[WARN] Skipping %s -> %s" % (path, msg), file=sys.stderr)
            buffer.extend(rows)
            if len(buffer) >= buffer_rows:
                flush()

        if workers == 1:
            for t in tasks:
                consume(*_convert_chunk(t))
        else:
            # imap (ordered) keeps CSV rows in sorted test-case order.
            with mp.Pool(processes=workers) as pool:
                for done, (rows, errors) in enumerate(pool.imap(_convert_chunk, tasks), 1):
                    consume(rows, errors)
                    if done % 20 == 0 or done == len(tasks):
                        print("[INFO] %d/%d chunks done" % (done, len(tasks)), flush=True)

        flush()

    print("[DONE] rows written: %d | skipped (errors): %d | time: %.2fs"
          % (written, failed, time.time() - t0))
    print("[DONE] CSV: %s" % out_csv)
    return 0


if __name__ == "__main__":
    mp.freeze_support()
    sys.exit(main())
__PAYLOAD:replay__
#!/usr/bin/env python3
"""Replay every test case (values column of testcases.csv) through the gcov-built binary."""
import csv
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

binary, csv_path = sys.argv[1], sys.argv[2]
workers = int(sys.argv[3]) if len(sys.argv) > 3 else 8
TIMEOUT = 20  # seconds per test

with open(csv_path, newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))


def run(row):
    try:
        subprocess.run([binary], input=(row["values"] + "\n").encode(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
        return "ok"
    except subprocess.TimeoutExpired:
        return "timeout"
    except Exception as exc:  # noqa: BLE001
        print("[WARN] %s: %s" % (row.get("test_case"), exc), file=sys.stderr)
        return "error"


with ThreadPoolExecutor(max_workers=workers) as ex:
    results = list(ex.map(run, rows))

print("[REPLAY] tests: %d | ok: %d | timeout: %d | error: %d"
      % (len(rows), results.count("ok"), results.count("timeout"), results.count("error")))
__PAYLOAD:mutate__
#!/usr/bin/env python3
"""
Self-contained mutation testing for a KLEE benchmark.

  1. Generate source-level mutants (relational / logical / arithmetic operators, integer constants).
  2. Compile each mutant against the replay shim (klee_make_symbolic reads stdin).
  3. Run every KLEE test case on original and mutant. A mutant is KILLED when the exit code,
     stdout, or the final value of the program's global variables differs from the original.
  4. Equivalent = mutant compiles to byte-identical object code. Invalid = does not compile.

Mutation Score = Killed / (Valid mutants - Equivalent mutants) * 100
"""
import csv
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

src, inc, csv_path, out_dir = sys.argv[1:5]
N_MUT = int(sys.argv[5])
WORKERS = max(1, int(sys.argv[6]))
BUDGET = float(sys.argv[7])
TEST_TIMEOUT = 5
T0 = time.time()
WORK = os.path.join(out_dir, "work")
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
CC = ["gcc", "-O0", "-g0", "-w", "-I", inc]


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)


# ---------------------------------------------------------------- original build + observer
lines = open(src, encoding="utf-8", errors="replace").read().split("\n")
orig_c = os.path.join(WORK, "orig.c")
open(orig_c, "w").write("\n".join(lines))
orig_o = os.path.join(WORK, "orig.o")
r = run(CC + ["-c", orig_c, "-o", orig_o])
if r.returncode:
    sys.exit("[MUT] original does not compile:\n" + r.stderr.decode(errors="replace"))

# Observer: hash all global variables of the program at exit (so state changes are visible
# even when the program prints nothing).
syms = []
for ln in run(["nm", "-S", "--defined-only", orig_o]).stdout.decode().splitlines():
    p = ln.split()
    if len(p) == 4 and p[2] in ("B", "D", "C") and "." not in p[3]:
        syms.append((p[3], int(p[1], 16)))
obs = ['#include <stdio.h>', '#include <stdlib.h>']
obs += ["extern char %s;" % n for n, _ in syms]
obs += ["static unsigned long long h = 1469598103934665603ULL;",
        "static void feed(const unsigned char *p, unsigned long n)"
        "{ for (unsigned long i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; } }",
        "static void dump(void) {"]
obs += ["  feed((const unsigned char *)&%s, %d);" % (n, sz) for n, sz in syms]
obs += ['  printf("\\nSTATE %llx\\n", h); }',
        "__attribute__((constructor)) static void reg(void) { atexit(dump); }"]
obs_c = os.path.join(WORK, "observer.c")
open(obs_c, "w").write("\n".join(obs))
obs_o = os.path.join(WORK, "observer.o")
r = run(["gcc", "-O0", "-w", "-c", obs_c, "-o", obs_o])
if r.returncode:
    sys.exit("[MUT] observer failed:\n" + r.stderr.decode(errors="replace"))
orig_bin = os.path.join(WORK, "orig")
r = run(["gcc", orig_o, obs_o, "-o", orig_bin, "-lm"])
if r.returncode:
    sys.exit("[MUT] link failed:\n" + r.stderr.decode(errors="replace"))

# ---------------------------------------------------------------- tests
with open(csv_path, newline="", encoding="utf-8") as fh:
    tests = [(row["values"] + "\n").encode() for row in csv.DictReader(fh)]
if not tests:
    sys.exit("[MUT] no test cases")
TESTS_TOTAL = len(tests)
MAX_TESTS = int(sys.argv[8]) if len(sys.argv) > 8 else 0
if MAX_TESTS > 0 and len(tests) > MAX_TESTS:      # huge suites: reproducible random subset
    keep = sorted(random.Random(2).sample(range(len(tests)), MAX_TESTS))
    tests = [tests[i] for i in keep]


def exec_test(binary, inp):
    try:
        p = subprocess.run([binary], input=inp, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=TEST_TIMEOUT)
        return (p.returncode, p.stdout)
    except subprocess.TimeoutExpired:
        return ("timeout", b"")


with ThreadPoolExecutor(max_workers=WORKERS) as _ex:
    baseline = list(_ex.map(lambda t: exec_test(orig_bin, t), tests))

# ---------------------------------------------------------------- mutant generation
RULES = [
    (re.compile(r"(?<![=!<>])==(?!=)"), lambda m: "!="),
    (re.compile(r"!="), lambda m: "=="),
    (re.compile(r"<=(?!=)"), lambda m: "<"),
    (re.compile(r">="), lambda m: ">"),
    (re.compile(r"(?<![<\-])<(?![<=])"), lambda m: "<="),
    (re.compile(r"(?<![>\-])>(?![>=])"), lambda m: ">="),
    (re.compile(r"&&"), lambda m: "||"),
    (re.compile(r"\|\|"), lambda m: "&&"),
    (re.compile(r"(?<=[\w\)\]])\s*\+\s*(?=[\w\(])"), lambda m: " - "),
    (re.compile(r"(?<=[\w\)\]])\s*-(?![->])\s*(?=[\w\(])"), lambda m: " + "),
    (re.compile(r"(?<![\w.])\d+(?![\w.])"), lambda m: str(int(m.group(0)) + 1)),
]
population = []                      # (line_idx, start, end, replacement)
for i, line in enumerate(lines):
    st = line.lstrip()
    if st.startswith("#") or '"' in line or "'" in line:
        continue
    code = line.split("//", 1)[0]
    for rx, fn in RULES:
        for m in rx.finditer(code):
            population.append((i, m.start(), m.end(), fn(m)))

random.Random(1).shuffle(population)
sample = population[:N_MUT] if N_MUT > 0 else []
print("[MUT] mutant population: %d | sampled: %d | tests per mutant: %d (of %d)"
      % (len(population), len(sample), len(tests), TESTS_TOTAL), flush=True)

orig_obj_bytes = open(orig_o, "rb").read()


def evaluate(item):
    idx, (li, s, e, repl) = item
    if time.time() - T0 > BUDGET:
        return idx, "not_run"
    d = os.path.join(WORK, "m%d" % idx)
    os.makedirs(d, exist_ok=True)
    try:
        new = list(lines)
        new[li] = lines[li][:s] + repl + lines[li][e:]
        c = os.path.join(d, "m.c")
        open(c, "w").write("\n".join(new))
        o = os.path.join(d, "m.o")
        if run(CC + ["-c", c, "-o", o]).returncode:
            return idx, "invalid"
        if open(o, "rb").read() == orig_obj_bytes:
            return idx, "equivalent"
        b = os.path.join(d, "m")
        if run(["gcc", o, obs_o, "-o", b, "-lm"]).returncode:
            return idx, "invalid"
        for t, base in zip(tests, baseline):
            if exec_test(b, t) != base:
                return idx, "killed"
        return idx, "survived"
    finally:
        shutil.rmtree(d, ignore_errors=True)


status = {}
with ThreadPoolExecutor(max_workers=WORKERS) as ex:
    for idx, st in ex.map(evaluate, list(enumerate(sample))):
        status[idx] = st
        if (len(status) % 25) == 0:
            print("[MUT] %d/%d evaluated" % (len(status), len(sample)), flush=True)

count = lambda k: sum(1 for v in status.values() if v == k)  # noqa: E731
killed, survived = count("killed"), count("survived")
equiv, invalid, not_run = count("equivalent"), count("invalid"), count("not_run")
valid = killed + survived + equiv
denom = valid - equiv
score = (100.0 * killed / denom) if denom > 0 else None

with open(os.path.join(out_dir, "mutants.csv"), "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["id", "line", "original", "mutated", "status"])
    for idx, (li, s, e, repl) in enumerate(sample):
        w.writerow([idx, li + 1, lines[li][s:e].strip(), repl.strip(), status.get(idx, "not_run")])

summary = {"population": len(population), "sampled": len(sample), "valid": valid,
           "killed": killed, "survived": survived, "equivalent": equiv,
           "invalid_excluded": invalid, "not_run": not_run, "tests": len(tests),
           "tests_total": TESTS_TOTAL,
           "mutation_score": score}
json.dump(summary, open(os.path.join(out_dir, "mutation_summary.json"), "w"), indent=2)
txt = [
    "Mutation testing summary",
    "Mutant population          : %d" % len(population),
    "Mutants sampled            : %d" % len(sample),
    "Tests used per mutant      : %d of %d" % (len(tests), TESTS_TOTAL),
    "Invalid (compile error)    : %d (excluded)" % invalid,
    "Equivalent (same object)   : %d (excluded)" % equiv,
    "Not run (time budget)      : %d" % not_run,
    "Valid mutants evaluated    : %d" % denom,
    "Killed                     : %d" % killed,
    "Survived                   : %d" % survived,
    "Mutation Score = Killed / (Valid - Equivalent) = %s"
    % ("%.2f%%" % score if score is not None else "N/A"),
]
open(os.path.join(out_dir, "mutation_summary.txt"), "w").write("\n".join(txt) + "\n")
shutil.rmtree(WORK, ignore_errors=True)
print("\n".join(txt))
__PAYLOAD:report__
#!/usr/bin/env python3
"""Add/update one row in the master Excel summary."""
import csv
import json
import os
import sys

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font

xlsx, program, bench, runtime_file, summary_json, csv_path = sys.argv[1:7]
mut_json = sys.argv[7] if len(sys.argv) > 7 else ""

HEADER = ["Name of the Program", "Type of Benchmarks (RERS/SLR/Coreutils)",
          "Time frame (in second)", "Line Coverage", "Branch coverage",
          "Mutation Score", "Statement Coverage", "Test Cases"]

runtime = ""
try:
    for _ln in reversed(open(runtime_file).read().splitlines()):
        try:
            runtime = float(_ln.strip())
            break
        except ValueError:
            continue
except Exception:  # noqa: BLE001
    pass

with open(summary_json) as fh:
    summ = json.load(fh)
line_pct = summ.get("line_percent")
branch_pct = summ.get("branch_percent")
# Statement coverage: gcov is line-granular, so executed lines / executable lines is
# used as the statement metric (same denominator as line coverage; see Notes sheet).
stmt_pct = line_pct

with open(csv_path, newline="", encoding="utf-8") as fh:
    n_tests = sum(1 for _ in csv.reader(fh)) - 1


mut_pct = None
if mut_json and os.path.exists(mut_json):
    with open(mut_json) as fh:
        mut_pct = json.load(fh).get("mutation_score")


def fmt(v):
    return "%.2f%%" % v if isinstance(v, (int, float)) else "N/A"


row = [program, bench, runtime, fmt(line_pct), fmt(branch_pct),
       fmt(mut_pct), fmt(stmt_pct), n_tests]

if os.path.exists(xlsx):
    wb = load_workbook(xlsx)
    ws = wb["Summary"] if "Summary" in wb.sheetnames else wb.active
else:
    wb = Workbook()
    ws = wb.active
    ws.title = "Summary"
    ws.append(HEADER)
    for c in ws[1]:
        c.font = Font(bold=True)
    notes = wb.create_sheet("Notes")
    for line in [
        "Coverage measured by replaying every KLEE test case on a gcc --coverage build (gcov/gcovr).",
        "Line coverage = executed executable lines / executable lines (gcov).",
        "Branch coverage = taken branches / branches (gcov -b).",
        "Statement coverage = line-based (gcov is line granular); same denominator as line coverage.",
        "Mutation score = killed / (valid mutants - equivalent mutants); see <program>/results/mutation/mutation_summary.txt.",
        "Mutants: source-level operator/constant mutations (sampled); equivalent = identical object code; a mutant is killed if exit code, stdout or final global-variable state differs on any KLEE test (huge suites use a random subset of tests, so the score is a lower bound).",
    ]:
        notes.append([line])

for r in range(2, ws.max_row + 1):          # replace an existing row for this program
    if ws.cell(r, 1).value == program:
        for c, v in enumerate(row, 1):
            ws.cell(r, c).value = v
        break
else:
    ws.append(row)

for col in ws.columns:
    ws.column_dimensions[col[0].column_letter].width = max(len(str(c.value or "")) for c in col) + 2

try:
    wb.save(xlsx)
except PermissionError:
    sys.exit("[EXCEL] Cannot write %s - close it in Excel and run again." % xlsx)
print("[EXCEL] %s | line %s | branch %s | tests %s -> %s"
      % (program, fmt(line_pct), fmt(branch_pct), n_tests, xlsx))