/*
 * sim_rtos.c - mo phong phan RTOS tren PC de chay thu toan bo luong ma khong can board.
 *
 * Cau truc giong firmware FreeRTOS (os/freertos/app/main_rtos.c):
 *   - luong "link_rx"  ~ callback RPMsg: doc dong lenh tu stdin, day vao hang doi su kien
 *   - luong chinh      ~ app_task: cho su kien hoac den han doc cam bien (timeout)
 *   - DHT22 gia lap: sinh 40 xung voi do rong ngau nhien quanh 27 us / 70 us, roi giai ma
 *     bang dung dht22_decode_pulses() ma board dung
 *   - stdout ~ kenh RPMsg sang Linux (nhi phan: dong '#...' va block 0xA55A)
 *
 *   sim_rtos --key key.hex [--period-ms 2000] [--count N] [--fail-pct 5] [--seed 1]
 *            [--cold] [--truth truth.csv]
 *
 * --count N : thoat sau N lan doc (tinh tu luc da START). --truth: ghi ban ro de kiem thu.
 */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "app_core.h"
#include "dht22.h"

/* ------------------------------------------------------------ hang doi su kien (~ xQueue) */
#define QLEN 32
#define LINE_MAX_LEN 128

static struct {
    pthread_mutex_t mu;
    pthread_cond_t  cv;
    char            lines[QLEN][LINE_MAX_LEN];
    int             head, count, eof;
} q = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, { { 0 } }, 0, 0, 0 };

static void *link_rx_thread(void *arg)
{
    char line[LINE_MAX_LEN];
    (void)arg;
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        pthread_mutex_lock(&q.mu);
        if (q.count < QLEN) {
            strcpy(q.lines[(q.head + q.count) % QLEN], line);
            q.count++;
        }
        pthread_cond_signal(&q.cv);
        pthread_mutex_unlock(&q.mu);
    }
    pthread_mutex_lock(&q.mu);
    q.eof = 1;
    pthread_cond_signal(&q.cv);
    pthread_mutex_unlock(&q.mu);
    return NULL;
}

/* Cho toi da den 'deadline'; tra 1 neu lay duoc lenh, 0 neu het gio, -1 neu stdin dong. */
static int wait_command(const struct timespec *deadline, char *out)
{
    int rc = 0;
    pthread_mutex_lock(&q.mu);
    while (q.count == 0 && !q.eof) {
        if (pthread_cond_timedwait(&q.cv, &q.mu, deadline) == ETIMEDOUT)
            break;
    }
    if (q.count > 0) {
        strcpy(out, q.lines[q.head]);
        q.head = (q.head + 1) % QLEN;
        q.count--;
        rc = 1;
    } else if (q.eof) {
        rc = -1;
    }
    pthread_mutex_unlock(&q.mu);
    return rc;
}

/* ------------------------------------------------------------ kenh ra (~ rpmsg_lite_send) */
static void tx_stdout(void *ctx, const uint8_t *buf, size_t len)
{
    (void)ctx;
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
}

/* ------------------------------------------------------------ DHT22 gia lap */
static uint32_t rng_state = 1;
static uint32_t rnd(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static int rh_x10 = 650, t_x10 = 285;

/* Mot lan "doc" cam bien: tra ma loi nhu port that va dien rh/t neu thanh cong. */
static int fake_dht_read(int fail_pct, int cold, dht22_value_t *v, uint16_t *rh_true, uint16_t *t_true)
{
    uint16_t high[DHT22_BITS];
    uint8_t b[5];
    uint16_t t_raw;
    int i;

    rh_x10 += (int)(rnd() % 7) - 3;
    t_x10 += (int)(rnd() % 5) - 2;
    if (rh_x10 < 200) rh_x10 = 200;
    if (rh_x10 > 950) rh_x10 = 950;
    if (cold) {
        if (t_x10 > -20) t_x10 = -20;
        if (t_x10 < -150) t_x10 = -150;
    } else {
        if (t_x10 < 150) t_x10 = 150;
        if (t_x10 > 400) t_x10 = 400;
    }
    t_raw = t_x10 < 0 ? (uint16_t)(0x8000 | (uint16_t)(-t_x10)) : (uint16_t)t_x10;
    *rh_true = (uint16_t)rh_x10;
    *t_true = t_raw;

    if ((int)(rnd() % 100) < fail_pct / 2)
        return DHT22_ERR_NO_RESPONSE;

    b[0] = (uint8_t)(rh_x10 >> 8);
    b[1] = (uint8_t)rh_x10;
    b[2] = (uint8_t)(t_raw >> 8);
    b[3] = (uint8_t)t_raw;
    b[4] = (uint8_t)(b[0] + b[1] + b[2] + b[3]);
    for (i = 0; i < DHT22_BITS; i++) {
        int bit = (b[i / 8] >> (7 - i % 8)) & 1;
        high[i] = (uint16_t)((bit ? 70 : 27) + (int)(rnd() % 9) - 4);   /* +-4 us jitter */
    }
    if ((int)(rnd() % 100) < fail_pct - fail_pct / 2) {
        int k = (int)(rnd() % DHT22_BITS);
        high[k] = high[k] > DHT22_BIT1_THRESHOLD_US ? 27 : 70;    /* nhieu lam lat 1 bit */
    }
    return dht22_decode_pulses(high, v);
}

/* ------------------------------------------------------------ main */
static int load_key(const char *path, uint8_t key[32])
{
    char hex[80] = { 0 };
    FILE *f = fopen(path, "r");
    int i;
    if (!f || !fgets(hex, sizeof hex, f)) {
        if (f) fclose(f);
        return -1;
    }
    fclose(f);
    for (i = 0; i < 32; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1)
            return -1;
        key[i] = (uint8_t)v;
    }
    return 0;
}

