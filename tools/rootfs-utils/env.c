#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static void print_env(void) {
    for (char **p = environ; p && *p; ++p) {
        puts(*p);
    }
}

int main(int argc, char **argv) {
    int i = 1;

    if (i < argc && strcmp(argv[i], "-i") == 0) {
        if (clearenv() != 0) {
            perror("env: clearenv");
            return 1;
        }
        i++;
    }

    while (i < argc && strchr(argv[i], '=') != NULL) {
        if (putenv(argv[i]) != 0) {
            fprintf(stderr, "env: failed to set %s: %s\n", argv[i], strerror(errno));
            return 1;
        }
        i++;
    }

    if (i >= argc) {
        print_env();
        return 0;
    }

    execvp(argv[i], &argv[i]);
    fprintf(stderr, "env: execvp %s failed: %s\n", argv[i], strerror(errno));
    return 127;
}
