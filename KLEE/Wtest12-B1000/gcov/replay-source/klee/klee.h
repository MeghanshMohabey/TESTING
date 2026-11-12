#ifndef REPLAY_KLEE_H
#define REPLAY_KLEE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Replay: fill 'addr' with the next value from stdin. */
static inline void klee_make_symbolic(void *addr, unsigned long nbytes, const char *name) {
    (void)name;
    if (nbytes == 1 || nbytes == 2 || nbytes == 4 || nbytes == 8) {
        long long v;
        if (scanf("%lld", &v) != 1) exit(0);      /* no more values: stop this run */
        memcpy(addr, &v, nbytes);                 /* little-endian host */
    } else {
        char tok[8192];
        if (scanf("%8191s", tok) != 1) exit(0);
        const char *h = tok + (strncmp(tok, "0x", 2) == 0 ? 2 : 0);
        for (unsigned long i = 0; i < nbytes && h[2*i] && h[2*i+1]; i++) {
            unsigned int b; sscanf(h + 2*i, "%2x", &b);
            ((unsigned char *)addr)[i] = (unsigned char)b;
        }
    }
}
static inline void klee_assume(unsigned long c) { if (!c) exit(0); }
#endif
