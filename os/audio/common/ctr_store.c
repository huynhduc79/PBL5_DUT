#include "ctr_store.h"

#include <string.h>

#include "chau_block.h"          /* chau_crc16 */

/* Ban ghi (big-endian): magic "CTRS" | seq(4) | next(8) | key_id(4) | 0... | crc16(2) o cuoi */
static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = (uint8_t)v; }
static uint32_t get32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

static void encode(uint8_t *b, uint32_t seq, uint64_t next, uint32_t key_id)
{
    uint16_t crc;
    memset(b, 0, CTR_REC_BYTES);
    memcpy(b, "CTRS", 4);
    put32(b + 4, seq);
    put32(b + 8, (uint32_t)(next >> 32));
    put32(b + 12, (uint32_t)next);
    put32(b + 16, key_id);
    crc = chau_crc16(b, CTR_REC_BYTES - 2);
    b[CTR_REC_BYTES - 2] = crc >> 8;
    b[CTR_REC_BYTES - 1] = (uint8_t)crc;
}

static int decode(const uint8_t *b, uint32_t *seq, uint64_t *next, uint32_t *key_id)
{
    if (memcmp(b, "CTRS", 4) != 0 ||
        chau_crc16(b, CTR_REC_BYTES - 2) != ((uint16_t)b[CTR_REC_BYTES - 2] << 8 | b[CTR_REC_BYTES - 1]))
        return 0;
    *seq = get32(b + 4);
    *next = (uint64_t)get32(b + 8) << 32 | get32(b + 12);
    *key_id = get32(b + 16);
    return 1;
}

int ctr_store_open(ctr_store_t *s, const ctr_nvm_t *nvm, uint32_t key_id)
{
    int slot, found = 0;
    uint32_t best_key = 0;

    memset(s, 0, sizeof *s);
    s->nvm = *nvm;
    s->key_id = key_id;
    s->slot = -1;
    for (slot = 0; slot < 2; slot++) {
        uint8_t b[CTR_REC_BYTES];
        uint32_t seq, kid;
        uint64_t next;
        if (s->nvm.read(s->nvm.ctx, slot, b) != 0 || !decode(b, &seq, &next, &kid))
            continue;
        if (!found || seq > s->seq) {
            s->seq = seq;
            s->next = next;
            s->slot = slot;
            best_key = kid;
            found = 1;
        }
    }
    if (found && best_key != key_id)
        return CTR_EKEYID;
    return CTR_OK;               /* chua co ban ghi nao: khoa moi, next = 0 */
}

static int persist(ctr_store_t *s, uint64_t next)
{
    uint8_t b[CTR_REC_BYTES];
    int slot = s->slot == 0 ? 1 : 0;           /* ghi o kia, o cu van con neu mat dien */

    if (next > CTR_SPACE)
        next = CTR_SPACE;
    if (next <= s->next)
        return CTR_OK;                         /* chi tang, khong bao gio lui */
    encode(b, s->seq + 1, next, s->key_id);
    if (s->nvm.write(s->nvm.ctx, slot, b) != 0)
        return CTR_EIO;
    s->seq++;
    s->slot = slot;
    s->next = next;
    return CTR_OK;
}

int ctr_store_begin(ctr_store_t *s, uint32_t *ctr_start)
{
    uint64_t start = s->next;
    int rc;

    if (start >= CTR_SPACE - CTR_STOP_MARGIN)
        return CTR_EEXHAUSTED;
    rc = persist(s, start + CTR_RESERVE_BLOCK);
    if (rc != CTR_OK)
        return rc;
    *ctr_start = (uint32_t)start;
    return CTR_OK;
}

int ctr_store_check(ctr_store_t *s, uint32_t ctr_now)
{
    uint64_t now = ctr_now, left = s->next > now ? s->next - now : 0;

    if (left < CTR_RENEW_MARGIN && s->next < CTR_SPACE)
        (void)persist(s, now + CTR_RESERVE_BLOCK);
    left = s->next > now ? s->next - now : 0;
    return left < CTR_STOP_MARGIN ? CTR_MUST_STOP : CTR_OK;
}
