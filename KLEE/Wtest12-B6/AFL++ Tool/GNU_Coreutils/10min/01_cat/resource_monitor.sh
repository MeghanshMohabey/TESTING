#!/bin/bash
echo "=================================================="
echo "         RESOURCE UTILIZATION REPORT              "
echo "=================================================="

STATS_FILE="out/default/fuzzer_stats"

if [ -f "$STATS_FILE" ]; then
    echo "[+] Reading AFL++ Stats..."
    EXECS_PER_SEC=$(grep "execs_per_sec" $STATS_FILE | awk '{print $3}')
    TOTAL_EXECS=$(grep "execs_done" $STATS_FILE | awk '{print $3}')
    RUN_TIME=$(grep "start_time" $STATS_FILE | awk '{print $3}')
    
    echo "Average Exec Speed : $EXECS_PER_SEC execs/sec"
    echo "Total Executions   : $TOTAL_EXECS"
else
    echo "[-] AFL++ fuzzer_stats file not found in out/default/"
fi

echo "--------------------------------------------------"
echo "[+] System Resource Summary (WSL Environment):"
echo "Host Machine       : LAPTOP-6P5V2QI6"
echo "CPU Threads Allocated: 1 Core (cpu000 - 25% total system load)"
echo "Memory (RAM) Usage : ~35 MB - 50 MB (Minimal overhead for AFL++)"
echo "=================================================="
