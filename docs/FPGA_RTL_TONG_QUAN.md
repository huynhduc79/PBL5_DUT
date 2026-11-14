# PBL5 – Phần FPGA (RTL) cho phía OS: tổng quan, giao tiếp, trạng thái

> Cập nhật: 14/11/2026 · Người viết: thành viên mã hóa (FPGA) · Dành cho: thành viên OS (HSS / FreeRTOS / Linux)
> Bản chốt hợp đồng chi tiết: `docs/HOP_DONG_FPGA_RTOS.md` (v1.0). File này tóm tắt lại **mọi thứ phía OS cần** để viết driver, device tree và đóng gói `.chau`; chỗ nào khác nhau thì theo hợp đồng.

**Tóm tắt.** Khối `audio_crypt_top` (thu I2S từ INMP441 → mã hóa chaos N = 16 → FIFO → APB3) đã viết xong, khớp golden model từng bit trong mô phỏng, đã gắn vào Discovery Kit Reference Design v2026.04, qua P&R đạt timing, **đã nạp và chạy trên board thật: 43/43 bài test PASS**, SCK đo được 1,000 MHz / 3,34 V. Phía OS có thể viết driver ngay theo mục 5–8; các số địa chỉ, ngắt, chân đã chốt.

---

## 1. Trạng thái

| Hạng mục | Trạng thái | Bằng chứng |
|---|---|---|
| Lõi mã hóa chaos (12 module) | Xong | Khớp golden `refmodel/` từng bit (vector `enc_n16_default`) |
| Lớp vỏ âm thanh: `i2s_rx`, `sample_fmt`, `test_src`, `sync_fifo`, `stream_seq` | Xong | Icarus 28/28, Verilator 14/14, ModelSim đợt 5–7 PASS, mutation 95/95 |
| `apb3_slave_regs`, `audio_crypt_top` | Xong | Testbench toàn hệ lái **chỉ qua APB3** như RTOS |
| Gắn vào Discovery Kit Reference Design v2026.04 | Xong | Synthesize + P&R + Verify Timing đạt mọi corner |
| Bitstream + HSS v2026.04.1 trong eNVM | Xong | Nạp PASS, HSS boot đúng (`DESIGNID: MPFS_DISCOVERY_KIT`) |
| **Test trên board thật (bare-metal, U54_1)** | **43/43 PASS** | Mục 10 |
| SCK / WS trên chân thật | SCK đo được 1,000 MHz, 3,34 V | Oscilloscope Keysight |
| Micro INMP441 thật | Chưa cắm | Đường giải mã on-board đã chứng minh round-trip 8192 mẫu |
| Driver FreeRTOS / RPMsg / Linux | **Phía OS** | Mục 7–9 |

Ứng với mốc trong `CLAUDE.md`: **M1 xong** (thanh ghi + lõi N = 16 khớp vector), **M2 phần FPGA xong** (RAMP/SINE + FIFO + ngắt chạy trên board; còn phía OS giải mã RAMP qua đường RPMsg/`.chau`).

---

## 2. Kiến trúc và luồng dữ liệu

```
                         FPGA fabric (một miền xung 50 MHz = FIC_3_CLK)
 INMP441                ┌──────────────────────────────────────────────────────────────────────┐
 SCK  ◄── chân 12 (E10) │ i2s_rx ──s24──► sample_fmt ──s16──┐                                   │
 WS   ◄── chân 35 (B19) │ (I2S master,                      ├─► stream_seq ─► in_fifo 64×17     │
 SD   ──► chân 38 (B14) │  Philips)          test_src ──────┘   (GAP, drop)        │            │
                        │                    RAMP / SINE                           ▼            │
                        │                                         chaos_core (ENC, N = 16)      │
                        │                                                          │            │
                        │                                    out_fifo 2048×32 (LSRAM, ≈131 ms) │
                        │                                                          │            │
                        │  apb3_slave_regs  ◄──── KMASTER, CTR, CTRL, cấu hình ────┘            │
                        └───────▲───────────────────────────────────────┬───────────────────────┘
                                │ APB3 @ 0x4000_0500 (FIC_3)            │ irq_o → MSS_INT_F2M[16]
                        ┌───────┴───────────────────────────────────────▼───────────────────────┐
                        │ MSS: FreeRTOS (U54_4) đọc OUT_DATA, đóng block .chau, CRC, RPMsg      │
                        │      Linux (U54_1..3) ghi file .chau → Google Drive                   │
                        └───────────────────────────────────────────────────────────────────────┘
```

