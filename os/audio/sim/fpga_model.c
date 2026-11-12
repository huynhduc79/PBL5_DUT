#include "fpga_model.h"

#include <math.h>
#include <string.h>

#include "acore_regs.h"

void fm_reset(fpga_model_t *m)
{
    uint32_t rng = m->rng ? m->rng : 1;
    memset(m, 0, sizeof *m);
    m->rng = rng;
    m->i2s_cfg = I2S_CFG(ACORE_SCK_DIV_DEFAULT, 0, 0);
    m->startup_skip = 4096;
    m->irq_thresh = 256;
}

static void update_irq(fpga_model_t *m)
{
    if (m->out_cnt >= m->irq_thresh)
        m->irq_status |= IRQ_THRESH_BIT;
}

/* Lo ma hoa: rut in_fifo vao out_fifo trong luc out_fifo con cho (tuc thi). */
static void process(fpga_model_t *m)
{
    while (m->key_ready && m->in_cnt && m->out_cnt < FM_OUT_DEPTH) {
        uint16_t c;
        uint32_t ctr = m->cipher.ctr, idx = m->cipher.idx;
        int gap = m->in[m->in_head].gap;
        chaos_encrypt(&m->cipher, m->in[m->in_head].s, &c, NULL);
        m->in_head = (m->in_head + 1) % FM_IN_DEPTH;
        m->in_cnt--;
        if (ctr > m->ctr_max)
            m->ctr_max = ctr;
        m->out[(m->out_head + m->out_cnt) % FM_OUT_DEPTH] =
            (ctr & 0xFFu) << 24 | (uint32_t)gap << 23 | 1u << 22 | (idx & 0x3Fu) << 16 | c;
        m->out_cnt++;
        m->sample_cnt++;
        if (m->cycles_max < 331)
            m->cycles_max = idx == 63 ? 331 : 68;
    }
    update_irq(m);
}

static uint16_t next_sample(fpga_model_t *m)
{
    switch (m->run_src) {
    case SRC_RAMP:
        return m->ramp++;
    case SRC_SINE: {
        double v = sin(2.0 * 3.14159265358979 * 1000.0 * m->sine_phase++ / 15625.0);
        if (m->sine_phase >= 15625)
            m->sine_phase = 0;
        return (uint16_t)(int16_t)lrint(v * 0x4000);
    }
    default: {                                 /* "micro": nhieu nho + giong noi gia */
        int32_t s24;
        m->rng = m->rng * 1103515245u + 12345u;
        s24 = (int32_t)((m->rng >> 8) & 0xFFFF) - 0x8000;
        s24 = s24 * 4 + (int32_t)(sin(m->sine_phase++ * 0.05) * 600000.0);
        {
            int shift = (int)((m->i2s_cfg >> 16) & 0xF), sh = 8 - (shift > 8 ? 8 : shift);
            int32_t v = s24 >> sh;
            if (v > 32767) { v = 32767; m->clip_cnt++; }
            if (v < -32768) { v = -32768; m->clip_cnt++; }
            return (uint16_t)(int16_t)v;
        }
    }
    }
}

void fm_step(fpga_model_t *m, uint32_t nsamples)
{
    while (nsamples--) {
        if (m->enable && m->key_ready) {
            uint16_t s = next_sample(m);
            if (m->run_src == SRC_MIC && m->skip_left) {
                m->skip_left--;
            } else if (m->in_cnt == FM_IN_DEPTH) {
                m->drop_cnt++;
                m->pending_gap = 1;
                m->status_sticky |= ST_IN_OVF;
                m->irq_status |= IRQ_IN_OVF_BIT;
            } else {
                uint32_t t = (m->in_head + m->in_cnt) % FM_IN_DEPTH;
                m->in[t].s = s;
                m->in[t].gap = (uint8_t)m->pending_gap;
                m->pending_gap = 0;
                m->in_cnt++;
            }
        }
        process(m);
    }
}

int fm_irq(const fpga_model_t *m)
{
    return (m->irq_status & m->irq_en) != 0;
}

