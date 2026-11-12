/*
 * sim_audio.c - gia lap RTOS U54_4 tren PC: app_audio + acore_drv + ctr_store chay NGUYEN VAN,
 * chi thay 3 lop duoi cung:
 *   thanh ghi FPGA  -> fpga_model.c          (board: volatile MMIO tai FIC_3)
 *   sNVM            -> file --nvm (2 x 32 B)  (board: system services sNVM)
 *   RPMsg tty       -> stdin / stdout         (board: rpmsg-lite, /dev/ttyRPMSG0 ben Linux)
 *
 *   sim_audio --key key.hex --nvm build/nvm.bin [--run-s 8] [--speed 20]
 *             [--stall-ms 300 --stall-every-s 2] [--key-id 1]
 *
 * Thoi gian la thoi gian GIA LAP (1 tick = 1 ms, fs = 15 625 Hz), chay nhanh hon thuc --speed lan.
 * --stall-*: gia lap RTOS bi tre (khong phuc vu ngat) de out_fifo day -> in_fifo bo mau -> GAP.
 * --run-s: sau khi START duoc ngan ay giay gia lap thi tu STOP va thoat (dong stdout).
 */
#include <fcntl.h>
#include <io.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "acore_regs.h"
#include "app_audio.h"
#include "fpga_model.h"

static pthread_mutex_t s_mu = PTHREAD_MUTEX_INITIALIZER;
static char s_lines[16][64];
static int s_nlines, s_eof;

static void *stdin_thread(void *arg)
{
    char line[64];
    (void)arg;
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0])
            continue;
        pthread_mutex_lock(&s_mu);
        if (s_nlines < 16)
            strcpy(s_lines[s_nlines++], line);
        pthread_mutex_unlock(&s_mu);
    }
    pthread_mutex_lock(&s_mu);
    s_eof = 1;
    pthread_mutex_unlock(&s_mu);
    return NULL;
}

static void tx_stdout(void *ctx, const uint8_t *buf, size_t len)
{
    (void)ctx;
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
}

static void delay_us(void *ctx, uint32_t us)
{
    fm_step(ctx, 0);       /* lo ma hoa trong mo hinh la tuc thi; chi can xu ly lai */
    (void)us;
}

/* ---- sNVM gia: file 64 byte (o 0 | o 1) ---- */
static int nvm_read(void *ctx, int slot, uint8_t buf[CTR_REC_BYTES])
{
    FILE *f = fopen(ctx, "rb");
    int ok = f && fseek(f, slot * CTR_REC_BYTES, SEEK_SET) == 0 && fread(buf, 1, CTR_REC_BYTES, f) == CTR_REC_BYTES;
    if (f)
        fclose(f);
    return ok ? 0 : -1;
}

static int nvm_write(void *ctx, int slot, const uint8_t buf[CTR_REC_BYTES])
{
    uint8_t all[2 * CTR_REC_BYTES];
    FILE *f = fopen(ctx, "rb");
    memset(all, 0xFF, sizeof all);
    if (f) {
        if (fread(all, 1, sizeof all, f) == 0) { /* file moi */ }
        fclose(f);
    }
    memcpy(all + slot * CTR_REC_BYTES, buf, CTR_REC_BYTES);
    f = fopen(ctx, "wb");
    if (!f || fwrite(all, 1, sizeof all, f) != sizeof all) {
        if (f)
            fclose(f);
        return -1;
    }
    fflush(f);
    _commit(_fileno(f));                         /* nhu fsync: ghi xong moi tra ve */
    fclose(f);
    return 0;
}

static int load_key(const char *path, uint8_t key[32])
{
    char hex[80];
    int i;
    FILE *f = fopen(path, "r");
    if (!f || !fgets(hex, sizeof hex, f)) {
        if (f)
            fclose(f);
        return -1;
    }
    fclose(f);
    for (i = 0; i < 32; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1)
            return -1;
        key[i] = (uint8_t)v;
    }
    memset(hex, 0, sizeof hex);
    return 0;
}

int main(int argc, char **argv)
{
    const char *key_path = NULL, *nvm_path = "nvm.bin";
    double run_s = 0, stall_every_s = 0;
    unsigned speed = 20, stall_ms = 0, key_id = 1;
    static fpga_model_t fm;
    static app_audio_t app;
    acore_bus_t bus;
    ctr_nvm_t nvm;
    uint8_t key[32];
    pthread_t th;
    uint64_t tick = 0, started_at = 0, stall_until = 0;
    double frac = 0;
    int i, was_running = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--key") && i + 1 < argc) key_path = argv[++i];
        else if (!strcmp(argv[i], "--nvm") && i + 1 < argc) nvm_path = argv[++i];
        else if (!strcmp(argv[i], "--run-s") && i + 1 < argc) run_s = atof(argv[++i]);
        else if (!strcmp(argv[i], "--speed") && i + 1 < argc) speed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--stall-ms") && i + 1 < argc) stall_ms = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--stall-every-s") && i + 1 < argc) stall_every_s = atof(argv[++i]);
        else if (!strcmp(argv[i], "--key-id") && i + 1 < argc) key_id = (unsigned)atoi(argv[++i]);
        else {
            fprintf(stderr, "tham so la: %s\n", argv[i]);
            return 2;
        }
    }
    if (!key_path || load_key(key_path, key)) {
        fprintf(stderr, "can --key <file chua 64 ky tu hex>\n");
        return 2;
    }
    _setmode(_fileno(stdout), _O_BINARY);
    if (speed == 0)
        speed = 1;

    fm.rng = 12345;
    fm_reset(&fm);
    bus.rd = fm_rd;
    bus.wr = fm_wr;
    bus.delay_us = delay_us;
    bus.ctx = &fm;
    nvm.read = nvm_read;
    nvm.write = nvm_write;
    nvm.ctx = (void *)nvm_path;
    if (app_audio_init(&app, &bus, &nvm, key_id, key, tx_stdout, NULL) != 0)
        return 1;
    memset(key, 0, sizeof key);
    app_audio_hello(&app);
    pthread_create(&th, NULL, stdin_thread, NULL);

    for (;; tick++) {
        char cmds[16][64];
        int n, eof, stalled;

        pthread_mutex_lock(&s_mu);
        n = s_nlines;
        memcpy(cmds, s_lines, sizeof cmds);
        s_nlines = 0;
        eof = s_eof;
        pthread_mutex_unlock(&s_mu);
        for (i = 0; i < n; i++)
            app_audio_command(&app, cmds[i]);

        if (app.running && !was_running)
            started_at = tick;
        was_running = app.running;

        frac += 15.625;                                   /* mau / ms */
        fm_step(&fm, (uint32_t)frac);
        frac -= (uint32_t)frac;

        if (stall_ms && stall_every_s > 0 && app.running &&
            (tick - started_at) % (uint64_t)(stall_every_s * 1000) == (uint64_t)(stall_every_s * 1000) - 1)
            stall_until = tick + stall_ms;                /* RTOS "ban" viec khac */
        stalled = tick < stall_until;
        if (!stalled && (fm_irq(&fm) || tick % 20 == 0))
            app_audio_service(&app);

        if (app.running && run_s > 0 && tick - started_at >= (uint64_t)(run_s * 1000)) {
            app_audio_command(&app, "STATUS");
            app_audio_command(&app, "STOP");
            break;
        }
        if (eof && !app.running)
            break;
        if (tick % speed == 0)
            usleep(1000);
    }
    fflush(stdout);
    return 0;
}