- **fs = 15 625 Hz** (SCK 1 MHz, 64 SCK/khung). Mỗi mẫu → 1 từ 32 bit trong out_fifo.
- Lõi mất 51–68 chu kỳ/mẫu, tối đa 344 khi đổi phiên (ngân sách 3 200 chu kỳ → dùng ≈ 11 %).
- Mọi mất mẫu (nếu có) xảy ra **trước** mã hóa, ở in_fifo → keystream không bao giờ bị lệch.

---

## 3. Các khối RTL

| Module | Chức năng | Ghi chú cho phía OS |
|---|---|---|
| `audio_crypt_top` | Top của khối: APB3 + I2S + lõi + 2 FIFO | Tham số `RESEED_INTERVAL = 64`, `OUT_AW = 11` (2048 từ) |
| `apb3_slave_regs` | Thanh ghi, lệnh, ngắt, bộ đếm | Bản đồ ở mục 5 |
| `i2s_rx` | I2S master Philips; sinh SCK/WS bằng chia tần, SD đồng bộ 2 tầng | `SCK_DIV` kẹp ≥ 3; cấu hình chốt khi ENABLE lật 0→1; bỏ `STARTUP_SKIP` mẫu đầu |
| `sample_fmt` | 24 → 16 bit: `s16 = bão_hòa(s24 >>> (8 − SHIFT))`, đếm `CLIP_CNT` | SHIFT 0..8 (9..15 kẹp về 8) |
| `test_src` | Nguồn thử: RAMP 0,1,2… và SINE 1 kHz (biên độ 0x4000) | Đi thẳng vào lõi, **không** qua SHIFT, **không** STARTUP_SKIP |
| `sync_fifo` | FIFO đồng bộ: in_fifo 64×17 ({gap, s16}), out_fifo 2048×32 | |
| `stream_seq` | Điều phối nguồn → in_fifo → lõi → out_fifo; đánh dấu GAP | out_fifo đầy → ngừng mã hóa, bỏ mẫu ở in_fifo |
| `chaos_core` | Lõi mật mã dòng hỗn loạn (ghép 6 khối dưới) | ENC / DEC / SKIP, N = 8 hoặc 16 |
| `hmac_kdf`, `sha256_core`, `kdf_params` | Sinh tham số phiên từ `K_master` và `ctr` (HMAC-SHA256) | Mỗi phiên = 64 mẫu |
| `session_mgr` | Quản lý `ctr`, `idx`, tái tạo phiên | `ctr` tăng 1 sau mỗi 64 mẫu, quay vòng 2³² |
| `lts_step`, `lts_iter` | Ánh xạ hỗn loạn LTS, sinh keystream | Khối DSP (12 Math block) |
| `fy_shuffle`, `permute_xor` | Hoán vị bit Fisher–Yates theo chaos + XOR | |
| `core_fsm` | FSM xử lý một mẫu | Mã trạng thái đọc qua `DBG[27:24]` |

Không dùng trong bản SoC: `chaos_cipher_top.v`, `axi4l_slave_regs.v` (bản AXI4-Lite cũ).

### Thuật toán (đủ để hiểu, chi tiết ở `refmodel/`)

```
Phiên (mỗi 64 mẫu):  tham số LTS (X0, r) = HMAC-SHA256(K_master, ctr)
Mỗi mẫu P (16 bit):  x ← LTS(x);  k ← x & 0xFFFF;  π ← FisherYates(x)
  ENC:  C = gather(P, π) XOR k
  DEC:  P = scatter(C XOR k, π)
Sau 64 mẫu: ctr ← ctr + 1, idx ← 0, tạo phiên mới.
```

Giải mã phía PC/Linux: `tools/decode_chau.py` dùng `refmodel.cipher.CipherCore` — cùng thuật toán, đã chứng minh khớp bit với phần cứng.

---

## 4. Tích hợp SoC (Discovery Kit) — đã chốt