uint32_t fm_rd(void *ctx, uint32_t off)
{
    fpga_model_t *m = ctx;
    process(m);
    switch (off) {
    case ACORE_CTRL:
        return (m->enable ? CTRL_ENABLE : 0) | CTRL_N_SEL;
    case ACORE_STATUS:
        return (m->in_cnt ? ST_BUSY : 0) | (m->key_ready ? ST_KEY_READY : 0) |
               (m->out_cnt == FM_OUT_DEPTH ? ST_OUT_FULL : 0) |
               (m->out_cnt >= m->irq_thresh ? ST_OUT_GE_THRESH : 0) |
               (m->enable && m->run_src == SRC_MIC ? ST_I2S_RUNNING : 0) | m->status_sticky;
    case ACORE_CTR:
        return m->key_ready ? m->cipher.ctr : m->ctr_reg;
    case ACORE_DATA_OUT:
        return m->data_out;
    case ACORE_I2S_CFG:
        return m->i2s_cfg;
    case ACORE_SRC_SEL:
        return m->src_sel;
    case ACORE_FIFO_LEVEL:
        return m->in_cnt << 16 | m->out_cnt;
    case ACORE_OUT_DATA: {
        uint32_t w;
        if (!m->out_cnt)
            return 0;                          /* VALID = 0 */
        w = m->out[m->out_head];
        m->out_head = (m->out_head + 1) % FM_OUT_DEPTH;
        m->out_cnt--;
        process(m);                            /* co cho trong -> lo chay tiep */
        return w;
    }
    case ACORE_IRQ_THRESH: return m->irq_thresh;
    case ACORE_IRQ_EN:     return m->irq_en;
    case ACORE_IRQ_STATUS: return m->irq_status;
    case ACORE_DROP_CNT:   return m->drop_cnt;
    case ACORE_SAMPLE_CNT: return m->sample_cnt;
    case ACORE_CYCLES_MAX: return m->cycles_max;
    case ACORE_STARTUP_SKIP: return m->startup_skip;
    case ACORE_VERSION:    return ACORE_VERSION_EXPECTED;
    case ACORE_CLIP_CNT:   return m->clip_cnt;
    default:               return 0;           /* KMASTER chi ghi, o trong doc 0 */
    }
}

static void cmd(fpga_model_t *m, uint32_t v)
{
    if (v & CTRL_SOFT_RESET) {
        fm_reset(m);
        return;
    }
    if (v & CTRL_KEY_CLEAR) {                  /* uu tien cao nhat */
        memset(m->kmaster, 0, sizeof m->kmaster);
        chaos_wipe(&m->cipher);
        m->key_ready = 0;
        m->in_cnt = 0;
    } else if (v & CTRL_RESEED_NOW) {
        if (m->in_cnt || !m->ctr_fresh) {
            m->status_sticky |= ST_CMD_IGN;
        } else {
            uint8_t k[32];
            int i;
            for (i = 0; i < 8; i++) {
                k[4 * i] = m->kmaster[i] >> 24;
                k[4 * i + 1] = m->kmaster[i] >> 16;
                k[4 * i + 2] = m->kmaster[i] >> 8;
                k[4 * i + 3] = (uint8_t)m->kmaster[i];
            }
            chaos_init(&m->cipher, k, 16, 64, m->ctr_reg);
            memset(k, 0, sizeof k);
            m->key_ready = 1;
            m->ctr_fresh = 0;
        }
    }
    if (v & CTRL_FIFO_CLR) {
        m->in_cnt = 0;
        m->out_cnt = 0;
    }
    if ((v & CTRL_ENABLE) && !m->enable) {     /* chot cau hinh luc 0 -> 1 */
        m->run_src = m->src_sel;
        m->skip_left = m->startup_skip;
        m->ramp = 0;
        m->sine_phase = 0;
        m->pending_gap = 0;
    }
    m->enable = (v & CTRL_ENABLE) != 0;
}

void fm_wr(void *ctx, uint32_t off, uint32_t v)
{
    fpga_model_t *m = ctx;
    if (off >= ACORE_KMASTER(0) && off <= ACORE_KMASTER(7)) {
        m->kmaster[(off - ACORE_KMASTER(0)) / 4] = v;
        return;
    }
    switch (off) {
    case ACORE_CTRL:   cmd(m, v); break;
    case ACORE_STATUS: m->status_sticky &= ~(v & ST_W1C_MASK); break;
    case ACORE_CTR:
        if (!m->ctr_any || v > m->ctr_max) {
            m->ctr_reg = m->ctr_max = v;
            m->ctr_any = m->ctr_fresh = 1;
        } else {
            m->status_sticky |= ST_CTR_REJECTED;
        }
        break;
    case ACORE_DATA_IN:                         /* che do REG: tu START, khong vao out_fifo */
        if (m->src_sel == SRC_REG && !m->enable && m->key_ready && !m->in_cnt) {
            uint16_t c;
            chaos_encrypt(&m->cipher, (uint16_t)v, &c, NULL);
            m->data_out = c;
        } else {
            m->status_sticky |= ST_CMD_IGN;
        }
        break;
    case ACORE_I2S_CFG:      m->i2s_cfg = v & 0xF1FFFu; break;
    case ACORE_SRC_SEL:      m->src_sel = v & 3u; break;
    case ACORE_IRQ_THRESH:   m->irq_thresh = v; break;
    case ACORE_IRQ_EN:       m->irq_en = v & 7u; break;
    case ACORE_IRQ_STATUS:   m->irq_status &= ~(v & 7u); update_irq(m); break;
    case ACORE_DROP_CNT:     m->drop_cnt = 0; break;
    case ACORE_CYCLES_MAX:   m->cycles_max = 0; break;
    case ACORE_STARTUP_SKIP: m->startup_skip = v; break;
    case ACORE_CLIP_CNT:     m->clip_cnt = 0; break;
    default: break;
    }
    process(m);
}
