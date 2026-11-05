#include "app_core.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Dong trang thai ASCII bat dau bang '#', ket thuc bang '\n'. */
static void __attribute__((format(printf, 2, 3))) send_line(app_t *a, const char *fmt, ...)
{
    char buf[160];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (n > (int)sizeof buf - 2)
        n = (int)sizeof buf - 2;
    buf[n++] = '\n';
    a->tx(a->tx_ctx, (const uint8_t *)buf, (size_t)n);
}

void app_init(app_t *a, const uint8_t k_master[CHAOS_KMASTER_BYTES], app_tx_fn tx, void *tx_ctx)
{
    memset(a, 0, sizeof *a);
    memcpy(a->k_master, k_master, CHAOS_KMASTER_BYTES);
    a->tx = tx;
    a->tx_ctx = tx_ctx;
}

void app_hello(app_t *a)
{
    send_line(a, "#HELLO spec=%s n=%d reseed=%d src=%s", CHAOS_SPEC_VERSION, APP_N,
              CHAOS_RESEED_DEFAULT, APP_SOURCE);
}

static int parse_u32(const char *s, uint32_t *out, const char **end)
{
    char *e;
    unsigned long long v;
    while (*s == ' ')
        s++;
    if (*s < '0' || *s > '9')
        return -1;
    v = strtoull(s, &e, 10);
    if (v > 0xFFFFFFFFull)
        return -1;
    *out = (uint32_t)v;
    *end = e;
    return 0;
}

static void cmd_start(app_t *a, const char *args)
{
    uint32_t ctr, limit;
    const char *p = args;

    if (parse_u32(p, &ctr, &p) || parse_u32(p, &limit, &p)) {
        send_line(a, "#ERR START can <ctr> <limit>");
        return;
    }
    if (a->running) {
        send_line(a, "#ERR START dang chay, gui STOP truoc");
        return;
    }
    if ((uint64_t)ctr < a->min_next_ctr) {
        /* Cung khoa, ctr cu -> lap keystream. Tu choi. */
        send_line(a, "#ERR START ctr=%lu da dung, toi thieu %llu", (unsigned long)ctr,
                  (unsigned long long)a->min_next_ctr);
        return;
    }
    if (limit <= ctr) {
        send_line(a, "#ERR START limit phai > ctr");
        return;
    }
    if (chaos_init(&a->cipher, a->k_master, APP_N, CHAOS_RESEED_DEFAULT, ctr) != CHAOS_OK) {
        send_line(a, "#ERR START khoi tao cipher");
        return;
    }
    a->limit = limit;
    a->running = 1;
    a->pending_gap = 0;
    a->lease_wait_sent = 0;
    send_line(a, "#OK START ctr=%lu limit=%lu", (unsigned long)ctr, (unsigned long)limit);
}

static void cmd_lease(app_t *a, const char *args)
{
    uint32_t limit;
    const char *p = args;

    if (parse_u32(p, &limit, &p) || limit <= a->limit) {
        send_line(a, "#ERR LEASE limit moi phai > %lu", (unsigned long)a->limit);
        return;
    }
    a->limit = limit;
    a->lease_wait_sent = 0;
    send_line(a, "#OK LEASE limit=%lu", (unsigned long)limit);
}

static void cmd_stop(app_t *a)
{
    if (a->running) {
        a->running = 0;
        chaos_wipe(&a->cipher);   /* trang thai phien khong con can */
    }
    send_line(a, "#OK STOP");
}

static void cmd_status(app_t *a)
{
    send_line(a, "#STAT run=%d ctr=%lu idx=%u limit=%lu ok=%lu fail=%lu blocked=%lu samples=%lu blocks=%lu",
              a->running, (unsigned long)(a->running ? a->cipher.ctr : 0),
              (unsigned)(a->running ? a->cipher.idx : 0), (unsigned long)a->limit,
              (unsigned long)a->st.reads_ok, (unsigned long)a->st.reads_fail,
              (unsigned long)a->st.blocked, (unsigned long)a->st.samples, (unsigned long)a->st.blocks);
}

void app_command(app_t *a, const char *line)
{
    if (strncmp(line, "START", 5) == 0 && (line[5] == ' ' || line[5] == 0))
        cmd_start(a, line + 5);
    else if (strncmp(line, "LEASE", 5) == 0 && (line[5] == ' ' || line[5] == 0))
        cmd_lease(a, line + 5);
    else if (strcmp(line, "STOP") == 0)
        cmd_stop(a);
    else if (strcmp(line, "STATUS") == 0)
        cmd_status(a);
    else if (line[0] != 0)
        send_line(a, "#ERR lenh khong ro");
}

static void flush_block(app_t *a, chau_block_t *b)
{
    uint8_t buf[CHAU_BLOCK_MAX_BYTES];
    size_t n = chau_block_serialize(b, buf, sizeof buf);
    if (n) {
        a->tx(a->tx_ctx, buf, n);
        a->st.blocks++;
    }
    b->count = 0;
    b->flags = 0;
}

void app_reading(app_t *a, int ok, uint16_t rh_raw, uint16_t t_raw)
{
    const uint16_t plain[2] = { rh_raw, t_raw };   /* moi lan doc = 2 mau N=16: RH roi T */
    chau_block_t b;
    uint32_t ctr_last;
    int i;

    if (!a->running)
        return;
    if (ok != 0) {
        a->st.reads_fail++;
        a->pending_gap = 1;           /* khong ma hoa -> khong ton keystream, chi danh dau GAP */
        return;
    }
    a->st.reads_ok++;

    /* ctr cua mau thu hai; ca hai mau phai nam duoi limit va khong duoc quay vong ctr. */
    ctr_last = a->cipher.ctr;
    if (a->cipher.idx + 1u >= a->cipher.reseed_interval) {
        if (ctr_last == 0xFFFFFFFFu) {
            a->st.blocked++;
            a->pending_gap = 1;
            send_line(a, "#ERR ctr sap quay vong, phai doi K_master");
            return;
        }
        ctr_last++;
    }
    if (ctr_last >= a->limit) {
        a->st.blocked++;
        a->pending_gap = 1;
        if (!a->lease_wait_sent) {
            send_line(a, "#LEASE_WAIT ctr=%lu limit=%lu", (unsigned long)a->cipher.ctr,
                      (unsigned long)a->limit);
            a->lease_wait_sent = 1;
        }
        return;
    }

    b.count = 0;
    b.flags = a->pending_gap ? CHAU_FLAG_GAP_BEFORE : 0;
    a->pending_gap = 0;
    for (i = 0; i < 2; i++) {
        chaos_detail_t d;
        uint16_t c;
        if (chaos_encrypt(&a->cipher, plain[i], &c, &d) != CHAOS_OK) {
            send_line(a, "#ERR cipher");
            a->running = 0;
            return;
        }
        if (b.count && d.ctr != b.ctr)          /* qua ranh gioi phien -> block moi */
            flush_block(a, &b);
        if (b.count == 0) {
            b.ctr = d.ctr;
            b.idx0 = (uint8_t)d.idx;
        }
        b.c[b.count++] = c;
        a->st.samples++;
        if ((uint64_t)d.ctr + 1 > a->min_next_ctr)
            a->min_next_ctr = (uint64_t)d.ctr + 1;
    }
    flush_block(a, &b);
}
