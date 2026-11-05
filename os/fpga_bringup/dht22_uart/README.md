# Bring-up 1: DHT22 → UART, chỉ dùng FPGA (SystemVerilog)

Bước đầu tiên trên board: **không MSS, không RTOS, không Linux**. Một khối SystemVerilog trong fabric đọc DHT22 mỗi 2 s và in kết quả ra cổng USB-UART của board. Chạy được bài này là đã chứng minh:
- quy trình Libero → nạp chip hoạt động;
- đồng hồ 50 MHz và cổng serial chạy đúng;
- dây nối và cảm biến tốt.

Sau đó mới lên phần RTOS ([../../HUONG_DAN_BOARD.md](../../HUONG_DAN_BOARD.md)).

> RTOS là phần mềm chạy trên lõi RISC-V nên không viết bằng SystemVerilog được. Bài này kiểm tra phần cứng trước, để khi lên RTOS có lỗi thì biết chắc không phải do board hay dây.

Trên serial monitor sẽ thấy:

```
PBL5 DHT22 bring-up (FPGA only) 115200 8N1 DATA=E12
#00001 RH=65.2% T=28.5C raw=028C011DAC OK
#00002 RH=65.4% T=28.5C raw=028E011DAE OK
#00003 ERR=NO_RESPONSE raw=...        <- khi rút dây DATA
```

`raw` là 5 byte nhận được: RH, T, checksum. Nó giúp so với bản C trên RTOS sau này.

## Cấu trúc

| File | Nội dung |
|---|---|
| `hdl/dht22_reader.sv` | FSM giao thức DHT22: open-drain, lọc nhiễu, đo xung theo µs, timeout ở mọi trạng thái, kiểm checksum và dải đo |
| `hdl/uart_tx.sv` | UART 8N1 115200 |
| `hdl/line_printer.sv` | Đổi số sang ASCII (BCD) và in từng ký tự |
| `hdl/dht22_uart_top.sv` | Top: POR, hẹn giờ 2 s, LED |
| `tb/tb_dht22_uart.sv` | Testbench: mô hình DHT22 + bộ thu UART, 5 kịch bản |
| `constraints/io.pdc`, `timing.sdc` | Chân + clock (theo thiết kế tham chiếu của Microchip) |
| `scripts/build.tcl` | Tạo project Libero, build, xuất `out/dht22_uart.job` |
| `scripts/program.tcl` | Nạp vào board |
| `scripts/serial_monitor.py` | Đọc serial, tự tìm đúng cổng COM |

## Đấu dây

| DHT22 | Header J10 | Chân FPGA |
|---|---|---|
| VCC | chân 1 (3,3 V) | — |
| DATA | **chân 7** | **E12** (Bank 1, LVCMOS33) |
| GND | chân 6 | — |

- Cảm biến trần cần thêm 4,7–10 kΩ từ DATA lên 3,3 V. Module 3 chân thường đã có sẵn. FPGA cũng bật pull-up nội, nhưng pull-up nội yếu.
- Jumper **J45 ở 1–2** (3,3 V, mặc định).

## Đèn LED

| LED | Ý nghĩa |
|---|---|
| LED1 | Nhấp nháy 1 Hz: bitstream đang chạy, có clock |
| LED2 | Đảo trạng thái mỗi lần đọc OK |
| LED3 | Sáng khi lần đọc gần nhất bị lỗi |
| LED4 | Sáng trong ~7 ms mỗi lần giao tiếp với cảm biến |

## 1. Mô phỏng (đã chạy: TB PASS)

```powershell
mkdir sim_work; cd sim_work
$Q = "D:\PBL5\Libero_SoC_2026.1\Libero_SoC\QuestaSim_Pro\win64"
& "$Q\vlib.exe" work
& "$Q\vlog.exe" -sv ../hdl/dht22_reader.sv ../hdl/uart_tx.sv ../hdl/line_printer.sv ../hdl/dht22_uart_top.sv ../tb/tb_dht22_uart.sv
& "$Q\vsim.exe" -c tb_dht22_uart -do "run -all; quit -f"
```

