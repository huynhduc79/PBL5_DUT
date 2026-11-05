/*
 * app_core.h - logic ung dung phia RTOS, dung chung cho FreeRTOS (board) va sim (PC).
 *
 * Khong biet gi ve phan cung hay he dieu hanh: nhan su kien (lenh tu Linux, ket qua doc
 * cam bien) va day byte ra qua ham tx. Chi duoc goi tu MOT task (khong khoa ben trong).
 *
 * Giao thuc tren kenh RTOS <-> Linux (RPMsg tty tren board, stdin/stdout trong sim):
 *
 *   Linux -> RTOS: dong van ban ASCII ket thuc bang '\n'
 *     START <ctr> <limit>   bat dau ma hoa tu phien ctr; chi duoc dung ctr < limit
 *     LEASE <limit>         noi rong gioi han ctr (limit moi > limit cu)
 *     STOP                  dung ma hoa
 *     STATUS                hoi trang thai
 *
 *   RTOS -> Linux: hai loai ban ghi tron chung mot luong byte
 *     '#' ... '\n'          dong trang thai ASCII (#HELLO, #OK, #ERR, #STAT, #LEASE_WAIT)
 *     0xA5 0x5A ...         block .chau (chau_block.h), co CRC
 *
 * "Lease" ctr: Linux luu limit xuong the nho TRUOC khi gui, lan khoi dong sau bat dau tu
 * limit da luu. RTOS khong bao gio dung ctr >= limit, nen du mat dien bat ky luc nao
 * cung khong co hai lan ma hoa nao dung chung (K_master, ctr) -> khong lap keystream.
 */
#ifndef APP_CORE_H
#define APP_CORE_H

#include <stddef.h>
#include <stdint.h>

#include "chaos_cipher.h"
#include "chau_block.h"

#define APP_N        16
#define APP_SOURCE   "dht22"

typedef void (*app_tx_fn)(void *ctx, const uint8_t *buf, size_t len);

typedef struct {
    uint32_t reads_ok, reads_fail, blocked, samples, blocks;
} app_stats_t;

typedef struct {
    chaos_ctx_t  cipher;
    uint8_t      k_master[CHAOS_KMASTER_BYTES];
    int          running;
    uint32_t     limit;          /* ctr phai < limit */
    uint64_t     min_next_ctr;   /* ctr nho nhat con duoc phep dung (tang dan tu luc khoi dong) */
    int          pending_gap;    /* co lan doc hong / bi chan truoc block ke tiep */
    int          lease_wait_sent;
    app_stats_t  st;
    app_tx_fn    tx;
    void        *tx_ctx;
} app_t;

void app_init(app_t *a, const uint8_t k_master[CHAOS_KMASTER_BYTES], app_tx_fn tx, void *tx_ctx);
void app_hello(app_t *a);
void app_command(app_t *a, const char *line);
/* ok = 0: doc thanh cong (rh_raw, t_raw hop le); khac 0: ma loi DHT22_ERR_*. */
void app_reading(app_t *a, int ok, uint16_t rh_raw, uint16_t t_raw);

#endif /* APP_CORE_H */
