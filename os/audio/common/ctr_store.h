/*
 * ctr_store.h - quan ly ctr phien tren bo nho ben (sNVM tren board, file tren PC).
 *
 * Muc tieu duy nhat: KHONG BAO GIO dung lai (K_master, ctr) - ke ca khi mat dien bat ky luc nao.
 * Chinh sach theo tai lieu FPGA (muc 4, 7): ctr do RTOS giu, khong lay tu Linux.
 *
 *   Ban ghi luu "next": moi ctr < next co the DA dung.  Bat bien: ctr dang dung < next da luu.
 *   begin : start = next;  ghi next = start + 2^20 XUONG sNVM TRUOC;  roi moi tra start.
 *   check : (goi dinh ky khi dang ghi) con < 2^16 phien den next thi ghi next = ctr + 2^20.
 *           Con < 2^10 phien ma chua ghi duoc -> bao MUST_STOP (dung ghi am ngay).
 *   Mat dien: lan sau bat dau tu next da luu, luon > moi ctr da dung.
 *
 * 2^20 phien x 64 mau / 15 625 Hz ~ 71,6 phut ghi cho moi lan ghi sNVM.
 * Ghi xen ke 2 o (A/B) co seq + CRC: mat dien giua luc ghi thi o kia van hop le.
 * Moi lan bat dau ghi am ton toi da 2^20 ctr -> mot khoa dung duoc >= 4096 lan bat dau.
 */
#ifndef CTR_STORE_H
#define CTR_STORE_H

#include <stdint.h>

#define CTR_REC_BYTES       32
#define CTR_RESERVE_BLOCK   (1ull << 20)
#define CTR_RENEW_MARGIN    (1ull << 16)   /* ~4,5 phut truoc khi het khoi */
#define CTR_STOP_MARGIN     (1ull << 10)   /* ~4 s; out_fifo chi chay truoc RTOS ~131 ms */
#define CTR_SPACE           (1ull << 32)

typedef struct {
    /* slot = 0 hoac 1. Tra 0 neu thanh cong. read tra khac 0 hoac du lieu rac deu duoc. */
    int  (*read)(void *ctx, int slot, uint8_t buf[CTR_REC_BYTES]);
    int  (*write)(void *ctx, int slot, const uint8_t buf[CTR_REC_BYTES]);
    void  *ctx;
} ctr_nvm_t;

typedef struct {
    ctr_nvm_t nvm;
    uint32_t  key_id;
    uint32_t  seq;
    int       slot;           /* o dang chua ban moi nhat (-1: chua co) */
    uint64_t  next;           /* gia tri da luu */
} ctr_store_t;

enum {
    CTR_OK = 0,
    CTR_EIO = -1,             /* ghi sNVM loi */
    CTR_EKEYID = -2,          /* ban ghi thuoc khoa khac: khong tu reset, phai xoa tay */
    CTR_EEXHAUSTED = -3,      /* het 2^32 ctr voi khoa nay: doi K_master */
    CTR_MUST_STOP = -4        /* sap vuot phan da dat truoc ma khong gia han duoc */
};

int ctr_store_open(ctr_store_t *s, const ctr_nvm_t *nvm, uint32_t key_id);
int ctr_store_begin(ctr_store_t *s, uint32_t *ctr_start);
/* ctr_now = ctr cua tu OUT_DATA moi nhat. */
int ctr_store_check(ctr_store_t *s, uint32_t ctr_now);

#endif /* CTR_STORE_H */
