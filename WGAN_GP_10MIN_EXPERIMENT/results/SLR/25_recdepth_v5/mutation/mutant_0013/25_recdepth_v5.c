/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 25  Family: recdepth  Variant: 5 (Mixed Tree)
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

/* Mode: Mixed Tree */
static int evaluate(const unsigned char *buf, size_t n, size_t *pos, int depth) {
    if (depth >= MAX_BOUND || *pos >= n) return 0; /* base case: recursion bound reached */
    unsigned char b = buf[(*pos)++];
    unsigned char kind = b % 3;
    if (kind == 0) {
        return b & 1; /* leaf literal */
    } else if (kind == 1) {
        int a = evaluate(buf, n, pos, depth + 1);
        return !a; /* NOT */
    } else {
        int a = evaluate(buf, n, pos, depth + 1);
        int c = evaluate(buf, n, pos, depth + 1);
        return (a & c) | (a ^ c);
    }
}

int main(int argc, char **argv) {
    unsigned char buf[32];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    size_t pos = 0;
    int result = evaluate(buf, n, &pos, 0); /* recursion never exceeds MAX_BOUND levels */
    printf("SLR_RECDEPTH_V5 result=%d consumed=%zu\n", result, pos);
    return 0;
}
