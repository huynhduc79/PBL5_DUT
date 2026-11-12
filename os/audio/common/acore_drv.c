#include "acore_drv.h"

#include <string.h>

#include "acore_regs.h"

#define KEY_READY_TIMEOUT_US  10000u    /* thuc te vai tram chu ky 50 MHz */
#define STOP_TIMEOUT_US       10000u    /* tai lieu FPGA: ~0,1 ms; 1 ms la du an toan */
#define POLL_STEP_US          10u

static uint32_t rd(acore_t *a, uint32_t off) { return a->bus.rd(a->bus.ctx, off); }
static void wr(acore_t *a, uint32_t off, uint32_t v) { a->bus.wr(a->bus.ctx, off, v); }

static int wait_status(acore_t *a, uint32_t mask, uint32_t want, uint32_t timeout_us)
{
    uint32_t t;
    for (t = 0; t <= timeout_us; t += POLL_STEP_US) {
        if ((rd(a, ACORE_STATUS) & mask) == want)
            return ACORE_OK;
        a->bus.delay_us(a->bus.ctx, POLL_STEP_US);
    }
    return ACORE_ETIMEOUT;
}

void acore_init(acore_t *a, const acore_bus_t *bus, acore_block_fn on_block, void *ctx)
{
    memset(a, 0, sizeof *a);
    a->bus = *bus;
    a->on_block = on_block;
    a->on_block_ctx = ctx;
}

void acore_default_cfg(acore_cfg_t *cfg)
{
    cfg->sck_div = ACORE_SCK_DIV_DEFAULT;
    cfg->channel = 0;
    cfg->shift = 0;
    cfg->src = SRC_MIC;
    cfg->startup_skip = 4096;
    cfg->irq_thresh = 256;
}

int acore_probe(acore_t *a, uint32_t *version)
{
    uint32_t v;
    wr(a, ACORE_CTRL, CTRL_SOFT_RESET);
    v = rd(a, ACORE_VERSION);
    if (version)
        *version = v;
    a->running = 0;
    return v == ACORE_VERSION_EXPECTED ? ACORE_OK : ACORE_EVERSION;
}

/* 8 mau dau cua vectors/out/enc_n16_default.csv (khoa 00..1f, ctr0 = 0) - khoa cong khai. */
static const uint16_t k_vec_p[8] = { 0x0000, 0xffff, 0xa5a5, 0x5a5a, 0x0001, 0x8000, 0x00ff, 0xff00 };
static const uint16_t k_vec_c[8] = { 0x39d0, 0x75ab, 0x7f7d, 0x9d6b, 0x7849, 0xd4af, 0xabc9, 0x15b1 };

int acore_selftest(acore_t *a, int *mismatches)
{
    uint8_t key[32];
    int i, rc = ACORE_OK, bad = 0;

    for (i = 0; i < 32; i++)
        key[i] = (uint8_t)i;
    wr(a, ACORE_CTRL, CTRL_SOFT_RESET);                     /* lan ghi CTR dau sau reset luon nhan, ke ca 0 */
    for (i = 0; i < 8; i++)
        wr(a, ACORE_KMASTER(i), (uint32_t)key[4 * i] << 24 | (uint32_t)key[4 * i + 1] << 16 |
                                (uint32_t)key[4 * i + 2] << 8 | key[4 * i + 3]);
    wr(a, ACORE_CTR, 0);
    wr(a, ACORE_SRC_SEL, SRC_REG);
    wr(a, ACORE_CTRL, CTRL_CMD_RESEED);
    if (wait_status(a, ST_KEY_READY, ST_KEY_READY, KEY_READY_TIMEOUT_US) != ACORE_OK)
        rc = ACORE_ETIMEOUT;
    for (i = 0; rc == ACORE_OK && i < 8; i++) {
        wr(a, ACORE_DATA_IN, k_vec_p[i]);                   /* tu START, ket qua o DATA_OUT */
        if (wait_status(a, ST_BUSY, 0, KEY_READY_TIMEOUT_US) != ACORE_OK)
            rc = ACORE_ETIMEOUT;
        else if (rd(a, ACORE_STATUS) & ST_CMD_IGN)
            rc = ACORE_ECMD;
        else if ((rd(a, ACORE_DATA_OUT) & 0xFFFFu) != k_vec_c[i])
            bad++;
    }
    wr(a, ACORE_CTRL, CTRL_CMD_KEY_CLEAR);
    wr(a, ACORE_CTRL, CTRL_SOFT_RESET);                     /* tra chinh sach CTR ve ban dau cho lan ghi that */
    if (mismatches)
        *mismatches = bad;
    return rc == ACORE_OK && bad ? ACORE_ECMD : rc;
}

static void flush_block(acore_t *a)
{
    if (a->blk.count == 0)
        return;
    a->on_block(a->on_block_ctx, &a->blk);
    a->st.blocks++;
    memset(&a->blk, 0, sizeof a->blk);       /* khong de ban ma cu nam lai */
}

