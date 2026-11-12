/*
 * board_config.h - cau hinh phan cung cho ghi am INMP441 tren PolarFire SoC Discovery Kit (U54_4).
 *
 * Moi gia tri danh dau [KIEM TRA] phai doi chieu voi:
 *   - SmartDesign cua thanh vien ma hoa (dia chi FIC_3, so ngat F2M) - ho se bao sau khi chot
 *   - mpfs_hal / mss_sys_services va vi du AMP cua Microchip ban dung lam goc
 */
#ifndef BOARD_CONFIG_H
#define BOARD_CONFIG_H

/* ---------------------------------------------------------------- lo audio_crypt_top
 * FIC_3 la cong APB toc do thap cua MSS ra fabric. Khoi chi giai ma paddr[7:2] (256 byte).
 */
#define ACORE_BASE          0x40000000ul    /* [KIEM TRA] dia chi goc FIC_3 + offset trong SmartDesign */
#define ACORE_PLIC_IRQ      FABRIC_F2H_0_PLIC   /* [KIEM TRA] irq_o -> MSS_INT_F2M[x], ten trong mss_plic.h */
#define ACORE_PLIC_PRIO     2
#define ACORE_POLL_MS       20              /* phuc vu dinh ky ke ca khi khong co ngat (phong mat ngat) */

/* ---------------------------------------------------------------- sNVM
 * Trang 0: K_master (32 byte). Trang 1, 2: hai o ban ghi ctr (ctr_store.c, ghi xen ke).
 * Dung che do khong xac thuc cho buoc dau; nang cap: che do xac thuc/ma hoa voi USK.
 */
#define SNVM_PAGE_KEY       0u              /* [KIEM TRA] trang sNVM con trong, khong trung thiet ke khac */
#define SNVM_PAGE_CTR0      1u
#define SNVM_PAGE_CTR1      2u
#define SNVM_PAGE_BYTES     252u            /* [KIEM TRA] kich thuoc trang che do non-authenticated */
#define KEY_ID              1u              /* so thu tu khoa nhom tu dat, ghi vao header .chau */

/* ---------------------------------------------------------------- dong ho */
#define CLINT_MTIME_ADDR    0x0200BFF8ul    /* CLINT base 0x0200_0000 + 0xBFF8 */
#define MTIME_HZ            1000000ul       /* [KIEM TRA] PolarFire SoC: 1 MHz */

/* ---------------------------------------------------------------- RPMsg toi Linux */
#define LINK_CHANNEL_NAME   "rpmsg-tty"     /* [KIEM TRA] ten driver rpmsg_tty ben Linux nhan */
#define LINK_LOCAL_EPT_ADDR 30u
#define LINK_MAX_PAYLOAD    496u            /* 3 block day = 420 byte, vua mot tin */
/* RPMSG_SHMEM_BASE va RPMSG_LINK_ID: lay dung macro trong vi du AMP Microchip. */

/* ---------------------------------------------------------------- task FreeRTOS */
#define PRIO_APP            (tskIDLE_PRIORITY + 3)   /* rut FIFO: uu tien cao nhat */
#define PRIO_LINK_RX        (tskIDLE_PRIORITY + 2)
#define STACK_APP           2048
#define STACK_LINK_RX       1024
#define EVENT_QUEUE_LEN     16

#endif /* BOARD_CONFIG_H */
