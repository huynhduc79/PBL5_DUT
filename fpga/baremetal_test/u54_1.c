/*******************************************************************************
 * u54_1.c - PBL5: thu khoi audio_crypt_top tren Discovery Kit (bare-metal, khong can the SD).
 *
 * Thay file src/application/hart1/u54_1.c cua vi du Microchip mpfs-mmuart-interrupt
 * (polarfire-soc-bare-metal-examples, board mpfs-discovery-kit, cau hinh lim-debug).
 * Ket qua in ra cong COM "interface 1" cua J4, 115200 8N1.
 *
 * Khoi o 0x4000_0500 (FIC_3). Khoa thu 00 01 .. 1F, ctr 0x1000 - CHI DE THU.
 * Gia tri mong doi tinh bang golden model refmodel (N = 16), xem docs/HOP_DONG_FPGA_RTOS.md.
 ******************************************************************************/
#include <stdio.h>
#include <string.h>
#include "mpfs_hal/mss_hal.h"
#include "drivers/mss/mss_mmuart/mss_uart.h"
#include "inc/common.h"
#include "inc/uart_mapping.h"
extern struct mss_uart_instance* p_uartmap_u54_1;

/* ------------------------------------------------------------------ thanh ghi */
#define ACORE_BASE      0x40000500UL
#define R_CTRL          0x00u
#define R_STATUS        0x04u
#define R_KMASTER0      0x08u
#define R_CTR           0x28u
#define R_DATA_IN       0x2Cu
#define R_DATA_OUT      0x30u
#define R_I2S_CFG       0x34u
#define R_SRC_SEL       0x38u
#define R_FIFO_LEVEL    0x3Cu
#define R_OUT_DATA      0x40u
#define R_IRQ_THRESH    0x44u
#define R_IRQ_EN        0x48u
#define R_IRQ_STATUS    0x4Cu
#define R_DROP_CNT      0x50u
#define R_SAMPLE_CNT    0x54u
#define R_CYCLES_MAX    0x58u
#define R_STARTUP_SKIP  0x5Cu
#define R_VERSION       0x60u
#define R_CLIP_CNT      0x64u

#define CTRL_ENABLE     0x001u
#define CTRL_RESEED     0x004u
#define CTRL_NSEL       0x100u
#define CTRL_SOFT_RESET 0x80000000u

#define ST_BUSY         (1u << 0)
#define ST_KEY_READY    (1u << 1)
#define ST_I2S_RUNNING  (1u << 6)
#define ST_CTR_REJECTED (1u << 7)
#define ST_CMD_IGN      (1u << 8)

static inline void wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(ACORE_BASE + off) = v; }
static inline uint32_t rd(uint32_t off) { return *(volatile uint32_t *)(ACORE_BASE + off); }

/* CLINT mtime: 1 MHz tren PolarFire SoC */
static inline uint64_t now_us(void) { return *(volatile uint64_t *)0x0200BFF8UL; }
static void delay_us(uint64_t us) { uint64_t t0 = now_us(); while ((now_us() - t0) < us) { } }

/* ------------------------------------------------------------------ in ra UART */
static char line[160];
static char name[48];
static unsigned n_pass, n_fail;

static void puts_u(const char *s) { MSS_UART_polled_tx_string(p_uartmap_u54_1, (const uint8_t *)s); }

static void check(const char *name, uint32_t got, uint32_t exp)
{
    int ok = (got == exp);
    snprintf(line, sizeof line, "  %-34s got 0x%08lx  exp 0x%08lx  %s\r\n",
             name, (unsigned long)got, (unsigned long)exp, ok ? "PASS" : "FAIL <<<");
    puts_u(line);
    if (ok) n_pass++; else n_fail++;
}

static void info(const char *name, uint32_t v)
{
    snprintf(line, sizeof line, "  %-34s 0x%08lx (%lu)\r\n", name, (unsigned long)v, (unsigned long)v);
    puts_u(line);
}

