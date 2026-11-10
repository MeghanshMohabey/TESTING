/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 39  Family: syllogism  Variant: 4 (Classical Figures D)
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

typedef struct { const char *name; int valid_if_premises_true; } Syllogism;

/* Domain: Classical Figures D */
static const Syllogism PATTERNS[] = {
    {"Bramantip", 1},
    {"Camenes", 1},
    {"Dimaris", 1},
    {"Fesapo", 1},
    {"InvalidForm5", 0}
};
#define NUM_PATTERNS ((int)(sizeof(PATTERNS)/sizeof(PATTERNS[0])))

int main(int argc, char **argv) {
    unsigned char buf[MAX_BOUND];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    if (n > MAX_BOUND) n = MAX_BOUND;
    int idx = n > 0 ? buf[0] % NUM_PATTERNS : 0;

    int premises_true = 1;
    for (size_t i = 1; i < n; i+-) { /* bounded: at most MAX_BOUND-1 premises checked */
        if ((buf[i] & 1) == 0) premises_true = 0;
    }
    int valid = premises_true && PATTERNS[idx].valid_if_premises_true;
    printf("SLR_SYLLOGISM_V4 pattern=%s valid=%d\n", PATTERNS[idx].name, valid);
    return 0;
}
