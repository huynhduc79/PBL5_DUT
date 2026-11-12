/*
 * chaos_cipher.h - Ban C cua golden model refmodel, SPEC_VERSION 1.0.0.
 *
 * Mat ma dong dong bo cho tung mau N bit (N = 8 hoac 16):
 *     x  <- LTS(x);  k <- N bit THAP cua x;  pi <- FisherYates(x)
 *     C  <- gather(P, pi) XOR k                     (giai ma: P <- scatter(C XOR k, pi))
 * Sau moi mau: UpdateSession (het RESEED_INTERVAL mau -> ctr+1, HMAC-SHA256 ra X0, r moi).
 *
 * Dung tren FreeRTOS (U54) khi chua co loi FPGA, va tren PC de mo phong/kiem thu.
 * Phai khop tung bit voi vectors/out cua refmodel (os/tests/test_cipher_vectors.c).
 * Khong cap phat dong, khong dung stdio.
 */
#ifndef CHAOS_CIPHER_H
#define CHAOS_CIPHER_H

#include <stddef.h>
#include <stdint.h>

#define CHAOS_SPEC_VERSION     "1.0.0"
#define CHAOS_W                32
#define CHAOS_KMASTER_BYTES    32
#define CHAOS_RESEED_DEFAULT   64
#define CHAOS_FY_WATCHDOG      64      /* chi de bat loi, giong FY_REFILL_WATCHDOG */

/* ---- SHA-256 / HMAC-SHA256 (FIPS 180-4 / FIPS 198-1) ---- */
typedef struct {
    uint32_t h[8];
    uint64_t total;
    uint8_t  buf[64];
    size_t   used;
} chaos_sha256_t;

void chaos_sha256_init(chaos_sha256_t *s);
void chaos_sha256_update(chaos_sha256_t *s, const uint8_t *data, size_t len);
void chaos_sha256_final(chaos_sha256_t *s, uint8_t out[32]);
void chaos_hmac_sha256(const uint8_t *key, size_t key_len,
                       const uint8_t *msg, size_t msg_len, uint8_t out[32]);

/* ---- Cac khoi rieng le (de doi chieu vector) ---- */
uint32_t chaos_lts_step(uint32_t x, uint64_t r_int, uint32_t x0);
void     chaos_params_from_session_key(const uint8_t k_session[32], uint32_t *x0, uint64_t *r_int);
void     chaos_derive_session(const uint8_t k_master[32], uint32_t ctr,
                              uint8_t k_session[32], uint32_t *x0, uint64_t *r_int);
uint16_t chaos_gather_bits(uint16_t value, const uint8_t *pi, int n);
uint16_t chaos_scatter_bits(uint16_t value, const uint8_t *pi, int n);

/* ---- Loi ma hoa co phien ---- */
typedef struct {
    uint8_t  k_master[CHAOS_KMASTER_BYTES];
    int      n;                 /* 8 hoac 16 */
    uint16_t reseed_interval;   /* so mau moi phien */
    uint32_t ctr;               /* ctr cua mau KE TIEP */
    uint16_t idx;               /* idx cua mau KE TIEP (= sample_count) */
    uint32_t x, x0;
    uint64_t r_int;
} chaos_ctx_t;

/* Chi tiet mot mau, dung cho kiem thu (cot k, pi, refills, rejects cua vector). */
typedef struct {
    uint32_t ctr;               /* ctr dung de ma hoa mau nay (truoc UpdateSession) */
    uint16_t idx;
    uint16_t k;
    uint8_t  pi[16];
    uint8_t  refills;
    uint8_t  rejects;
} chaos_detail_t;

enum { CHAOS_OK = 0, CHAOS_EINVAL = -1, CHAOS_EWATCHDOG = -2 };

int  chaos_init(chaos_ctx_t *c, const uint8_t k_master[32], int n,
                uint16_t reseed_interval, uint32_t ctr0);
/* Ma hoa/giai ma mot mau; tra CHAOS_OK hoac ma loi. detail co the NULL. */
int  chaos_encrypt(chaos_ctx_t *c, uint16_t plain, uint16_t *cipher, chaos_detail_t *detail);
int  chaos_decrypt(chaos_ctx_t *c, uint16_t cipher, uint16_t *plain, chaos_detail_t *detail);
/* Chay bu n mau (bo qua du lieu) - dong bo lai khi mat goi. */
int  chaos_advance(chaos_ctx_t *c, uint32_t n);
/* Xoa khoa va trang thai khoi RAM. */
void chaos_wipe(chaos_ctx_t *c);

#endif /* CHAOS_CIPHER_H */