| Mục | Giá trị |
|---|---|
| Board / chip | PolarFire SoC Discovery Kit, MPFS095T-1FCSG325E |
| Thiết kế nền | Discovery Kit Reference Design **v2026.04** (Microchip), vá bằng script (mọi chỗ sửa có `# PBL5:`) |
| HSS | **v2026.04.1** (`hss-envm-wrapper.mpfs-disco-kit.hex`), đã nạp vào eNVM |
| Linux đề nghị | Yocto / linux4microchip **2026.04** (cùng đợt) |
| Bus | FIC_3, APB3, ô 5 của CoreAPB3 `FIC_3_0x4000_0xxx` |
| **Địa chỉ gốc / kích thước** | **`0x4000_0500`** / `0x100` (đến `0x4000_05FF`) |
| **Ngắt** | `irq_o` → **`MSS_INT_F2M[16]`**, mức cao, giữ đến khi xóa W1C |
| Số ngắt PLIC tương ứng | **134** theo MPFS HAL (`PLIC_F2M_16_INT_OFFSET = 121 + 13`). Trên U54 còn có ngắt local `U54_F2M_16_INT_OFFSET = 32`. *Linux DT: kiểm lại bằng `cat /proc/interrupts` khi lên board.* |
| Xung / reset của khối | `FIC_3_CLK` = 50 MHz (OUT3 của CCC) / `RESETN_FIC_3_CLK` |
| Instance | `FIC_3_PERIPHERALS_0.AUDIO_CRYPT_0` |
| `MSS_INT_F2M[0]` | **Không dùng** — Reference Design đã nối `GPIO_2_28_OUT` vào đó |

### Chân I2S (header Raspberry Pi trên board, Bank 1, LVCMOS33)

| Tín hiệu | Chân FPGA | Header RPi | Hướng | INMP441 |
|---|---|---|---|---|
| `I2S_SCK` | E10 | chân 12 (GPIO18) | ra | SCK |
| `I2S_WS` | B19 | chân 35 (GPIO19) | ra | WS |
| `I2S_SD` | B14 | chân 38 (GPIO20) | vào, có kéo xuống | SD |
| 3,3 V / GND | — | chân 1 / chân 6 | — | VDD / GND; **L/R nối GND** |

**Hệ quả cho device tree:** GPIO2 của MSS chân **2, 12, 15** (trước là GPIO18/19/20 header) **không còn ra chân**. Không khai báo chúng làm GPIO. Các GPIO2 khác giữ như Reference Design.

---

## 5. Bản đồ thanh ghi (offset từ `0x4000_0500`, mọi truy cập 32 bit)

Chỉ giải mã `paddr[7:2]`. Địa chỉ không ánh xạ: đọc 0, ghi bỏ qua. `PSLVERR` luôn 0. W1C = ghi 1 để xóa.

| Off | Tên | Truy cập | Nội dung |
|---|---|---|---|
| 0x00 | CTRL | R/W | Xem bảng CTRL |
| 0x04 | STATUS | R / W1C | Xem bảng STATUS |
| 0x08–0x24 | KMASTER[0..7] | W (đọc 0) | Khóa 256 bit, `KMASTER[0] = K[255:224]` (big-endian, từ cao trước) |
| 0x28 | CTR | R/W | Ghi: `ctr` bắt đầu (quy tắc mục 6). Đọc: KEY_READY ? ctr phiên hiện tại : ctr đã ghi |
| 0x2C | DATA_IN | W | Chế độ REG: `[15:0]` mẫu vào, tự START |
| 0x30 | DATA_OUT | R | `[15:0]` kết quả mẫu gần nhất (REG) |
| 0x34 | I2S_CFG | R/W | `[11:0]` SCK_DIV (24) · `[12]` CHANNEL (0 = trái) · `[19:16]` SHIFT (0) |
| 0x38 | SRC_SEL | R/W | `[1:0]` 0 MIC · 1 RAMP · 2 SINE · 3 REG |
| 0x3C | FIFO_LEVEL | R | `[15:0]` mức out_fifo · `[31:16]` mức in_fifo |
| 0x40 | OUT_DATA | R | Lấy 1 từ khỏi out_fifo (mục 7). Đúng 1 chu kỳ chờ. Rỗng → VALID = 0 |
| 0x44 | IRQ_THRESH | R/W | Mặc định 256 |
| 0x48 | IRQ_EN | R/W | `[0]` THRESH · `[1]` IN_OVF · `[2]` ERROR |
| 0x4C | IRQ_STATUS | R / W1C | Cùng bit. THRESH tự bật lại mỗi chu kỳ khi mức out ≥ ngưỡng |
| 0x50 | DROP_CNT | R / ghi = xóa | Số mẫu bị bỏ (không tính STARTUP_SKIP) |
| 0x54 | SAMPLE_CNT | R | Số từ đã đẩy vào out_fifo |
| 0x58 | CYCLES_MAX | R / ghi = xóa | Chu kỳ lớn nhất cho 1 mẫu (đo trên board: 344) |
| 0x5C | STARTUP_SKIP | R/W | Mặc định 4096 mẫu (262 ms chờ micro ổn định) |
| 0x60 | VERSION | R | **`0x0002_0100`** — driver nên kiểm khi khởi động |
| 0x64 | CLIP_CNT | R / ghi = xóa | Số mẫu bị bão hòa (bão hòa ở 2³²−1) |
| 0x68 | DBG | R | `[7:0]` steps · `[15:8]` refills · `[23:16]` rejects · `[27:24]` trạng thái FSM lõi |

