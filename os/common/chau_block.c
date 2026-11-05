#include "chau_block.h"

/* CRC-16/CCITT-FALSE: da thuc 0x1021, gia tri dau 0xFFFF, khong dao bit, khong XOR cuoi. */
uint16_t chau_crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    while (len--) {
        int i;
        crc ^= (uint16_t)(*data++ << 8);
        for (i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

size_t chau_block_serialize(const chau_block_t *b, uint8_t *out, size_t cap)
{
    size_t n = CHAU_BLOCK_BYTES(b->count), pos = 0;
    uint16_t crc;
    unsigned i;

    if (b->count == 0 || b->count > CHAU_MAX_SAMPLES || cap < n)
        return 0;
    out[pos++] = (uint8_t)(CHAU_SYNC >> 8);
    out[pos++] = (uint8_t)CHAU_SYNC;
    out[pos++] = (uint8_t)(b->ctr >> 24);
    out[pos++] = (uint8_t)(b->ctr >> 16);
    out[pos++] = (uint8_t)(b->ctr >> 8);
    out[pos++] = (uint8_t)b->ctr;
    out[pos++] = b->idx0;
    out[pos++] = b->count;
    out[pos++] = b->flags;
    out[pos++] = 0;
    for (i = 0; i < b->count; i++) {
        out[pos++] = (uint8_t)(b->c[i] >> 8);
        out[pos++] = (uint8_t)b->c[i];
    }
    crc = chau_crc16(out + 2, pos - 2);
    out[pos++] = (uint8_t)(crc >> 8);
    out[pos++] = (uint8_t)crc;
    return pos;
}
