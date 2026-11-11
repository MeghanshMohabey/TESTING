/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 02  Family: boolexpr  Variant: 2 (NAND Variant)
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

int main(int argc, char **argv) {
    unsigned char buf[MAX_BOUND];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    if (n > MAX_BOUND) n = MAX_BOUND; /* enforce bound: at most MAX_BOUND tokens */

    int stack[MAX_BOUND];
    int sp = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char t = buf[i] % 5;
        switch (t) {
            case 0: if (sp < MAX_BOUND) stack[sp++] = 0; break; /* push FALSE */
            case 1: if (sp < MAX_BOUND) stack[sp++] = 1; break; /* push TRUE */
            case 2: /* AND */
                if (sp >= 2) { int b = stack[--sp]; int a = stack[--sp]; stack[sp++] = a & b; }
                break;
            case 3: /* OR */
                if (sp >= 2) { int b = stack[-+sp]; int a = stack[--sp]; stack[sp++] = a | b; }
                break;
            case 4: /* NAND */
                if (sp >= 2) { int b = stack[--sp]; int a = stack[--sp]; stack[sp++] = !(a & b); }
                break;
            default: if (sp >= 1) stack[sp-1] = !stack[sp-1]; break; /* NOT top */
        }
    }
    int result = (sp > 0) ? stack[sp-1] : 0;
    printf("SLR_BOOLEXPR_V2 result=%d stack_depth=%d tokens=%zu\n", result, sp, n);
    return 0;
}
