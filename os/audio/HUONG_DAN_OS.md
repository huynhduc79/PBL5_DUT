# Hướng dẫn phần OS – PBL5 ghi âm mã hóa chaos (bản cuối)

> Dựa trên tài liệu **"PBL5 – Tình trạng FPGA và giao tiếp FPGA ↔ RTOS"** (12/11/2026) của thành viên mã hóa.
> RTL đã xong, đạt timing 50 MHz, bản đồ thanh ghi đã chốt (`VERSION = 0x0002_0100`).
> Phía FPGA còn thiếu SmartDesign + gán chân, nên phía OS **viết driver và test trên PC trước**, khi có bitstream thì chỉ cần nối vào.

---

## 1. Bức tranh tổng thể: ai làm gì

```
 INMP441 ─I2S─► FPGA audio_crypt_top ──APB3 (FIC_3) + irq_o (MSS_INT_F2M[x])──┐
               (thu + mã hóa, đã xong)                                        │
 ┌────────────────────────── MSS (RISC-V) ───────────────────────────────────┴───┐
 │ E51      : HSS – khởi động AMP, chia bộ nhớ, PMP                    ← BẠN       │
 │ U54_4    : FreeRTOS – driver lõi, sNVM (khóa + ctr), đóng block .chau ← BẠN     │
 │              └── RPMsg (IHC + DDR dùng chung) ──┐                              │
 │ U54_1..3 : Linux – chaosd ghi file 60 s, rclone ─┴─► Ethernet ─► Google Drive ← BẠN│
 └──────────────────────────────────────────────────────────────────────────────┘
                                                Laptop: decode_chau.py + phân tích ← BẠN MÃ HÓA
```

Ranh giới tin cậy (đúng với tài liệu FPGA):

| Miền | Thấy bản rõ | Giữ K_master | Quyết định ctr | Nối mạng |
|---|---|---|---|---|
| FPGA | Có | Có (thanh ghi chỉ ghi) | Kiểm `CTR` tăng chặt | Không |
| FreeRTOS U54_4 | **Không** (chỉ đọc bản mã) | Có (đọc từ sNVM, nạp vào FPGA) | **Có** (sNVM, đặt trước 2^20) | Không |
| Linux U54_1..3 | Không | Không | **Không** | Có |

> **Thay đổi so với bài DHT22:** trước đây Linux cấp "lease" ctr. Tài liệu FPGA chốt **ctr do RTOS giữ trong sNVM, không lấy từ Linux**. Lý do: nếu Linux bị chiếm quyền, kẻ tấn công không thể ép RTOS dùng lại ctr. `chaosd` vẫn giữ chế độ cũ (`--ctr-owner linux`) cho bài DHT22, nhưng mặc định là `rtos`.

---

## 2. Cấu trúc thư mục `os/audio`

| Đường dẫn | Chạy ở | Nội dung | Trạng thái |
|---|---|---|---|
| `common/acore_regs.h` | RTOS + PC | Bản đồ thanh ghi mục 6 của tài liệu FPGA | Đã chép đúng hợp đồng |
| `common/acore_drv.[ch]` | RTOS + PC | Driver: probe, **tự kiểm REG**, start, drain, stop (trình tự mục 7) | Đã test trên mô hình |
| `common/ctr_store.[ch]` | RTOS + PC | ctr trong sNVM: 2 ô A/B, đặt trước 2^20, gia hạn, dừng an toàn | Đã test (cả mất điện) |
| `common/app_audio.[ch]` | RTOS + PC | Lệnh từ Linux (`START/STOP/STATUS`), gom 3 block/tin RPMsg | Đã test |
| `common/chau_block.[ch]` | RTOS + PC | Block `.chau` + CRC-16/CCITT-FALSE, thêm `drop_before` | Đã test |
| `common/chaos_cipher.[ch]` | PC | Bản C của refmodel, **chỉ dùng cho mô hình FPGA** trên PC | Khớp 7 bộ vector |
| `sim/fpga_model.[ch]` | PC | Mô hình thanh ghi của `audio_crypt_top` theo quy tắc mục 6–8 | – |
| `sim/sim_audio.c` | PC | "RTOS giả": chạy `common/` nguyên văn trên mô hình FPGA | – |
| `freertos/app/main_audio.c` | U54_4 | Task + hàng đợi + ngắt | Chỉ kiểm cú pháp |
| `freertos/app/acore_port_mpfs.[ch]` | U54_4 | MMIO FIC_3, PLIC, sNVM (System Services) | Chỉ kiểm cú pháp, nhiều **[KIỂM TRA]** |
| `freertos/app/link_rpmsg.[ch]` | U54_4 | RPMsg-Lite (giữ từ bài DHT22) | Chỉ kiểm cú pháp |
| `linux/chaosd/chaosd.py` | Linux | Nhận block, ghi file 60 s, `--ctr-owner rtos` | Đã test với sim |
| `linux/systemd/`, `linux/upload/` | Linux | Dịch vụ chaosd, timer rclone lên `gdrive:PBL5/audio` | Giữ từ bài DHT22 |
| `tools/verify_chau.py` | Laptop | Công cụ kiểm của phía OS (CRC, liên mạch, RAMP, WAV) | – |
| `tests/e2e_audio.py` | PC | Kiểm thử đầu-cuối | **Tất cả đạt** |

