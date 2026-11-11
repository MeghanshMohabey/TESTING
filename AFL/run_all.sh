#!/bin/bash
#
# run_everything.sh -- ALL-IN-ONE benchmark pipeline.
#
# For every program (.c file) found under <root_dir>, this does:
#   1. Compile AFL++ instrumented binary + GCOV instrumented binary
#   2. Fuzz with AFL++ for <time_limit> (LIVE table shown normally -- see note below)
#   3. Replay the fuzzing queue through the GCOV binary, print coverage
#   4. Run mutation testing (parallel, across all CPU cores)
#   5. Sanity-check Line Coverage vs Statement Coverage
#   6. Append one row per program to a master CSV:
#        Name of the Program, Type of Benchmarks, Time frame(in second),
#        Line Coverage, Branch coverage, Mutation Score, Statement Coverage,
#        Test Cases
#
# Everything lives in this ONE file -- the mutation tester and the
# statement-coverage checker are embedded as Python here-docs and written
# to temp files at runtime, so you only need to copy/download this file.
#
# Usage:
#   ./run_everything.sh <root_dir> [time_limit=10m] [master_csv]
#
# Example:
#   ./run_everything.sh "/mnt/d/AFL++ Tool/SLR/10min" 10m slr_10min_report.csv
#   ./run_everything.sh .   1m                 <- just the program in the current folder
#
# IMPORTANT -- why the AFL table disappeared before, and how this fixes it:
#   AFL++'s live status box only renders when its stdout is a real terminal
#   (isatty() check). Anything that pipes/captures the whole run (e.g.
#   `out=$(./script.sh)`) breaks that, and AFL silently falls back to
#   plain-text logging. This script never wraps the fuzzing step itself in
#   command substitution -- it inherits your terminal directly, so the
#   table shows exactly like a manual run. Only non-interactive steps
#   (gcov, mutation testing, python checks) are captured for parsing.
#
# Optional env vars (same as before):
#   EXTRA_CFLAGS   extra -I/-L flags needed to compile the source, e.g.
#                    EXTRA_CFLAGS="-I/path/to/lib" ./run_everything.sh ...
#   PREBUILT=1     skip compiling; expects "<base>_afl" and "<base>_cov"
#                    binaries to already exist next to each .c file.

set -uo pipefail

ROOT_DIR="${1:?Usage: $0 <root_dir> [time_limit=10m] [master_csv]}"
export TIME_LIMIT="${2:-10m}"
MASTER_CSV="${3:-$(pwd)/full_report.csv}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
PREBUILT="${PREBUILT:-0}"
# Caps how many mutants get tested for very large source files (thousands of
# operators = thousands of gcc compiles = very slow). 0 = no cap, test ALL
# mutants (default -- accuracy over speed). Set MAX_MUTANTS=1500 etc. if you
# ever want a faster, sampled estimate instead.
export MAX_MUTANTS="${MAX_MUTANTS:-0}"
# Caps how many test files (from in/ + crashes/ + AFL queue/) each mutant is
# run against. AFL queues can have 500-2000+ files after a long fuzz session,
# and mutants_count x test_files_count is what actually makes mutation
# testing slow (each is a subprocess run). 0 = no cap (use everything, slow
# but exhaustive). Default 150 keeps runtime sane with minimal score impact,
# since queue files are heavily redundant. Set MAX_TEST_FILES=0 to disable.
export MAX_TEST_FILES="${MAX_TEST_FILES:-150}"

# ---------------------------------------------------------------------------
# Embedded Python helpers -- written to temp files once, reused for every
# program, cleaned up on exit.
# ---------------------------------------------------------------------------
MUTATION_PY="$(mktemp --suffix=.py)"
STMT_PY="$(mktemp --suffix=.py)"
SEED_PY="$(mktemp --suffix=.py)"

cleanup_all() {
    rm -f "$MUTATION_PY" "$STMT_PY" "$SEED_PY"
}
trap cleanup_all EXIT

cat > "$MUTATION_PY" << 'PYEOF_MUTATION'
import os
import sys
import subprocess
import glob
import re
import csv
from multiprocessing import Pool, cpu_count

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        return res.returncode
    except subprocess.TimeoutExpired:
        return 1

