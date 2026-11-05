#include "dht22.h"

int dht22_decode_bytes(const uint8_t b[5], dht22_value_t *out)
{
    uint8_t sum = (uint8_t)(b[0] + b[1] + b[2] + b[3]);
    int16_t t;

    if (sum != b[4])
        return DHT22_ERR_CHECKSUM;
    out->rh_raw = (uint16_t)((b[0] << 8) | b[1]);
    out->t_raw  = (uint16_t)((b[2] << 8) | b[3]);
    /* Dai do cua DHT22: 0-100 %RH, -40..80 do C */
    t = dht22_temp_x10(out->t_raw);
    if (out->rh_raw > 1000 || t < -400 || t > 800)
        return DHT22_ERR_RANGE;
    return DHT22_OK;
}

int dht22_decode_pulses(const uint16_t high_us[DHT22_BITS], dht22_value_t *out)
{
    uint8_t b[5] = { 0 };
    int i;

    for (i = 0; i < DHT22_BITS; i++)
        if (high_us[i] > DHT22_BIT1_THRESHOLD_US)
            b[i / 8] |= (uint8_t)(0x80u >> (i % 8));
    return dht22_decode_bytes(b, out);
}

int16_t dht22_temp_x10(uint16_t t_raw)
{
    int16_t mag = (int16_t)(t_raw & 0x7FFF);
    return (t_raw & 0x8000) ? (int16_t)-mag : mag;
}