/* cho bit trong STATUS dat gia tri mong muon; tra 1 neu kip */
static int wait_status(uint32_t mask, uint32_t want, uint32_t timeout_us)
{
    uint64_t t0 = now_us();
    while ((rd(R_STATUS) & mask) != want)
        if ((now_us() - t0) > timeout_us) return 0;
    return 1;
}

/* ------------------------------------------------------------------ golden (refmodel, N = 16) */
static const uint32_t TEST_KEY[8] = {
    0x00010203u, 0x04050607u, 0x08090a0bu, 0x0c0d0e0fu,
    0x10111213u, 0x14151617u, 0x18191a1bu, 0x1c1d1e1fu };
#define TEST_CTR 0x00001000u
static const uint16_t REG_IN[3]  = { 0x0000u, 0x1234u, 0xBEEFu };
static const uint16_t REG_EXP[3] = { 0xB44Au, 0x646Du, 0xF72Cu };
static const uint32_t RAMP_EXP[16] = {
    0x0040b44au, 0x00416ca0u, 0x004228b1u, 0x00435137u, 0x00448f0au, 0x0045a093u, 0x004684beu, 0x004716bfu,
    0x00484db2u, 0x0049b5a9u, 0x004ac35eu, 0x004b0643u, 0x004cf30eu, 0x004dade5u, 0x004e0fc2u, 0x004fb9dau };

static void reset_and_key(void)
{
    wr(R_CTRL, CTRL_SOFT_RESET);
    delay_us(10);
    for (unsigned i = 0; i < 8; i++) wr(R_KMASTER0 + 4u * i, TEST_KEY[i]);
    wr(R_CTR, TEST_CTR);
    wr(R_CTRL, CTRL_NSEL | CTRL_RESEED);
    (void)wait_status(ST_KEY_READY, ST_KEY_READY, 10000u);
}

/* ------------------------------------------------------------------ cac bai thu */
static void test_a(void)
{
    puts_u("\r\n[A] Doc thanh ghi sau SOFT_RESET\r\n");
    wr(R_CTRL, CTRL_SOFT_RESET);
    delay_us(10);
    check("VERSION", rd(R_VERSION), 0x00020100u);
    check("CTRL mac dinh (N_SEL = 1)", rd(R_CTRL), CTRL_NSEL);
    check("STATUS", rd(R_STATUS), 0u);
    check("I2S_CFG mac dinh (SCK_DIV = 24)", rd(R_I2S_CFG), 24u);
    check("IRQ_THRESH mac dinh", rd(R_IRQ_THRESH), 256u);
    check("STARTUP_SKIP mac dinh", rd(R_STARTUP_SKIP), 4096u);
}

static void test_b(void)
{
    puts_u("\r\n[B] Nap khoa thu + CTR + RESEED_NOW\r\n");
    wr(R_CTRL, CTRL_SOFT_RESET);
    delay_us(10);
    for (unsigned i = 0; i < 8; i++) wr(R_KMASTER0 + 4u * i, TEST_KEY[i]);
    check("KMASTER[0] doc ve 0 (chi ghi)", rd(R_KMASTER0), 0u);
    wr(R_CTR, TEST_CTR);
    check("CTR_REJECTED sau ghi CTR", rd(R_STATUS) & ST_CTR_REJECTED, 0u);
    wr(R_CTRL, CTRL_NSEL | CTRL_RESEED);
    check("KEY_READY trong 10 ms", (uint32_t)wait_status(ST_KEY_READY, ST_KEY_READY, 10000u), 1u);
    check("CTR doc ve", rd(R_CTR), TEST_CTR);
    check("CMD_IGN", rd(R_STATUS) & ST_CMD_IGN, 0u);
    wr(R_CTR, TEST_CTR);                                   /* ghi lai cung ctr: phai bi tu choi */
    check("Ghi lai CTR cu -> CTR_REJECTED", rd(R_STATUS) & ST_CTR_REJECTED, ST_CTR_REJECTED);
}