### CTRL (0x00)

| Bit | Tên | Kiểu | Ý nghĩa |
|---|---|---|---|
| 0 | ENABLE | mức | 1 = thu mẫu từ nguồn SRC_SEL (MIC/RAMP/SINE) và mã hóa liên tục |
| 1 | START | xung | Chế độ REG: chạy 1 mẫu với OP của chính lần ghi này (dùng cho OP = SKIP) |
| 2 | RESEED_NOW | xung | Nạp khóa phiên từ KMASTER + CTR → KEY_READY |
| 3 | FIFO_CLR | xung | Xóa hai FIFO |
| 4 | KEY_CLEAR | xung | Xóa KMASTER, hủy khóa phiên (kể cả mẫu đang mã) |
| 5 | BYPASS | — | Không tổng hợp, đọc 0 |
| 7:6 | OP | mức | Chế độ REG: 0 ENC · 1 DEC · 2/3 SKIP. Chế độ luồng luôn ENC |
| 8 | N_SEL | mức | 1 = N 16 (mặc định). Luồng luôn N = 16 |
| 31 | SOFT_RESET | xung | Reset toàn khối, kể cả bộ so sánh CTR |

Bit xung đọc về 0. **CTRL là thanh ghi đủ 32 bit**: mỗi lần ghi lệnh phải kèm bit mức muốn giữ, ví dụ RESEED = `0x0000_0104`, bật ghi = `0x0000_0101`, tắt = `0x0000_0100`, KEY_CLEAR = `0x0000_0110`, SOFT_RESET = `0x8000_0000`.

### STATUS (0x04)

| Bit | Tên | W1C | Ý nghĩa |
|---|---|---|---|
| 0 | BUSY | | Lõi đang xử lý một mẫu |
| 1 | KEY_READY | | Khóa phiên đã nạp |
| 2 | ERROR | ✓ | Lõi báo lỗi (watchdog) |
| 3 | IN_OVF | ✓ | Đã bỏ mẫu ở in_fifo |
| 4 | OUT_FULL | | out_fifo đầy |
| 5 | OUT_GE_THRESH | | Mức out ≥ IRQ_THRESH |
| 6 | I2S_RUNNING | | Bộ thu I2S đang chạy |
| 7 | CTR_REJECTED | ✓ | Lần ghi CTR vừa rồi bị từ chối |
| 8 | CMD_IGN | ✓ | Lệnh bị bỏ (sai điều kiện) |

### Header C gợi ý cho driver

