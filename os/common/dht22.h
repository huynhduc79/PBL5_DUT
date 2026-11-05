/*
 * dht22.h - giai ma khung 40 bit cua DHT22 (AM2302), khong phu thuoc phan cung.
 *
 * Giao thuc 1 day (chan DATA keo len 3,3 V bang dien tro 4,7-10 kOhm):
 *   MCU keo thap >= 1 ms roi nha  -> cam bien tra loi: thap 80 us, cao 80 us
 *   40 bit, moi bit: thap ~50 us roi cao 26-28 us (bit 0) hoac ~70 us (bit 1)
 *   Du lieu: RH[16] | T[16] | checksum[8] = tong 4 byte dau (mod 256)
 *   RH = do am x10 (%). T = dau-do lon: bit 15 la dau, 15 bit con lai = nhiet do x10 (do C).
 *
 * Phan doc chan GPIO (do do rong xung) nam o port cua tung nen tang; o day chi
 * co phan giai ma tu do rong xung cao -> bit -> byte -> gia tri.
 */
#ifndef DHT22_H
#define DHT22_H

#include <stdint.h>

#define DHT22_BITS              40
#define DHT22_BIT1_THRESHOLD_US 48      /* xung cao > 48 us la bit 1 */
#define DHT22_MIN_PERIOD_MS     2000    /* khong doc nhanh hon 1 lan / 2 s */

typedef struct {
    uint16_t rh_raw;      /* do am x10 */
    uint16_t t_raw;       /* dang dau-do lon nhu cam bien gui */
} dht22_value_t;

enum {
    DHT22_OK = 0,
    DHT22_ERR_CHECKSUM = -1,
    DHT22_ERR_NO_RESPONSE = -2,   /* dung boi port */
    DHT22_ERR_TIMEOUT = -3,       /* dung boi port */
    DHT22_ERR_RANGE = -4,
};

/* high_us[i]: do rong xung cao cua bit i (bit 0 = bit gui dau tien = MSB cua RH). */
int     dht22_decode_pulses(const uint16_t high_us[DHT22_BITS], dht22_value_t *out);
int     dht22_decode_bytes(const uint8_t b[5], dht22_value_t *out);
int16_t dht22_temp_x10(uint16_t t_raw);           /* -> so co dau, don vi 0,1 do C */

#endif /* DHT22_H */
