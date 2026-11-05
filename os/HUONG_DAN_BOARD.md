# Đưa bài thực hành DHT22 lên PolarFire SoC Discovery Kit

> Trạng thái: phần dùng chung (`common/`) và Linux (`chaosd.py`) đã kiểm thử trên PC. Ba file phụ thuộc SDK (`dht_port_mpfs.c`, `link_rpmsg.c`, `main_rtos.c`) **mới chỉ kiểm tra cú pháp với header giả**, chưa chạy trên board. Mọi chỗ ghi **[KIỂM TRA]** phải đối chiếu với phiên bản Libero/SDK/ví dụ Microchip bạn tải về.

Làm theo thứ tự. Mỗi bước có cách kiểm tra riêng, để khi hỏng biết ngay hỏng ở tầng nào.

## Bước 0 – Chuẩn bị

- Libero SoC (đã có 2026.1) + license, SoftConsole, FlashPro Express.
- **Thiết kế tham chiếu cho Discovery Kit** của Microchip (Libero project) và **ví dụ AMP FreeRTOS + Linux dùng RPMsg** của Microchip (trong bộ ví dụ bare-metal/AMP cho PolarFire SoC). Bài này **ghép vào ví dụ đó**, không viết lại phần khởi tạo hart, IHC, linker script.
- Ảnh Linux có hỗ trợ AMP (Yocto `meta-polarfire-soc-yocto-bsp` hoặc Buildroot của Microchip) với `python3` và `rclone`. **[KIỂM TRA]** bản BSP có máy (MACHINE) cho Discovery Kit ở chế độ AMP.
- Cảm biến DHT22 (AM2302), điện trở 10 kΩ nếu là cảm biến trần (module 3 chân thường đã có sẵn).

## Bước 1 – Đấu dây

| DHT22 | Header J10 (chân vật lý) | Chân FPGA |
|---|---|---|
| VCC | 1 (3,3 V) | — |
| DATA | **7** | **E12** (GPIO Bank 1) |
| GND | 6 | — |
| (cảm biến trần) 10 kΩ từ DATA lên 3,3 V | | |

Jumper **J45 ở 1–2 (3,3 V)**. Chân này không trùng các chân dự kiến cho INMP441 (E10, B19, B14), nên sau này cắm được cả hai cùng lúc.

## Bước 2 – Thiết kế FPGA (Libero)

1. Mở thiết kế tham chiếu Discovery Kit.
2. **MSS Configurator → GPIO_2:** bật, cho 2 bit nối ra fabric. Bit 0 là ngõ ra M2F (`DRIVE`), bit 1 là ngõ vào F2M (`SENSE`). **[KIỂM TRA]** tên tín hiệu (`GPIO_2_M2F`, `GPIO_2_F2M`) và vùng địa chỉ `GPIO2_LO`/`GPIO2_HI` trong bản Libero của bạn.
3. **SmartDesign:** thêm một `BIBUF`:
   - `D` = 0 (GND)
   - `E` = `GPIO_2_M2F[0]`
   - `Y` → `GPIO_2_F2M[1]`
   - `PAD` → cổng top-level `DHT_DATA`

   Như vậy chân chỉ kéo xuống 0 hoặc thả nổi (open-drain), không bao giờ đẩy 3,3 V ngược vào cảm biến.
4. **Ràng buộc I/O (PDC):** `DHT_DATA` → chân **E12**, chuẩn **LVCMOS33**. Có thể bật pull-up nội (nhưng vẫn nên có điện trở ngoài).
5. Tổng hợp, place & route, nạp bitstream. Xuất cấu hình MSS (XML) để dùng cho HSS và SoftConsole.

**Kiểm tra:** chưa cần RTOS. Dùng một chương trình bare-metal nhỏ (hoặc SmartDebug) đọc `GPIO_2` bit 1: khi rảnh phải bằng **1** nhờ điện trở kéo lên. Ghi bit 0 = 1 thì đọc lại phải là **0**.

## Bước 3 – Chạy ví dụ AMP gốc của Microchip (chưa sửa gì)

1. Build ví dụ FreeRTOS cho U54_4 và Linux cho U54_1..3 theo hướng dẫn của ví dụ. Dùng `hss-payload-generator` với file YAML gán hart 1–3 cho U-Boot/Linux, hart 4 cho ELF FreeRTOS.
2. Boot, đăng nhập Linux qua UART (FT4232H trên USB-C).

**Kiểm tra:**
```bash
dmesg | grep -i rpmsg
ls /dev/ttyRPMSG* /dev/rpmsg* 2>/dev/null
```
Phải thấy kênh RPMsg của ví dụ hoạt động. **Chưa qua bước này thì đừng làm tiếp.** Lỗi ở đây thuộc về cấu hình AMP/HSS/device tree, không phải code của bài.

## Bước 4 – Ghép ứng dụng PBL5 vào project FreeRTOS

1. Thêm vào project SoftConsole: `os/common/*.c`, `os/freertos/app/*.c`. Thêm include path `os/common`, `os/freertos/app`.
2. Định nghĩa `RPMSG_SHMEM_BASE`, `RPMSG_LINK_ID` (Project → Properties → C/C++ Build → Defines). Lấy **đúng giá trị ví dụ đang dùng**.
3. Trong `board_config.h`:
   - Chỉnh `LINK_CHANNEL_NAME` sao cho Linux tạo `/dev/ttyRPMSGx`. Driver `rpmsg_tty` của Linux nhận kênh tên `rpmsg-tty`. **[KIỂM TRA]** tên kênh trong ví dụ/kernel của bạn.
   - Kiểm tra `MTIME_HZ` (1 MHz trên PolarFire SoC). Cách kiểm tra: in `now_us()` hai lần cách nhau `vTaskDelay(1000)` phải chênh khoảng 1 000 000.