static void test_c(void)
{
    puts_u("\r\n[C] Che do REG: ma tung mau qua DATA_IN / DATA_OUT\r\n");
    reset_and_key();
    wr(R_SRC_SEL, 3u);
    for (unsigned i = 0; i < 3; i++) {
        wr(R_DATA_IN, REG_IN[i]);
        (void)wait_status(ST_BUSY, 0u, 1000u);
        snprintf(name, sizeof name, "DATA_OUT(ENC 0x%04x)", REG_IN[i]);
        check(name, rd(R_DATA_OUT) & 0xFFFFu, REG_EXP[i]);
    }
    check("CMD_IGN", rd(R_STATUS) & ST_CMD_IGN, 0u);
}

static void test_d(void)
{
    puts_u("\r\n[D] Luong RAMP qua in_fifo -> loi -> out_fifo -> OUT_DATA\r\n");
    reset_and_key();
    wr(R_SRC_SEL, 1u);
    wr(R_CTRL, CTRL_NSEL | CTRL_ENABLE);
    uint64_t t0 = now_us();
    while ((rd(R_FIFO_LEVEL) & 0xFFFFu) < 16u && (now_us() - t0) < 100000u) { }
    for (unsigned i = 0; i < 16; i++) {
        snprintf(name, sizeof name, "OUT_DATA[%2u]", i);
        check(name, rd(R_OUT_DATA), RAMP_EXP[i]);
    }

    /* rut lien tuc 1 giay: kiem cau truc tu (VALID, GAP = 0, idx/ctr noi tiep) */
    uint32_t n = 16, bad = 0, gaps = 0, first_bad = 0;
    t0 = now_us();
    while ((now_us() - t0) < 1000000u) {
        uint32_t lvl = rd(R_FIFO_LEVEL) & 0xFFFFu;
        while (lvl--) {
            uint32_t w = rd(R_OUT_DATA);
            uint32_t exp_hdr = (((TEST_CTR + n / 64u) & 0xFFu) << 24) | (1u << 22) | ((n % 64u) << 16);
            if (w & (1u << 23)) gaps++;
            if ((w & 0xFFFF0000u) != exp_hdr) { if (!bad) first_bad = n; bad++; }
            n++;
        }
    }
    info("So tu da kiem cau truc", n);
    check("Tu sai ctr/idx/VALID", bad, 0u);
    if (bad) info("  tu sai dau tien o vi tri", first_bad);
    check("So tu co GAP", gaps, 0u);
    check("DROP_CNT", rd(R_DROP_CNT), 0u);

    /* do fs: FIFO da rut can (khong con mau ton), dem SAMPLE_CNT tang trong dung 1 s */
    {
        uint32_t s0 = rd(R_SAMPLE_CNT);
        t0 = now_us();
        while ((now_us() - t0) < 1000000u) {
            uint32_t lvl = rd(R_FIFO_LEVEL) & 0xFFFFu;
            while (lvl--) (void)rd(R_OUT_DATA);
        }
        uint32_t fs = rd(R_SAMPLE_CNT) - s0;
        info("fs do duoc (Hz, ly thuyet 15625)", fs);
        check("fs trong khoang 15550..15700", (fs >= 15550u && fs <= 15700u) ? 1u : 0u, 1u);
    }
    info("CYCLES_MAX (binh thuong ~331)", rd(R_CYCLES_MAX));

    /* ngat: IRQ_STATUS.THRESH phai bat khi muc out >= nguong */
    wr(R_IRQ_THRESH, 32u);
    wr(R_IRQ_EN, 1u);
    delay_us(5000);                                        /* ~78 mau */
    check("IRQ_STATUS.THRESH", rd(R_IRQ_STATUS) & 1u, 1u);
    wr(R_CTRL, CTRL_NSEL);                                 /* tat ENABLE */
    delay_us(2000);
    info("FIFO_LEVEL sau khi tat", rd(R_FIFO_LEVEL));
}

#define MIC_N 8192u                                    /* 8192 mau = 0,52 s */
static uint32_t mic_w[MIC_N];
static int16_t  mic_p[MIC_N];