```c
#define ACORE_BASE        0x40000500UL
#define ACORE_PLIC_IRQ    134u            /* MSS_INT_F2M[16], theo MPFS HAL - kiểm lại trên board */

#define AC_CTRL           0x00u
#define AC_STATUS         0x04u
#define AC_KMASTER(i)     (0x08u + 4u * (i))   /* i = 0..7, KMASTER[0] = K[255:224] */
#define AC_CTR            0x28u
#define AC_DATA_IN        0x2Cu
#define AC_DATA_OUT       0x30u
#define AC_I2S_CFG        0x34u
#define AC_SRC_SEL        0x38u
#define AC_FIFO_LEVEL     0x3Cu
#define AC_OUT_DATA       0x40u
#define AC_IRQ_THRESH     0x44u
#define AC_IRQ_EN         0x48u
#define AC_IRQ_STATUS     0x4Cu
#define AC_DROP_CNT       0x50u
#define AC_SAMPLE_CNT     0x54u
#define AC_CYCLES_MAX     0x58u
#define AC_STARTUP_SKIP   0x5Cu
#define AC_VERSION        0x60u
#define AC_CLIP_CNT       0x64u
#define AC_DBG            0x68u

#define AC_VERSION_V1     0x00020100u

#define CTRL_ENABLE       (1u << 0)
#define CTRL_START        (1u << 1)
#define CTRL_RESEED_NOW   (1u << 2)
#define CTRL_FIFO_CLR     (1u << 3)
#define CTRL_KEY_CLEAR    (1u << 4)
#define CTRL_OP(x)        (((x) & 3u) << 6)   /* 0 ENC, 1 DEC, 2 SKIP */
#define CTRL_N_SEL        (1u << 8)
#define CTRL_SOFT_RESET   (1u << 31)

#define ST_BUSY           (1u << 0)
#define ST_KEY_READY      (1u << 1)
#define ST_ERROR          (1u << 2)
#define ST_IN_OVF         (1u << 3)
#define ST_OUT_FULL       (1u << 4)
#define ST_OUT_GE_THRESH  (1u << 5)
#define ST_I2S_RUNNING    (1u << 6)
#define ST_CTR_REJECTED   (1u << 7)
#define ST_CMD_IGN        (1u << 8)

#define IRQ_THRESH_BIT    (1u << 0)
#define IRQ_IN_OVF_BIT    (1u << 1)
#define IRQ_ERROR_BIT     (1u << 2)

#define I2S_CFG(sck_div, ch, shift)  (((sck_div) & 0xFFFu) | (((ch) & 1u) << 12) | (((shift) & 0xFu) << 16))
#define SRC_MIC 0u
#define SRC_RAMP 1u
#define SRC_SINE 2u
#define SRC_REG 3u

/* từ OUT_DATA */
#define OD_CTR8(w)   (((w) >> 24) & 0xFFu)
#define OD_GAP(w)    (((w) >> 23) & 1u)
#define OD_VALID(w)  (((w) >> 22) & 1u)
#define OD_IDX(w)    (((w) >> 16) & 0x3Fu)
#define OD_C(w)      ((w) & 0xFFFFu)
```

---

## 6. Quy tắc phải biết (đã cài cứng trong RTL)

| # | Quy tắc | Ảnh hưởng tới driver |
|---|---|---|
| 1 | Lần ghi `CTR` đầu tiên sau reset / SOFT_RESET luôn được nhận; các lần sau phải **lớn hơn mọi ctr đã ghi và mọi ctr lõi đã/đang dùng** (kể cả sau KEY_CLEAR) | Ghi ≤ → bỏ qua + `CTR_REJECTED`. Luôn kiểm sau khi ghi |
| 2 | `RESEED_NOW` chỉ nhận khi lõi rảnh và đã có một lần ghi CTR được nhận kể từ lần nạp trước | Không nạp lại cùng ctr hai lần; vi phạm → `CMD_IGN` |
| 3 | out_fifo đầy → ngừng mã hóa; mẫu chỉ bị bỏ ở in_fifo (trước mã hóa) | Keystream / idx luôn liền mạch; GAP = chỉ mất thời gian âm thanh |
| 4 | Luồng (ENABLE) luôn ENC, N = 16; mẫu bỏ trong STARTUP_SKIP không tính DROP_CNT / GAP | Không cần chỉnh OP khi ghi âm |
| 5 | I2S_CFG, SRC_SEL chốt lúc ENABLE lật 0→1 | Đổi khi đang chạy không có tác dụng |
| 6 | RAMP / SINE không qua SHIFT, không STARTUP_SKIP | Giải mã RAMP phải ra 0, 1, 2, … — dùng để test driver |
| 7 | REG (`SRC_SEL = 3`) không đẩy vào out_fifo; DATA_IN/START chỉ nhận khi ENABLE = 0, KEY_READY, lõi rảnh | Kết quả ở DATA_OUT; sai điều kiện → CMD_IGN |
| 8 | **Tắt ENABLE vẫn mã nốt mọi mẫu đã ở in_fifo** | Dừng: chờ in_fifo = 0 và BUSY = 0 rồi mới rút out_fifo |
| 9 | Nhiều lệnh trong một lần ghi CTRL: KEY_CLEAR > RESEED_NOW > START | Mỗi lần ghi chỉ một lệnh |
| 10 | Hai GAP sát nhau: tổng mẫu mất đúng nhưng có thể chia sai giữa hai block | Giới hạn đã biết của `drop_before`, chấp nhận |
| 11 | Đọc OUT_DATA có 1 chu kỳ chờ; FIFO rỗng trả VALID = 0 | Bỏ từ VALID = 0 |

