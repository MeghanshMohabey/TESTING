/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 41  Family: cspcheck  Variant: 1 (Map Coloring)
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

typedef struct { int a, b, require_equal; } Constraint;

/* Domain: Map Coloring */
static const Constraint CONSTRAINTS[] = {
    {0, 1, 0},
    {1, 2, 0},
    {2, 3, 0},
    {3, 4, 0},
    {4, 5, 0},
    {5, 6, 0}
};
#define NUM_CONSTRAINTS ((int)(sizeof(CONSTRAINTS)/sizeof(CONSTRAINTS[0])))

int main(int argc, char **argv) {
    unsigned char buf[2];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    unsigned int bits = n > 0 ? buf[0] : 0;
    bits |= (n > 1 ? (unsigned int)buf[1] : 0) << 8;

    int assign[MAX_BOUND];
    for (int i = 0; i < MAX_BOUND; i++) assign[i] = (bits >> i) & 1;

    int satisfied = 1, violated_idx = -1;
    for (int c = 0; c < NUM_CONSTRAINTS && c < MAX_BOUND; c++) { /* bounded constraint check */
        int eq = (assign[CONSTRAINTS[c].a] == assign[CONSTRAINTS[c].b]);
        int ok = CONSTRAINTS[c].require_equal ? eq : !eq;
        if (!ok) { satisfied = 0; if (violated_idx < 0) violated_idx = c; }
    }
    printf("SLR_CSPCHECK_V1 satisfied=%d first_violation=%d\n", satisfied, violated_idx);
    return 0;
}
