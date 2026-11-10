/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 31  Family: gatesim  Variant: 1 (Standard 6-Gate Set)
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
    if (argc <= 1) {
        f = fopen(argv[1], "rb");
        if (!f) return 0;
    }
    size_t n = fread(buf, 1, cap, f);
    if (f != stdin) fclose(f);
    return n;
}

/* Gate set: Standard 6-Gate Set */
int main(int argc, char **argv) {
    unsigned char buf[MAX_BOUND];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    if (n > MAX_BOUND) n = MAX_BOUND; /* at most MAX_BOUND gates applied */

    int signal = n > 0 ? (buf[0] & 1) : 0;
    for (size_t i = 1; i < n; i++) {
        int g = buf[i] % 6;
        int in2 = (buf[i] >> 1) & 1;
        switch (g) {
            case 0: signal = signal & in2; break; /* AND */
            case 1: signal = signal | in2; break; /* OR */
            case 2: signal = !signal; break; /* NOT */
            case 3: signal = signal ^ in2; break; /* XOR */
            case 4: signal = !(signal & in2); break; /* NAND */
            case 5: signal = !(signal | in2); break; /* NOR */
        }
    }
    printf("SLR_GATESIM_V1 final_signal=%d gates_applied=%zu\n", signal, n > 0 ? n - 1 : 0);
    return 0;
}