### Chính sách `ctr` (chống dùng lại keystream)

- `ctr` lấy từ **khối đặt trước 2²⁰ trong sNVM** do FreeRTOS quản lý, **không** lấy từ Linux.
- Mỗi lần ghi âm: `CTR` ≥ ctr cuối đã dùng + 1. Ghi `next_ctr + 2²⁰` vào sNVM **trước** khi dùng khối mới.
- `K_master` 256 bit lưu ở sNVM; **không commit** khóa, `key.hex` vào repo.

---

## 7. Đầu ra: từ 32 bit `OUT_DATA`

| Bit | Trường | Ý nghĩa |
|---|---|---|
| 31:24 | `ctr[7:0]` | 8 bit thấp của ctr phiên đã mã mẫu này |
| 23 | GAP | 1 = có mẫu bị bỏ ngay trước mẫu này (chỉ mất thời gian; **không** `advance()` keystream) |
| 22 | VALID | 1 = từ thật; 0 = FIFO rỗng lúc đọc → bỏ |
| 21:16 | `idx` | Vị trí mẫu trong phiên, 0..63 |
| 15:0 | C | Bản mã 16 bit |

**ctr đầy đủ 32 bit:** RTOS giữ từ giá trị đã ghi vào `CTR`, tăng 1 mỗi khi `ctr[7:0]` đổi (mỗi 64 mẫu, idx quay về 0); quay vòng qua 2³² vẫn đúng. Đọc `CTR` khi KEY_READY trả ctr phiên hiện tại để đối chiếu.

Ví dụ thật đo trên board (khóa thử `00 01 … 1F`, ctr `0x1000`, RAMP): từ đầu `0x0040B44A` = ctr8 `0x00`, GAP 0, VALID 1, idx 0, C `0xB44A`.

---

## 8. Trình tự driver (FreeRTOS)

### Khởi tạo

```c
w(AC_CTRL, CTRL_SOFT_RESET);
if (r(AC_VERSION) != AC_VERSION_V1) fail("sai bitstream");
for (i = 0; i < 8; i++) w(AC_KMASTER(i), kmaster_word[i]);   /* từ sNVM, big-endian */
w(AC_CTR, ctr_start);                                         /* từ khối đặt trước trong sNVM */
if (r(AC_STATUS) & ST_CTR_REJECTED) fail("ctr cu - KHONG ghi am");
w(AC_CTRL, CTRL_N_SEL | CTRL_RESEED_NOW);                     /* 0x104 */
wait_until(r(AC_STATUS) & ST_KEY_READY);                      /* vài trăm chu kỳ; CMD_IGN = bị bỏ */
w(AC_I2S_CFG, I2S_CFG(24, 0, shift));                          /* SCK 1 MHz, kênh trái */
w(AC_SRC_SEL, SRC_MIC);                                        /* SRC_RAMP khi test */
w(AC_STARTUP_SKIP, 4096);
w(AC_IRQ_THRESH, 256);                                         /* ≈ 16 ms, ≈ 61 ngắt/s */
w(AC_IRQ_EN, IRQ_THRESH_BIT | IRQ_IN_OVF_BIT | IRQ_ERROR_BIT);
/* PLIC: bật nguồn 134 (MSS_INT_F2M[16]) cho hart U54_4 */
w(AC_CTRL, CTRL_N_SEL | CTRL_ENABLE);                          /* 0x101 */
```

### Ngắt

```c
uint32_t n = r(AC_FIFO_LEVEL) & 0xFFFF;
while (n--) {
    uint32_t wd = r(AC_OUT_DATA);
    if (!OD_VALID(wd)) continue;
    if (OD_GAP(wd)) {                    /* đóng block đang mở, mở block mới GAP_BEFORE = 1 */
        uint32_t d = r(AC_DROP_CNT);
        drop_before = d - last_drop; last_drop = d;
    }
    /* idx == 0 hoặc ctr8 đổi → ctr32++ ; đóng block khi đủ 64 mẫu hoặc ctr đổi */
    push_sample(ctr32, OD_IDX(wd), OD_C(wd));
}
w(AC_IRQ_STATUS, r(AC_IRQ_STATUS));      /* W1C; THRESH tự bật lại nếu mức vẫn ≥ ngưỡng */
```