/* Mot tu OUT_DATA -> them vao block dang mo; dong block khi du 64 mau, doi ctr, gap GAP. */
static void push_word(acore_t *a, uint32_t w)
{
    uint8_t lo = W_CTR_LO(w), idx = W_IDX(w), d;
    int gap = (int)W_GAP(w);

    a->st.words++;
    if (!W_VALID(w)) {
        a->st.invalid++;
        return;
    }
    /* Khoi phuc ctr 32 bit: out_fifo khong bao gio bo mau nen d binh thuong la 0 hoac 1. */
    d = (uint8_t)(lo - (uint8_t)a->ctr);
    if (d) {
        a->ctr += d;
        if (d != 1)
            a->st.ctr_jumps++;
    }
    if (a->blk.count) {
        int same_ctr = a->blk.ctr == a->ctr;
        int idx_break = same_ctr && (unsigned)a->blk.idx0 + a->blk.count != idx;
        if (idx_break)
            a->st.idx_breaks++;              /* khong duoc xay ra: keystream luon lien mach */
        if (gap || !same_ctr || idx_break)
            flush_block(a);
    }
    if (a->blk.count == 0) {
        a->blk.ctr = a->ctr;
        a->blk.idx0 = idx;
        a->blk.flags = a->test_src ? CHAU_FLAG_TEST_SOURCE : 0;
        if (gap) {
            uint32_t drop = rd(a, ACORE_DROP_CNT), n = drop - a->last_drop;
            a->last_drop = drop;
            a->blk.flags |= CHAU_FLAG_GAP_BEFORE;
            a->blk.drop_before = (uint8_t)(n > 255 ? 255 : n);
            a->st.gaps++;
        }
    }
    a->blk.c[a->blk.count++] = W_C(w);
    if (a->blk.count == CHAU_MAX_SAMPLES || idx == CHAU_MAX_SAMPLES - 1)
        flush_block(a);
}

int acore_start(acore_t *a, const uint8_t k_master[32], uint32_t ctr_start, const acore_cfg_t *cfg)
{
    int i, rc;
    uint32_t st;

    if (a->running)
        return ACORE_ESTATE;
    wr(a, ACORE_STATUS, ST_W1C_MASK);                       /* xoa co dinh tu lan truoc */
    for (i = 0; i < 8; i++) {
        const uint8_t *p = k_master + 4 * i;
        wr(a, ACORE_KMASTER(i), (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
    }
    wr(a, ACORE_CTR, ctr_start);
    st = rd(a, ACORE_STATUS);
    if (st & ST_CTR_REJECTED) {
        wr(a, ACORE_CTRL, CTRL_CMD_KEY_CLEAR);
        return ACORE_ECTR;
    }
    wr(a, ACORE_CTRL, CTRL_CMD_RESEED);
    rc = wait_status(a, ST_KEY_READY, ST_KEY_READY, KEY_READY_TIMEOUT_US);
    if (rd(a, ACORE_STATUS) & ST_CMD_IGN)
        rc = ACORE_ECMD;
    if (rc != ACORE_OK) {
        wr(a, ACORE_CTRL, CTRL_CMD_KEY_CLEAR);
        return rc;
    }

    wr(a, ACORE_I2S_CFG, I2S_CFG(cfg->sck_div, cfg->channel, cfg->shift));
    wr(a, ACORE_SRC_SEL, cfg->src);
    wr(a, ACORE_STARTUP_SKIP, cfg->startup_skip);
    wr(a, ACORE_IRQ_THRESH, cfg->irq_thresh);
    wr(a, ACORE_DROP_CNT, 0);
    wr(a, ACORE_CYCLES_MAX, 0);
    wr(a, ACORE_CLIP_CNT, 0);
    wr(a, ACORE_IRQ_STATUS, IRQ_THRESH_BIT | IRQ_IN_OVF_BIT | IRQ_ERROR_BIT);
    wr(a, ACORE_IRQ_EN, IRQ_THRESH_BIT | IRQ_IN_OVF_BIT | IRQ_ERROR_BIT);

    memset(&a->blk, 0, sizeof a->blk);
    memset(&a->st, 0, sizeof a->st);
    a->ctr = a->ctr_start = ctr_start;
    a->last_drop = 0;
    a->test_src = cfg->src != SRC_MIC;
    a->running = 1;
    wr(a, ACORE_CTRL, CTRL_CMD_RUN);                        /* cau hinh I2S/SRC chot o day */
    return ACORE_OK;
}

uint32_t acore_drain(acore_t *a)
{
    uint32_t n = FIFO_OUT_LEVEL(rd(a, ACORE_FIFO_LEVEL)), i;
    for (i = 0; i < n; i++)
        push_word(a, rd(a, ACORE_OUT_DATA));
    return n;
}

void acore_irq_ack(acore_t *a)
{
    /* THRESH tu bat lai neu muc van >= nguong, nen xoa sau khi da rut. */
    wr(a, ACORE_IRQ_STATUS, rd(a, ACORE_IRQ_STATUS));
}

int acore_stop(acore_t *a, uint32_t *last_ctr)
{
    int rc;
    uint32_t t;

    if (!a->running)
        return ACORE_ESTATE;
    wr(a, ACORE_CTRL, CTRL_CMD_IDLE);                       /* FPGA van ma not mau trong in_fifo */
    rc = ACORE_ETIMEOUT;
    for (t = 0; t <= STOP_TIMEOUT_US; t += POLL_STEP_US) {
        acore_drain(a);                                     /* out_fifo co the day: phai rut de lo chay tiep */
        if (FIFO_IN_LEVEL(rd(a, ACORE_FIFO_LEVEL)) == 0 && !(rd(a, ACORE_STATUS) & ST_BUSY)) {
            rc = ACORE_OK;
            break;
        }
        a->bus.delay_us(a->bus.ctx, POLL_STEP_US);
    }
    acore_drain(a);
    flush_block(a);
    wr(a, ACORE_CTRL, CTRL_CMD_KEY_CLEAR);
    wr(a, ACORE_IRQ_EN, 0);
    a->running = 0;
    if (last_ctr)
        *last_ctr = a->ctr;      /* phien dang do cung tinh la da dung */
    return rc;
}
