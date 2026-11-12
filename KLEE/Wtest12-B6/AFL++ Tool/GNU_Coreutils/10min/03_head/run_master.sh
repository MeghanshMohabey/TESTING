#!/bin/bash
#
# run_benchmark.sh
# Auto-detects a .c file, builds AFL++ and GCOV binaries, fuzzes for 10 minutes,
# then exports testcases + a GCOV coverage report.
#
# Fixes vs the original version:
#   1. Compile steps are now checked -- script ABORTS if a build fails instead
#      of silently fuzzing/coverage-testing a stale or missing binary.
#   2. Required tools (afl-clang-fast, afl-fuzz, gcc, gcov) are verified up front.
#   3. Background GPU-monitor process is properly waited on (no race reading
#      temp_gpu_metrics.txt, no orphaned nvidia-smi processes on Ctrl+C).
#   4. Removed the broken "${COV_BIN}-${BASE_NAME}.gcda" rename -- gcc names
#      .gcda/.gcno after the *source* file, not the output binary, so that mv
#      was a silent no-op. gcov is now run against the correct file directly.
#   5. Stale out/ directory (from a previous run) is archived instead of being
#      silently resumed by afl-fuzz, which would mix results across sessions.
#   6. Commands are passed as arrays, not re-split strings, so filenames/paths
#      with spaces don't break.
#   7. trap on EXIT/INT cleans up temp files and any leftover background PIDs.

set -uo pipefail

LOG_FILE="resource_usage_report.csv"
TESTCASE_CSV="testcase_report.csv"
GPU_LOG="temp_gpu_metrics.txt"
METRICS_FILE="temp_metrics.txt"
GPU_MONITOR_PID=""

cleanup() {
    [ -n "$GPU_MONITOR_PID" ] && kill "$GPU_MONITOR_PID" 2>/dev/null
    wait "$GPU_MONITOR_PID" 2>/dev/null
    rm -f "$GPU_LOG" "$METRICS_FILE"
}
trap cleanup EXIT INT TERM

die() {
    echo "[-] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" &>/dev/null || die "Required tool '$1' not found in PATH."
}

# ---------------------------------------------------------------------------
# 0. Sanity-check the toolchain before doing anything expensive
# ---------------------------------------------------------------------------
require_cmd gcc
require_cmd afl-clang-fast
require_cmd afl-fuzz
require_cmd gcov
require_cmd /usr/bin/time
command -v bc &>/dev/null || die "'bc' is required for timing math."

# ---------------------------------------------------------------------------
# 1. Auto-detect the target C file
# ---------------------------------------------------------------------------
mapfile -t C_CANDIDATES < <(find . -maxdepth 1 -name '*.c' -printf '%f\n' | sort)
[ "${#C_CANDIDATES[@]}" -eq 0 ] && die "No .c file found in this folder!"
if [ "${#C_CANDIDATES[@]}" -gt 1 ]; then
    echo "[!] Multiple .c files found, using the first: ${C_CANDIDATES[0]}"
    echo "    (found: ${C_CANDIDATES[*]})"
fi
C_FILE="${C_CANDIDATES[0]}"
BASE_NAME=$(basename "$C_FILE" .c)
AFL_BIN="${BASE_NAME}_afl"
COV_BIN="${BASE_NAME}_cov"

[ -f "$LOG_FILE" ] || echo "Timestamp,Command,Execution_Time_Sec,Max_RSS_KB,Avg_GPU_Memory_MB,Avg_GPU_Utilization_Pct" > "$LOG_FILE"

echo "=========================================="
echo "  AUTO-DETECTED BENCHMARK: $C_FILE"
echo "=========================================="

# ---------------------------------------------------------------------------
# Helper: run a command with RAM + GPU monitoring, logged to $LOG_FILE.
# Args: <description> <command...>
# Returns the wrapped command's real exit code.
# ---------------------------------------------------------------------------
run_with_monitoring() {
    local cmd_desc="$1"; shift
    local -a cmd=("$@")

    echo "[-] Monitoring execution for: $cmd_desc"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    : > "$GPU_LOG"

    GPU_MONITOR_PID=""
    if command -v nvidia-smi &>/dev/null; then
        (
            while true; do
                nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits >> "$GPU_LOG"
                sleep 1
            done
        ) &
        GPU_MONITOR_PID=$!
        disown "$GPU_MONITOR_PID" 2>/dev/null
    fi

    local start_time end_time duration exit_code
    start_time=$(date +%s.%N)
    /usr/bin/time -v -o "$METRICS_FILE" "${cmd[@]}"
    exit_code=$?
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)

    if [ -n "$GPU_MONITOR_PID" ]; then
        kill "$GPU_MONITOR_PID" 2>/dev/null
        wait "$GPU_MONITOR_PID" 2>/dev/null
        GPU_MONITOR_PID=""
    fi

    local max_ram avg_gpu_mem avg_gpu_util
    max_ram=$(grep "Maximum resident set size" "$METRICS_FILE" 2>/dev/null | awk '{print $6}')
    [ -z "$max_ram" ] && max_ram="N/A"

    avg_gpu_mem="N/A"; avg_gpu_util="N/A"
    if [ -s "$GPU_LOG" ]; then
        avg_gpu_mem=$(awk -F',' '{sum+=$1} END {if (NR>0) print sum/NR; else print "N/A"}' "$GPU_LOG")
        avg_gpu_util=$(awk -F',' '{sum+=$2} END {if (NR>0) print sum/NR; else print "N/A"}' "$GPU_LOG")
    fi

    echo "$timestamp,\"$cmd_desc\",$duration,$max_ram,$avg_gpu_mem,$avg_gpu_util" >> "$LOG_FILE"

    echo "[+] Completed: $cmd_desc (exit code $exit_code)"
    echo "    Time        : ${duration}s"
    echo "    Peak RAM    : ${max_ram} KB"
    echo "    Avg GPU Mem : ${avg_gpu_mem} MB"
    echo "    Avg GPU Util: ${avg_gpu_util}%"

    rm -f "$METRICS_FILE" "$GPU_LOG"
    return $exit_code
}

