#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <intrin.h>

typedef struct {
    int cpu_info0[4];
    int cpu_info1[4];
    int cpu_info7[4];
} cpu_snapshot_t;

static void capture_snapshot(cpu_snapshot_t *snap) {
    __cpuid(snap->cpu_info0, 0);
    __cpuid(snap->cpu_info1, 1);
    __cpuidex(snap->cpu_info7, 7, 0);
}

static int compare_snapshot(const cpu_snapshot_t *a, const cpu_snapshot_t *b) {
    for (int i = 0; i < 4; i++) {
        if (a->cpu_info0[i] != b->cpu_info0[i]) return 0;
        if (a->cpu_info1[i] != b->cpu_info1[i]) return 0;
        if (a->cpu_info7[i] != b->cpu_info7[i]) return 0;
    }
    return 1;
}

typedef struct {
    cpu_snapshot_t baseline;
    volatile LONG mismatch_count;
    int iterations;
    DWORD_PTR affinity_mask;
} thread_ctx_t;

static DWORD WINAPI thread_fn(LPVOID param) {
    thread_ctx_t *ctx = (thread_ctx_t *)param;
    if (ctx->affinity_mask != 0) {
        SetThreadAffinityMask(GetCurrentThread(), ctx->affinity_mask);
    }

    cpu_snapshot_t cur;
    for (int i = 0; i < ctx->iterations; i++) {
        capture_snapshot(&cur);
        if (!compare_snapshot(&cur, &ctx->baseline)) {
            InterlockedIncrement(&ctx->mismatch_count);
            break;
        }
        Sleep(1);
    }
    return 0;
}

static FILE *open_log_file(void) {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;
    char *slash = strrchr(path, '\\');
    if (!slash) return NULL;
    *(slash + 1) = '\0';
    strncat(path, "cpuid_probe.log", MAX_PATH - strlen(path) - 1);
    return fopen(path, "w");
}

static void print_snapshot(FILE *out, const cpu_snapshot_t *snap) {
    fprintf(out, "CPUID(0): %08x %08x %08x %08x\n",
            snap->cpu_info0[0], snap->cpu_info0[1], snap->cpu_info0[2], snap->cpu_info0[3]);
    fprintf(out, "CPUID(1): %08x %08x %08x %08x\n",
            snap->cpu_info1[0], snap->cpu_info1[1], snap->cpu_info1[2], snap->cpu_info1[3]);
    fprintf(out, "CPUID(7,0): %08x %08x %08x %08x\n",
            snap->cpu_info7[0], snap->cpu_info7[1], snap->cpu_info7[2], snap->cpu_info7[3]);
}

int main(void) {
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    int cpu_count = (int)sysinfo.dwNumberOfProcessors;
    if (cpu_count <= 0) cpu_count = 1;
    if (cpu_count > 8) cpu_count = 8;

    cpu_snapshot_t baseline;
    capture_snapshot(&baseline);

    FILE *out = open_log_file();
    if (!out) out = stdout;

    fprintf(out, "cpuid_probe: cpu_count=%d\n", cpu_count);
    print_snapshot(out, &baseline);

    const int iterations = 2000;
    thread_ctx_t ctx;
    ctx.baseline = baseline;
    ctx.mismatch_count = 0;
    ctx.iterations = iterations;

    HANDLE threads[8];
    for (int i = 0; i < cpu_count; i++) {
        ctx.affinity_mask = (DWORD_PTR)1 << i;
        threads[i] = CreateThread(NULL, 0, thread_fn, &ctx, 0, NULL);
    }

    WaitForMultipleObjects(cpu_count, threads, TRUE, INFINITE);
    for (int i = 0; i < cpu_count; i++) {
        CloseHandle(threads[i]);
    }

    fprintf(out, "cpuid_probe: mismatches=%ld\n", ctx.mismatch_count);

    if (out != stdout) fclose(out);
    return 0;
}
