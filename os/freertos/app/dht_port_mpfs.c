/*
 * dht_port_mpfs.c - doc DHT22 bang bit-bang MSS GPIO_2 tren U54_4.
 *
 * Diem mau chot cua bai thu: U54_4 la loi RIENG cua RTOS. Khoa ngat ~5 ms trong luc
 * do xung chi anh huong loi nay, Linux tren U54_1..3 van chay binh thuong. Neu doc
 * DHT22 tu Linux, bo lap lich co the chen vao giua mot xung 27 us va lam sai bit.
 */
#include "dht_port_mpfs.h"

#include "FreeRTOS.h"
#include "task.h"

#include "mpfs_hal/mss_hal.h"
#include "drivers/mss/mss_gpio/mss_gpio.h"

#include "board_config.h"

static inline uint32_t now_us(void)
{
    uint64_t t = *(volatile uint64_t *)CLINT_MTIME_ADDR;
    return (uint32_t)(t / (MTIME_HZ / 1000000ul));
}

static inline int data_level(void)
{
    return (MSS_GPIO_get_inputs(DHT_GPIO_INSTANCE) & DHT_SENSE_MASK) ? 1 : 0;
}

static inline void data_drive_low(int on)
{
    MSS_GPIO_set_output(DHT_GPIO_INSTANCE, DHT_DRIVE_PIN, on ? 1u : 0u);
}

/* Cho DATA ve 'level'; tra so us da cho, hoac -1 neu qua timeout_us. */
static int32_t wait_level(int level, uint32_t timeout_us)
{
    uint32_t t0 = now_us();
    while (data_level() != level) {
        if (now_us() - t0 > timeout_us)
            return -1;
    }
    return (int32_t)(now_us() - t0);
}

void dht_port_init(void)
{
    MSS_GPIO_init(DHT_GPIO_INSTANCE);
    MSS_GPIO_config(DHT_GPIO_INSTANCE, DHT_DRIVE_PIN, MSS_GPIO_OUTPUT_MODE);
    MSS_GPIO_config(DHT_GPIO_INSTANCE, DHT_SENSE_PIN, MSS_GPIO_INPUT_MODE);
    data_drive_low(0);
}

int dht_port_read(uint16_t high_us[DHT22_BITS])
{
    int i, rc = DHT22_OK;

    /* 1. Tin hieu bat dau: keo thap >= 1 ms (duoc phep nhuong CPU trong luc cho). */
    data_drive_low(1);
    vTaskDelay(pdMS_TO_TICKS(DHT_START_LOW_MS));

    /* 2. Tu day den het 40 bit (~5 ms) can do thoi gian chinh xac: khoa ngat loi nay. */
    taskENTER_CRITICAL();
    data_drive_low(0);
    if (wait_level(0, 200) < 0 ||     /* cam bien keo thap sau 20-40 us */
        wait_level(1, 120) < 0 ||     /* thap ~80 us */
        wait_level(0, 120) < 0) {     /* cao ~80 us */
        rc = DHT22_ERR_NO_RESPONSE;
    } else {
        for (i = 0; i < DHT22_BITS; i++) {
            int32_t hi;
            if (wait_level(1, 100) < 0) {          /* thap ~50 us truoc moi bit */
                rc = DHT22_ERR_TIMEOUT;
                break;
            }
            hi = wait_level(0, 120);               /* do rong xung cao = gia tri bit */
            if (hi < 0) {
                rc = DHT22_ERR_TIMEOUT;
                break;
            }
            high_us[i] = (uint16_t)hi;
        }
    }
    taskEXIT_CRITICAL();
    return rc;
}