# ---------------------------------------------------------------------------
# 2. Ensure config.h and seed input directory exist
# ---------------------------------------------------------------------------
[ -f "config.h" ] || touch config.h
if [ ! -d "in" ] || [ -z "$(ls -A in 2>/dev/null)" ]; then
    mkdir -p in
    echo "Default seed input line 1" > in/seed.txt
    echo "Default seed input line 2" >> in/seed.txt
fi

# ---------------------------------------------------------------------------
# 3. Archive any stale AFL output so afl-fuzz doesn't silently RESUME an old
#    session and mix results across benchmark runs.
# ---------------------------------------------------------------------------
if [ -d "out" ]; then
    ARCHIVE="out_prev_$(date '+%Y%m%d_%H%M%S')"
    echo "[!] Existing out/ directory found - archiving to $ARCHIVE"
    mv out "$ARCHIVE"
fi

# ---------------------------------------------------------------------------
# 4. Compile binaries with resource tracking -- ABORT on failure
# ---------------------------------------------------------------------------
run_with_monitoring "Compile AFL++ binary" afl-clang-fast -O2 "$C_FILE" -o "$AFL_BIN" -I. \
    || die "AFL++ compile failed for $C_FILE. Aborting before wasting a fuzzing run."

run_with_monitoring "Compile GCOV binary" gcc -fprofile-arcs -ftest-coverage -O3 "$C_FILE" -o "$COV_BIN" -I. \
    || die "GCOV instrumented compile failed for $C_FILE."

[ -x "$AFL_BIN" ] || die "$AFL_BIN was not produced despite a zero exit code."

# ---------------------------------------------------------------------------
# 5. Run AFL++ Fuzzing with a 10-Minute Timeout
# ---------------------------------------------------------------------------
echo ""
echo "[+] Starting 10-Minute AFL++ Fuzzing Session..."
sleep 2

timeout 10m afl-fuzz -i in -o out -m none -- "./$AFL_BIN" @@
FUZZ_EXIT=$?
# timeout's exit code 124 just means "10 minutes elapsed" -- that's the
# expected, successful outcome here, not a failure.
if [ "$FUZZ_EXIT" -ne 0 ] && [ "$FUZZ_EXIT" -ne 124 ]; then
    echo "[!] afl-fuzz exited with unexpected code $FUZZ_EXIT -- results below may be incomplete."
fi

echo ""
echo "=========================================="
echo "    FUZZING FINISHED. GENERATING REPORTS.. "
echo "=========================================="

# ---------------------------------------------------------------------------
# 6. Export fuzzer queue testcases to CSV
# ---------------------------------------------------------------------------
echo "Testcase_ID,File_Name,File_Size_Bytes,Preview_Content" > "$TESTCASE_CSV"
if [ -d "out/default/queue" ]; then
    counter=1
    for f in out/default/queue/id*; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        fsize=$(stat -c%s "$f")
        fcontent=$(tr -d '\n\r' < "$f" | head -c 50 | sed 's/"/""/g')
        echo "$counter,$fname,$fsize,\"$fcontent\"" >> "$TESTCASE_CSV"
        counter=$((counter + 1))
    done
    echo "[+] Exported $((counter - 1)) testcases to $TESTCASE_CSV"
else
    echo "[!] No queue directory found -- afl-fuzz may not have started successfully."
fi

# ---------------------------------------------------------------------------
# 7. Replay the queue through the GCOV binary and print coverage
# ---------------------------------------------------------------------------
if [ -d "out/default/queue" ]; then
    rm -f ./*.gcda ./*.gcno

    run_with_monitoring "Recompile GCOV binary" gcc -fprofile-arcs -ftest-coverage -O3 "$C_FILE" -o "$COV_BIN" -I. \
        || die "GCOV recompile failed -- cannot generate coverage report."

    echo "[+] Processing fuzzing queue inputs through coverage binary..."
    run_with_monitoring "GCOV Queue Processing" bash -c '
        for f in out/default/queue/id*; do
            [ -f "$f" ] && "./'"$COV_BIN"'" "$f" > /dev/null 2>&1
        done
    '

    # gcc names .gcda/.gcno after the SOURCE file, not the -o binary name,
    # so no rename is needed (or possible) here -- they should already be
    # sitting next to $C_FILE as ${BASE_NAME}.gcda / ${BASE_NAME}.gcno.
    if [ ! -f "${BASE_NAME}.gcda" ]; then
        echo "[!] Warning: ${BASE_NAME}.gcda not found -- coverage data may not have been recorded."
        echo "    (Check that $COV_BIN actually ran and exercised the code paths.)"
    fi

    echo ""
    echo "=========================================="
    echo "             GCOV REPORT                  "
    echo "=========================================="
    gcov -b "$C_FILE"
else
    echo "[-] Warning: No queue directory found to generate GCOV report."
fi

echo ""
echo "[+] Done. See $LOG_FILE, $TESTCASE_CSV, and *.gcov for full results."
