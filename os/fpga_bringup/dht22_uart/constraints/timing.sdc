# timing.sdc - clock 50 MHz tu bo dao dong X3 (chan R18).
create_clock -name REF_CLK_50MHz -period 20 [get_ports REF_CLK_50MHz]

# DHT22 va UART deu cham (us, 115200 baud) va di qua bo dong bo -> khong can rang buoc I/O.
set_false_path -from [get_ports DHT_DATA]
set_false_path -to [get_ports {DHT_DATA UART_TXD LED1 LED2 LED3 LED4}]
