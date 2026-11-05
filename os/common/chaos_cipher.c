/*
 * chaos_cipher.c - xem chaos_cipher.h. Moi ham ung voi mot ham cung ten trong refmodel/.
 */
#include "chaos_cipher.h"

#include <string.h>

/* ======================================================================= SHA-256 */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR32(v, s) (((v) >> (s)) | ((v) << (32 - (s))))

static void sha256_block(uint32_t h[8], const uint8_t blk[64])
{
    uint32_t w[64], a, b, c, d, e, f, g, hh;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)blk[4 * i] << 24) | ((uint32_t)blk[4 * i + 1] << 16) |
               ((uint32_t)blk[4 * i + 2] << 8) | blk[4 * i + 3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROR32(w[i - 15], 7) ^ ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR32(w[i - 2], 17) ^ ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (i = 0; i < 64; i++) {
        uint32_t t1 = hh + (ROR32(e, 6) ^ ROR32(e, 11) ^ ROR32(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROR32(a, 2) ^ ROR32(a, 13) ^ ROR32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void chaos_sha256_init(chaos_sha256_t *s)
{
    static const uint32_t iv[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(s->h, iv, sizeof iv);
    s->total = 0;
    s->used = 0;
}

void chaos_sha256_update(chaos_sha256_t *s, const uint8_t *data, size_t len)
{
    s->total += len;
    while (len > 0) {
        size_t take = 64 - s->used;
        if (take > len)
            take = len;
        memcpy(s->buf + s->used, data, take);
        s->used += take;
        data += take;
        len -= take;
        if (s->used == 64) {
            sha256_block(s->h, s->buf);
            s->used = 0;
        }
    }
}

void chaos_sha256_final(chaos_sha256_t *s, uint8_t out[32])
{
    uint64_t bits = s->total * 8;
    uint8_t pad = 0x80;
    uint8_t lenbuf[8];
    int i;

    chaos_sha256_update(s, &pad, 1);
    pad = 0;
    while (s->used != 56)
        chaos_sha256_update(s, &pad, 1);
    for (i = 0; i < 8; i++)
        lenbuf[i] = (uint8_t)(bits >> (56 - 8 * i));
    chaos_sha256_update(s, lenbuf, 8);
    for (i = 0; i < 8; i++) {
        out[4 * i]     = (uint8_t)(s->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(s->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(s->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)s->h[i];
    }
    memset(s, 0, sizeof *s);
}

void chaos_hmac_sha256(const uint8_t *key, size_t key_len,
                       const uint8_t *msg, size_t msg_len, uint8_t out[32])
{
    uint8_t k0[64], pad[64], inner[32];
    chaos_sha256_t s;
    int i;

    memset(k0, 0, sizeof k0);
    if (key_len > 64) {
        chaos_sha256_init(&s);
        chaos_sha256_update(&s, key, key_len);
        chaos_sha256_final(&s, k0);
    } else {
        memcpy(k0, key, key_len);
    }

    for (i = 0; i < 64; i++)
        pad[i] = k0[i] ^ 0x36;
    chaos_sha256_init(&s);
    chaos_sha256_update(&s, pad, 64);
    chaos_sha256_update(&s, msg, msg_len);
    chaos_sha256_final(&s, inner);

    for (i = 0; i < 64; i++)
        pad[i] = k0[i] ^ 0x5c;
    chaos_sha256_init(&s);
    chaos_sha256_update(&s, pad, 64);
    chaos_sha256_update(&s, inner, 32);
    chaos_sha256_final(&s, out);

    memset(k0, 0, sizeof k0);
    memset(pad, 0, sizeof pad);
    memset(inner, 0, sizeof inner);
}

/* ======================================================================= LTS (4.3.2) */

#define ONE_W   ((uint64_t)1 << CHAOS_W)
#define HALF_W  ((uint64_t)1 << (CHAOS_W - 1))
#define TRAP_MAX 1u
#define X0_MIN   2u

typedef unsigned __int128 u128;   /* r_int toi 2^34: tich co the vuot 64 bit */

uint32_t chaos_lts_step(uint32_t x, uint64_t r_int, uint32_t x0)
{
    uint64_t one_minus_x = ONE_W - x;
    uint64_t prod  = (uint64_t)(((u128)x * one_minus_x) >> CHAOS_W);
    uint64_t term1 = (uint64_t)(((u128)r_int * prod) >> CHAOS_W);
    uint64_t half  = ((4 * ONE_W) - r_int) >> 1;
    uint64_t term2 = (uint64_t)(((u128)half * (x < HALF_W ? x : one_minus_x)) >> CHAOS_W);
    uint32_t nxt   = (uint32_t)(term1 + term2);          /* & (2^W - 1) */

    return nxt <= TRAP_MAX ? x0 : nxt;
}

/* ======================================================================= KDF (4.2.2-4.2.3) */

static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

void chaos_params_from_session_key(const uint8_t k_session[32], uint32_t *x0, uint64_t *r_int)
{
    uint32_t v = be32(k_session) ^ be32(k_session + 4) ^ be32(k_session + 8) ^ be32(k_session + 12);
    uint32_t x = be32(k_session + 16) ^ be32(k_session + 20) ^ be32(k_session + 24) ^ be32(k_session + 28);

    *x0 = v < X0_MIN ? X0_MIN : v;
    /* r thuoc [1, 2): R_MIN_INT = R_SPAN_INT = 2^32 -> r_int = 2^32 + ((2^32 * x) >> 32) */
    *r_int = ONE_W + x;
}

void chaos_derive_session(const uint8_t k_master[32], uint32_t ctr,
                          uint8_t k_session[32], uint32_t *x0, uint64_t *r_int)
{
    uint8_t msg[11] = { 's', 'e', 's', 's', 'i', 'o', 'n' };

    msg[7]  = (uint8_t)(ctr >> 24);
    msg[8]  = (uint8_t)(ctr >> 16);
    msg[9]  = (uint8_t)(ctr >> 8);
    msg[10] = (uint8_t)ctr;
    chaos_hmac_sha256(k_master, CHAOS_KMASTER_BYTES, msg, sizeof msg, k_session);
    chaos_params_from_session_key(k_session, x0, r_int);
}

/* ======================================================================= Fisher-Yates (4.3.4-4.3.5) */

uint16_t chaos_gather_bits(uint16_t value, const uint8_t *pi, int n)
{
    uint16_t out = 0;
    int i;
    for (i = 0; i < n; i++)
        out |= (uint16_t)(((value >> pi[i]) & 1u) << i);
    return out;
}

uint16_t chaos_scatter_bits(uint16_t value, const uint8_t *pi, int n)
{
    uint16_t out = 0;
    int i;
    for (i = 0; i < n; i++)
        out |= (uint16_t)(((value >> i) & 1u) << pi[i]);
    return out;
}

static int bit_length(unsigned v)
{
    int b = 0;
    while (v) {
        b++;
        v >>= 1;
    }
    return b;
}

/* BitPool: hang doi bit, moi trang thai X nap tu bit 0 len; pool rong o dau moi lan goi. */
static int fisher_yates(chaos_ctx_t *c, uint8_t *pi, uint8_t *refills_out, uint8_t *rejects_out)
{
    uint64_t pool = 0;
    int pool_n = 0, i;
    unsigned refills = 0, rejects = 0;

    for (i = 0; i < c->n; i++)
        pi[i] = (uint8_t)i;

    for (i = c->n - 1; i >= 1; i--) {
        unsigned rng = (unsigned)i + 1;
        int b = bit_length(rng - 1);
        unsigned cand;
        uint8_t tmp;

        for (;;) {
            while (pool_n < b) {
                c->x = chaos_lts_step(c->x, c->r_int, c->x0);
                pool |= (uint64_t)c->x << pool_n;
                pool_n += CHAOS_W;
                if (++refills > CHAOS_FY_WATCHDOG)
                    return CHAOS_EWATCHDOG;
            }
            cand = (unsigned)(pool & ((1u << b) - 1));
            pool >>= b;
            pool_n -= b;
            if (cand < rng)
                break;
            rejects++;
        }
        tmp = pi[i];
        pi[i] = pi[cand];
        pi[cand] = tmp;
    }
    *refills_out = (uint8_t)refills;
    *rejects_out = (uint8_t)rejects;
    return CHAOS_OK;
}

/* ======================================================================= Phien + ma hoa (4.2.6, 4.3.6-4.3.7) */

static void start_session(chaos_ctx_t *c)
{
    uint8_t ks[32];
    chaos_derive_session(c->k_master, c->ctr, ks, &c->x0, &c->r_int);
    c->x = c->x0;
    memset(ks, 0, sizeof ks);
}

static void update_session(chaos_ctx_t *c)
{
    if (++c->idx >= c->reseed_interval) {
        c->ctr++;                       /* quay vong mod 2^32 nhu SPEC */
        c->idx = 0;
        start_session(c);
    }
}

int chaos_init(chaos_ctx_t *c, const uint8_t k_master[32], int n,
               uint16_t reseed_interval, uint32_t ctr0)
{
    if ((n != 8 && n != 16) || reseed_interval == 0)
        return CHAOS_EINVAL;
    memset(c, 0, sizeof *c);
    memcpy(c->k_master, k_master, CHAOS_KMASTER_BYTES);
    c->n = n;
    c->reseed_interval = reseed_interval;
    c->ctr = ctr0;
    c->idx = 0;
    start_session(c);
    return CHAOS_OK;
}

/* Sinh (k, pi) cho mau hien tai; cap nhat X. */
static int gen_ks_perm(chaos_ctx_t *c, chaos_detail_t *d)
{
    d->ctr = c->ctr;
    d->idx = c->idx;
    c->x = chaos_lts_step(c->x, c->r_int, c->x0);              /* LTS_KEYSTREAM */
    d->k = (uint16_t)(c->x & ((1u << c->n) - 1));               /* N bit THAP */
    return fisher_yates(c, d->pi, &d->refills, &d->rejects);    /* FY_* */
}

int chaos_encrypt(chaos_ctx_t *c, uint16_t plain, uint16_t *cipher, chaos_detail_t *detail)
{
    chaos_detail_t local, *d = detail ? detail : &local;
    int rc;

    if (plain >> c->n)
        return CHAOS_EINVAL;
    rc = gen_ks_perm(c, d);
    if (rc != CHAOS_OK)
        return rc;
    *cipher = (uint16_t)(chaos_gather_bits(plain, d->pi, c->n) ^ d->k);
    update_session(c);
    return CHAOS_OK;
}

int chaos_decrypt(chaos_ctx_t *c, uint16_t cipher, uint16_t *plain, chaos_detail_t *detail)
{
    chaos_detail_t local, *d = detail ? detail : &local;
    int rc;

    if (cipher >> c->n)
        return CHAOS_EINVAL;
    rc = gen_ks_perm(c, d);
    if (rc != CHAOS_OK)
        return rc;
    *plain = chaos_scatter_bits((uint16_t)(cipher ^ d->k), d->pi, c->n);
    update_session(c);
    return CHAOS_OK;
}

int chaos_advance(chaos_ctx_t *c, uint32_t n)
{
    chaos_detail_t d;
    while (n--) {
        int rc = gen_ks_perm(c, &d);
        if (rc != CHAOS_OK)
            return rc;
        update_session(c);
    }
    return CHAOS_OK;
}

void chaos_wipe(chaos_ctx_t *c)
{
    volatile uint8_t *p = (volatile uint8_t *)c;
    size_t i;
    for (i = 0; i < sizeof *c; i++)
        p[i] = 0;
}