`common/` được biên dịch **nguyên văn** cho cả PC lẫn board. Thứ đã chạy đúng trên PC chính là thứ chạy trên U54_4, chỉ khác 3 lớp dưới cùng: thanh ghi, sNVM, RPMsg.

---

## 3. Chạy thử trên PC ngay bây giờ (không cần board)

Cần: MSYS2 MinGW64 (`C:\msys64\mingw64\bin\gcc`), Python ≥ 3.10, refmodel của thành viên mã hóa.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Test -RefModel D:\PBL5\chaos_refmodel_v1.0.0\chaos_project
```

Kết quả đã chạy được (12/11/2026):

```
10036 kiem tra, 0 sai -> TAT CA KHOP
1. RAMP, RTOS bi tre 150 ms moi 2 s (6 s am thanh)
   9 file, 1459 block, 93208 mau, ctr 0..1456, GAP 2 (bo 510), CRC sai 0, dut 0, RAMP sai 0
2. Mat dien giua luc ghi
   ... ctr 2097152..2097640 ...   DAT  ctr sau khi mat dien lon hon moi ctr da dung
3. Nguon MIC (gia), co STARTUP_SKIP          DAT  da bo 4096 mau khoi dong
4. Bi mat                                    DAT  K_master khong co trong file outbox
TAT CA DAT
```

Muốn quan sát bằng tay:

```powershell
python linux\chaosd\chaosd.py -v --data-dir build\demo --source ramp --rotate-s 5 --sim-cmd "build\sim_audio.exe --key build\e2e\test.key --nvm build\demo_nvm.bin --run-s 20 --speed 5"
python tools\verify_chau.py "build\demo\outbox\*.chau" --key build\e2e\test.key --refmodel D:\PBL5\chaos_refmodel_v1.0.0\chaos_project
```

---

## 4. Thiết kế RTOS (U54_4)

### 4.1 Một task sở hữu tất cả

```
ISR irq_o ─ EV_IRQ ─┐                         ┌─ acore_drain(): đọc FIFO_LEVEL → OUT_DATA × n
link_rx ─ EV_COMMAND ┼─► queue ─► app_task ───┼─ ctr_store_check(): gia hạn sNVM trước khi hết
hết 20 ms ───────────┘         (ưu tiên cao)  └─ gom ≤ 3 block (420 B) → link_send() → Linux
```

- Chỉ `app_task` chạm vào thanh ghi FPGA và trạng thái ứng dụng, nên **không cần mutex**.
- `irq_o` là **ngắt mức** (cao khi `out_fifo ≥ IRQ_THRESH`). ISR trả `EXT_IRQ_DISABLE` để tắt nguồn ngắt, task rút FIFO, xóa `IRQ_STATUS`, rồi mới bật lại. Nếu bật lại ngay trong ISR thì sẽ bị **bão ngắt**.
- Task tự phục vụ mỗi 20 ms dù không có ngắt. Lần đầu lên board có thể **chạy hoàn toàn bằng polling** (chưa nối `irq_o`) mà vẫn đúng: `out_fifo` chứa 131 ms âm thanh.

### 4.2 Trình tự driver (khớp mục 7 tài liệu FPGA)

| Bước | Hàm | Việc làm |
|---|---|---|
| Khởi động | `acore_probe` | `CTRL = 0x8000_0000`, `VERSION` phải bằng `0x0002_0100` |
| | `acore_selftest` | Chế độ REG, khóa vector công khai, ctr 0, so 8 mẫu với `enc_n16_default`, rồi `SOFT_RESET` |
| Mỗi lần ghi | `ctr_store_begin` | Ghi `next = start + 2^20` vào sNVM **trước**, rồi mới dùng `start` |
| | `acore_start` | `KMASTER[0..7]` (big-endian, `KMASTER[0] = K[255:224]`) → `CTR` → kiểm `CTR_REJECTED` → `CTRL = 0x104` → chờ `KEY_READY`, kiểm `CMD_IGN` → cấu hình → `CTRL = 0x101` |
| Vòng ngắt | `acore_drain` | Đọc đúng `FIFO_LEVEL[15:0]` lần `OUT_DATA`, bỏ `VALID = 0`. Khôi phục ctr 32 bit từ `ctr[7:0]`. Gặp `GAP` thì đóng block, đọc `DROP_CNT`, hiệu số là `drop_before` |
| | `acore_irq_ack` | Ghi 1 vào `IRQ_STATUS` **sau khi** đã rút |
| Dừng | `acore_stop` | `CTRL = 0x100` → vừa rút vừa chờ `in_fifo = 0` và `BUSY = 0` → rút hết → `CTRL = 0x110` (KEY_CLEAR) |

> Lúc dừng phải **vừa chờ vừa rút** `out_fifo`. Nếu `out_fifo` đầy, lõi ngừng mã hóa nên `in_fifo` không bao giờ rỗng, và nếu chỉ chờ thì sẽ kẹt tới hết thời gian chờ.

### 4.3 ctr và sNVM: vì sao an toàn khi mất điện

- sNVM lưu `next`: mọi ctr nhỏ hơn `next` **có thể đã dùng**.
- `START`: lấy `start = next`, ghi `next = start + 2^20` (fsync), rồi mới nạp `CTR = start`.
- Đang ghi: còn < 2^16 phiên (khoảng 4,5 phút) thì gia hạn `next = ctr + 2^20`. Còn < 2^10 phiên mà sNVM vẫn lỗi thì **tự dừng ghi** (`#OK STOP why=ctr_limit`).
- Mất điện bất kỳ lúc nào: lần sau bắt đầu từ `next` đã lưu, luôn lớn hơn mọi ctr đã dùng. Test 2 kiểm đúng điều này: bị kill ở ctr 1 048 602, lần sau bắt đầu từ 2 097 152.
- Ghi xen kẽ 2 ô có `seq` + CRC, nên mất điện giữa lúc ghi thì ô kia vẫn hợp lệ.
- Chi phí: 1 lần ghi sNVM mỗi lần bấm ghi âm + mỗi khoảng 71,6 phút. Một khóa đủ cho ít nhất 4 096 lần bấm ghi.
- Khóa khác (`key_id` khác) thì `ctr_store_open` **báo lỗi, không tự reset về 0**. Đổi khóa phải xóa trang ctr bằng tay, có chủ đích.