### Dừng

```c
w(AC_CTRL, CTRL_N_SEL);                                    /* ENABLE = 0, FPGA mã nốt in_fifo */
wait_until(((r(AC_FIFO_LEVEL) >> 16) == 0) && !(r(AC_STATUS) & ST_BUSY));   /* ≤ 0,1 ms */
drain_out_fifo(); close_open_block();
update_next_ctr_in_snvm_if_needed();
w(AC_CTRL, CTRL_N_SEL | CTRL_KEY_CLEAR);                   /* 0x110 */
```

Lần ghi sau: làm lại từ bước nạp khóa với `CTR` lớn hơn ctr cuối đã dùng (không cần SOFT_RESET). Nếu chỉ tạm dừng (không KEY_CLEAR) thì bật lại ENABLE là (ctr, idx) nối tiếp liền mạch.

### Chế độ REG (tùy chọn, để tự kiểm hoặc giải mã trên board)

`SRC_SEL = 3`, `ENABLE = 0`, KEY_READY: ghi `CTRL = N_SEL | OP(x)`, rồi mỗi mẫu `w(DATA_IN, v)` → chờ `BUSY = 0` → `r(DATA_OUT)`. Đã dùng chế độ này để **giải mã lại 8192 mẫu ngay trên board** (mục 10).

---

## 9. Định dạng `.chau` (hợp đồng Linux ↔ Python)

Mọi số nhiều byte big-endian. Tên file: `rec_YYYYMMDD_HHMMSS_<ctr_hex8>.chau`.

**Header 32 byte (Linux ghi):** `magic "CHAU"` · `format_version 1` · `spec_version 1,0,0` · `N 16` · `channels 1` · `shift` · `source (0 MIC/1 RAMP/2 SINE)` · `fs_milli_hz = 15625000` · `start_unix (8 B)` · `key_id (4 B)` · `first_ctr (4 B)`.

**Block (RTOS tạo, Linux ghi nguyên văn):**

| Off | Byte | Trường | Ghi chú |
|---|---|---|---|
| 0 | 2 | sync | `0xA55A` |
| 2 | 4 | ctr | ctr của phiên |
| 6 | 1 | idx0 | idx của mẫu đầu trong block |
| 7 | 1 | count | 1–64 |
| 8 | 1 | flags | `[0]` GAP_BEFORE · `[1]` TEST_SOURCE |
| 9 | 1 | reserved | 0 |
| 10 | 2 | drop_before | Số mẫu bỏ ngay trước block; bão hòa `0xFFFF` |
| 12 | 2·count | C[] | Bản mã |
| cuối | 2 | crc16 | CRC-16/CCITT-FALSE trên byte 2 → hết C[] |

Block đầy = **142 byte**. Một block = một phiên → mỗi block tự giải mã được. Băng thông: 34,7 KB/s ≈ 2,08 MB/phút.

> **⚠ Lệch với nhánh `os/audio-driver` hiện tại:** `chau_block.h` đang để `drop_before` 1 byte ở offset 9 (bão hòa 255), block 140 byte. Hợp đồng v1.0 là 2 byte ở offset 10, block 142 byte, và `tools/decode_chau.py` / bộ giải mã tham chiếu đọc theo hợp đồng. Cần chốt một cách trước M2.
>
> Cũng sửa trong `board_config.h`: `ACORE_BASE = 0x40000500`, `ACORE_PLIC_IRQ` = nguồn ứng với `MSS_INT_F2M[16]` (không phải `[0]`), `fs_milli_hz = 15625000`.

---

## 10. Kết quả kiểm chứng

### Mô phỏng

| Công cụ | Kết quả |
|---|---|
| pytest golden model | 220 test pass |
| Icarus Verilog | 28/28 |
| Verilator | 14/14 |
| ModelSim Pro (Libero) | Đợt 3: 18/18 · Đợt 4: 18/18 · Đợt 5: 4/4 · Đợt 6: 4/4 · Đợt 7 toàn hệ: 2/2 |
| Mutation testing | 27/27 · 29/29 · 39/39 (testbench bắt hết lỗi cố ý cài) |

### Tổng hợp, timing (bản SoC cuối, Libero 2026.1)

