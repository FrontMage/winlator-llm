#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <intrin.h>

static FILE *open_log_file(void) {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;
    char *slash = strrchr(path, '\\');
    if (!slash) return NULL;
    *(slash + 1) = '\0';
    strncat(path, "clock_probe.log", MAX_PATH - strlen(path) - 1);
    return fopen(path, "w");
}

static void print_time_header(FILE *out, LARGE_INTEGER freq) {
    fprintf(out, "clock_probe: freq=%lld\n", (long long)freq.QuadPart);
}

int main(void) {
    FILE *out = open_log_file();
    if (!out) out = stdout;

    LARGE_INTEGER freq;
    if (!QueryPerformanceFrequency(&freq)) {
        fprintf(out, "clock_probe: QueryPerformanceFrequency failed\n");
        return 1;
    }

    print_time_header(out, freq);

    LARGE_INTEGER prev_qpc = {0};
    LARGE_INTEGER cur_qpc = {0};
    uint64_t prev_tick = GetTickCount64();
    uint64_t prev_tsc = __rdtsc();

    uint64_t max_qpc_delta = 0;
    uint64_t max_tick_delta = 0;
    uint64_t max_tsc_delta = 0;
    uint64_t min_qpc_delta = UINT64_MAX;
    uint64_t min_tick_delta = UINT64_MAX;
    uint64_t min_tsc_delta = UINT64_MAX;

    int qpc_non_monotonic = 0;
    int tick_non_monotonic = 0;
    int tsc_non_monotonic = 0;
    int large_gap = 0;

    const int iterations = 5000;
    const int sleep_ms = 1;

    QueryPerformanceCounter(&prev_qpc);

    for (int i = 0; i < iterations; i++) {
        Sleep(sleep_ms);

        QueryPerformanceCounter(&cur_qpc);
        uint64_t cur_tick = GetTickCount64();
        uint64_t cur_tsc = __rdtsc();

        uint64_t qpc_delta = (uint64_t)(cur_qpc.QuadPart - prev_qpc.QuadPart);
        uint64_t tick_delta = (uint64_t)(cur_tick - prev_tick);
        uint64_t tsc_delta = (uint64_t)(cur_tsc - prev_tsc);

        if (cur_qpc.QuadPart < prev_qpc.QuadPart) {
            qpc_non_monotonic++;
            fprintf(out, "QPC_NON_MONOTONIC prev=%lld cur=%lld\n", (long long)prev_qpc.QuadPart, (long long)cur_qpc.QuadPart);
        }
        if (cur_tick < prev_tick) {
            tick_non_monotonic++;
            fprintf(out, "TICK_NON_MONOTONIC prev=%llu cur=%llu\n", (unsigned long long)prev_tick, (unsigned long long)cur_tick);
        }
        if (cur_tsc < prev_tsc) {
            tsc_non_monotonic++;
            fprintf(out, "TSC_NON_MONOTONIC prev=%llu cur=%llu\n", (unsigned long long)prev_tsc, (unsigned long long)cur_tsc);
        }

        if (qpc_delta > max_qpc_delta) max_qpc_delta = qpc_delta;
        if (tick_delta > max_tick_delta) max_tick_delta = tick_delta;
        if (tsc_delta > max_tsc_delta) max_tsc_delta = tsc_delta;
        if (qpc_delta < min_qpc_delta) min_qpc_delta = qpc_delta;
        if (tick_delta < min_tick_delta) min_tick_delta = tick_delta;
        if (tsc_delta < min_tsc_delta) min_tsc_delta = tsc_delta;

        // detect large gap: QPC indicates >250ms while tick indicates <=20ms
        if (qpc_delta > (uint64_t)(freq.QuadPart / 4) && tick_delta <= 20) {
            large_gap++;
            fprintf(out, "LARGE_GAP qpc_delta=%llu tick_delta=%llu\n",
                   (unsigned long long)qpc_delta,
                   (unsigned long long)tick_delta);
        }

        prev_qpc = cur_qpc;
        prev_tick = cur_tick;
        prev_tsc = cur_tsc;
    }

    fprintf(out, "clock_probe: done\n");
    fprintf(out, "QPC delta min=%llu max=%llu non_monotonic=%d\n",
           (unsigned long long)min_qpc_delta, (unsigned long long)max_qpc_delta, qpc_non_monotonic);
    fprintf(out, "TICK delta min=%llu max=%llu non_monotonic=%d\n",
           (unsigned long long)min_tick_delta, (unsigned long long)max_tick_delta, tick_non_monotonic);
    fprintf(out, "TSC delta min=%llu max=%llu non_monotonic=%d\n",
           (unsigned long long)min_tsc_delta, (unsigned long long)max_tsc_delta, tsc_non_monotonic);
    fprintf(out, "Large gaps=%d\n", large_gap);

    if (out != stdout) fclose(out);

    return 0;
}
