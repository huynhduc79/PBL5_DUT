/*
 * app_audio.h - logic ung dung RTOS cho ghi am INMP441, dung chung FreeRTOS (board) va sim (PC).
 *
 * Khong biet gi ve phan cung: dieu khien lo FPGA qua acore_t, luu ctr qua ctr_store_t,
 * day byte sang Linux qua ham tx. Chi duoc goi tu MOT task (khong khoa ben trong).
 *
 * Giao thuc tren kenh RTOS <-> Linux (RPMsg tty tren board, stdin/stdout trong sim):
 *
 *   Linux -> RTOS: dong ASCII ket thuc '\n'
 *     START [mic|ramp|sine] [shift]   bat dau ghi; ctr do RTOS tu lay tu sNVM
 *     STOP                            dung ghi, xoa khoa trong FPGA
 *     STATUS                          hoi trang thai/bo dem
 *
 *   RTOS -> Linux: hai loai ban ghi tron chung mot luong byte
 *     '#' ... '\n'     #HELLO, #OK START ctr=.., #OK STOP last_ctr=.., #STAT .., #ERR ..
 *     0xA5 0x5A ...    block .chau (chau_block.h), co CRC
 *
 * Khac bai DHT22: Linux KHONG cap ctr nua (khong con LEASE). Linux bi chiem quyen cung
 * khong ep duoc RTOS dung lai ctr.
 */
#ifndef APP_AUDIO_H
#define APP_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#include "acore_drv.h"
#include "ctr_store.h"

#define APP_TX_BLOCKS   3            /* 3 block day = 420 byte <= 496 byte/tin RPMsg */

typedef void (*app_tx_fn)(void *ctx, const uint8_t *buf, size_t len);

typedef struct {
    acore_t      core;
    ctr_store_t  ctr;
    acore_cfg_t  cfg;
    uint8_t      k_master[32];
    int          running;
    uint32_t     last_ctr;
    uint32_t     checked_ctr;      /* ctr lan cuoi da goi ctr_store_check */
    app_tx_fn    tx;
    void        *tx_ctx;
    uint8_t      txbuf[APP_TX_BLOCKS * CHAU_BLOCK_MAX_BYTES];
    size_t       txlen;
} app_audio_t;

/* bus: truy cap thanh ghi lo FPGA; nvm: o luu ctr; k_master: 32 byte (doc tu sNVM). */
int  app_audio_init(app_audio_t *a, const acore_bus_t *bus, const ctr_nvm_t *nvm,
                    uint32_t key_id, const uint8_t k_master[32], app_tx_fn tx, void *tx_ctx);
void app_audio_hello(app_audio_t *a);
void app_audio_command(app_audio_t *a, const char *line);
/* Goi khi co ngat irq_o, hoac dinh ky (vd. 20 ms) de phong mat ngat. */
void app_audio_service(app_audio_t *a);

#endif /* APP_AUDIO_H */