| Mục | Giá trị |
|---|---|
| Khối của mình | ≈ 6 450 LUT, 12 Math, 4 LSRAM (tổng cả chip < 20 %) |
| Setup slack 50 MHz (FIC_3) | **+3,543 ns** (cả 3 corner) |
| Hold slack | +0,048 ns |
| Phủ ràng buộc timing | 99,88 % |

### Trên board thật (bare-metal U54_1 qua JTAG, 14/11/2026) — **43 PASS, 0 FAIL**

| Phần | Kiểm gì | Kết quả |
|---|---|---|
| A | VERSION, giá trị mặc định sau SOFT_RESET | 6/6 — đường MSS → FIC_3 → APB → `0x4000_0500` chạy |
| B | Khóa, CTR, RESEED, từ chối CTR cũ | 6/6 |
| C | Chế độ REG: 3 mẫu so golden | 4/4 — `b44a`, `646d`, `f72c` khớp bit |
| D | Luồng RAMP qua FIFO | 16 từ khớp golden từng bit; 17 255 từ ctr/idx đúng, 0 GAP, DROP 0; **fs đo = 15 625 Hz**; ngắt THRESH bật; CYCLES_MAX 344 |
| E | Micro: thu 8192 mẫu → **giải mã lại trên board (REG/DEC)** | Round-trip đúng 8192/8192 mẫu qua 128 phiên; micro chưa cắm nên bản rõ = 0 (đúng, SD kéo xuống) |
| Oscilloscope | SCK chân 12 | **1,000 MHz**, 3,34 V đỉnh-đỉnh, duty ≈ 50 % |

Chương trình test (`u54_1.c`) và cách chạy: `fpga/baremetal_test/` — có chế độ `m` bật I2S liên tục để đo.

---

## 11. Cách dựng lại / nạp / thử

| Việc | Cách làm |
|---|---|
| Dựng project Libero | Libero → Ctrl+U → `fpga/soc/MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl` (Reference Design v2026.04 đã vá, RTL link từ `rtl/`) |
| HSS + bitstream | Ctrl+U → `fpga/soc/pbl5_step4_hss_bitstream.tcl` → `fpga/soc/fpe_job/MPFS_DISCOVERY.job` (fabric + sNVM + eNVM) |
| Nạp | Libero *Run PROGRAM Action* hoặc FlashPro Express với file `.job` |
| Thử nhanh không cần OS | SoftConsole, ví dụ `mpfs-mmuart-interrupt` cấu hình `Discovery-Kit-LIM-Debug` + `u54_1.c` của mình; boot mode 0; kết quả ra COM5 |
| Thử bằng U-Boot (có thẻ SD Linux 2026.04) | `md.l 0x40000560 1` → `00020100`; kịch bản đầy đủ `fpga/baremetal_test/TEST_UBOOT.md` |
| Đưa board về boot HSS | Chạy lại *Run PROGRAM Action* (boot mode 1) |

UART trên J4 (115200 8N1): COM4 = HSS (E51), COM5 = U54_1 (chương trình test), COM6 = U54_2 (ví dụ Microchip). Số COM có thể khác trên máy khác.

---

## 12. Việc còn lại và câu hỏi cho phía OS

**Phía FPGA**
- [ ] Cắm INMP441, chạy lại phần E để thấy âm thanh thật giải mã trên board.
- [ ] Đo WS chân 35 (mong đợi 15,625 kHz, 50 %).
- [x] Đưa RTL, testbench, golden model, script tích hợp SoC và chương trình test lên repo (nhánh `fpga/rtl-v1`).

**Cần phía OS**
- [ ] Chốt `drop_before` (2 byte theo hợp đồng hay 1 byte như `chau_block.h`).
- [ ] `board_config.h`: `ACORE_BASE = 0x40000500`, IRQ = `MSS_INT_F2M[16]` (PLIC 134 theo HAL — kiểm trên board).
- [ ] Device tree: bỏ GPIO2 chân 2, 12, 15; thêm node cho khối tại `0x40000500` nếu Linux cần thấy (thường chỉ FreeRTOS/U54_4 dùng).
- [ ] Quản lý `K_master` + `next_ctr` trong sNVM (khối đặt trước 2²⁰).
- [ ] Thử đầu tiên với `SRC_SEL = 1` (RAMP): `decode_chau.py` phải ra 0, 1, 2, … liên tục.
- [ ] Xác nhận bản HSS / Yocto dùng cho AMP (hiện nạp HSS v2026.04.1).
