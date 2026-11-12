#!/bin/bash

echo "=========================================="
echo "    AUTOMATED MUTATION TESTING REPORT     "
echo "=========================================="

echo "[+] Generating Mutants from 01_cat.c..."

sed 's/optind >= argc/optind > argc/g' 01_cat.c > m1.c
sed 's/line_number++/line_number--/g' 01_cat.c > m2.c
sed 's/pending_blank = false/pending_blank = true/g' 01_cat.c > m3.c
sed 's/case '\''b'\'': number_nonblank = true; break;/case '\''b'\'': number_nonblank = true; return 0;/g' 01_cat.c > m4.c

gcc m1.c -o cat_m1 2>/dev/null
gcc m2.c -o cat_m2 2>/dev/null
gcc m3.c -o cat_m3 2>/dev/null
gcc m4.c -o cat_m4 2>/dev/null

total_mutants=4
killed=0

echo "[+] Replaying AFL++ Queue against Mutants..."
echo "------------------------------------------"

for i in $(seq 1 $total_mutants); do
    is_killed=0
    for f in out/default/queue/id*; do
        ./cat_cov -n "$f" > out_orig.tmp 2>&1
        ./cat_m$i -n "$f" > out_mut.tmp 2>&1

        if ! cmp -s out_orig.tmp out_mut.tmp; then
            is_killed=1
            break
        fi
    done

    if [ $is_killed -eq 1 ]; then
        echo "Mutant $i: KILLED"
        ((killed++))
    else
        echo "Mutant $i: SURVIVED"
    fi
done

rm -f m1.c m2.c m3.c m4.c cat_m1 cat_m2 cat_m3 cat_m4 out_orig.tmp out_mut.tmp

score=$(awk "BEGIN {print ($killed / $total_mutants) * 100}")

echo "=========================================="
echo "           FINAL SCORE METRICS            "
echo "=========================================="
echo "Total Mutants Generated : $total_mutants"
echo "Killed Mutants          : $killed"
echo "Survived Mutants        : $((total_mutants - killed))"
echo "Mutation Score          : $score%"
echo "=========================================="
