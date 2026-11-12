/*
 * acore_drv.h - driver khoi audio_crypt_top (FPGA) phia RTOS, dung chung board + PC.
 *
 * Driver khong biet dia chi that hay ngat: moi truy cap thanh ghi di qua acore_bus_t.
 *   board : rd/wr = doc/ghi volatile tai FIC_3 base (acore_port_mpfs.c)
 *   PC    : rd/wr = mo hinh FPGA (sim/fpga_model.c)
 *
 * Trinh tu theo muc 7 tai lieu FPGA:
 *   acore_probe()  : SOFT_RESET, kiem VERSION                     (1 lan sau khi boot)
 *   acore_start()  : KMASTER, CTR, RESEED_NOW, cau hinh, ENABLE   (moi lan ghi am)
 *   acore_drain()  : doc FIFO_LEVEL, doc OUT_DATA dung ngan ay lan, dong block .chau
 *   acore_stop()   : tat ENABLE, cho in_fifo rut het, rut out_fifo, KEY_CLEAR
 *
 * Chi MOT task goi cac ham nay (task drain/app); ISR chi bao thuc task do.
 */
#ifndef ACORE_DRV_H
#define ACORE_DRV_H

#include <stdint.h>

#include "chau_block.h"

typedef struct {
    uint32_t (*rd)(void *ctx, uint32_t off);
    void     (*wr)(void *ctx, uint32_t off, uint32_t val);
    void     (*delay_us)(void *ctx, uint32_t us);
    void      *ctx;
} acore_bus_t;

typedef struct {
    uint16_t sck_div;        /* 24 -> fs 15 625 Hz */
    uint8_t  channel;        /* 0 = trai (L/R noi GND) */
    uint8_t  shift;          /* 0..8, chinh theo CLIP_CNT */
    uint8_t  src;            /* SRC_MIC / SRC_RAMP / SRC_SINE */
    uint32_t startup_skip;   /* 4096 */
    uint32_t irq_thresh;     /* 256 */
} acore_cfg_t;

/* Goi moi khi dong xong mot block (tu trong acore_drain/acore_stop). */
typedef void (*acore_block_fn)(void *ctx, const chau_block_t *b);

typedef struct {
    uint32_t words, invalid, blocks, gaps, ctr_jumps, idx_breaks;
} acore_stats_t;

typedef struct {
    acore_bus_t    bus;
    acore_block_fn on_block;
    void          *on_block_ctx;
    int            running;
    uint32_t       ctr;          /* ctr day du 32 bit cua tu gan nhat (khoi tao = ctr_start) */
    uint32_t       ctr_start;
    uint32_t       last_drop;    /* DROP_CNT lan doc truoc */
    uint8_t        test_src;
    chau_block_t   blk;          /* block dang mo (count = 0: chua co) */
    acore_stats_t  st;
} acore_t;

enum {
    ACORE_OK = 0,
    ACORE_EVERSION = -1,      /* VERSION != 0x0002_0100: sai bitstream */
    ACORE_ECTR = -2,          /* CTR_REJECTED: ctr khong tang chat */
    ACORE_ECMD = -3,          /* CMD_IGN: lenh bi bo */
    ACORE_ETIMEOUT = -4,      /* KEY_READY / rut in_fifo qua lau */
    ACORE_ESTATE = -5         /* goi sai thu tu (vd. start khi dang chay) */
};

void acore_init(acore_t *a, const acore_bus_t *bus, acore_block_fn on_block, void *ctx);
void acore_default_cfg(acore_cfg_t *cfg);
/* SOFT_RESET + kiem VERSION. Tra ACORE_OK hoac ACORE_EVERSION (*version = gia tri doc). */
int  acore_probe(acore_t *a, uint32_t *version);
/* Moc M1: che do REG (SRC_SEL = 3), ma 8 mau cua enc_n16_default bang khoa vector cong khai,
 * so voi golden, roi SOFT_RESET. Goi ngay sau acore_probe, truoc lan ghi am dau tien.
 * Tra ACORE_OK neu khop het; *mismatches = so mau sai. */
int  acore_selftest(acore_t *a, int *mismatches);
/* Nap khoa + ctr, cau hinh, bat ghi. k_master: 32 byte, big-endian (K[255:248] = k_master[0]). */
int  acore_start(acore_t *a, const uint8_t k_master[32], uint32_t ctr_start, const acore_cfg_t *cfg);
/* Rut moi tu dang co trong out_fifo; tra so tu da doc (ke ca VALID = 0). */
uint32_t acore_drain(acore_t *a);
/* Xoa co ngat da xu ly (sau acore_drain trong vong ngat). */
void acore_irq_ack(acore_t *a);
/* Dung ghi, rut het, dong block do, xoa khoa trong FPGA.
 * *last_ctr = ctr lon nhat da dung (lan ghi sau phai dung ctr > gia tri nay). */
int  acore_stop(acore_t *a, uint32_t *last_ctr);

#endif /* ACORE_DRV_H */
