#include "app_audio.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "acore_regs.h"

#define CTR_CHECK_EVERY  256u        /* goi ctr_store_check moi ~1 s ghi am */

static void tx_flush(app_audio_t *a)
{
    if (a->txlen) {
        a->tx(a->tx_ctx, a->txbuf, a->txlen);
        a->txlen = 0;
    }
}

static void reply(app_audio_t *a, const char *fmt, ...)
{
    char line[160];
    va_list ap;
    int n;

    tx_flush(a);                             /* giu thu tu: block truoc, dong sau */
    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (n > (int)sizeof line - 2)
        n = (int)sizeof line - 2;
    line[n++] = '\n';
    a->tx(a->tx_ctx, (const uint8_t *)line, (size_t)n);
}

static void on_block(void *ctx, const chau_block_t *b)
{
    app_audio_t *a = ctx;
    if (sizeof a->txbuf - a->txlen < CHAU_BLOCK_MAX_BYTES)
        tx_flush(a);
    a->txlen += chau_block_serialize(b, a->txbuf + a->txlen, sizeof a->txbuf - a->txlen);
    if (sizeof a->txbuf - a->txlen < CHAU_BLOCK_MAX_BYTES)
        tx_flush(a);
}

int app_audio_init(app_audio_t *a, const acore_bus_t *bus, const ctr_nvm_t *nvm,
                   uint32_t key_id, const uint8_t k_master[32], app_tx_fn tx, void *tx_ctx)
{
    uint32_t version = 0;
    int rc;

    memset(a, 0, sizeof *a);
    a->tx = tx;
    a->tx_ctx = tx_ctx;
    memcpy(a->k_master, k_master, sizeof a->k_master);
    acore_init(&a->core, bus, on_block, a);
    acore_default_cfg(&a->cfg);
    rc = acore_probe(&a->core, &version);
    if (rc != ACORE_OK) {
        reply(a, "#ERR VERSION got=0x%08lx want=0x%08lx", (unsigned long)version,
              (unsigned long)ACORE_VERSION_EXPECTED);
        return rc;
    }
    {
        int bad = 0;
        rc = acore_selftest(&a->core, &bad);
        reply(a, "#SELFTEST %s mismatches=%d rc=%d", rc == ACORE_OK ? "ok" : "FAIL", bad, rc);
        if (rc != ACORE_OK)
            return rc;               /* lo ma sai: khong ghi am voi khoa that */
    }
    rc = ctr_store_open(&a->ctr, nvm, key_id);
    if (rc != CTR_OK)
        reply(a, "#ERR CTR_STORE rc=%d", rc);
    return rc;
}

void app_audio_hello(app_audio_t *a)
{
    reply(a, "#HELLO spec=1.0.0 n=16 reseed=64 src=inmp441 fs_milli_hz=%lu version=0x%08lx next_ctr=%llu",
          (unsigned long)ACORE_FS_MILLI_HZ, (unsigned long)ACORE_VERSION_EXPECTED,
          (unsigned long long)a->ctr.next);
}

static void do_start(app_audio_t *a, char *args)
{
    uint32_t ctr0;
    char *src = strtok(args, " "), *shift = strtok(NULL, " ");
    int rc;

    if (a->running) {
        reply(a, "#ERR START dang ghi");
        return;
    }
    a->cfg.src = SRC_MIC;
    if (src && strcmp(src, "ramp") == 0)
        a->cfg.src = SRC_RAMP;
    else if (src && strcmp(src, "sine") == 0)
        a->cfg.src = SRC_SINE;
    else if (src && strcmp(src, "mic") != 0) {
        reply(a, "#ERR START nguon '%s'", src);
        return;
    }
    a->cfg.shift = shift ? (uint8_t)atoi(shift) : 0;
    rc = ctr_store_begin(&a->ctr, &ctr0);    /* sNVM da ghi next = ctr0 + 2^20 TRUOC khi dung */
    if (rc != CTR_OK) {
        reply(a, "#ERR START ctr_store rc=%d", rc);
        return;
    }
    rc = acore_start(&a->core, a->k_master, ctr0, &a->cfg);
    if (rc != ACORE_OK) {
        reply(a, "#ERR START acore rc=%d ctr=%lu", rc, (unsigned long)ctr0);
        return;
    }
    a->running = 1;
    a->checked_ctr = ctr0;
    reply(a, "#OK START ctr=%lu src=%u shift=%u limit=%llu", (unsigned long)ctr0, a->cfg.src,
          a->cfg.shift, (unsigned long long)a->ctr.next);
}

static void do_stop(app_audio_t *a, const char *why)
{
    int rc;
    if (!a->running) {
        reply(a, "#OK STOP idle");
        return;
    }
    rc = acore_stop(&a->core, &a->last_ctr);
    tx_flush(a);
    a->running = 0;
    reply(a, "#OK STOP last_ctr=%lu blocks=%lu gaps=%lu rc=%d%s%s", (unsigned long)a->last_ctr,
          (unsigned long)a->core.st.blocks, (unsigned long)a->core.st.gaps, rc,
          why ? " why=" : "", why ? why : "");
}

static void do_status(app_audio_t *a)
{
    acore_t *c = &a->core;
    uint32_t lvl = c->bus.rd(c->bus.ctx, ACORE_FIFO_LEVEL);
    reply(a, "#STAT run=%d ctr=%lu next=%llu words=%lu blocks=%lu gaps=%lu jumps=%lu breaks=%lu "
          "drop=%lu clip=%lu cycles_max=%lu out=%lu in=%lu status=0x%03lx",
          a->running, (unsigned long)c->ctr, (unsigned long long)a->ctr.next,
          (unsigned long)c->st.words, (unsigned long)c->st.blocks, (unsigned long)c->st.gaps,
          (unsigned long)c->st.ctr_jumps, (unsigned long)c->st.idx_breaks,
          (unsigned long)c->bus.rd(c->bus.ctx, ACORE_DROP_CNT),
          (unsigned long)c->bus.rd(c->bus.ctx, ACORE_CLIP_CNT),
          (unsigned long)c->bus.rd(c->bus.ctx, ACORE_CYCLES_MAX),
          (unsigned long)FIFO_OUT_LEVEL(lvl), (unsigned long)FIFO_IN_LEVEL(lvl),
          (unsigned long)c->bus.rd(c->bus.ctx, ACORE_STATUS));
}

void app_audio_command(app_audio_t *a, const char *line)
{
    char buf[64], *sp;
    strncpy(buf, line, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
    sp = strchr(buf, ' ');
    if (sp)
        *sp++ = 0;
    if (strcmp(buf, "START") == 0)
        do_start(a, sp ? sp : buf + strlen(buf));
    else if (strcmp(buf, "STOP") == 0)
        do_stop(a, NULL);
    else if (strcmp(buf, "STATUS") == 0)
        do_status(a);
    else
        reply(a, "#ERR lenh '%s'", buf);
}

void app_audio_service(app_audio_t *a)
{
    if (!a->running)
        return;
    acore_drain(&a->core);
    acore_irq_ack(&a->core);
    tx_flush(a);
    if (a->core.ctr - a->checked_ctr >= CTR_CHECK_EVERY) {
        a->checked_ctr = a->core.ctr;
        if (ctr_store_check(&a->ctr, a->core.ctr) == CTR_MUST_STOP)
            do_stop(a, "ctr_limit");
    }
}
