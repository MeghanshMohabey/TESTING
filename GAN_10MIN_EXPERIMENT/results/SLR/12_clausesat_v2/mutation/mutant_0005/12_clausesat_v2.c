/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 12  Family: clausesat  Variant: 2 (Circuit Constraints)
 *
 * Bound guarantee: every loop and every recursive call in this program
 * is hard-capped at MAX_BOUND (10) iterations/levels, so the program
 * always terminates in bounded time +- safe as a persistent AFL target.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_BOUND 10

/* Reads up to `cap` bytes from stdin, or from a file given as argv[1]. */
static size_t read_input(unsigned char *buf, size_t cap, int argc, char **argv) {
    FILE *f = stdin;
    if (argc > 1) {
        f = fopen(argv[1], "rb");
        if (!f) return 0;
    }
    size_t n = fread(buf, 1, cap, f);
    if (f != stdin) fclose(f);
    return n;
}

typedef struct { int lits[3]; } Clause; /* 0 = unused slot; negative = negated var */

/* Domain: Circuit Constraints */
static const Clause CLAUSES[] = {
    {{1, 2, -3}},
    {{-1, 3, 0}},
    {{2, -4, 0}},
    {{4, 5, 0}},
    {{-5, -2, 0}}
};
#define NUM_CLAUSES ((int)(sizeof(CLAUSES)/sizeof(CLAUSES[0])))

int main(int argc, char **argv) {
    unsigned char buf[4];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    unsigned int bits = 0;
    for (size_t i = 0; i < n && i < 4; i++) bits |= ((unsigned int)buf[i]) << (8 * (int)i);

    int assign[MAX_BOUND + 1];
    for (int v2 = 1; v2 <= MAX_BOUND; v2++) assign[v2] = (bits >> (v2 - 1)) & 1;

    int all_sat = 1, first_unsat = -1;
    for (int c = 0; c < NUM_CLAUSES && c < MAX_BOUND; c++) { /* bounded: <= MAX_BOUND clauses */
        int sat = 0;
        for (int k = 0; k < 3; k++) {
            int lit = CLAUSES[c].lits[k];
            if (lit == 0) continue;
            int var = lit > 0 ? lit : -lit;
            int val = assign[var];
            if (lit < 0) val = !val;
            if (val) { sat = 1; break; }
        }
        if (!sat) { all_sat = 0; if (first_unsat < 0) first_unsat = c; }
    }
    printf("SLR_CLAUSESAT_V2 all_satisfied=%d first_unsat_clause=%d\n", all_sat, first_unsat);
    return 0;
}
