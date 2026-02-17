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
    strncat(path, "crypto_probe.log", MAX_PATH - strlen(path) - 1);
    return fopen(path, "w");
}

static void cpuid(int out[4], int eax, int ecx) {
    __cpuidex(out, eax, ecx);
}

static void print_features(FILE *out) {
    int r[4] = {0};
    cpuid(r, 1, 0);
    int ecx = r[2];
    int edx = r[3];

    fprintf(out, "features: SSE2=%d SSE3=%d SSSE3=%d SSE4.1=%d SSE4.2=%d AES=%d AVX=%d\n",
            (edx >> 26) & 1,
            (ecx >> 0) & 1,
            (ecx >> 9) & 1,
            (ecx >> 19) & 1,
            (ecx >> 20) & 1,
            (ecx >> 25) & 1,
            (ecx >> 28) & 1);
}

static uint32_t crc32c_sw(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0x82F63B78u & mask); // Castagnoli
        }
    }
    return ~crc;
}

static uint32_t crc32c_sse42(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    size_t i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t v;
        memcpy(&v, data + i, sizeof(v));
        crc = (uint32_t)_mm_crc32_u64(crc, v);
    }
    for (; i < len; i++) {
        crc = _mm_crc32_u8(crc, data[i]);
    }
    return ~crc;
}

#ifdef __AES__
#include <wmmintrin.h>

#define AES128_KEY_EXP_STEP(tmp, tmp2, rcon)         \
    tmp2 = _mm_aeskeygenassist_si128(tmp, rcon);     \
    tmp2 = _mm_shuffle_epi32(tmp2, 0xff);            \
    tmp = _mm_xor_si128(tmp, _mm_slli_si128(tmp, 4));\
    tmp = _mm_xor_si128(tmp, _mm_slli_si128(tmp, 4));\
    tmp = _mm_xor_si128(tmp, _mm_slli_si128(tmp, 4));\
    tmp = _mm_xor_si128(tmp, tmp2)

static void aes128_key_expansion(const uint8_t *key, __m128i *round_keys) {
    round_keys[0] = _mm_loadu_si128((const __m128i *)key);
    __m128i temp = round_keys[0];
    __m128i temp2;

    AES128_KEY_EXP_STEP(temp, temp2, 0x01); round_keys[1]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x02); round_keys[2]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x04); round_keys[3]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x08); round_keys[4]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x10); round_keys[5]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x20); round_keys[6]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x40); round_keys[7]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x80); round_keys[8]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x1B); round_keys[9]  = temp;
    AES128_KEY_EXP_STEP(temp, temp2, 0x36); round_keys[10] = temp;
}
#undef AES128_KEY_EXP_STEP

static void aes128_encrypt_block(const uint8_t *in, uint8_t *out, const __m128i *round_keys) {
    __m128i state = _mm_loadu_si128((const __m128i *)in);
    state = _mm_xor_si128(state, round_keys[0]);
    for (int i = 1; i < 10; i++) {
        state = _mm_aesenc_si128(state, round_keys[i]);
    }
    state = _mm_aesenclast_si128(state, round_keys[10]);
    _mm_storeu_si128((__m128i *)out, state);
}
#endif

static int test_aes(FILE *out) {
    int r[4] = {0};
    cpuid(r, 1, 0);
    int aes = (r[2] >> 25) & 1;
    if (!aes) {
        fprintf(out, "AES-NI not supported (cpuid says no). Skipping AES test.\n");
        return 0;
    }
#ifndef __AES__
    fprintf(out, "AES-NI supported by CPU but compiler has no AES intrinsics. Skipping AES test.\n");
    return 0;
#else
    const uint8_t key[16] = {
        0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
        0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f
    };
    const uint8_t plain[16] = {
        0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
        0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff
    };
    const uint8_t expected[16] = {
        0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,
        0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a
    };

    __m128i round_keys[11];
    aes128_key_expansion(key, round_keys);
    uint8_t outbuf[16];
    aes128_encrypt_block(plain, outbuf, round_keys);

    int ok = memcmp(outbuf, expected, 16) == 0;
    fprintf(out, "AES test: %s\n", ok ? "OK" : "FAIL");
    if (!ok) {
        fprintf(out, "AES output: ");
        for (int i = 0; i < 16; i++) fprintf(out, "%02x", outbuf[i]);
        fprintf(out, "\nExpected:  ");
        for (int i = 0; i < 16; i++) fprintf(out, "%02x", expected[i]);
        fprintf(out, "\n");
    }
    return ok ? 0 : 1;
#endif
}

static int test_crc32c(FILE *out) {
    const char *msg = "123456789";
    uint32_t sw = crc32c_sw((const uint8_t *)msg, strlen(msg));
    int r[4] = {0};
    cpuid(r, 1, 0);
    int sse42 = (r[2] >> 20) & 1;
    fprintf(out, "CRC32C (software) = 0x%08x (expected 0xe3069283)\n", sw);
    int err = 0;
    if (sw != 0xe3069283u) {
        fprintf(out, "CRC32C software mismatch!\n");
        err = 1;
    }
    if (sse42) {
        uint32_t hw = crc32c_sse42((const uint8_t *)msg, strlen(msg));
        fprintf(out, "CRC32C (SSE4.2) = 0x%08x\n", hw);
        if (hw != sw) {
            fprintf(out, "CRC32C SSE4.2 mismatch vs software!\n");
            err = 1;
        }
    } else {
        fprintf(out, "SSE4.2 not supported (cpuid says no). Skipping CRC32C SSE test.\n");
    }
    return err;
}

int main(void) {
    FILE *out = open_log_file();
    if (!out) out = stdout;

    fprintf(out, "crypto_probe: start\n");
    print_features(out);

    int err = 0;
    err |= test_crc32c(out);
    err |= test_aes(out);

    fprintf(out, "crypto_probe: %s\n", err ? "FAIL" : "OK");

    if (out != stdout) fclose(out);
    return err;
}
