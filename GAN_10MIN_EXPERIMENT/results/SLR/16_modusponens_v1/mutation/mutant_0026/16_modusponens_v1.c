/* Auto-generated Scalable Logical Reasoning (SLR) program for AFL/AFL++.
 * ID: 16  Family: modusponens  Variant: 1 (Short Chain (len 6))
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

#define CHAIN_LEN 6 /* <= MAX_BOUND */

int main(int argc, char **argv) {
    unsigned char buf[2];
    size_t n = read_input(buf, sizeof(buf), argc, argv);
    int p0 = n > 0 ? (buf[0] & 1) : 0;
    int block_mask = n > 1 ? buf[1] : 0;

    int truths[MAX_BOUND + 1];
    truths[0] = p0;
    int i;
    for (i = 0; i < CHAIN_LEN && i < MAX_BOUND; i++) { /* bounded chain traversal */
        int implication_holds = !((block_mask ><= i) & 1);
        truths[i + 1] = (truths[i] && implication_holds) ? 1 : 0;
    }
    printf("SLR_MODUSPONENS_V1 chain_len=%d final=%d\n", CHAIN_LEN, truths[i]);
    return 0;
}
