/*
 * board_config.h - cau hinh phan cung cho bai thu DHT22 tren PolarFire SoC Discovery Kit.
 *
 * Moi gia tri danh dau [KIEM TRA] phai doi chieu voi thiet ke Libero va vi du AMP cua
 * Microchip ma ban dung lam goc (xem os/HUONG_DAN_BOARD.md).
 */
#ifndef BOARD_CONFIG_H
#define BOARD_CONFIG_H

/* ---------------------------------------------------------------- DHT22 qua MSS GPIO_2
 * Chan DATA cua DHT22 noi vao chan 7 header Raspberry Pi J10 = chan FPGA E12 (GPIO Bank 1).
 * Trong fabric: BIBUF voi D = 0, E = GPIO_2_M2F[DHT_DRIVE_PIN], Y -> GPIO_2_F2M[DHT_SENSE_PIN].
 *   DRIVE = 1 -> keo DATA xuong 0;  DRIVE = 0 -> nha ra (dien tro keo len dua ve 1).
 * Nhu vay chan hoat dong kieu open-drain, khong bao gio day 3,3 V chong lai cam bien.
 */
#define DHT_GPIO_INSTANCE   GPIO2_LO        /* [KIEM TRA] GPIO2_LO hay GPIO2_HI theo MSS Configurator */
#define DHT_DRIVE_PIN       MSS_GPIO_0      /* [KIEM TRA] bit M2F noi vao BIBUF.E */
#define DHT_SENSE_PIN       MSS_GPIO_1      /* [KIEM TRA] bit F2M noi tu BIBUF.Y */
#define DHT_SENSE_MASK      (1u << 1)

#define DHT_PERIOD_MS       2000            /* DHT22: toi thieu 2 s giua hai lan doc */
#define DHT_START_LOW_MS    2               /* MCU keo thap >= 1 ms */

/* ---------------------------------------------------------------- dong ho do thoi gian
 * Doc thang thanh ghi MTIME cua CLINT (chuan RISC-V), khong phu thuoc phien ban HAL.
 */
#define CLINT_MTIME_ADDR    0x0200BFF8ul    /* CLINT base 0x0200_0000 + 0xBFF8 */
#define MTIME_HZ            1000000ul       /* [KIEM TRA] PolarFire SoC: 1 MHz (RTC toggle) */

/* ---------------------------------------------------------------- RPMsg toi Linux
 * Lay tu vi du AMP FreeRTOS + RPMsg cua Microchip (context chay tren U54_4).
 */
#define LINK_CHANNEL_NAME   "rpmsg-tty"     /* [KIEM TRA] ten Linux driver rpmsg_tty nhan */
#define LINK_LOCAL_EPT_ADDR 30u
#define LINK_MAX_PAYLOAD    496u            /* RL_BUFFER_PAYLOAD_SIZE mac dinh */
/* RPMSG_SHMEM_BASE va RPMSG_LINK_ID: dung dung macro trong vi du (dia chi vung DDR dung chung
 * da khai bao trong device tree Linux va cau hinh HSS). link_rpmsg.c bao loi neu thieu. */

/* ---------------------------------------------------------------- task FreeRTOS */
#define PRIO_DHT            (tskIDLE_PRIORITY + 3)
#define PRIO_APP            (tskIDLE_PRIORITY + 2)
#define PRIO_LINK_RX        (tskIDLE_PRIORITY + 2)
#define STACK_DHT           1024
#define STACK_APP           2048            /* chaos_cipher dung ~1 KB stack (SHA-256) */
#define STACK_LINK_RX       1024
#define EVENT_QUEUE_LEN     16

#endif /* BOARD_CONFIG_H */
