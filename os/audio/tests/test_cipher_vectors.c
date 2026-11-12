/*
 * test_cipher_vectors.c - doi chieu os/common/chaos_cipher.c voi vector golden cua refmodel.
 *
 *   test_cipher_vectors <thu_muc_vectors_out>
 *
 * Kiem tra: kat_sha256, kat_hmac, kdf, kdf_words, lts_step va moi bo enc_*.csv
 * (c, k, pi, refills, rejects; giai ma nguoc lai ra p). Tra 0 neu tat ca khop.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "chaos_cipher.h"

static int g_fail, g_checks;

#define CHECK(cond, ...)                                  \
    do {                                                  \
        g_checks++;                                       \
        if (!(cond)) {                                    \
            if (g_fail < 20) {                            \
                printf("  SAI: " __VA_ARGS__);            \
                printf("\n");                             \
            }                                             \
            g_fail++;                                     \
        }                                                 \
    } while (0)

static size_t unhex(const char *s, uint8_t *out, size_t cap)
{
    size_t n = 0;
    while (s[0] && s[1] && n < cap) {
        unsigned v;
        sscanf(s, "%2x", &v);
        out[n++] = (uint8_t)v;
        s += 2;
    }
    return n;
}

/* Doc CSV: bo dong tieu de, tach cot bang ',' vao cols[]. Tra so cot, 0 khi het file. */
static int next_row(FILE *f, char *line, size_t cap, char **cols, int maxcols)
{
    int n = 0;
    char *p;
    if (!fgets(line, (int)cap, f))
        return 0;
    line[strcspn(line, "\r\n")] = 0;
    p = line;
    cols[n++] = p;
    while ((p = strchr(p, ',')) != NULL && n < maxcols) {
        *p++ = 0;
        cols[n++] = p;
    }
    return n;
}

static FILE *open_csv(const char *dir, const char *name, char *line, size_t cap)
{
    char path[512];
    FILE *f;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    f = fopen(path, "r");
    if (!f) {
        printf("Khong mo duoc %s\n", path);
        exit(2);
    }
    fgets(line, (int)cap, f);   /* tieu de */
    return f;
}

static void test_sha_hmac(const char *dir)
{
    static char line[1 << 16];
    static uint8_t msg[1 << 15], key[1 << 12];
    char *col[8];
    uint8_t got[32], exp[32];
    FILE *f;
    int n;
    chaos_sha256_t s;

    f = open_csv(dir, "kat_sha256.csv", line, sizeof line);
    while ((n = next_row(f, line, sizeof line, col, 8)) >= 2) {
        size_t ml = unhex(col[0], msg, sizeof msg);
        unhex(col[1], exp, 32);
        chaos_sha256_init(&s);
        chaos_sha256_update(&s, msg, ml);
        chaos_sha256_final(&s, got);
        CHECK(memcmp(got, exp, 32) == 0, "sha256 msg_len=%zu", ml);
    }
    fclose(f);

    f = open_csv(dir, "kat_hmac.csv", line, sizeof line);
    while ((n = next_row(f, line, sizeof line, col, 8)) >= 3) {
        size_t kl = unhex(col[0], key, sizeof key);
        size_t ml = unhex(col[1], msg, sizeof msg);
        size_t el = unhex(col[2], exp, 32);
        chaos_hmac_sha256(key, kl, msg, ml, got);
        CHECK(memcmp(got, exp, el) == 0, "hmac key_len=%zu", kl);
    }
    fclose(f);
}

static void test_kdf_lts(const char *dir)
{
    static char line[4096];
    char *col[12];
    uint8_t km[32], ks[32], ks_exp[32];
    uint32_t x0;
    uint64_t r;
    FILE *f;

    f = open_csv(dir, "kdf.csv", line, sizeof line);
    while (next_row(f, line, sizeof line, col, 12) >= 5) {
        unhex(col[0], km, 32);
        unhex(col[2], ks_exp, 32);
        chaos_derive_session(km, (uint32_t)strtoul(col[1], NULL, 16), ks, &x0, &r);
        CHECK(memcmp(ks, ks_exp, 32) == 0, "kdf k_session ctr=%s", col[1]);
        CHECK(x0 == strtoul(col[3], NULL, 16), "kdf x0 ctr=%s", col[1]);
        CHECK(r == strtoull(col[4], NULL, 16), "kdf r_int ctr=%s", col[1]);
    }
    fclose(f);

    f = open_csv(dir, "kdf_words.csv", line, sizeof line);
    while (next_row(f, line, sizeof line, col, 12) >= 4) {
        unhex(col[1], ks, 32);
        chaos_params_from_session_key(ks, &x0, &r);
        CHECK(x0 == strtoul(col[2], NULL, 16) && r == strtoull(col[3], NULL, 16), "kdf_words %s", col[0]);
    }
    fclose(f);

    f = open_csv(dir, "lts_step.csv", line, sizeof line);
    while (next_row(f, line, sizeof line, col, 12) >= 5) {
        uint32_t got = chaos_lts_step((uint32_t)strtoul(col[1], NULL, 16), strtoull(col[2], NULL, 16),
                                      (uint32_t)strtoul(col[3], NULL, 16));
        CHECK(got == strtoul(col[4], NULL, 16), "lts %s x=%s r=%s", col[0], col[1], col[2]);
    }
    fclose(f);
}

