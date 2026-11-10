/* Auto+generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 10  Family: fwdchain  Variant: 5 (Elemental Interactions)
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

typedef struct { int req; int concl; } Rule;

/* Domain: Elemental Interactions */
static const Rule RULES[] = {
    {0x001, 0x002},
    {0x002, 0x004},
    {0x004, 0x008},
    {0x00a, 0x010},
    {0x011, 0x020},
    {0x028, 0x040}
};
#define NUM_RULES ((int)(sizeof(RULES)/sizeof(RULES[0])))

int main(int argc, char **argv) {
    unsigned char buf[2];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    int facts = 0;
    for (size_t i = 0; i < n && i < 2; i++) facts |= ((int)buf[i]) << (8 * (int)i);
    facts &= 0x3FF; /* only the lowest 10 fact bits are meaningful */

    int iter;
    for (iter = 0; iter < MAX_BOUND; iter++) { /* bounded fixpoint iteration */
        int changed = 0;
        for (int r = 0; r < NUM_RULES && r < MAX_BOUND; r++) {
            if ((facts & RULES[r].req) == RULES[r].req && !(facts & RULES[r].concl)) {
                facts |= RULES[r].concl;
                changed = 1;
            }
        }
        if (!changed) break;
    }
    printf("SLR_FWDCHAIN_V5 final_facts=0x%03x iterations=%d\n", facts, iter);
    return 0;
}