### 4.4 Giao thức RTOS ↔ Linux

| Hướng | Bản ghi | Ví dụ |
|---|---|---|
| Linux → RTOS | dòng lệnh | `START mic 2`, `START ramp`, `STOP`, `STATUS` |
| RTOS → Linux | dòng `#…\n` | `#SELFTEST ok mismatches=0`, `#HELLO … version=0x00020100 next_ctr=…`, `#OK START ctr=… limit=…`, `#STAT … drop=… clip=… cycles_max=…` |
| RTOS → Linux | block `.chau` | `A5 5A` + ctr + idx0 + count + flags + **drop_before** + C[] + CRC. Tối đa 3 block/tin RPMsg (420 B ≤ 496 B) |

---

## 5. Lên board: làm theo thứ tự, mỗi bước có cách kiểm

| # | Việc | Cần gì | Đạt khi |
|---|---|---|---|
| **B0** | Lấy từ bạn mã hóa: bitstream (`.job`), file cấu hình MSS (XML), **địa chỉ gốc FIC_3**, **số ngắt F2M** | Họ làm SmartDesign | Điền vào `freertos/app/board_config.h` (`ACORE_BASE`, `ACORE_PLIC_IRQ`) |
| **B1** | Linux đơn (chưa AMP) + Ethernet, **J45 mặc định 1–2 (3,3 V)** | Yocto/Buildroot BSP Discovery Kit | `ping` ra Internet được. Nếu Ethernet cần J45 = 2,5 V thì báo bạn mã hóa ngay (ảnh hưởng chân I2S Bank 1) |
| **B2** | Ví dụ AMP của Microchip (Linux U54_1..3 + FreeRTOS U54_4 + RPMsg) **chạy nguyên bản** | HSS payload generator, device tree AMP | Linux thấy `/dev/ttyRPMSG0`, echo qua lại được |
| **B3** | Ghép `common/` + `freertos/app/` vào app FreeRTOS của ví dụ. Gọi `pbl5_app_start()` trước `vTaskStartScheduler()` | Sửa các chỗ **[KIỂM TRA]** | `cat /dev/ttyRPMSG0` thấy `#SELFTEST ok` và `VERSION` đúng. **Đây là mốc M1** |
| **B4** | Chạy polling trước (chưa bật PLIC), `START ramp` | – | `verify_chau.py` báo `RAMP sai 0`. **Mốc M2 phía OS** |
| **B5** | Bật ngắt `irq_o` → PLIC U54_4 | Số ngắt F2M | `#STAT` thấy `drop=0`, CPU U54_4 rảnh |
| **B6** | Device tree Linux: **không** khai vùng FIC_3 của lõi, **không** nhận ngắt F2M đó, **tắt driver System Controller** phía Linux | – | Linux không đọc được sNVM / thanh ghi lõi |
| **B7** | Ghi khóa thật vào trang sNVM `SNVM_PAGE_KEY` (một lần, bằng chương trình riêng hoặc SmartDebug) | – | `START mic` chạy, `verify_chau.py` giải mã ra WAV nghe được |
| **B8** | `chaosd.service` + `chaos-upload.timer`, `rclone authorize "drive"` trên laptop rồi dán token vào `/etc/chaos/rclone.conf` | – | File xuất hiện trên Drive mỗi 5 phút. **Mốc M4**: chạy 1 giờ, `drop=0` |

