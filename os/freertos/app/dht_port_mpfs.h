#ifndef DHT_PORT_MPFS_H
#define DHT_PORT_MPFS_H

#include <stdint.h>

#include "dht22.h"

void dht_port_init(void);
/* Doc 40 do rong xung cao (us). Tra DHT22_OK hoac DHT22_ERR_NO_RESPONSE / DHT22_ERR_TIMEOUT. */
int  dht_port_read(uint16_t high_us[DHT22_BITS]);

#endif /* DHT_PORT_MPFS_H */