Kết quả mong đợi:

```
[  5.9 ms] UART: PBL5 DHT22 bring-up (FPGA only) 115200 8N1 DATA=E12
[ 22.9 ms] UART: #00001 RH=65.2% T=28.5C raw=028C011DAC OK
[ 36.3 ms] UART: #00002 ERR=CHECKSUM raw=028C011DAD
[ 46.9 ms] UART: #00003 ERR=NO_RESPONSE raw=028C011DAD
[ 65.0 ms] UART: #00004 RH=100.0% T=-3.5C raw=03E880238E OK
[ 78.4 ms] UART: #00005 RH=5.0% T=0.0C raw=0032000032 OK
TB PASS (6 dong khop)
```

Muốn xem dạng sóng: bỏ `-c`, chạy `vsim tb_dht22_uart`, rồi `add wave -r /*` và `run -all`.

## 2. Build bằng Libero (đã chạy: timing đạt ở mọi corner)

Chạy từ thư mục này:

```powershell
& "D:\PBL5\Libero_SoC_2026.1\Libero_SoC\Designer\bin\libero.exe" SCRIPT:scripts/build.tcl LOGFILE:build.log
```

Mất khoảng 3 phút. Kết quả: `out/dht22_uart.job` và project `work/libero/dht22_uart.prjx` (mở bằng Libero GUI để xem). Tài nguyên dùng: 1425 4LUT (1,5 %), 359 DFF (0,4 %), 7 I/O, không cần CCC/PLL. Phần lớn LUT là bộ đổi BCD tổ hợp trong `line_printer`.

## 3. Nạp vào board

Cắm USB-C vào **J4** (J47 ở 1–2: nguồn từ USB). Có hai cách:

**Cách A, dòng lệnh:**

```powershell
& "D:\PBL5\Libero_SoC_2026.1\Libero_SoC\Designer\bin\libero.exe" SCRIPT:scripts/program.tcl LOGFILE:program.log
```

**Cách B, FlashPro Express** (`D:\PBL5\Libero_SoC_2026.1\Libero_SoC\Designer\bin\FPExpress.exe`): Project → New Job Project from FlashPro Express Job → chọn `out/dht22_uart.job` → RUN → chờ `RUN PASSED`.

> Việc này ghi đè thiết kế demo FIR có sẵn trên board. Muốn lấy lại, nạp job của AN5165.

## 4. Xem serial

```powershell
python scripts/serial_monitor.py --list     # xem các cổng COM
python scripts/serial_monitor.py            # tự thử từng cổng của FT4232H
```

Hoặc dùng PuTTY / Arduino Serial Monitor / Tera Term: **115200, 8N1, không flow control**. FT4232H tạo nhiều cổng COM; cổng của bài này là kênh **D**, thường là số COM lớn nhất trong nhóm.

## Không thấy gì trên serial?

Đi theo thứ tự:

1. **LED1 không nháy:** chưa nạp được, hoặc nạp sai. Xem `program.log` / FlashPro Express.
2. **LED1 nháy, không có chữ trên mọi cổng COM:** chân TX có thể bị đảo. Thiết kế tham chiếu đặt tên theo phía FTDI (`FTDI_UART_D_RXD` = Y21), mình dùng Y21 làm ngõ ra.
   - Thử đổi `UART_TXD` sang `W21` trong `constraints/io.pdc`, build lại.
   - Trong lúc thử, **đừng gõ phím vào terminal**, để FTDI không phát ngược vào chân đang là ngõ ra.
3. **Có chữ nhưng toàn ký tự rác:** sai baud. Đặt terminal đúng 115200.
4. **Có dòng chào, nhưng mọi lần đọc đều `ERR=NO_RESPONSE`:** kiểm tra dây DATA ở chân 7, VCC, GND, và điện trở kéo lên. LED4 phải chớp mỗi 2 s.
5. **`ERR=CHECKSUM` / `ERR=TIMEOUT` thường xuyên:** dây quá dài hoặc nhiễu. Rút ngắn dây, dùng điện trở 4,7 kΩ.