def build_code_mask(code):
    mask = [False] * len(code)
    i, n = 0, len(code)
    state = None
    while i < n:
        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line_comment'; mask[i] = mask[i + 1] = True; i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block_comment'; mask[i] = mask[i + 1] = True; i += 2; continue
            if c == '"':
                state = 'string'; mask[i] = True; i += 1; continue
            if c == "'":
                state = 'char'; mask[i] = True; i += 1; continue
            i += 1; continue
        if state == 'line_comment':
            mask[i] = True
            if c == '\n': state = None
            i += 1; continue
        if state == 'block_comment':
            mask[i] = True
            if c == '*' and nxt == '/':
                mask[i + 1] = True; i += 2; state = None; continue
            i += 1; continue
        if state in ('string', 'char'):
            mask[i] = True
            if c == '\\' and i + 1 < n:
                mask[i + 1] = True; i += 2; continue
            if (state == 'string' and c == '"') or (state == 'char' and c == "'"):
                state = None
            i += 1; continue
    return mask

def _safe_remove(path):
    # Race-proof cleanup: two evaluate_mutant() workers can, in rare
    # timing windows (esp. after a subprocess timeout kills things mid-way),
    # end up trying to remove the same path -- or the OS/tmp-cleaner beats
    # us to it. A plain `if os.path.exists(): os.remove()` is a classic
    # TOCTOU race: the file can vanish between the check and the remove,
    # raising FileNotFoundError and crashing the whole mutation run. So we
    # just try to remove and swallow "already gone".
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

