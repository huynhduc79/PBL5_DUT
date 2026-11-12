/*
 * fpga_model.h - mo hinh muc thanh ghi cua audio_crypt_top de chay driver tren PC.
 *
 * KHONG phai RTL: lo ma hoa xu ly tuc thi (dung chaos_cipher.c, da khop vector golden).
 * Chi mo phong nhung gi driver nhin thay qua APB, theo cac quy tac muc 6-8 tai lieu FPGA:
 *   - CTR: lan ghi dau sau reset luon nhan; sau do phai > moi ctr da ghi/da dung, khong thi CTR_REJECTED
 *   - RESEED_NOW chi nhan khi co CTR moi duoc nhan tu lan nap truoc, khong thi CMD_IGN
 *   - in_fifo 64 (day thi bo mau TRUOC ma hoa, DROP_CNT++, mau ke tiep co GAP)
 *   - out_fifo 2048 (day thi lo ngung ma hoa, khong bao gio bo o day)
 *   - STARTUP_SKIP chi ap cho MIC; RAMP/SINE di thang
 *   - IRQ muc cao = OR(IRQ_STATUS & IRQ_EN); THRESH tu bat lai khi muc van >= nguong
 */
#ifndef FPGA_MODEL_H
#define FPGA_MODEL_H

#include <stdint.h>

#include "chaos_cipher.h"

#define FM_IN_DEPTH   64
#define FM_OUT_DEPTH  2048

typedef struct {
    uint32_t kmaster[8];
    uint32_t ctr_reg, ctr_max;
    int      ctr_any, ctr_fresh, key_ready, enable;
    uint32_t status_sticky;
    uint32_t i2s_cfg, src_sel, startup_skip, irq_thresh, irq_en, irq_status;
    uint32_t drop_cnt, sample_cnt, cycles_max, clip_cnt, data_out;
    /* da chot luc ENABLE 0 -> 1 */
    uint32_t run_src, skip_left;
    uint16_t ramp, sine_phase;
    int      pending_gap;
    chaos_ctx_t cipher;
    struct { uint16_t s; uint8_t gap; } in[FM_IN_DEPTH];
    uint32_t in_head, in_cnt;
    uint32_t out[FM_OUT_DEPTH];
    uint32_t out_head, out_cnt;
    uint32_t rng;
} fpga_model_t;

void     fm_reset(fpga_model_t *m);
uint32_t fm_rd(void *ctx, uint32_t off);
void     fm_wr(void *ctx, uint32_t off, uint32_t val);
/* Cho thoi gian troi qua nsamples chu ky lay mau (fs). */
void     fm_step(fpga_model_t *m, uint32_t nsamples);
int      fm_irq(const fpga_model_t *m);

#endif /* FPGA_MODEL_H */