---

## 6. Những điểm cần chốt lại với bạn mã hóa

1. **`drop_before` (byte thứ 9 của block, trước là `reserved`)**: mình mã hóa thành `uint8` **bão hòa ở 255**. Trong test, RTOS trễ 150 ms làm mất khoảng 255 mẫu, đã chạm trần. Hỏi lại: `docs/HOP_DONG_FPGA_RTOS.md` của bạn định nghĩa trường này thế nào? (repo bên mình chưa có file đó, nhờ bạn đẩy lên `docs/`.)
2. **Header `.chau`**: `fs_milli_hz = 15 625 000` (SCK_DIV 24), `source` 0 = MIC, 1 = RAMP, 2 = SINE. Mã 3 (DHT22) chỉ dùng cho bài cũ.
3. **Địa chỉ FIC_3 và số ngắt F2M**: phía OS **không có yêu cầu riêng**, bạn chọn gì thì báo lại. Gợi ý dùng `MSS_INT_F2M[0]` cho dễ.
4. **Chế độ REG để tự kiểm lúc khởi động**: mình dùng khóa vector công khai + ctr 0 ngay sau `SOFT_RESET`, rồi `SOFT_RESET` lại trước lần ghi thật. Cần bạn xác nhận `SOFT_RESET` đặt lại quy tắc "lần ghi CTR đầu luôn được nhận" (tài liệu mục 8.1 nói vậy).
5. **ctr do RTOS giữ (sNVM)**: phía OS đã chuyển theo tài liệu của bạn. Cập nhật mục 10 của `docs/thiet_ke_he_thong_inmp441.md` qua PR.

---

## 7. Rủi ro đã biết

| Rủi ro | Ảnh hưởng | Cách xử lý |
|---|---|---|
| Linux và RTOS cùng dùng System Controller (mailbox) | Tranh nhau khi RTOS ghi sNVM, Linux có thể đọc trang khóa | Tắt driver `mpfs-sys-controller` (và driver con) trong device tree Linux (B6) |
| sNVM ghi chậm (cỡ ms) và có giới hạn số lần ghi | Ghi trong lúc thu âm có thể làm trễ drain | Chỉ ghi lúc START và mỗi khoảng 71 phút. `out_fifo` đệm 131 ms. Kiểm số lần ghi tối đa trong datasheet |
| J45: Bank 1 cần 3,3 V cho I2S, User Guide ghi 2,5 V cho Ethernet | Có thể không chạy được cả micro lẫn Ethernet | Kiểm ở B1 trước khi gán chân |
| Tên hàm HAL (PLIC, sNVM) khác giữa các phiên bản SDK | Lỗi biên dịch trên SoftConsole | Chỉ sửa trong `acore_port_mpfs.c` (các chỗ **[KIỂM TRA]**) |
| Trang khóa sNVM ở chế độ không xác thực | Ai có quyền System Controller đều đọc được | Bản demo chấp nhận. Nâng cấp: sNVM xác thực/mã hóa bằng USK |
| Hai GAP sát nhau | `drop_before` chia sai giữa hai block (tổng vẫn đúng) | Giới hạn đã được tài liệu FPGA chấp nhận (mục 8.4) |

---

## 8. Báo cáo phần OS nên trình bày gì

- **AMP trên PolarFire SoC:** vì sao tách RTOS/Linux (cô lập lỗi, bề mặt tấn công, thời gian thực), cách HSS chia hart, bộ nhớ, PMP.
- **Thời gian thực:** ngân sách 15 625 mẫu/s. FPGA đệm 131 ms, RTOS phục vụ khoảng 61 lần/s (ngưỡng 256). Đo `#STAT drop`, `cycles_max` (khoảng 331) trên board.
- **An toàn khóa và nonce:** chứng minh bất biến "không lặp (K_master, ctr)" qua mất điện (mục 4.3), kèm số liệu test 2.
- **Kiểm chứng:** mô hình FPGA trên PC + test đầu-cuối (RAMP từng bit, GAP, mất điện, bí mật), rồi cùng bài test đó trên board.
