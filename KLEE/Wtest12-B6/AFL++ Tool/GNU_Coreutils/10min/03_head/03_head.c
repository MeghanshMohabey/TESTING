#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>

static void head_file(FILE *fp, long n_lines) {
    char *line = NULL;
    size_t len = 0;
    long count = 0;

    while (count < n_lines && getline(&line, &len, fp) != -1) {
        fputs(line, stdout);
        count++;
    }
    free(line);
}

int main(int argc, char **argv) {
    long n_lines = 10;
    int opt;

    while ((opt = getopt(argc, argv, "n:")) != -1) {
        switch (opt) {
            case 'n':
                n_lines = atol(optarg);
                break;
            default:
                break;
        }
    }

    if (optind >= argc) {
        head_file(stdin, n_lines);
    } else {
        for (int i = optind; i < argc; i++) {
            if (strcmp(argv[i], "-") == 0) {
                head_file(stdin, n_lines);
            } else {
                FILE *fp = fopen(argv[i], "r");
                if (fp) {
                    head_file(fp, n_lines);
                    fclose(fp);
                }
            }
        }
    }
    return 0;
}
