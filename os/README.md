# Phần OS – bài thực hành DHT22 (bước đệm trước INMP441)

Mục tiêu: hiểu **cách chia việc giữa RTOS và Linux trên PolarFire SoC** và **cách dữ liệu được mã hóa** bằng một cảm biến đơn giản (DHT22, 1 lần đọc / 2 s), trước khi làm micro INMP441 (16 000 mẫu/s).

Bài này mã hóa **bằng phần mềm C trên FreeRTOS** (bản port từng bit của `refmodel`), chưa dùng lõi FPGA. Khi lõi FPGA của thành viên mã hóa xong (mốc M1), chỉ thay một chỗ trong RTOS. Linux, giao thức, định dạng file và công cụ giải mã giữ nguyên.

```
 DHT22 ──GPIO (E12)──► FreeRTOS @ U54_4                       Linux @ U54_1..3                Laptop
                       ├ dht_task: đo xung (khóa ngắt ~5 ms)    chaosd.py                       dht_decode.py
                       ├ app_task: chaos_encrypt (N=16)  ─RPMsg─►├ cấp lease ctr                   (refmodel)
                       │   RH, T = 2 mẫu / lần đọc        tty    ├ ghi rec_*.chau (1 giờ/file)       │
                       └ K_master chỉ ở đây                      └ rclone ──Ethernet──► Google Drive ─┘
```

## 1. Cấu trúc thư mục

| Đường dẫn | Chạy ở đâu | Nội dung |
|---|---|---|
| `common/chaos_cipher.[ch]` | RTOS + PC | Port C của refmodel SPEC 1.0.0: SHA-256, HMAC, LTS, Fisher–Yates, phiên |
| `common/chau_block.[ch]` | RTOS + PC | Đóng block `.chau` + CRC-16/CCITT-FALSE (mục 8.2 tài liệu thiết kế) |
| `common/dht22.[ch]` | RTOS + PC | Giải mã 40 xung → RH/T, kiểm checksum |
| `common/app_core.[ch]` | RTOS + PC | Logic ứng dụng: lệnh từ Linux, lease ctr, mã hóa, đóng block |
| `freertos/app/` | U54_4 | `main_rtos.c` (task + hàng đợi), `dht_port_mpfs.c` (GPIO), `link_rpmsg.c` (RPMsg) |
| `linux/chaosd/chaosd.py` | Linux | Daemon: lease ctr, tách luồng, ghi/xoay file |
| `linux/systemd/`, `linux/upload/` | Linux | Dịch vụ systemd, script `rclone move` lên Drive |
| `sim/sim_rtos.c` | PC | Mô phỏng RTOS (luồng + hàng đợi + DHT22 giả) để chạy thử không cần board |
| `tools/dht_decode.py` | Laptop | Giải mã `.chau` ra CSV bằng refmodel |
| `tests/` | PC | So C với vector golden, kiểm thử đầu-cuối |
| `fpga_bringup/dht22_uart/` | FPGA fabric | **Làm bước này đầu tiên:** SystemVerilog đọc DHT22 và in ra serial, không cần MSS/RTOS |

`common/` được biên dịch **nguyên văn** cho cả board lẫn PC. Thứ chạy đúng trên PC chính là thứ sẽ chạy trên U54_4, chỉ khác lớp GPIO/RPMsg.

## 2. Chạy thử trên PC (không cần board)

Cần: MSYS2 MinGW64 (`gcc`, `make`) hoặc Linux, Python ≥ 3.10, thư mục chứa `refmodel/` và `vectors/out` của thành viên mã hóa.

```bash
make test REFMODEL=D:/PBL5/chaos_refmodel_v1.0.0/chaos_project
```

Kết quả mong đợi:

```
10036 kiem tra, 0 sai -> TAT CA KHOP              # C khớp từng bit với refmodel (7 bộ vector)
lan 1: ... ma hoa+giai ma dung 224/224, co GAP=14, ctr 0..6 -> DAT
lan 2: ... ma hoa+giai ma dung 215/215, co GAP=23, ctr 8..14 -> DAT
khong lap ctr giua hai lan chay: DAT
K_master khong xuat hien trong file outbox: DAT
```

Chạy tay để quan sát (cửa sổ 1 dòng log mỗi lệnh/phản hồi):

```bash
python linux/chaosd/chaosd.py -v --data-dir build/demo --rotate-s 30 --lease 2 --status-every 5 --sim-cmd "build/sim_rtos.exe --key build/e2e/test.key --period-ms 200"
```

Rồi giải mã:

```bash
python tools/dht_decode.py "build/demo/outbox/*.chau" --key build/e2e/test.key --refmodel D:/PBL5/chaos_refmodel_v1.0.0/chaos_project
```

## 3. Giao thức RTOS ↔ Linux

Một kênh RPMsg (trên Linux là `/dev/ttyRPMSG0`). Chi tiết trong `common/app_core.h`.

| Hướng | Bản ghi | Ví dụ |
|---|---|---|
| Linux → RTOS | dòng lệnh ASCII | `STOP`, `START 0 16`, `LEASE 24`, `STATUS` |
| RTOS → Linux | dòng trạng thái `#…\n` | `#HELLO spec=1.0.0 n=16 reseed=64 src=dht22`, `#OK START ctr=0 limit=16`, `#LEASE_WAIT …` |
| RTOS → Linux | block `.chau` (bắt đầu `A5 5A`, có CRC) | 1 lần đọc = 1 block 2 mẫu (RH, T) |

### Vì sao cần "lease" ctr?

Mật mã dòng **cấm dùng lại keystream**: cùng `K_master` và cùng `ctr` mà mã hóa hai dữ liệu khác nhau thì XOR hai bản mã sẽ làm lộ thông tin. RTOS không có bộ nhớ bền, nên sau khi khởi động lại nó không biết ctr nào đã dùng. Cách giải quyết:

1. Linux đọc `next_ctr` từ `/var/lib/chaos/ctr_state.json`, **ghi `limit = next_ctr + lease` xuống đĩa (fsync)**, rồi mới gửi `START next_ctr limit`.
2. RTOS chỉ được mã hóa với `ctr < limit`. Hết lease thì RTOS dừng mã hóa (đánh dấu GAP) và báo `#LEASE_WAIT`.
3. Linux thấy ctr gần chạm limit thì ghi limit mới xuống đĩa trước, rồi gửi `LEASE`.

Mất điện ở bất kỳ thời điểm nào thì lần sau vẫn bắt đầu từ một limit đã lưu, tức là **lớn hơn mọi ctr RTOS có thể đã dùng**. Test đầu-cuối kiểm tra đúng điều này (lần 2 bắt đầu sau lần 1).

### Đọc hỏng / mất mẫu

Đọc DHT22 hỏng (checksum sai, không phản hồi) thì **không mã hóa gì cả**: không tốn keystream, nên bên giải mã không lệch đồng bộ. Block kế tiếp mang cờ `GAP_BEFORE`. Đây đúng là cơ chế `in_fifo` bỏ mẫu trước khi mã hóa trong thiết kế INMP441.

## 4. Mỗi phần dạy điều gì

| Phần | Khái niệm OS | Sẽ dùng lại cho INMP441 |
|---|---|---|
| `dht_port_mpfs.c` | Thời gian thực: khóa ngắt trên **lõi riêng** U54_4 để đo xung 27 µs/70 µs mà không ảnh hưởng Linux | Bỏ: FPGA tự thu I2S |
| `main_rtos.c` | Task, hàng đợi, ưu tiên; một task duy nhất sở hữu dữ liệu (không cần mutex) | Giữ: thay `dht_task` bằng ISR rút `out_fifo` |
| `chaos_cipher.c` | Mã hóa phần mềm, đối chiếu golden | Thay bằng ghi/đọc thanh ghi lõi FPGA |
| `link_rpmsg.c` | AMP, bộ nhớ dùng chung, RPMsg/IHC | Giữ nguyên |
| `app_core.c` | Giao thức, lease ctr, đóng block | Giữ, đổi `APP_SOURCE` và cách đóng block (64 mẫu/block) |
| `chaosd.py` | Daemon, ghi file an toàn (fsync + rename), xoay file | Giữ, đổi `--source mic --channels 1 --fs-milli-hz 16000000 --rotate-s 60 --lease 4096` |
| `chaos-upload` | systemd timer, rclone, hàng đợi khi mất mạng | Giữ nguyên |

## 5. Lên board

Xem [HUONG_DAN_BOARD.md](HUONG_DAN_BOARD.md).

## 6. Việc cần thống nhất với thành viên mã hóa

- Header `.chau`: bài này dùng `source = 3` (DHT22) và `channels = 2`, chưa có trong mục 8.1 của tài liệu thiết kế. Đề xuất thêm vào mục 8.1 qua PR `docs/`.
- Giao thức lease ở mục 3 nên được ghi vào mục 10 của tài liệu thiết kế.
- `common/chaos_cipher.c` là bản port **phía OS** của refmodel. Nếu `SPEC_VERSION` đổi thì phải cập nhật file này và chạy lại `make test`.
