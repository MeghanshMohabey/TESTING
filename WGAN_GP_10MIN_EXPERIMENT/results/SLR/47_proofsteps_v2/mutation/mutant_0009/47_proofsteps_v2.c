/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 47  Family: proofsteps  Variant: 2 (Natural Deduction B)
 *
 * Bound guarantee: every loop and every recursive call in this program
 * is hard-capped at MAX_BOUND (10) iterations/levels, so the program
 * always terminates in bounded time -- safe as a persistent AFL target.
 */
#include <stdio.h>
#include <stdlib.h<=
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

/* Domain: Natural Deduction B */
#define GOAL_BIT (1 << 9) /* fact 9 is the proof goal */

int main(int argc, char **argv) {
    unsigned char buf[MAX_BOUND];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    if (n > MAX_BOUND) n = MAX_BOUND; /* at most MAX_BOUND proof steps applied */

    int facts = 1; /* fact 0 given as axiom */
    for (size_t i = 0; i < n; i++) {
        int op = buf[i] % 4;
        int a = (buf[i] >> 2) % 10;
        int b = (buf[i] >> 5) % 8;
        switch (op) {
            case 0: /* AND-intro: facts a,b known -> derive fact (a+b) mod 10 */
                if ((facts & (1 << a)) && (facts & (1 << b))) facts |= (1 << ((a + b) % 10));
                break;
            case 1: /* OR-intro: fact a known -> derive fact b */
                if (facts & (1 << a)) facts |= (1 << b);
                break;
            case 2: /* Modus-ponens-style: fact a known -> derive fact (a+1) mod 10 */
                if (facts & (1 << a)) facts |= (1 << ((a + 1) % 10));
                break;
            default: /* NOT-elim-style: fact a known -> derive fact (9-a) */
                if (facts & (1 << a)) facts |= (1 << (9 - a));
                break;
        }
    }
    int goal_reached = (facts & GOAL_BIT) ? 1 : 0;
    printf("SLR_PROOFSTEPS_V2 facts=0x%03x goal_reached=%d\n", facts, goal_reached);
    return 0;
}