static void test_e(void)
{
    puts_u("\r\n[E] Micro INMP441: thu 8192 mau (SHIFT = 8), giai ma lai ngay tren board bang che do REG/DEC\r\n");
    puts_u("    Trong luc chay hay noi / vo tay gan micro.\r\n");
    reset_and_key();
    wr(R_I2S_CFG, 24u | (8u << 16));                      /* SCK_DIV 24, CHANNEL 0, SHIFT 8 (khuech dai lon nhat) */
    wr(R_SRC_SEL, 0u);
    wr(R_CTRL, CTRL_NSEL | CTRL_ENABLE);

    uint32_t n = 0;
    uint64_t t0 = now_us();
    while (n < MIC_N && (now_us() - t0) < 3000000u) {      /* rut ngay tu dau: khong de FIFO day */
        uint32_t lvl = rd(R_FIFO_LEVEL) & 0xFFFFu;
        while (lvl-- && n < MIC_N) mic_w[n++] = rd(R_OUT_DATA);
    }
    uint32_t st = rd(R_STATUS);
    wr(R_CTRL, CTRL_NSEL);
    info("STATUS khi dang chay (bit 6 = I2S_RUNNING)", st);
    check("I2S_RUNNING", st & ST_I2S_RUNNING, ST_I2S_RUNNING);
    check("So mau thu duoc", n, MIC_N);
    check("DROP_CNT", rd(R_DROP_CNT), 0u);
    info("CLIP_CNT", rd(R_CLIP_CNT));

    uint32_t bad = 0, gaps = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t exp_hdr = (((TEST_CTR + i / 64u) & 0xFFu) << 24) | (1u << 22) | ((i % 64u) << 16);
        if (mic_w[i] & (1u << 23)) gaps++;
        if ((mic_w[i] & 0xFF7F0000u) != exp_hdr) bad++;
    }
    check("Tu sai ctr/idx/VALID", bad, 0u);
    check("So tu co GAP", gaps, 0u);

    /* giai ma: cung khoa, cung ctr 0x1000 (lan ghi CTR dau sau SOFT_RESET luon duoc nhan) */
    reset_and_key();
    wr(R_SRC_SEL, 3u);
    wr(R_CTRL, CTRL_NSEL | (1u << 6));                    /* OP = DEC, ENABLE = 0 */
    uint32_t ign = 0;
    for (uint32_t i = 0; i < n; i++) {
        wr(R_DATA_IN, mic_w[i] & 0xFFFFu);
        (void)wait_status(ST_BUSY, 0u, 1000u);
        mic_p[i] = (int16_t)(rd(R_DATA_OUT) & 0xFFFFu);
        if (rd(R_STATUS) & ST_CMD_IGN) ign++;
    }
    check("CMD_IGN khi giai ma", ign, 0u);

    /* thong ke ban ro (am thanh that) */
    int32_t mn = 32767, mx = -32768;
    uint32_t zeros = 0;
    int64_t sum = 0;
    for (uint32_t i = 0; i < n; i++) {
        int32_t v = mic_p[i];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        if (v == 0) zeros++;
        sum += v;
    }
    snprintf(line, sizeof line, "  Ban ro: min %ld  max %ld  trung binh %ld  so mau = 0: %lu / %lu\r\n",
             (long)mn, (long)mx, (long)(n ? sum / (int64_t)n : 0), (unsigned long)zeros, (unsigned long)n);
    puts_u(line);
    puts_u("  Muc am tung doan 1024 mau (65 ms), trung binh |x| tru DC:\r\n");
    int32_t dc = (int32_t)(n ? sum / (int64_t)n : 0);
    for (uint32_t b = 0; b + 1024u <= n; b += 1024u) {
        uint64_t a = 0;
        for (uint32_t i = b; i < b + 1024u; i++) { int32_t d = mic_p[i] - dc; a += (uint64_t)(d < 0 ? -d : d); }
        uint32_t lvl = (uint32_t)(a / 1024u);
        char bar[41]; uint32_t k = 0, len = lvl / 64u; if (len > 40u) len = 40u;
        for (; k < len; k++) bar[k] = '#';
        bar[k] = 0;
        snprintf(line, sizeof line, "    %5lu  %s\r\n", (unsigned long)lvl, bar);
        puts_u(line);
    }
    puts_u("  16 mau dau:");
    for (uint32_t i = 0; i < 16u && i < n; i++) { snprintf(line, sizeof line, " %d", mic_p[i]); puts_u(line); }
    puts_u("\r\n");
    if (zeros == n)
        puts_u("  => Toan 0: KHONG co tin hieu micro (chua cam, sai day SD/SCK/WS, hoac L/R khong noi GND).\r\n");
    else
        puts_u("  => Co tin hieu micro va giai ma tren board cho ra am thanh (khong phai so ngau nhien).\r\n");
    wr(R_I2S_CFG, 24u);
}

