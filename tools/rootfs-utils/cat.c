#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int cat_fd(int fd, const char *label) {
    char buffer[8192];
    for (;;) {
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n == 0) return 0;
        if (n < 0) {
            fprintf(stderr, "cat: read %s failed: %s\n", label, strerror(errno));
            return 1;
        }

        char *out = buffer;
        ssize_t remaining = n;
        while (remaining > 0) {
            ssize_t written = write(STDOUT_FILENO, out, (size_t)remaining);
            if (written < 0) {
                fprintf(stderr, "cat: write failed: %s\n", strerror(errno));
                return 1;
            }
            out += written;
            remaining -= written;
        }
    }
}

int main(int argc, char **argv) {
    if (argc == 1) return cat_fd(STDIN_FILENO, "stdin");

    int exit_code = 0;
    for (int i = 1; i < argc; ++i) {
        const char *path = argv[i];
        if (strcmp(path, "-") == 0) {
            if (cat_fd(STDIN_FILENO, "stdin") != 0) exit_code = 1;
            continue;
        }

        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "cat: cannot open %s: %s\n", path, strerror(errno));
            exit_code = 1;
            continue;
        }

        if (cat_fd(fd, path) != 0) exit_code = 1;
        close(fd);
    }
    return exit_code;
}