4. Copy `kmaster.h.example` → `kmaster.h`, dán khóa sinh bằng lệnh trong file. Lưu dòng hex vào `key.hex` **trên laptop** (không đưa lên board Linux, không commit).
5. Trong `main` / `u54_4()` của ví dụ:
   - Bỏ các task demo của ví dụ (để chúng không giữ kênh RPMsg).
   - Gọi `pbl5_app_start();` ngay trước `vTaskStartScheduler();`.
6. Chỉnh stack: `chaos_cipher` cần khoảng 1 KB stack (mảng `w[64]` của SHA-256) → `STACK_APP = 2048` word là đủ.
7. Build, tạo lại payload, nạp vào thẻ nhớ/eMMC.

**Kiểm tra trên Linux** (chưa chạy daemon):
```bash
stty -F /dev/ttyRPMSG0 raw -echo
cat /dev/ttyRPMSG0 | xxd &
echo "STATUS" > /dev/ttyRPMSG0                 # mong đợi: #STAT run=0 ...
echo "START 0 4" > /dev/ttyRPMSG0              # mong đợi: #OK START ctr=0 limit=4
# sau ~2 s: các block bắt đầu bằng a5 5a, mỗi 2 s một block 16 byte
echo "STOP" > /dev/ttyRPMSG0
```
Nếu `#STAT` cho thấy `fail` tăng còn `ok` đứng yên thì lỗi nằm ở dây/GPIO/thời gian đo. Xem bảng cuối tài liệu.

> ⚠️ Lần thử tay này đã dùng ctr 0..3. Trước khi chạy daemon, ghi `{"next_ctr": 4}` vào `/var/lib/chaos/ctr_state.json` (hoặc lớn hơn), nếu không daemon sẽ bắt đầu lại từ 0. RTOS cũng tự từ chối nếu chưa khởi động lại, nhưng đừng dựa vào điều đó.

## Bước 5 – Daemon Linux

```bash
mkdir -p /opt/chaos /etc/chaos /var/lib/chaos
cp chaosd.py chaos-upload.sh /opt/chaos/ && chmod +x /opt/chaos/*
cp chaosd.conf.example /etc/chaosd.conf
cp chaosd.service chaos-upload.service chaos-upload.timer /etc/systemd/system/
python3 /opt/chaos/chaosd.py --config /etc/chaosd.conf -v      # chạy tay trước, Ctrl+C để dừng
```

**Kiểm tra:** log có `-> START n m`, `<- #OK START`, sau 2 s có `mo file rec_…chau`. Ctrl+C thì file chuyển sang `/var/lib/chaos/outbox/`.

Bật dịch vụ: `systemctl daemon-reload && systemctl enable --now chaosd`.

## Bước 6 – Google Drive bằng rclone

Board không có trình duyệt, nên lấy token trên laptop:

```bash
rclone authorize "drive"
```

Trên board:

```bash
rclone config --config /etc/chaos/rclone.conf
```

Chọn `n` (new remote), tên `gdrive`, loại `drive`, đến câu "Use auto config?" chọn **No** và dán token vừa lấy.

```bash
chmod 600 /etc/chaos/rclone.conf
rclone --config /etc/chaos/rclone.conf lsd gdrive:            # kiểm tra
systemctl enable --now chaos-upload.timer
```

Token Drive nằm trên Linux là chấp nhận được, vì Linux chỉ có bản mã. **Không commit `rclone.conf`.**

## Bước 7 – Giải mã trên laptop

Tải các file `rec_*.chau` từ Drive (thư mục `PBL5/dht22`), rồi:

```bash
python os/tools/dht_decode.py "Downloads/rec_*.chau" --key key.hex --refmodel <thư mục chứa refmodel> -o dht.csv
```

So vài giá trị với một nhiệt kế/ẩm kế thật để chắc chắn dữ liệu đúng là đo được, không chỉ là giải mã khớp.

## Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp | Cách kiểm tra |
|---|---|---|
| `fail` tăng, `ok` = 0, lỗi NO_RESPONSE | Thiếu điện trở kéo lên, sai chân, BIBUF nối ngược `E` | Đo DATA lúc rảnh phải là 3,3 V. Bước 2 kiểm tra GPIO |
| Lỗi checksum thường xuyên | `MTIME_HZ` sai hoặc ngưỡng 48 µs không hợp | In ra 40 giá trị `high_us[]`: phải gom quanh khoảng 25 và 70 |
| Không có `/dev/ttyRPMSG0` | Tên kênh không khớp driver, hoặc RTOS chưa announce | `dmesg | grep rpmsg`; thử `LINK_CHANNEL_NAME` của ví dụ |
| `#ERR START ctr=... da dung` | Daemon gửi ctr cũ trong khi RTOS chưa khởi động lại | Đúng hành vi bảo vệ. Sửa `ctr_state.json` cho lớn hơn |
| `#LEASE_WAIT` liên tục | Daemon không chạy hoặc không ghi được state | `systemctl status chaosd`, quyền ghi `/var/lib/chaos` |
| File không lên Drive | Mạng/token | `journalctl -u chaos-upload`; file vẫn nằm an toàn trong outbox |
