#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

static void trim(char *s) {
    size_t len = strlen(s);
    while (len > 0 && isspace((unsigned char)s[len - 1])) {
        s[--len] = '\0';
    }
    char *start = s;
    while (*start && isspace((unsigned char)*start)) start++;
    if (start != s) memmove(s, start, strlen(start) + 1);
}

static void extract_value(const char *line, char *out, size_t out_size) {
    const char *colon = strchr(line, ':');
    if (!colon) return;
    colon++;
    while (*colon == ' ' || *colon == '\t') colon++;
    snprintf(out, out_size, "%s", colon);
    trim(out);
}

static int count_cpus_from_cpuinfo(void) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) return 0;
    char line[512];
    int count = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "processor", 9) == 0) count++;
    }
    fclose(f);
    return count;
}

static void detect_model(char *model, size_t model_size) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "model name", 10) == 0 ||
            strncmp(line, "Processor", 9) == 0 ||
            strncmp(line, "Hardware", 8) == 0) {
            extract_value(line, model, model_size);
            break;
        }
    }
    fclose(f);
}

int main(void) {
    struct utsname uts;
    if (uname(&uts) != 0) {
        perror("lscpu: uname");
        return 1;
    }

    int cpus = count_cpus_from_cpuinfo();
    if (cpus <= 0) {
        long n = sysconf(_SC_NPROCESSORS_ONLN);
        cpus = (n > 0) ? (int)n : 1;
    }

    char model[256] = "";
    detect_model(model, sizeof(model));
    if (model[0] == '\0') snprintf(model, sizeof(model), "%s", uts.machine);

    printf("Architecture:\t\t%s\n", uts.machine);
    printf("CPU op-mode(s):\t\t64-bit\n");
    printf("Byte Order:\t\tLittle Endian\n");
    printf("CPU(s):\t\t\t%d\n", cpus);
    printf("Model name:\t\t%s\n", model);
    return 0;
}