static void add_ms(struct timespec *t, long ms)
{
    t->tv_sec += ms / 1000;
    t->tv_nsec += (ms % 1000) * 1000000L;
    if (t->tv_nsec >= 1000000000L) {
        t->tv_sec++;
        t->tv_nsec -= 1000000000L;
    }
}

int main(int argc, char **argv)
{
    const char *key_path = NULL, *truth_path = NULL;
    long period_ms = DHT22_MIN_PERIOD_MS, count = -1, done = 0;
    int fail_pct = 5, cold = 0, i;
    uint8_t key[32];
    FILE *truth = NULL;
    app_t app;
    pthread_t th;
    struct timespec next;
    char line[LINE_MAX_LEN];

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--key") && i + 1 < argc) key_path = argv[++i];
        else if (!strcmp(argv[i], "--period-ms") && i + 1 < argc) period_ms = atol(argv[++i]);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--fail-pct") && i + 1 < argc) fail_pct = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) rng_state = (uint32_t)strtoul(argv[++i], NULL, 0) | 1u;
        else if (!strcmp(argv[i], "--truth") && i + 1 < argc) truth_path = argv[++i];
        else if (!strcmp(argv[i], "--cold")) cold = 1;
        else {
            fprintf(stderr, "tham so khong ro: %s\n", argv[i]);
            return 2;
        }
    }
    if (!key_path || load_key(key_path, key)) {
        fprintf(stderr, "can --key <file chua 64 ky tu hex>\n");
        return 2;
    }
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);   /* khong cho Windows doi '\n' thanh "\r\n" */
#endif
    if (truth_path && !(truth = fopen(truth_path, "w"))) {
        fprintf(stderr, "khong mo duoc %s\n", truth_path);
        return 2;
    }
    if (truth)
        fprintf(truth, "n,status,rh_raw,t_raw\n");

    app_init(&app, key, tx_stdout, NULL);
    memset(key, 0, sizeof key);
    pthread_create(&th, NULL, link_rx_thread, NULL);
    app_hello(&app);

    clock_gettime(CLOCK_REALTIME, &next);
    add_ms(&next, period_ms);
    for (;;) {
        int rc = wait_command(&next, line);
        if (rc == 1) {
            app_command(&app, line);
            continue;
        }
        if (rc < 0)
            break;                                   /* Linux dong kenh */
        /* den han doc cam bien (~ dht_task) */
        add_ms(&next, period_ms);
        {
            dht22_value_t v;
            uint16_t rh_true, t_true;
            int st = fake_dht_read(fail_pct, cold, &v, &rh_true, &t_true);
            if (!app.running)
                continue;
            app_reading(&app, st, v.rh_raw, v.t_raw);
            if (truth)
                fprintf(truth, "%ld,%d,%u,%u\n", done, st, rh_true, t_true);
            if (count >= 0 && ++done >= count)
                break;
        }
    }
    app_command(&app, "STATUS");
    if (truth)
        fclose(truth);
    chaos_wipe(&app.cipher);
    memset(app.k_master, 0, sizeof app.k_master);
    return 0;
}