/* bat I2S (nguon MIC) lien tuc cho toi khi nhan phim: SCK 1 MHz, WS 15,625 kHz tren header.
 * Moi giay in fs do duoc va so mau khac 0 (giai ma lai bang REG/DEC khong lam o day: chi dem tu). */
static void scope_mode(void)
{
    puts_u("\r\n[SCOPE] I2S dang chay: SCK = chan 12, WS = chan 35, SD = chan 38. Nhan phim bat ky de dung.\r\n");
    reset_and_key();
    wr(R_I2S_CFG, 24u | (8u << 16));
    wr(R_SRC_SEL, 0u);
    wr(R_CTRL, CTRL_NSEL | CTRL_ENABLE);
    uint8_t ch;
    for (;;) {
        uint32_t s0 = rd(R_SAMPLE_CNT);
        uint64_t t0 = now_us();
        while ((now_us() - t0) < 1000000u) {
            uint32_t lvl = rd(R_FIFO_LEVEL) & 0xFFFFu;
            while (lvl--) (void)rd(R_OUT_DATA);
            if (MSS_UART_get_rx(p_uartmap_u54_1, &ch, 1u) != 0u) {
                wr(R_CTRL, CTRL_NSEL);
                wr(R_I2S_CFG, 24u);
                puts_u("[SCOPE] da dung.\r\n");
                return;
            }
        }
        snprintf(line, sizeof line, "  fs = %lu Hz  STATUS = 0x%03lx  CLIP_CNT = %lu\r\n",
                 (unsigned long)(rd(R_SAMPLE_CNT) - s0), (unsigned long)rd(R_STATUS), (unsigned long)rd(R_CLIP_CNT));
        puts_u(line);
    }
}

/* ------------------------------------------------------------------ main hart 1 */
void u54_1(void)
{
    clear_soft_interrupt();
    set_csr(mie, MIP_MSIP);

#if (IMAGE_LOADED_BY_BOOTLOADER == 0)
    do { __asm("wfi"); } while (0 == (read_csr(mip) & MIP_MSIP));
    clear_soft_interrupt();
#endif

    (void) mss_config_clk_rst(MSS_PERIPH_MMUART_U54_1, (uint8_t) 1, PERIPHERAL_ON);
    (void) mss_config_clk_rst(MSS_PERIPH_FIC3, (uint8_t) 1, PERIPHERAL_ON);
    mss_enable_fabric();

    MSS_UART_init(p_uartmap_u54_1, MSS_UART_115200_BAUD,
                  MSS_UART_DATA_8_BITS | MSS_UART_NO_PARITY | MSS_UART_ONE_STOP_BIT);

    puts_u("\r\n\r\n==== PBL5: thu audio_crypt_top @ 0x40000500 ====\r\n");
    puts_u("Nhan phim bat ky de chay lai.\r\n");

    for (;;) {
        n_pass = n_fail = 0;
        test_a();
        test_b();
        test_c();
        test_d();
        test_e();
        snprintf(line, sizeof line, "\r\n==== KET QUA: %u PASS, %u FAIL ====\r\n", n_pass, n_fail);
        puts_u(line);
        puts_u("Phim 'm': bat I2S lien tuc de do SCK (chan 12) / WS (chan 35). Phim khac: chay lai test.\r\n");
        uint8_t ch;
        while (MSS_UART_get_rx(p_uartmap_u54_1, &ch, 1u) == 0u) { }
        if (ch == 'm' || ch == 'M') scope_mode();
    }
}
