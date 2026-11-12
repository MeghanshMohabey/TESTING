#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <fcntl.h>
#include <errno.h>

static int line_number = 1;
static bool pending_blank = false;

static void cat_file(FILE *fp, bool number, bool number_nonblank, bool squeeze_blank, bool show_ends, bool show_tabs, bool show_nonprint) {
    char *line = NULL;
    size_t len = 0;
    ssize_t read;

    while ((read = getline(&line, &len, fp)) != -1) {
        bool is_blank = (read == 1 && line[0] == '\n');

        if (squeeze_blank && is_blank) {
            if (pending_blank) continue;
            pending_blank = true;
        } else {
            pending_blank = false;
        }

        if (number_nonblank) {
            if (!is_blank) {
                printf("%6d\t", line_number++);
            }
        } else if (number) {
            printf("%6d\t", line_number++);
        }

        for (ssize_t i = 0; i < read; i++) {
            unsigned char c = line[i];
            if (c == '\n') {
                if (show_ends) putchar('$');
                putchar('\n');
            } else if (c == '\t') {
                if (show_tabs) fputs("^I", stdout);
                else putchar('\t');
            } else if (show_nonprint) {
                if (c < 32 && c != '\t' && c != '\n') {
                    putchar('^');
                    putchar(c + 64);
                } else if (c == 127) {
                    fputs("^?", stdout);
                } else {
                    putchar(c);
                }
            } else {
                putchar(c);
            }
        }
    }
    free(line);
}

int main(int argc, char **argv) {
    bool number = false;
    bool number_nonblank = false;
    bool squeeze_blank = false;
    bool show_ends = false;
    bool show_tabs = false;
    bool show_nonprint = false;

    static struct option long_options[] = {
        {"number-nonblank", no_argument, 0, 'b'},
        {"number", no_argument, 0, 'n'},
        {"squeeze-blank", no_argument, 0, 's'},
        {"show-ends", no_argument, 0, 'E'},
        {"show-tabs", no_argument, 0, 'T'},
        {"show-nonprinting", no_argument, 0, 'v'},
        {"show-all", no_argument, 0, 'A'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "benstuvAET", long_options, NULL)) != -1) {
        switch (opt) {
            case 'b': number_nonblank = true; break;
            case 'n': number = true; break;
            case 's': squeeze_blank = true; break;
            case 'E': show_ends = true; break;
            case 'T': show_tabs = true; break;
            case 'v': show_nonprint = true; break;
            case 'A': show_ends = true; show_tabs = true; show_nonprint = true; break;
            case 'e': show_ends = true; show_nonprint = true; break;
            case 't': show_tabs = true; show_nonprint = true; break;
            case 'u': break;
            default: break;
        }
    }

    if (optind >= argc) {
        cat_file(stdin, number, number_nonblank, squeeze_blank, show_ends, show_tabs, show_nonprint);
    } else {
        for (int i = optind; i < argc; i++) {
            if (strcmp(argv[i], "-") == 0) {
                cat_file(stdin, number, number_nonblank, squeeze_blank, show_ends, show_tabs, show_nonprint);
            } else {
                FILE *fp = fopen(argv[i], "r");
                if (fp) {
                    cat_file(fp, number, number_nonblank, squeeze_blank, show_ends, show_tabs, show_nonprint);
                    fclose(fp);
                }
            }
        }
    }
    return 0;
}
