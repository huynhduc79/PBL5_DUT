/*
 * chau_block.h - block cua file .chau (muc 8.2 docs/thiet_ke_he_thong_inmp441.md).
 *
 *   sync(2)=0xA55A | ctr(4) | idx0(1) | count(1) | flags(1) | reserved(1) | C[count](2 moi mau) | crc16(2)
 *
 * Moi so nhieu byte la big-endian. CRC-16/CCITT-FALSE tinh tren ctr..C (khong gom sync).
 * Mot block chi chua mau cua MOT phien (cung ctr), idx lien tiep tu idx0.
 */
#ifndef CHAU_BLOCK_H
#define CHAU_BLOCK_H

#include <stddef.h>
#include <stdint.h>

#define CHAU_SYNC              0xA55Au
#define CHAU_MAX_SAMPLES       64
#define CHAU_FLAG_GAP_BEFORE   0x01u   /* co mau bi bo ngay truoc block nay */
#define CHAU_FLAG_TEST_SOURCE  0x02u   /* du lieu tu nguon thu (khong phai cam bien that) */
#define CHAU_BLOCK_BYTES(n)    (12u + 2u * (n))
#define CHAU_BLOCK_MAX_BYTES   CHAU_BLOCK_BYTES(CHAU_MAX_SAMPLES)

typedef struct {
    uint32_t ctr;
    uint8_t  idx0;
    uint8_t  count;
    uint8_t  flags;
    uint16_t c[CHAU_MAX_SAMPLES];
} chau_block_t;

uint16_t chau_crc16(const uint8_t *data, size_t len);
/* Ghi block ra out; tra so byte, 0 neu cap khong du hoac block rong. */
size_t   chau_block_serialize(const chau_block_t *b, uint8_t *out, size_t cap);

#endif /* CHAU_BLOCK_H */
