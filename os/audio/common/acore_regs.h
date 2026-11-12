/*
 * acore_regs.h - ban do thanh ghi APB3 cua khoi audio_crypt_top (phia FPGA).
 *
 * Nguon: "PBL5 - Tinh trang FPGA va giao tiep FPGA <-> RTOS" (12/11/2026), muc 6,
 * va chu thich dau file libero/chaos_crypto/hdl/apb3_slave_regs.v cua thanh vien ma hoa.
 * Offset 0x00-0x60 giu dung hop dong 31/10; them CLIP_CNT (0x64) va DBG (0x68).
 * Moi thanh ghi 32 bit, chi giai ma paddr[7:2] (cua so 256 byte). W1C = ghi 1 de xoa.
 *
 * KHONG tu y doi file nay: doi o FPGA thi phai sua tai lieu hop dong truoc (CLAUDE.md).
 */
#ifndef ACORE_REGS_H
#define ACORE_REGS_H

#define ACORE_VERSION_EXPECTED  0x00020100u

/* ---------------------------------------------------------------- offset */
#define ACORE_CTRL          0x00u
#define ACORE_STATUS        0x04u
#define ACORE_KMASTER(i)    (0x08u + 4u * (i))   /* i = 0..7, KMASTER[0] = K[255:224]; chi ghi */
#define ACORE_CTR           0x28u
#define ACORE_DATA_IN       0x2Cu
#define ACORE_DATA_OUT      0x30u
#define ACORE_I2S_CFG       0x34u
#define ACORE_SRC_SEL       0x38u
#define ACORE_FIFO_LEVEL    0x3Cu
#define ACORE_OUT_DATA      0x40u                /* doc = lay 1 tu khoi out_fifo */
#define ACORE_IRQ_THRESH    0x44u
#define ACORE_IRQ_EN        0x48u
#define ACORE_IRQ_STATUS    0x4Cu
#define ACORE_DROP_CNT      0x50u                /* ghi de xoa */
#define ACORE_SAMPLE_CNT    0x54u
#define ACORE_CYCLES_MAX    0x58u                /* ghi de xoa */
#define ACORE_STARTUP_SKIP  0x5Cu
#define ACORE_VERSION       0x60u
#define ACORE_CLIP_CNT      0x64u                /* ghi de xoa */
#define ACORE_DBG           0x68u

/* ---------------------------------------------------------------- CTRL
 * Bit xung (*) doc ve 0. CTRL la thanh ghi ca 32 bit: moi lan ghi phai kem N_SEL = 1,
 * va moi lan ghi chi nen co MOT lenh (uu tien KEY_CLEAR > RESEED_NOW > START).
 */
#define CTRL_ENABLE         (1u << 0)
#define CTRL_START          (1u << 1)    /* * che do REG */
#define CTRL_RESEED_NOW     (1u << 2)    /* * */
#define CTRL_FIFO_CLR       (1u << 3)    /* * */
#define CTRL_KEY_CLEAR      (1u << 4)    /* * huy ca mau dang ma */
#define CTRL_OP_SHIFT       6            /* [7:6] 0 ENC, 1 DEC, 2/3 SKIP; chi che do REG */
#define CTRL_N_SEL          (1u << 8)    /* 1 = N 16 (mac dinh) */
#define CTRL_SOFT_RESET     (1u << 31)   /* * */

/* Cac gia tri ghi CTRL dung trong trinh tu muc 7 */
#define CTRL_CMD_RESEED     (CTRL_N_SEL | CTRL_RESEED_NOW)   /* 0x0000_0104 */
#define CTRL_CMD_RUN        (CTRL_N_SEL | CTRL_ENABLE)       /* 0x0000_0101 */
#define CTRL_CMD_IDLE       (CTRL_N_SEL)                     /* 0x0000_0100 */
#define CTRL_CMD_KEY_CLEAR  (CTRL_N_SEL | CTRL_KEY_CLEAR)    /* 0x0000_0110 */

/* ---------------------------------------------------------------- STATUS († = W1C) */
#define ST_BUSY             (1u << 0)
#define ST_KEY_READY        (1u << 1)
#define ST_ERROR            (1u << 2)    /* † */
#define ST_IN_OVF           (1u << 3)    /* † */
#define ST_OUT_FULL         (1u << 4)
#define ST_OUT_GE_THRESH    (1u << 5)
#define ST_I2S_RUNNING      (1u << 6)
#define ST_CTR_REJECTED     (1u << 7)    /* † ghi CTR <= ctr da dung */
#define ST_CMD_IGN          (1u << 8)    /* † lenh bi bo (sai dieu kien) */
#define ST_W1C_MASK         (ST_ERROR | ST_IN_OVF | ST_CTR_REJECTED | ST_CMD_IGN)

/* ---------------------------------------------------------------- I2S_CFG, SRC_SEL */
#define I2S_CFG(sck_div, channel, shift) \
    (((sck_div) & 0xFFFu) | (((channel) & 1u) << 12) | (((shift) & 0xFu) << 16))
#define ACORE_SCK_DIV_DEFAULT   24u      /* SCK = 50 MHz / (2*(24+1)) = 1 MHz, fs = 15 625 Hz */
#define ACORE_FS_MILLI_HZ       15625000u

#define SRC_MIC             0u
#define SRC_RAMP            1u
#define SRC_SINE            2u
#define SRC_REG             3u

/* ---------------------------------------------------------------- FIFO_LEVEL */
#define FIFO_OUT_LEVEL(v)   ((v) & 0xFFFFu)
#define FIFO_IN_LEVEL(v)    ((v) >> 16)
#define ACORE_OUT_FIFO_DEPTH 2048u
#define ACORE_IN_FIFO_DEPTH  64u

/* ---------------------------------------------------------------- IRQ_EN / IRQ_STATUS */
#define IRQ_THRESH_BIT      (1u << 0)
#define IRQ_IN_OVF_BIT      (1u << 1)
#define IRQ_ERROR_BIT       (1u << 2)

/* ---------------------------------------------------------------- tu OUT_DATA
 *  [31:24] ctr[7:0] | [23] GAP | [22] VALID | [21:16] idx | [15:0] C
 */
#define W_CTR_LO(w)         ((uint8_t)((w) >> 24))
#define W_GAP(w)            (((w) >> 23) & 1u)
#define W_VALID(w)          (((w) >> 22) & 1u)
#define W_IDX(w)            ((uint8_t)(((w) >> 16) & 0x3Fu))
#define W_C(w)              ((uint16_t)(w))

#endif /* ACORE_REGS_H */
