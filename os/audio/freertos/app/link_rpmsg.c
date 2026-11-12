/*
 * link_rpmsg.c - kenh RTOS <-> Linux bang RPMsg-Lite (phia remote, U54_4).
 *
 * Linux dung driver rpmsg_tty: khi RTOS announce kenh LINK_CHANNEL_NAME, Linux tao
 * /dev/ttyRPMSGx. chaosd mo tty do. Moi rpmsg_lite_send() = mot tin nhan <= 496 byte;
 * ben Linux thay no nhu luong byte, nen giao thuc tu co sync/CRC (app_core.h).
 *
 * API theo RPMsg-Lite co trong vi du AMP cua Microchip (rpmsg_lite.h, rpmsg_queue.h,
 * rpmsg_ns.h). Neu ban SDK cua ban khac ten/tham so, chi can sua file nay.
 */
#include "link_rpmsg.h"

#include <string.h>

#include "FreeRTOS.h"
#include "task.h"

#include "rpmsg_lite.h"
#include "rpmsg_ns.h"
#include "rpmsg_queue.h"

#include "board_config.h"

#if !defined(RPMSG_SHMEM_BASE) || !defined(RPMSG_LINK_ID)
#error "Dinh nghia RPMSG_SHMEM_BASE va RPMSG_LINK_ID theo vi du AMP cua Microchip"
#endif

static struct rpmsg_lite_instance *s_rl;
static struct rpmsg_lite_endpoint *s_ept;
static rpmsg_queue_handle s_q;
static volatile uint32_t s_remote_addr = RL_ADDR_ANY;
static link_line_fn s_on_line;

static void link_rx_task(void *arg)
{
    static char rx[LINK_MAX_PAYLOAD];
    char line[128];
    size_t used = 0;
    (void)arg;

    for (;;) {
        uint32_t src, len = 0, i;
        if (rpmsg_queue_recv(s_rl, s_q, &src, rx, sizeof rx, &len, RL_BLOCK) != RL_SUCCESS)
            continue;
        s_remote_addr = src;                 /* dia chi endpoint cua Linux */
        for (i = 0; i < len; i++) {          /* ghep dong: tin nhan co the cat ngang dong */
            char ch = rx[i];
            if (ch == '\n' || ch == '\r') {
                if (used) {
                    line[used] = 0;
                    s_on_line(line);
                    used = 0;
                }
            } else if (used < sizeof line - 1) {
                line[used++] = ch;
            }
        }
    }
}

void link_start(link_line_fn on_line)
{
    s_on_line = on_line;
    s_rl = rpmsg_lite_remote_init((void *)RPMSG_SHMEM_BASE, RPMSG_LINK_ID, RL_NO_FLAGS);
    while (!rpmsg_lite_is_link_up(s_rl))     /* cho Linux nap remoteproc/virtio */
        vTaskDelay(pdMS_TO_TICKS(50));
    s_q = rpmsg_queue_create(s_rl);
    s_ept = rpmsg_lite_create_ept(s_rl, LINK_LOCAL_EPT_ADDR, rpmsg_queue_rx_cb, s_q);
    rpmsg_ns_announce(s_rl, s_ept, LINK_CHANNEL_NAME, RL_NS_CREATE);
    xTaskCreate(link_rx_task, "link_rx", STACK_LINK_RX, NULL, PRIO_LINK_RX, NULL);
}

void link_send(const uint8_t *buf, size_t len)
{
    uint32_t dst = s_remote_addr;
    if (s_rl == NULL || dst == RL_ADDR_ANY || len == 0 || len > LINK_MAX_PAYLOAD)
        return;
    rpmsg_lite_send(s_rl, s_ept, dst, (char *)buf, (uint32_t)len, RL_BLOCK);
}
