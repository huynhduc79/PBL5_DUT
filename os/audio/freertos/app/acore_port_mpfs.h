#ifndef ACORE_PORT_MPFS_H
#define ACORE_PORT_MPFS_H

#include <stdint.h>

#include "FreeRTOS.h"
#include "queue.h"

#include "acore_drv.h"
#include "ctr_store.h"

void acore_port_bus(acore_bus_t *bus);
void acore_port_nvm(ctr_nvm_t *nvm);
/* Doc K_master tu trang sNVM SNVM_PAGE_KEY. Tra 0 neu thanh cong. */
int  acore_port_load_key(uint8_t k_master[32]);
/* ISR day *ev_irq (mot phan tu cua q, vd. event_t loai EV_IRQ) vao q moi khi irq_o len,
 * roi tu tat nguon ngat. ev_irq phai song suot (static). */
void acore_port_irq_init(QueueHandle_t q, const void *ev_irq);
/* Bat lai nguon ngat sau khi da rut FIFO va xoa IRQ_STATUS. */
void acore_port_irq_rearm(void);

#endif /* ACORE_PORT_MPFS_H */