struct encset {
    const char *name;
    int n;
    uint16_t reseed;
    uint32_t ctr0;
    const char *key_hex;
};

/* Lay tu vectors/out/manifest.json -> cipher_sets. */
static const struct encset SETS[] = {
    { "enc_n16_default", 16, 64, 0, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" },
    { "enc_n8_default",   8, 64, 0, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" },
    { "enc_ctrwrap",      8,  4, 4294967294u, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" },
    { "enc_key00",        8, 64, 0, "0000000000000000000000000000000000000000000000000000000000000000" },
    { "enc_keyff",        8, 64, 0, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" },
    { "enc_keyrnd",       8, 64, 0, "5de575139c41461938df9f5ffa1d2235193ba681abd9cb13468f1690524ab5d2" },
    { "enc_reseed1",      8,  1, 0, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" },
};

static void test_enc(const char *dir, const struct encset *e)
{
    static char line[4096];
    char fname[128], *col[12];
    uint8_t km[32];
    chaos_ctx_t enc, dec;
    FILE *f;
    int rows = 0, before = g_fail;

    unhex(e->key_hex, km, 32);
    chaos_init(&enc, km, e->n, e->reseed, e->ctr0);
    chaos_init(&dec, km, e->n, e->reseed, e->ctr0);
    snprintf(fname, sizeof fname, "%s.csv", e->name);
    f = open_csv(dir, fname, line, sizeof line);
    while (next_row(f, line, sizeof line, col, 12) >= 8) {
        chaos_detail_t d;
        uint16_t c, p_back;
        uint16_t p = (uint16_t)strtoul(col[2], NULL, 16);
        unsigned long long pi_exp = strtoull(col[5], NULL, 16), pi_got = 0;
        int i, rc = chaos_encrypt(&enc, p, &c, &d);

        for (i = 0; i < e->n; i++)
            pi_got |= (unsigned long long)d.pi[i] << (4 * i);   /* nibble i = pi[i] */
        CHECK(rc == CHAOS_OK, "%s dong %d rc=%d", e->name, rows, rc);
        CHECK(d.ctr == strtoul(col[0], NULL, 16) && d.idx == strtoul(col[1], NULL, 16),
              "%s dong %d ctr/idx", e->name, rows);
        CHECK(c == strtoul(col[3], NULL, 16), "%s dong %d c=%04x", e->name, rows, c);
        CHECK(d.k == strtoul(col[4], NULL, 16), "%s dong %d k", e->name, rows);
        CHECK(pi_got == pi_exp, "%s dong %d pi", e->name, rows);
        CHECK(d.refills == strtoul(col[6], NULL, 16) && d.rejects == strtoul(col[7], NULL, 16),
              "%s dong %d refills/rejects", e->name, rows);
        chaos_decrypt(&dec, c, &p_back, NULL);
        CHECK(p_back == p, "%s dong %d giai ma", e->name, rows);
        rows++;
    }
    fclose(f);
    printf("  %-16s %4d mau  %s\n", e->name, rows, g_fail == before ? "KHOP" : "SAI");
}

static void test_advance(void)
{
    /* advance(k) roi giai ma phai bang giai ma tuan tu bo qua k mau dau. */
    uint8_t km[32];
    chaos_ctx_t a, b;
    uint16_t c[150], p1, p2;
    int i;

    for (i = 0; i < 32; i++)
        km[i] = (uint8_t)i;
    chaos_init(&a, km, 16, 64, 7);
    for (i = 0; i < 150; i++)
        chaos_encrypt(&a, (uint16_t)(i * 977), &c[i], NULL);
    chaos_init(&b, km, 16, 64, 7 + 1);     /* bat dau tu phien thu hai (mau 64) */
    chaos_advance(&b, 10);                 /* -> mau 74 */
    for (i = 74; i < 150; i++) {
        chaos_decrypt(&b, c[i], &p2, NULL);
        p1 = (uint16_t)(i * 977);
        CHECK(p1 == p2, "advance mau %d", i);
    }
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "vectors/out";
    size_t i;

    printf("chaos_cipher (SPEC %s) <-> %s\n", CHAOS_SPEC_VERSION, dir);
    test_sha_hmac(dir);
    test_kdf_lts(dir);
    for (i = 0; i < sizeof SETS / sizeof SETS[0]; i++)
        test_enc(dir, &SETS[i]);
    test_advance();
    printf("%d kiem tra, %d sai -> %s\n", g_checks, g_fail, g_fail ? "THAT BAI" : "TAT CA KHOP");
    return g_fail ? 1 : 0;
}
