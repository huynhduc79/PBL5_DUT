/*
 * main_rtos.c - ung dung FreeRTOS tren U54_4: DHT22 -> ma hoa chaos (phan mem) -> RPMsg -> Linux.
 *
 * Tich hop: giu nguyen ham u54_4() cua vi du AMP Microchip (khoi tao PLIC, IHC, tick...),
 * chi them mot dong goi pbl5_app_start() truoc vTaskStartScheduler().
 *
 *   dht_task  (uu tien cao) --EV_READING--\
 *                                          >-- event queue --> app_task --> link_send() --> Linux
 *   link_rx   (RPMsg rx)    --EV_COMMAND--/                    (app_core: cipher, lease, block)
 *
 * Chi app_task cham vao app_t (khoa, trang thai cipher) -> khong can mutex.
 * Sau nay chuyen sang loi FPGA: app_task ghi DATA_IN / doc OUT_DATA thay cho chaos_encrypt(),
 * con lai giu nguyen.
 */
#include <string.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "task.h"

#include "app_core.h"
#include "board_config.h"
#include "dht22.h"
#include "dht_port_mpfs.h"
#include "kmaster.h"            /* K_MASTER[32]; KHONG commit, xem kmaster.h.example */
#include "link_rpmsg.h"

typedef enum { EV_READING, EV_COMMAND } ev_type_t;

typedef struct {
    ev_type_t type;
    union {
        struct {
            int      status;
            uint16_t rh_raw, t_raw;
        } reading;
        char line[64];
    } u;
} event_t;

static QueueHandle_t s_events;
static app_t s_app;

static void tx_link(void *ctx, const uint8_t *buf, size_t len)
{
    (void)ctx;
    link_send(buf, len);
}

static void on_line(const char *line)          /* chay trong link_rx_task */
{
    event_t ev;
    ev.type = EV_COMMAND;
    strncpy(ev.u.line, line, sizeof ev.u.line - 1);
    ev.u.line[sizeof ev.u.line - 1] = 0;
    xQueueSend(s_events, &ev, pdMS_TO_TICKS(100));
}

static void dht_task(void *arg)
{
    TickType_t last = xTaskGetTickCount();
    (void)arg;

    dht_port_init();
    for (;;) {
        uint16_t high[DHT22_BITS];
        dht22_value_t v = { 0, 0 };
        event_t ev;
        int st;

        vTaskDelayUntil(&last, pdMS_TO_TICKS(DHT_PERIOD_MS));
        st = dht_port_read(high);
        if (st == DHT22_OK)
            st = dht22_decode_pulses(high, &v);        /* kiem checksum + dai do */
        ev.type = EV_READING;
        ev.u.reading.status = st;
        ev.u.reading.rh_raw = v.rh_raw;
        ev.u.reading.t_raw = v.t_raw;
        xQueueSend(s_events, &ev, 0);                   /* day thi bo, app se thay GAP */
        memset(high, 0, sizeof high);
    }
}

static void app_task(void *arg)
{
    (void)arg;
    app_init(&s_app, K_MASTER, tx_link, NULL);
    link_start(on_line);                    /* cho Linux san sang, tao link_rx */
    app_hello(&s_app);
    xTaskCreate(dht_task, "dht", STACK_DHT, NULL, PRIO_DHT, NULL);

    for (;;) {
        event_t ev;
        if (xQueueReceive(s_events, &ev, portMAX_DELAY) != pdPASS)
            continue;
        if (ev.type == EV_COMMAND)
            app_command(&s_app, ev.u.line);
        else
            app_reading(&s_app, ev.u.reading.status, ev.u.reading.rh_raw, ev.u.reading.t_raw);
        memset(&ev, 0, sizeof ev);           /* khong de ban ro nam lai tren stack */
    }
}

void pbl5_app_start(void)
{
    s_events = xQueueCreate(EVENT_QUEUE_LEN, sizeof(event_t));
    xTaskCreate(app_task, "app", STACK_APP, NULL, PRIO_APP, NULL);
}