def evaluate_mutant(args):
    mutant_id, pattern, repl, mutated_code, test_files, uses_argv_file = args
    pid = os.getpid()
    mutant_c_file = f"mutant_temp_{pid}.c"
    mutant_bin = f"./mutant_temp_{pid}"
    try:
        with open(mutant_c_file, 'w') as f:
            f.write(mutated_code)
        compile_ret = run_cmd(f"gcc {mutant_c_file} -o {mutant_bin}")
        if compile_ret != 0:
            return {"Mutant_ID": mutant_id, "Operator": f"{pattern} -> {repl}", "Status": "Killed (Compilation Error)"}
        mutant_killed = False
        for tfile in test_files:
            if uses_argv_file:
                ret = run_cmd(f"{mutant_bin} '{tfile}'")
            else:
                ret = run_cmd(f"{mutant_bin} < '{tfile}'")
            if ret != 0:
                mutant_killed = True
                break
        if mutant_killed:
            return {"Mutant_ID": mutant_id, "Operator": f"{pattern} -> {repl}", "Status": "Killed"}
        else:
            return {"Mutant_ID": mutant_id, "Operator": f"{pattern} -> {repl}", "Status": "Survived"}
    finally:
        _safe_remove(mutant_c_file)
        _safe_remove(mutant_bin)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 run_mutation.py <path_to_c_file> [input_dir] [crashes_dir] [uses_argv_file]")
        sys.exit(1)
    c_file = sys.argv[1]
    input_dir = sys.argv[2] if len(sys.argv) > 2 else "in"
    crashes_dir = sys.argv[3] if len(sys.argv) > 3 else "out/default/crashes"
    uses_argv_file = sys.argv[4] == "1" if len(sys.argv) > 4 else False
    csv_output = "mutation_report.csv"
    if not os.path.exists(c_file):
        print(f"[-] Error: Target file {c_file} not found.")
        sys.exit(1)
    seed_files = [f for f in glob.glob(f"{input_dir}/*") if os.path.isfile(f)]
    crash_files = [f for f in glob.glob(f"{crashes_dir}/id*") if os.path.isfile(f)]
    queue_files = [f for f in glob.glob("out/default/queue/id*") if os.path.isfile(f)]
    max_test_files = int(os.environ.get("MAX_TEST_FILES", "0") or 0)
    original_queue_count = len(queue_files)
    if max_test_files > 0 and len(queue_files) > max_test_files:
        # Keep it deterministic (seed=7) and spread across the queue instead
        # of pure random, so we don't accidentally keep only near-duplicate
        # early inputs -- evenly-spaced indices sample the whole run.
        step = len(queue_files) / max_test_files
        queue_files = [queue_files[int(i * step)] for i in range(max_test_files)]
    # Seeds and crash inputs are always kept in full -- they're few in number
    # and crashes in particular are the most valuable mutation-killers.
    test_files = seed_files + crash_files + queue_files
    if max_test_files > 0 and original_queue_count > max_test_files:
        print(f"[+] Queue had {original_queue_count} files -- sampled down to {len(queue_files)} "
              f"(+{len(seed_files)} seeds, +{len(crash_files)} crashes) for speed. "
              f"Set MAX_TEST_FILES=0 to use all.")
    with open(c_file, 'r') as f:
        original_code = f.read()
    code_mask = build_code_mask(original_code)
    skipped_in_literals = 0
    mutations = [
        (r'==', '!='), (r'!=', '=='), (r'&&', '||'), (r'\|\|', '&&'),
        (r'\+', '-'), (r'-', '+'), (r'\*', '/'), (r'/', '*'),
        (r'<', '>='), (r'>', '<='), (r'<=', '>'), (r'>=', '<'),
    ]
    print(f"\n[+] Starting Fast Parallel Expert Mutation Testing on: {c_file}")
    print(f"[+] Loaded {len(test_files)} test inputs. Input mode: {'file argument' if uses_argv_file else 'stdin'}")
    print("[+] Generating mutant tasks...")
    # Two passes on purpose: first collect only lightweight (pattern, repl,
    # start, end) candidates -- NOT the mutated source text -- so that a
    # large file with tens of thousands of match sites doesn't blow up
    # memory just to build the candidate list. We apply MAX_MUTANTS
    # sampling on these lightweight candidates first, and only then
    # materialize the (potentially large) mutated_code string for the
    # subset we actually kept. Without this ordering, a ~500KB source
    # file with ~24k candidate mutants would try to hold ~24k full-size
    # mutated copies (~12GB) in memory before the cap ever got a chance
    # to apply, and the process would be OOM-killed.
    candidates = []
    for pattern, repl in mutations:
        matches = list(re.finditer(pattern, original_code))
        for match in matches:
            start, end = match.span()
            if any(code_mask[start:end]):
                skipped_in_literals += 1
                continue
            candidates.append((pattern, repl, start, end))
    mutant_count = len(candidates)
    if mutant_count == 0:
        print("[-] No mutants generated.")
        return
    max_mutants = int(os.environ.get("MAX_MUTANTS", "0") or 0)
    if max_mutants > 0 and len(candidates) > max_mutants:
        import random
        random.seed(42)
        candidates = random.sample(candidates, max_mutants)
        mutant_count = len(candidates)
        print(f"[!] Large mutant set -- sampling down to {max_mutants} mutants for speed (set MAX_MUTANTS=0 to disable).")
    print(f"[+] Total Mutants to test: {mutant_count}")
    tasks = []
    for i, (pattern, repl, start, end) in enumerate(candidates, start=1):
        mutated_code = original_code[:start] + repl + original_code[end:]
        tasks.append((i, pattern, repl, mutated_code, test_files, uses_argv_file))
    print(f"[+] Executing in parallel using {cpu_count()} CPU cores...\n")
    with Pool() as pool:
        detailed_results = pool.map(evaluate_mutant, tasks)
    killed_mutants = sum(1 for r in detailed_results if "Killed" in r["Status"])
    survived_mutants = sum(1 for r in detailed_results if r["Status"] == "Survived")
    score = (killed_mutants / mutant_count) * 100
    detailed_results.sort(key=lambda x: x["Mutant_ID"])
    with open(csv_output, 'w', newline='') as csvfile:
        fieldnames = ["Mutant_ID", "Operator", "Status"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for row in detailed_results:
            writer.writerow(row)
    print("=" * 45)
    print(f" EXPERT MUTATION TESTING SUMMARY (PARALLEL)")
    print("=" * 45)
    print(f" TOTAL MUTANTS GENERATED : {mutant_count}")
    print(f" KILLED MUTANTS          : {killed_mutants}")
    print(f" SURVIVED MUTANTS        : {survived_mutants}")
    print(f" SKIPPED (in string/comment): {skipped_in_literals}")
    print(f" MUTATION SCORE          : {score:.2f}%")
    print("=" * 45)
    print(f"[+] Detailed report successfully saved to {csv_output}\n")

if __name__ == "__main__":
    main()
PYEOF_MUTATION

cat > "$STMT_PY" << 'PYEOF_STMT'
import sys

def build_code_mask(code):
    mask = [False] * len(code)
    i, n = 0, len(code)
    state = None
    while i < n:
        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line_comment'; mask[i] = mask[i + 1] = True; i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block_comment'; mask[i] = mask[i + 1] = True; i += 2; continue
            if c == '"':
                state = 'string'; mask[i] = True; i += 1; continue
            if c == "'":
                state = 'char'; mask[i] = True; i += 1; continue
            i += 1; continue
        if state == 'line_comment':
            mask[i] = True
            if c == '\n': state = None
            i += 1; continue
        if state == 'block_comment':
            mask[i] = True
            if c == '*' and nxt == '/':
                mask[i + 1] = True; i += 2; state = None; continue
            i += 1; continue
        if state in ('string', 'char'):
            mask[i] = True
            if c == '\\' and i + 1 < n:
                mask[i + 1] = True; i += 2; continue
            if (state == 'string' and c == '"') or (state == 'char' and c == "'"):
                state = None
            i += 1; continue
    return mask

def strip_masked(code, mask):
    return ''.join((c if c == '\n' else ' ') if m else c for c, m in zip(code, mask))

def remove_paren_content(s):
    out = []
    depth = 0
    for ch in s:
        if ch == '(':
            depth += 1; out.append(' ')
        elif ch == ')':
            depth = max(0, depth - 1); out.append(' ')
        elif depth > 0:
            out.append(ch if ch == '\n' else ' ')
        else:
            out.append(ch)
    return ''.join(out)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 check_statements.py <path_to_c_file>")
        sys.exit(1)
    path = sys.argv[1]
    with open(path, 'r') as f:
        code = f.read()
    mask = build_code_mask(code)
    stripped = strip_masked(code, mask)
    no_parens = remove_paren_content(stripped)
    flagged = []
    for lineno, line in enumerate(no_parens.split('\n'), start=1):
        semis = line.count(';')
        if semis > 1:
            flagged.append((lineno, semis))
    if flagged:
        print("MULTI_STATEMENT_LINES:")
        for lineno, count in flagged:
            print(f"  line {lineno}: {count} statement-terminators on one line")
        print("-> Statement Coverage may differ from Line Coverage here; review manually.")
    else:
        print("OK: no multi-statement lines detected; Statement Coverage == Line Coverage is safe here.")

if __name__ == "__main__":
    main()
PYEOF_STMT

cat > "$SEED_PY" << 'PYEOF_SEED'
import sys, os, re, struct, random

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 gen_seeds.py <c_file> <in_dir> [dict_out] [num_seeds]")
        sys.exit(1)
    c_file = sys.argv[1]
    in_dir = sys.argv[2]
    dict_out = sys.argv[3] if len(sys.argv) > 3 else None
    num_seeds = int(sys.argv[4]) if len(sys.argv) > 4 else 8

    with open(c_file) as f:
        code = f.read()

    bound_m = re.search(r'#define\s+BOUND\s+(\d+)', code)
    bound = int(bound_m.group(1)) if bound_m else 4

    alpha_m = re.search(r'int\s+inputs\[\]\s*=\s*\{([^}]*)\}', code)
    if alpha_m:
        alphabet = [int(x.strip()) for x in alpha_m.group(1).split(',') if x.strip()]
    else:
        vals = set(int(x) for x in re.findall(r'input\s*==\s*(-?\d+)', code))
        alphabet = sorted(vals) if vals else [1, 2, 3, 4, 5, 6]

    if not alphabet:
        print("[!] Could not detect input alphabet -- skipping custom seed generation.")
        sys.exit(0)

    os.makedirs(in_dir, exist_ok=True)

    # Seed 0: the program's own declared inputs[] sequence, padded/truncated to BOUND
    seq = (alphabet * ((bound // max(1, len(alphabet))) + 1))[:bound]
    with open(os.path.join(in_dir, "seed_default.bin"), "wb") as f:
        for v in seq:
            f.write(struct.pack('i', v))

    random.seed(1234)
    for i in range(num_seeds):
        seq = [random.choice(alphabet) for _ in range(bound)]
        with open(os.path.join(in_dir, f"seed_{i}.bin"), "wb") as f:
            for v in seq:
                f.write(struct.pack('i', v))

    if dict_out:
        with open(dict_out, "w") as f:
            for v in alphabet:
                packed = struct.pack('i', v)
                escaped = ''.join('\\x%02x' % b for b in packed)
                f.write(f'"{escaped}"\n')

    print(f"[+] Generated {num_seeds + 1} structured seed(s) for alphabet {alphabet} (BOUND={bound}) in {in_dir}")
    if dict_out:
        print(f"[+] Wrote AFL dictionary: {dict_out}")

if __name__ == "__main__":
    main()
PYEOF_SEED

# ---------------------------------------------------------------------------
# Bash helpers
# ---------------------------------------------------------------------------
die() { echo "[-] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" &>/dev/null || die "Required tool '$1' not found in PATH."; }

require_cmd gcc
require_cmd afl-fuzz
require_cmd gcov
require_cmd /usr/bin/time
command -v bc &>/dev/null || die "'bc' is required for timing math."
if [ "$PREBUILT" != "1" ]; then
    require_cmd afl-clang-fast
fi

detect_type() {
    local path="$1"
    if echo "$path" | grep -qi "RERS"; then echo "RERS"
    elif echo "$path" | grep -qi "SLR"; then echo "SLR"
    elif echo "$path" | grep -Eqi "coreutils|corutils"; then echo "coreutils"
    else echo "Unknown"
    fi
}

# Converts a duration like "30s", "10m", "2h", or a plain number of seconds
# into an integer number of seconds.
parse_duration_seconds() {
    local s="$1"
    if [[ "$s" =~ ^([0-9]+)s$ ]]; then echo "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$s" =~ ^([0-9]+)h$ ]]; then echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$s" =~ ^([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"
    else echo 600
    fi
}

# Runs a command with RAM+GPU monitoring, logged to resource_usage_report.csv
# in the CURRENT directory. Does NOT capture the command's own stdout/stderr,
# so interactive programs (like afl-fuzz) keep their normal terminal UI.
run_with_monitoring() {
    local cmd_desc="$1"; shift
    local -a cmd=("$@")
    local log_file="resource_usage_report.csv"
    [ -f "$log_file" ] || echo "Timestamp,Command,Execution_Time_Sec,Max_RSS_KB,Avg_GPU_Memory_MB,Avg_GPU_Utilization_Pct" > "$log_file"

    echo "[-] Monitoring execution for: $cmd_desc"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local gpu_log="temp_gpu_metrics.txt"
    local metrics_file="temp_metrics.txt"
    : > "$gpu_log"

    local gpu_pid=""
    if command -v nvidia-smi &>/dev/null; then
        ( while true; do
              nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits >> "$gpu_log"
              sleep 1
          done ) &
        gpu_pid=$!
        disown "$gpu_pid" 2>/dev/null
    fi

    local start_time end_time duration exit_code
    start_time=$(date +%s.%N)
    /usr/bin/time -v -o "$metrics_file" "${cmd[@]}"
    exit_code=$?
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)

    if [ -n "$gpu_pid" ]; then
        kill "$gpu_pid" 2>/dev/null
        wait "$gpu_pid" 2>/dev/null
    fi

    local max_ram avg_gpu_mem avg_gpu_util
    max_ram=$(grep "Maximum resident set size" "$metrics_file" 2>/dev/null | awk '{print $6}')
    [ -z "$max_ram" ] && max_ram="N/A"
    avg_gpu_mem="N/A"; avg_gpu_util="N/A"
    if [ -s "$gpu_log" ]; then
        avg_gpu_mem=$(awk -F',' '{sum+=$1} END {if (NR>0) print sum/NR; else print "N/A"}' "$gpu_log")
        avg_gpu_util=$(awk -F',' '{sum+=$2} END {if (NR>0) print sum/NR; else print "N/A"}' "$gpu_log")
    fi

    echo "$timestamp,\"$cmd_desc\",$duration,$max_ram,$avg_gpu_mem,$avg_gpu_util" >> "$log_file"
    echo "[+] Completed: $cmd_desc (exit code $exit_code)"
    echo "    Time        : ${duration}s"
    echo "    Peak RAM    : ${max_ram} KB"
    echo "    Avg GPU Mem : ${avg_gpu_mem} MB"
    echo "    Avg GPU Util: ${avg_gpu_util}%"

    rm -f "$metrics_file" "$gpu_log"
    return $exit_code
}

# ---------------------------------------------------------------------------
# Master CSV header
# ---------------------------------------------------------------------------
if [ ! -f "$MASTER_CSV" ]; then
    echo "Name of the Program,Type of Benchmarks,Time frame(in second),Line Coverage,Branch coverage,Mutation Score,Statement Coverage,Test Cases" > "$MASTER_CSV"
fi

mapfile -t C_FILES < <(find "$ROOT_DIR" -type f -name "*.c" ! -name "mutant_*.c" | sort)
if [ "${#C_FILES[@]}" -eq 0 ]; then
    echo "No .c files found under $ROOT_DIR"
    exit 1
fi
echo "[+] Found ${#C_FILES[@]} program(s) under $ROOT_DIR. TIME_LIMIT=$TIME_LIMIT"

# ---------------------------------------------------------------------------
# Main loop -- one program at a time
# ---------------------------------------------------------------------------
for c_path in "${C_FILES[@]}"; do
    dir=$(cd "$(dirname "$c_path")" && pwd)
    base=$(basename "$c_path" .c)
    btype=$(detect_type "$dir")
    C_FILE="${base}.c"
    AFL_BIN="${base}_afl"
    COV_BIN="${base}_cov"

    # Does this program actually read from a file path passed as argv[1],
    # or does it only ever read from stdin? Passing "@@" (file-arg mode) to
    # a stdin-only program means AFL's mutated input is silently ignored --
    # the program just reads empty/closed stdin every single run, which
    # explains near-zero corpus growth AND zero coverage on replay.
    uses_argv_file=0
    if grep -qE 'argv\[1\]' "$C_FILE"; then
        uses_argv_file=1
    fi

    echo ""
    echo "################################################################"
    echo "[+] Program: $base   (type: $btype)   folder: $dir"
    echo "[+] Input mode: $([ "$uses_argv_file" = "1" ] && echo "file argument (@@)" || echo "stdin only")"
    echo "################################################################"

    pushd "$dir" > /dev/null || continue

    # --- seed input + config.h ---
    [ -f "config.h" ] || touch config.h
    if [ ! -d "in" ] || [ -z "$(ls -A in 2>/dev/null)" ]; then
        mkdir -p in
        echo "Default seed input line 1" > in/seed.txt
        echo "Default seed input line 2" >> in/seed.txt
    fi

    # --- RERS-style "read raw ints from stdin" programs: replace the plain
    #     text seed with structured binary seeds + an AFL dictionary of the
    #     program's own valid input alphabet. This is what actually lets
    #     AFL make progress on these -- see the "odd, check syntax!" note. ---
    dict_opt=""
    if grep -qE 'fread\(&[A-Za-z_][A-Za-z0-9_]*,\s*sizeof\(int\)' "$C_FILE"; then
        echo "[+] Detected RERS-style int-stream input in $C_FILE -- generating structured seeds + dictionary"
        rm -f in/seed.txt
        dict_file="${base}.dict"
        python3 "$SEED_PY" "$C_FILE" "in" "$dict_file" 8
        [ -f "$dict_file" ] && dict_opt="-x $dict_file"
    fi


    # --- archive stale out/ so afl-fuzz doesn't silently resume ---
    if [ -d "out" ]; then
        archive="out_prev_$(date '+%Y%m%d_%H%M%S')"
        echo "[!] Existing out/ directory found - archiving to $archive"
        mv out "$archive"
    fi

    # --- compile ---
    build_ok=1
    if [ "$PREBUILT" = "1" ]; then
        echo "[+] PREBUILT=1 -- using existing $AFL_BIN / $COV_BIN"
        [ -x "$AFL_BIN" ] || { echo "[!] $AFL_BIN missing/not executable -- skipping."; build_ok=0; }
        [ -x "$COV_BIN" ] || { echo "[!] $COV_BIN missing/not executable -- skipping."; build_ok=0; }
    else
        if ! run_with_monitoring "Compile AFL++ binary" afl-clang-fast -O2 "$C_FILE" -o "$AFL_BIN" -I. $EXTRA_CFLAGS; then
            echo "[!] AFL++ compile failed for $C_FILE -- skipping this program."
            build_ok=0
        elif ! run_with_monitoring "Compile GCOV binary" gcc -fprofile-arcs -ftest-coverage -O0 "$C_FILE" -o "$COV_BIN" -I. $EXTRA_CFLAGS; then
            echo "[!] GCOV instrumented compile failed for $C_FILE -- skipping this program."
            build_ok=0
        fi
    fi
    if [ "$build_ok" -ne 1 ]; then
        popd > /dev/null
        continue
    fi

    # --- fuzz (NOT captured -- table shows live, exactly like a manual run) ---
    echo ""
    echo "[+] Starting $TIME_LIMIT AFL++ Fuzzing Session..."
    sleep 1
    limit_seconds=$(parse_duration_seconds "$TIME_LIMIT")
    run_with_monitoring "AFL++ Fuzzing Session ($TIME_LIMIT)" bash -c '
        limit_seconds='"$limit_seconds"'
        uses_argv_file='"$uses_argv_file"'
        start_epoch=$(date +%s)
        end_epoch=$((start_epoch + limit_seconds))

        if [ "$uses_argv_file" = "1" ]; then
            afl-fuzz -i in -o out -m none '"$dict_opt"' -- "./'"$AFL_BIN"'" @@ &
        else
            afl-fuzz -i in -o out -m none '"$dict_opt"' -- "./'"$AFL_BIN"'" &
        fi
        afl_pid=$!

        # Poll REAL wall-clock time (date +%s), not process runtime -- this
        # is what makes it strict: if the laptop was suspended and the
        # current real time is already past the deadline the moment we wake
        # up and get scheduled again, we kill immediately instead of giving
        # the fuzzer a fresh countdown.
        while kill -0 "$afl_pid" 2>/dev/null; do
            now_epoch=$(date +%s)
            if [ "$now_epoch" -ge "$end_epoch" ]; then
                kill -TERM "$afl_pid" 2>/dev/null
                sleep 2
                kill -KILL "$afl_pid" 2>/dev/null
                break
            fi
            sleep 0.5
        done
        wait "$afl_pid" 2>/dev/null
    '
    fuzz_exit=$?
    # 0/124/130/137/143 are all "stopped on schedule" outcomes (clean exit,
    # SIGTERM, SIGINT, SIGKILL, or old-style timeout code) -- not errors.
    case "$fuzz_exit" in
        0|124|130|137|143) : ;;
        *) echo "[!] afl-fuzz exited with unexpected code $fuzz_exit -- results below may be incomplete." ;;
    esac

    # --- export queue testcases ---
    echo "Testcase_ID,File_Name,File_Size_Bytes,Preview_Content" > "testcase_report.csv"
    if [ -d "out/default/queue" ]; then
        counter=1
        for f in out/default/queue/id*; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            fsize=$(stat -c%s "$f")
            fcontent=$(tr -d '\000\n\r' < "$f" | head -c 50 | sed 's/"/""/g')
            echo "$counter,$fname,$fsize,\"$fcontent\"" >> "testcase_report.csv"
            counter=$((counter + 1))
        done
        echo "[+] Exported $((counter - 1)) testcases to testcase_report.csv"
    fi

    # --- recompile + replay queue through gcov binary ---
    line_cov="N/A"; branch_cov="N/A"
    if [ -d "out/default/queue" ] && [ "$PREBUILT" != "1" ]; then
        rm -f ./*.gcda ./*.gcno
        if run_with_monitoring "Recompile GCOV binary" gcc -fprofile-arcs -ftest-coverage -O0 "$C_FILE" -o "$COV_BIN" -I. $EXTRA_CFLAGS; then
            queue_count=$(find out/default/queue -maxdepth 1 -type f -name 'id*' 2>/dev/null | wc -l)
            # 8s slack per file (5s soft timeout + kill grace + process overhead),
            # floor of 60s so tiny corpora still get a sane minimum window.
            overall_timeout=$(( queue_count * 8 + 30 ))
            [ "$overall_timeout" -lt 60 ] && overall_timeout=60
            run_with_monitoring "GCOV Queue Processing" timeout -k 5 "$overall_timeout" bash -c '
                uses_argv_file='"$uses_argv_file"'
                for f in out/default/queue/id*; do
                    [ -f "$f" ] || continue
                    if [ "$uses_argv_file" = "1" ]; then
                        timeout -k 2 5 "./'"$COV_BIN"'" "$f" > /dev/null 2>&1
                    else
                        timeout -k 2 5 "./'"$COV_BIN"'" < "$f" > /dev/null 2>&1
                    fi
                done
            '
            gcda_found=$(ls -1 -- *"${base}.gcda" 2>/dev/null | head -n1)
            gcno_found=$(ls -1 -- *"${base}.gcno" 2>/dev/null | head -n1)
            if [ -n "$gcda_found" ] && [ -n "$gcno_found" ]; then
                [ "$gcda_found" != "${base}.gcda" ] && mv -f "$gcda_found" "${base}.gcda"
                [ "$gcno_found" != "${base}.gcno" ] && mv -f "$gcno_found" "${base}.gcno"

                echo ""
                echo "=========================================="
                echo "             GCOV REPORT                  "
                echo "=========================================="
                # captured (not interactive, safe) purely to parse the %s below
                gcov_out=$(gcov -b "$C_FILE" 2>&1)
                echo "$gcov_out"
                line_cov=$(echo "$gcov_out" | grep -m1 "Lines executed" | grep -oP '\d+\.\d+(?=%)')
                branch_cov=$(echo "$gcov_out" | grep -m1 "Branches executed" | grep -oP '\d+\.\d+(?=%)')
                [ -z "$line_cov" ] && line_cov="N/A"
                [ -z "$branch_cov" ] && branch_cov="N/A"
            else
                echo "[!] Warning: no .gcda/.gcno found matching *${base} -- coverage not recorded."
            fi
        fi
    fi

    # --- time frame + test cases, from AFL's own fuzzer_stats ---
    time_frame="N/A"; test_cases="N/A"
    if [ -f "out/default/fuzzer_stats" ]; then
        tf=$(grep -m1 "^run_time" out/default/fuzzer_stats | awk -F':' '{print $2}' | tr -d ' ')
        tc=$(grep -m1 "^corpus_count" out/default/fuzzer_stats | awk -F':' '{print $2}' | tr -d ' ')
        [ -n "$tf" ] && time_frame="$tf"
        [ -n "$tc" ] && test_cases="$tc"
    fi

    # --- mutation testing ---
    echo ""
    echo "------------------------------------------------------------"
    echo "[+] AB MUTATION TESTING SHURU HO RAHI HAI: $base"
    echo "------------------------------------------------------------"
    mut_out=$(python3 "$MUTATION_PY" "$C_FILE" "in" "out/default/crashes" "$uses_argv_file" 2>&1)
    echo "$mut_out"
    mut_score=$(echo "$mut_out" | grep -m1 "MUTATION SCORE" | grep -oP '\d+\.\d+(?=%)')
    [ -z "$mut_score" ] && mut_score="N/A"
    echo "[+] MUTATION TESTING KHATAM: $base"

    # --- statement coverage sanity check ---
    stmt_cov="$line_cov"
    stmt_check=$(python3 "$STMT_PY" "$C_FILE" 2>&1)
    if echo "$stmt_check" | grep -q "MULTI_STATEMENT_LINES"; then
        echo "[!] $base: possible Line/Statement coverage mismatch --"
        echo "$stmt_check" | sed 's/^/    /'
    fi

    popd > /dev/null

    echo "\"$base\",\"$btype\",\"$time_frame\",\"$line_cov\",\"$branch_cov\",\"$mut_score\",\"$stmt_cov\",\"$test_cases\"" >> "$MASTER_CSV"
    echo "[+] Row added for $base."
done

echo ""
echo "================================================================"
echo "  [+] POORA PIPELINE COMPLETE. Full report saved to: $MASTER_CSV"
echo "================================================================"
echo ""
column -s, -t "$MASTER_CSV" 2>/dev/null || cat "$MASTER_CSV"