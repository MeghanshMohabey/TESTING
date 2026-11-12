#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <getopt.h>

static void tac_file(FILE *fp, const char *separator) {
    char **lines = NULL;
    size_t line_count = 0;
    size_t capacity = 10;
    char *line = NULL;
    size_t len = 0;

    lines = malloc(capacity * sizeof(char *));
    if (!lines) return;

    while (getline(&line, &len, fp) != -1) {
        if (line_count >= capacity) {
            capacity *= 2;
            char **temp = realloc(lines, capacity * sizeof(char *));
            if (!temp) break;
            lines = temp;
        }
        lines[line_count++] = strdup(line);
    }
    free(line);

    // Print lines in reverse order
    for (size_t i = line_count; i > 0; i--) {
        fputs(lines[i - 1], stdout);
        free(lines[i - 1]);
    }
    free(lines);
}

int main(int argc, char **argv) {
    char const *separator = "\n";
    int opt;
    
    static struct option const longopts[] = {
        {"before", no_argument, NULL, 'b'},
        {"regex", no_argument, NULL, 'r'},
        {"separator", required_argument, NULL, 's'},
        {NULL, 0, NULL, 0}
    };

    while ((opt = getopt_long(argc, argv, "brs:", longopts, NULL)) != -1) {
        switch (opt) {
            case 'b': break;
            case 'r': break;
            case 's': separator = optarg; break;
            default: break;
        }
    }

    if (optind >= argc) {
        tac_file(stdin, separator);
    } else {
        for (int i = optind; i < argc; i++) {
            if (strcmp(argv[i], "-") == 0) {
                tac_file(stdin, separator);
            } else {
                FILE *fp = fopen(argv[i], "r");
                if (fp) {
                    tac_file(fp, separator);
                    fclose(fp);
                }
            }
        }
    }
    return 0;
}
