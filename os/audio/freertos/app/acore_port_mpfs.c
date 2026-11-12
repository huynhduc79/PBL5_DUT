/*
 * acore_port_mpfs.c - lop duoi cung tren board cho acore_drv / ctr_store (U54_4).
 *
 *   thanh ghi : doc/ghi volatile 32 bit tai ACORE_BASE (FIC_3, APB3)
 *   ngat      : irq_o -> MSS_INT_F2M[x] -> PLIC cua U54_4
 *   sNVM      : system services (mailbox toi System Controller)
 *
 * Moi ten ham HAL danh dau [KIEM TRA] lay theo mpfs_hal / mss_sys_services ban dang dung.
 * Day la cho DUY NHAT trong RTOS biet dia chi that; common/ khong doi khi chuyen PC <-> board.
 */
#include "acore_port_mpfs.h"

#include <stdint.h>
#include <string.h>

#include "FreeRTOS.h"
#include "queue.h"

#include "mpfs_hal/mss_hal.h"                          /* [KIEM TRA] PLIC_*, EXT_IRQ_* */
#include "drivers/mss/mss_sys_services/mss_sys_services.h"   /* [KIEM TRA] */

#include "board_config.h"

/* ---------------------------------------------------------------- thanh ghi */
static uint32_t mmio_rd(void *ctx, uint32_t off)
{
    (void)ctx;
    return *(volatile uint32_t *)(uintptr_t)(ACORE_BASE + off);
}

static void mmio_wr(void *ctx, uint32_t off, uint32_t val)
{
    (void)ctx;
    *(volatile uint32_t *)(uintptr_t)(ACORE_BASE + off) = val;
    __asm__ volatile ("fence o, o" ::: "memory");     /* giu thu tu ghi APB (vd. KMASTER truoc CTR) */
}

static void busy_us(void *ctx, uint32_t us)
{
    volatile uint64_t *mtime = (volatile uint64_t *)CLINT_MTIME_ADDR;
    uint64_t end = *mtime + (uint64_t)us * MTIME_HZ / 1000000u + 1;
    (void)ctx;
    while (*mtime < end)
        ;
}

void acore_port_bus(acore_bus_t *bus)
{
    bus->rd = mmio_rd;
    bus->wr = mmio_wr;
    bus->delay_us = busy_us;
    bus->ctx = NULL;
}

/* ---------------------------------------------------------------- ngat
 * irq_o la ngat MUC: con du lieu tren nguong thi con cao. ISR tat nguon ngat trong PLIC
 * roi bao task; task rut FIFO, xoa IRQ_STATUS, roi moi bat lai (acore_port_irq_rearm).
 */
static QueueHandle_t s_q;
static const void *s_ev_irq;

uint8_t PLIC_f2m_0_IRQHandler(void)                     /* [KIEM TRA] ten handler ung voi ACORE_PLIC_IRQ */
{
    BaseType_t woken = pdFALSE;
    xQueueSendFromISR(s_q, s_ev_irq, &woken);           /* day hang thi bo: task van poll 20 ms */
    portYIELD_FROM_ISR(woken);
    return EXT_IRQ_DISABLE;                              /* [KIEM TRA] HAL tu tat nguon nay sau khi tra ve */
}

void acore_port_irq_init(QueueHandle_t q, const void *ev_irq)
{
    s_q = q;
    s_ev_irq = ev_irq;
    PLIC_SetPriority(ACORE_PLIC_IRQ, ACORE_PLIC_PRIO);  /* [KIEM TRA] */
    PLIC_EnableIRQ(ACORE_PLIC_IRQ);
}

void acore_port_irq_rearm(void)
{
    PLIC_EnableIRQ(ACORE_PLIC_IRQ);
}

/* ---------------------------------------------------------------- sNVM
 * Chi U54_4 dung System Controller. Neu Linux cung dung (driver mpfs-sys-controller cho
 * RNG, ...), hai ben se tranh nhau mailbox: tat driver do trong device tree, hoac chi
 * goi sNVM luc Linux chua chay (xem HUONG_DAN_OS.md, muc rui ro).
 */
static int snvm_read_page(uint8_t page, uint8_t *buf, uint16_t len)
{
    uint8_t admin[4];
    return MSS_SYS_secure_nvm_read(page, NULL, admin, buf, len, 0) == MSS_SYS_SUCCESS ? 0 : -1;  /* [KIEM TRA] */
}

static int snvm_write_page(uint8_t page, const uint8_t *buf)
{
    return MSS_SYS_secure_nvm_write(MSS_SYS_SNVM_NON_AUTHEN_TEXT_REQUEST_CMD, page, buf, NULL, 0)
           == MSS_SYS_SUCCESS ? 0 : -1;                                                        /* [KIEM TRA] */
}

static int nvm_read(void *ctx, int slot, uint8_t buf[CTR_REC_BYTES])
{
    static uint8_t page[SNVM_PAGE_BYTES];
    (void)ctx;
    if (snvm_read_page(slot ? SNVM_PAGE_CTR1 : SNVM_PAGE_CTR0, page, sizeof page) != 0)
        return -1;
    memcpy(buf, page, CTR_REC_BYTES);
    return 0;
}

static int nvm_write(void *ctx, int slot, const uint8_t buf[CTR_REC_BYTES])
{
    static uint8_t page[SNVM_PAGE_BYTES];
    (void)ctx;
    memset(page, 0, sizeof page);
    memcpy(page, buf, CTR_REC_BYTES);
    return snvm_write_page(slot ? SNVM_PAGE_CTR1 : SNVM_PAGE_CTR0, page);
}

void acore_port_nvm(ctr_nvm_t *nvm)
{
    MSS_SYS_select_service_mode(MSS_SYS_SERVICE_POLLING_MODE, NULL);   /* [KIEM TRA] */
    nvm->read = nvm_read;
    nvm->write = nvm_write;
    nvm->ctx = NULL;
}

int acore_port_load_key(uint8_t k_master[32])
{
    static uint8_t page[SNVM_PAGE_BYTES];
    int rc = snvm_read_page(SNVM_PAGE_KEY, page, sizeof page);
    memcpy(k_master, page, 32);
    memset(page, 0, sizeof page);
    return rc;
}
