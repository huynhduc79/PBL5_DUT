/*
 * main_audio.c - ung dung FreeRTOS tren U54_4: lo FPGA (INMP441 + ma hoa) -> block .chau -> RPMsg -> Linux.
 *
 * Tich hop: giu nguyen ham u54_4() cua vi du AMP Microchip (khoi tao PLIC, IHC, tick...),
 * chi them mot dong goi pbl5_app_start() truoc vTaskStartScheduler().
 *
 *   ISR irq_o  --EV_IRQ----\
 *   link_rx    --EV_COMMAND-> event queue --> app_task --> app_audio (acore_drv, ctr_store) --> link_send()
 *   (het 20 ms khong co gi) -> app_task tu phuc vu, phong mat ngat
 *
 * Chi app_task cham vao app_audio_t va thanh ghi FPGA -> khong can mutex.
 * K_master: doc tu sNVM vao app (RAM cua U54_4), nap vao FPGA moi lan START; Linux khong bao gio thay.
 */
#include <string.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "task.h"

#include "acore_port_mpfs.h"
#include "app_audio.h"
#include "board_config.h"
#include "link_rpmsg.h"

typedef enum { EV_IRQ, EV_COMMAND } ev_type_t;

typedef struct {
    ev_type_t type;
    char      line[64];
} event_t;

static QueueHandle_t s_events;
static app_audio_t s_app;
static const event_t s_ev_irq = { EV_IRQ, "" };

static void tx_link(void *ctx, const uint8_t *buf, size_t len)
{
    (void)ctx;
    link_send(buf, len);
}

static void on_line(const char *line)          /* chay trong link_rx_task */
{
    event_t ev;
    ev.type = EV_COMMAND;
    strncpy(ev.line, line, sizeof ev.line - 1);
    ev.line[sizeof ev.line - 1] = 0;
    xQueueSend(s_events, &ev, pdMS_TO_TICKS(100));
}

static void app_task(void *arg)
{
    acore_bus_t bus;
    ctr_nvm_t nvm;
    uint8_t key[32];
    (void)arg;

    acore_port_bus(&bus);
    acore_port_nvm(&nvm);
    link_start(on_line);                    /* cho Linux san sang, tao link_rx */
    if (acore_port_load_key(key) != 0 ||
        app_audio_init(&s_app, &bus, &nvm, KEY_ID, key, tx_link, NULL) != 0) {
        /* app_audio_init da gui #ERR cho Linux; khong ghi am, chi tra loi STATUS */
    }
    memset(key, 0, sizeof key);
    app_audio_hello(&s_app);
    acore_port_irq_init(s_events, &s_ev_irq);

    for (;;) {
        event_t ev;
        if (xQueueReceive(s_events, &ev, pdMS_TO_TICKS(ACORE_POLL_MS)) == pdPASS && ev.type == EV_COMMAND) {
            app_audio_command(&s_app, ev.line);
            continue;
        }
        app_audio_service(&s_app);          /* EV_IRQ hoac het 20 ms */
        acore_port_irq_rearm();
    }
}

void pbl5_app_start(void)
{
    s_events = xQueueCreate(EVENT_QUEUE_LEN, sizeof(event_t));
    xTaskCreate(app_task, "app", STACK_APP, NULL, PRIO_APP, NULL);
}
