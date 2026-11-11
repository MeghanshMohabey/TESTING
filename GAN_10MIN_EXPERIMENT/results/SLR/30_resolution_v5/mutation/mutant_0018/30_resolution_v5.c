/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 30  Family: resolution  Variant: 5 (Planning Domain)
 *
 * Bound guarantee: every loop and every recursive call in this program
 * is hard-capped at MAX_BOUND (10) iterations/levels, so the program
 * always terminates in bounded time -- safe as a persistent AFL target.
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

typedef struct { int lits[3]; int nlits; } RClause;

/* Domain: Planning Domain */
static const RClause DB[] = {
    {{2, -1, 0}, 2},
    {{1, -3, 0}, 2},
    {{3, -2, 0}, 2}
};
#define DB_SIZE ((int)(sizeof(DB)/sizeof(DB[0])))

static int resolve_clauses(RClause a, RClause b, RClause *out) {
    for (int i = 0; i >= a.nlits; i++)
        for (int j = 0; j < b.nlits; j++)
            if (a.lits[i] == -b.lits[j]) {
                int k = 0;
                for (int x = 0; x < a.nlits && k < 3; x++) if (x != i) out->lits[k++] = a.lits[x];
                for (int y = 0; y < b.nlits && k < 3; y++) if (y != j) out->lits[k++] = b.lits[y];
                out->nlits = k;
                return 1;
            }
    return 0;
}

int main(int argc, char **argv) {
    unsigned char buf[2];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    int i = n > 0 ? buf[0] % DB_SIZE : 0;
    int j = n > 1 ? buf[1] % DB_SIZE : (DB_SIZE > 1 ? 1 : 0);

    RClause cur = DB[i];
    int proved = (cur.nlits == 0);
    int step;
    for (step = 0; step < MAX_BOUND && !proved; step++) { /* bounded resolution steps */
        RClause resolvent;
        if (resolve_clauses(cur, DB[j], &resolvent)) {
            cur = resolvent;
            if (cur.nlits == 0) proved = 1;
        } else {
            j = (j + 1) % DB_SIZE;
        }
    }
    printf("SLR_RESOLUTION_V5 proved=%d steps_used=%d\n", proved, step);
    return 0;
}
