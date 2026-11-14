# PBL5 – Phần FPGA (RTL): tài liệu đầy đủ cho phía OS

> Cập nhật: 14/11/2026 · Người viết: thành viên mã hóa (FPGA) · Dành cho: thành viên OS (HSS / FreeRTOS / Linux)
> File duy nhất, tự đủ: mục 1–12 là tổng quan + mọi thứ cần để viết driver; **Phụ lục A** là cây khối và cổng RTL; **Phụ lục B** là nguyên văn hợp đồng FPGA ↔ RTOS v1.0 (`docs/HOP_DONG_FPGA_RTOS.md`, kèm bộ giải mã tham chiếu Python và số đo); **Phụ lục C** là kịch bản thử bằng U-Boot kèm giá trị mong đợi; **Phụ lục D** là danh sách file. Chỗ nào khác nhau thì theo Phụ lục B.

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

---

## Phụ lục A. Cây khối và cổng RTL

### A.1 Cây phân cấp (trong bitstream SoC)

```
MPFS_DISCOVERY_KIT (top Reference Design v2026.04, đã vá)
├── MSS_WRAPPER (MSS: 5 hart, DDR, MMUART, GPIO2 — bỏ chân 2/12/15)
├── CLOCKS_AND_RESETS (PF_CCC: OUT3 = 50 MHz = FIC_3_CLK; CORERESET → RESETN_FIC_3_CLK)
└── FIC_3_PERIPHERALS
    ├── FIC_3_ADDRESS_GENERATION (CoreAPB3 0x4000_0xxx: ô 0..4 có sẵn, ô 5 = khối của mình)
    ├── (PWM, GPIO, I2C, UART, SPI 7 đoạn của Reference Design)
    └── AUDIO_CRYPT_0 : audio_crypt_top  (RESEED_INTERVAL = 64, OUT_AW = 11)
        ├── u_regs     : apb3_slave_regs   (VERSION = 0x0002_0100)
        ├── u_i2s      : i2s_rx            (I2S master Philips, MIN_DIV = 3)
        ├── u_fmt      : sample_fmt        (CW = 32)
        ├── u_tsrc     : test_src          (RAMP, SINE 1 kHz)
        ├── u_seq      : stream_seq        (IDLE / WAITD / REQ / RUN / PUSH)
        ├── u_in_fifo  : sync_fifo DW 17, AW 6   (64 × {gap, s16})
        ├── u_out_fifo : sync_fifo DW 32, AW 11  (2048 × 32, LSRAM)
        └── u_core     : chaos_core (RESEED_INTERVAL = 64)
            ├── u_fsm  : core_fsm
            ├── u_sess : session_mgr
            ├── u_kdf  : hmac_kdf → sha256_core, kdf_params
            ├── u_lts  : lts_iter → lts_step (DSP)
            ├── u_fy   : fy_shuffle
            └── u_px   : permute_xor
```

### A.2 Cổng của `audio_crypt_top`

| Cổng | Hướng | Rộng | Nối vào | Ghi chú |
|---|---|---|---|---|
| `clk_i` | in | 1 | `FIC_3_CLK` | 50 MHz, miền xung duy nhất của khối |
| `rst_n_i` | in | 1 | `RESETN_FIC_3_CLK` | Tích cực mức 0, đồng bộ với `clk_i` |
| `psel_i`, `penable_i`, `pwrite_i` | in | 1 | CoreAPB3 ô 5 | APB3 chuẩn |
| `paddr_i` | in | 32 | CoreAPB3 | Chỉ dùng `[7:2]` |
| `pwdata_i` / `prdata_o` | in / out | 32 | CoreAPB3 | |
| `pready_o` | out | 1 | CoreAPB3 | 1 ngay; đọc OUT_DATA chờ đúng 1 chu kỳ |
| `pslverr_o` | out | 1 | CoreAPB3 | Luôn 0 |
| `irq_o` | out | 1 | `MSS_INT_F2M[16]` | `= OR(IRQ_STATUS & IRQ_EN)`, qua thanh ghi |
| `i2s_sck_o` | out | 1 | Chân E10 → header 12 | SCK = 50 MHz / (2 × (SCK_DIV + 1)) |
| `i2s_ws_o` | out | 1 | Chân B19 → header 35 | WS = SCK / 64; đổi mức ở sườn xuống SCK |
| `i2s_sd_i` | in | 1 | Chân B14 ← header 38 | Đồng bộ 2 tầng, lấy mẫu ở sườn lên SCK; kéo xuống |

### A.3 Giao diện của `chaos_core` (dùng nội bộ, để hiểu DBG)

`op_i`: 00 ENC · 01 DEC · 1x SKIP (= advance). `n_sel_i`: 0 → N = 8, 1 → N = 16. `ctr_out_o` / `idx_out_o` là ctr, idx **đã dùng** cho mẫu vừa xong. Mã sự kiện debug: 1 RESEED_HMAC · 2 LTS_KEYSTREAM · 3 FY_INIT · 4 FY_REFILL · 5 FY_DRAW · 6 FY_SWAP · 7 PERMUTE_XOR · 8 CHECK_RESEED · 9 DONE.

### A.4 Số chu kỳ

| Trường hợp | Chu kỳ @ 50 MHz | Thời gian |
|---|---|---|
| Một mẫu thường | 51–68 | 1,0–1,4 µs |
| Mẫu có đổi phiên (HMAC) | tối đa 344 (đo trên board) | 6,9 µs |
| Ngân sách mỗi mẫu (fs 15 625 Hz) | 3 200 | 64 µs |
| Dừng: rút hết in_fifo 64 mẫu | ≤ 65 × 68 | ≤ 0,1 ms |

---

## Phụ lục B. Hợp đồng FPGA ↔ RTOS v1.0 (nguyên văn `docs/HOP_DONG_FPGA_RTOS.md`)


Nov 6, 2026 · @Nguyễn Đức Anh Tuấn · cập nhật 12/11/2026: thêm mục **Tích hợp SoC** (địa chỉ gốc, ngắt, chân, phiên bản HSS)

Bản này chốt giao diện giữa khối FPGA và FreeRTOS: bản đồ thanh ghi, định dạng file `.chau`, và chính sách `ctr`. Mọi offset thanh ghi trong bản 31/10 giữ nguyên địa chỉ — phía OS không phải sửa gì đã viết. Ba thay đổi cần biết: block `.chau` dài thêm 2 byte, `ctr` phải lấy từ sNVM thay vì từ Linux, và cờ GAP có ngữ nghĩa khác với điều bộ giải mã hiện tại giả định.

#### Phạm vi

Bản này thay thế mục "Hợp đồng FPGA ↔ RTOS" và mục "Định dạng file .chau" của tài liệu ngày 31/10. Mọi phần khác của tài liệu đó (kiến trúc, phần cứng INMP441, phân công, mốc) vẫn còn hiệu lực.

Ba thay đổi so với bản 31/10, xếp theo mức ảnh hưởng tới phía OS:

1. **`ctr` phải lấy từ sNVM, không từ Linux.** Đây là thay đổi bắt buộc, không phải tùy chọn: cách cũ có lỗ hổng dùng lại keystream. Chi tiết ở mục dưới.
2. **Block `.chau` dài thêm 2 byte.** Header block từ 10 lên 12 byte, thêm trường `drop_before`. Block đầy từ 140 lên 142 byte.
3. **Cờ GAP có nghĩa khác điều bộ giải mã cũ giả định.** GAP nghĩa là mất thời gian âm thanh, keystream vẫn liền mạch — không được gọi `advance()`.

Thanh ghi thì chỉ thêm, không dời: `0x00`–`0x60` giữ đúng offset và đúng ý nghĩa của bản 31/10. Thêm `CLIP_CNT` ở `0x64`, `DBG` ở `0x68`, ba trường mới trong CTRL và hai bit mới trong STATUS — tất cả ở vị trí bản cũ để trống.

Những gì bản này **không** đổi: thuật toán SPEC 1.0.0, N = 16, RESEED\_INTERVAL = 64, cách chia miền tin cậy, và việc chỉ bảo đảm tính bí mật (không xác thực).

#### Chính sách ctr — chống dùng lại keystream

Đây là ràng buộc an toàn duy nhất mà cả hai bên phải tôn trọng. Mạt mã dòng đồng bộ: nếu một cặp `(K_master, ctr)` được dùng hai lần, XOR hai bản mã cho ra XOR hai bản rõ. Với âm thanh đó là mất trắng, không phải rò rỉ một phần.

Cách cũ (Linux giữ `last_ctr`) không đủ: Linux là miền dễ mất dữ liệu nhất (xóa thẻ SD, crash trước `fsync`, clone ảnh đĩa), và không ai cưỡng chế tính tăng. Trong lúc làm đồ án sẽ nạp lại bitstream hàng chục lần, gần như chắc chắn với `ctr = 0` mỗi lần.

##### FreeRTOS: đặt trước khối ctr trong sNVM

FreeRTOS giữ `next_ctr` trong sNVM — cùng miền với khóa, không phải Linux.

1. Khi khởi động: đọc `next_ctr`, ghi ngay `next_ctr + 2^20` trở lại sNVM, rồi dùng trong khoảng vừa đặt trước.
2. Khi dùng gần hết khối: đặt trước khối kế tiếp theo cách trên.
3. Linux vẫn lưu `last_ctr`, nhưng chỉ để đối chiếu, không phải nguồn sự thật.

Một lần ghi sNVM mỗi lần boot và mỗi 71 phút ghi âm — mòn flash không đáng kể. Crash chỉ có thể làm nhảy về phía trước, không bao giờ lùi.

| Thông số | Giá trị |
| --- | --- |
| Phiên/giây (fs = 15 625 Hz, RI = 64) | 244,1 |
| Không gian `ctr` 32 bit | 203 ngày ghi liên tục |
| Khối đặt trước 2^20 `ctr` | 71,6 phút âm thanh |
| Số khối tổng cộng | 4096 |

##### RTL: cưỡng chế tính tăng

Thanh ghi `CTR` chỉ nhận giá trị lến hơn giá trị hiện tại. Ghi giá trị nhỏ hơn hoặc bằng thì bị bỏ qua và dựng bit `STATUS.CTR_REJECTED`. Một bộ so sánh 32 bit — rẻ, và biến bất biến này thành tính chất của phần cứng thay vì lời hứa của phần mềm. Sau `SOFT_RESET` thì bộ so sánh được xóa, nên RTOS phải kiểm `CTR_REJECTED = 0` sau khi ghi.

##### Khóa thử khi phát triển

Dùng `key_id = 0` cho khóa dev và không bao giờ dùng lại nó cho bản ghi thật. Khi trạng thái bộ đếm bị nghi ngờ thì đổi `K_master` và tăng `key_id`, không tìm cách cứu bộ đếm.

Kèm một script quét thư mục `.chau` tìm khoảng `[first_ctr, first_ctr + n)` chồng nhau trong cùng một `key_id`. Vừa là lưới an toàn, vừa là thứ đưa vào báo cáo.

#### Bản đồ thanh ghi

Địa chỉ gốc **`0x4000_0500`** (xem mục Tích hợp SoC): thanh ghi offset `X` nằm ở `0x4000_0500 + X`. Tất cả 32 bit. W1C = ghi 1 để xóa. Cửa sổ 256 byte, chỉ giải mã `addr[7:2]`. Đọc địa chỉ không ánh xạ trả về 0, mọi giao dịch trả OKAY.

| Offset | Tên | Truy cập | Mô tả |
| --- | --- | --- | --- |
| `0x00` | CTRL | R/W | xem bên dưới |
| `0x04` | STATUS | R / W1C | xem bên dưới |
| `0x08`–`0x24` | KMASTER\[0..7\] | W | `K_master` 256 bit, KMASTER\[0\] = `K[255:224]` (big-endian). Đọc trả 0 |
| `0x28` | CTR | R/W | Ghi: `ctr_init`, **chỉ nhận nếu lến hơn giá trị hiện tại**. Đọc: `ctr` hiện tại |
| `0x2C` | DATA\_IN | W | Chỉ ở `SRC_SEL = 3`. **Ghi vào đây là lệnh start một mẫu** |
| `0x30` | DATA\_OUT | R | Kết quả mẫu gần nhất ở chế độ thanh ghi |
| `0x34` | I2S\_CFG | R/W | `[11:0]` SCK\_DIV · `[12]` CHANNEL · `[19:16]` SHIFT |
| `0x38` | SRC\_SEL | R/W | 0 MIC · 1 RAMP · 2 SINE · 3 REG |
| `0x3C` | FIFO\_LEVEL | R | `[15:0]` mức out · `[31:16]` mức in |
| `0x40` | OUT\_DATA | R (pop) | Đọc = lấy 1 từ khỏi out\_fifo; rỗng thì VALID = 0 |
| `0x44` | IRQ\_THRESH | R/W | Ngắt khi mức out ≥ giá trị. Mặc định 256 |
| `0x48` | IRQ\_EN | R/W | `[0]` THRESH · `[1]` IN\_OVF · `[2]` ERROR |
| `0x4C` | IRQ\_STATUS | R / W1C | cùng bit với IRQ\_EN |
| `0x50` | DROP\_CNT | R / W xóa | Số mẫu bị bỏ **trước** khi mã hóa (tích lũy) |
| `0x54` | SAMPLE\_CNT | R | Tổng mẫu đã mã hóa |
| `0x58` | CYCLES\_MAX | R / W xóa | Chu kỳ lớn nhất cho 1 mẫu |
| `0x5C` | STARTUP\_SKIP | R/W | Số mẫu bỏ sau ENABLE. Mặc định 4096 |
| `0x60` | VERSION | R | `[31:16]` phiên bản khối · `[15:0]` SPEC = `0x0100` |
| `0x64` | CLIP\_CNT | R / W xóa | Số lần bão hòa trong `sample_fmt` (mới) |
| `0x68` | DBG | R | `[7:0]` steps · `[15:8]` refills · `[23:16]` rejects · `[27:24]` trạng thái FSM (mới) |

##### CTRL (`0x00`)

| Bit | Tên | Kiểu | Ý nghĩa |
| --- | --- | --- | --- |
| 0 | ENABLE | mức | 1 = chạy luồng stream |
| 1 | START | xung | Chạy 1 mẫu ở chế độ REG không cần dữ liệu (dùng cho SKIP) |
| 2 | RESEED\_NOW | xung | Tạo lại khóa phiên từ `K_master` và `ctr` |
| 3 | FIFO\_CLR | xung | Xóa cả hai FIFO |
| 4 | KEY\_CLEAR | xung | Xóa `K_master` và khóa phiên |
| 5 | BYPASS | mức | Chỉ có khi tổng hợp với `ENABLE_BYPASS = 1` (mặc định 0) |
| 7:6 | OP | mức | 00 ENC · 01 DEC · 1x SKIP. Chỉ dùng ở chế độ REG (mới) |
| 8 | N\_SEL | mức | 0 = N 8 bit · 1 = N 16 bit. Mặc định 1 (mới) |
| 31 | SOFT\_RESET | xung | Reset toàn khối |

##### STATUS (`0x04`)

| Bit | Tên | Kiểu | Ý nghĩa |
| --- | --- | --- | --- |
| 0 | BUSY | sống | Lõi đang xử lý một mẫu |
| 1 | KEY\_READY | sống | Khóa phiên đã sẵn sàng |
| 2 | ERROR | W1C | Lỗi nội bộ (watchdog lõi) |
| 3 | IN\_OVF | W1C | Đã bỏ mẫu vì in\_fifo đầy |
| 4 | OUT\_FULL | sống | out\_fifo đầy |
| 5 | OUT\_GE\_THRESH | sống | Mức out ≥ IRQ\_THRESH |
| 6 | I2S\_RUNNING | sống | Bộ phát SCK/WS đang chạy |
| 7 | CTR\_REJECTED | W1C | Một lần ghi CTR bị từ chối vì không tăng (mới) |
| 8 | CMD\_IGN | W1C | Một lệnh bị bỏ qua vì lõi đang busy (mới) |

Bảo mật: KMASTER chỉ ghi, đọc trả 0. Linux không ánh xạ vùng thanh ghi này.

#### Từ 32 bit OUT\_DATA

Mỗi mẫu mã hóa xong đẩy một từ vào out\_fifo. Đọc `0x40` lấy ra một từ.

```
 bit 31      24   23      22      21        16   15                 0
    [ ctr[7:0] ] [ GAP ] [ VALID ] [ idx[5:0] ] [    C[15:0]       ]
```

| Trường | Bit | Ý nghĩa |
| --- | --- | --- |
| `ctr[7:0]` | 31:24 | 8 bit thấp của `ctr` đã dùng cho chính mẫu này. RTOS tự giữ `ctr` đầy đủ và dùng 8 bit này để đối chiếu |
| `GAP` | 23 | Có lỗ thời gian âm thanh **ngay trước** mẫu này. Xem mục sau |
| `VALID` | 22 | 0 = out\_fifo rỗng, ba trường còn lại vô nghĩa |
| `idx[5:0]` | 21:16 | Vị trí mẫu trong phiên, 0–63 |
| `C[15:0]` | 15:0 | Bản mã 16 bit |

`ctr` và `idx` là giá trị đã dùng để mã hóa chính mẫu đó, không phải giá trị kế tiếp.

**Lưu ý cho phía OS:** đọc `0x40` có tác dụng phụ (pop). Vùng này phải được ánh xạ không cache và không bufferable, và không được để debugger đọc dạo — mỗi lần đọc là mất một mẫu. Đọc `FIFO_LEVEL` trước rồi đọc đúng số từ đó; `SAMPLE_CNT` dùng để đối chiếu.

#### Hai kiểu mất dữ liệu

Đây là chỗ dễ sai nhất trong cả hệ thống. Hai kiểu mất dữ liệu đòi hỏi bộ giải mã xử lý **ngược nhau**, và nếu lẫn thì bản giải mã lệch pha âm thầm — không có lỗi nào báo ra, chỉ là tiếng ồn từ điểm lệch trở đi.

|  | Bỏ trước mã hóa | Mất sau mã hóa |
| --- | --- | --- |
| Nguyên nhân | in\_fifo đầy (RTOS trễ, out\_fifo back-pressure) | Mất tin RPMsg, mất block trong file, CRC sai |
| Lõi mật mã có chạy mẫu đó? | **Không** | **Có** |
| `ctr`/`idx` có tiến? | Không — keystream liền mạch | Có — keystream đã bị tiêu thụ |
| Báo hiệu | `GAP` = 1 trong từ OUT\_DATA; `DROP_CNT` tăng | `idx0` của block không nối tiếp block trước |
| Bộ giải mã phải làm | Chèn `drop_before` mẫu lặng. **Không gọi `advance()`** | **Gọi `advance()`** cho đúng số mẫu bị mất, rồi chèn lặng |

##### Nghĩa là gì

Mẫu bị bỏ **trước** khi mã hóa thì lõi không hề sinh keystream cho nó. Nên `idx` chỉ đếm **mẫu đã mã hóa**, và luôn liên tục. Cờ `GAP` vì vậy không phải lệnh "nhảy keystream", mà là "ở đây có một lỗ trên trục thời gian".

Ngược lại, block đã rời FPGA rồi mới mất thì keystream đã tiêu thụ. Bộ giải mã phải chạy không tải đúng số mẫu đó để bắt lại pha.

##### Trách nhiệm phía RTOS

Khi đọc được một từ có `GAP = 1`, RTOS đọc `DROP_CNT`, lấy hiệu so với lần đọc trước, và ghi hiệu đó vào trường `drop_before` của block sắp đóng. Đó là lý do block dài thêm 2 byte: FPGA không đủ chỗ trong từ 32 bit để nói đã bỏ bao nhiêu mẫu.

Trên thực tế việc bỏ mẫu gần như không xảy ra: lõi chỉ dùng 11% ngân sách thời gian và out\_fifo đệm 126 ms. Nhưng đã chốt hợp đồng thì phải chốt cả đường biên.

#### Định dạng file `.chau`

Mọi trường nhiều byte là big-endian. Tên file: `rec_YYYYMMDD_HHMMSS_<ctr_hex8>.chau`.

##### Header — 32 byte, Linux ghi

| Offset | Byte | Trường | Giá trị |
| --- | --- | --- | --- |
| 0 | 4 | `magic` | `CHAU` |
| 4 | 1 | `format_version` | 1 |
| 5 | 3 | `spec_version` | 1, 0, 0 |
| 8 | 1 | `N` | 16 |
| 9 | 1 | `channels` | 1 |
| 10 | 1 | `shift` | SHIFT đang dùng |
| 11 | 1 | `source` | 0 MIC · 1 RAMP · 2 SINE |
| 12 | 4 | `fs_milli_hz` | fs × 1000. Với SCK\_DIV = 24 thì đúng `15625000` |
| 16 | 8 | `start_unix` | giây, theo NTP |
| 24 | 4 | `key_id` | số thứ tự khóa, không phải khóa |
| 28 | 4 | `first_ctr` | `ctr` của block đầu |

##### Block — RTOS tạo, Linux ghi nguyên văn

| Offset | Byte | Trường | Ghi chú |
| --- | --- | --- | --- |
| 0 | 2 | `sync` | `0xA55A` |
| 2 | 4 | `ctr` | `ctr` của phiên |
| 6 | 1 | `idx0` | `idx` của mẫu đầu trong block |
| 7 | 1 | `count` | 1–64 |
| 8 | 1 | `flags` | `[0]` GAP\_BEFORE · `[1]` TEST\_SOURCE |
| 9 | 1 | `reserved` | 0 |
| 10 | 2 | `drop_before` | Số mẫu bị bỏ ngay trước block. 0 nếu không GAP; `0xFFFF` nếu lớn hơn 65535 (mới) |
| 12 | 2 × `count` | `C[]` | Bản mã 16 bit |
| cuối | 2 | `crc16` | CRC-16/CCITT-FALSE trên byte 2 đến hết `C[]` |

Block đầy dài 142 byte. RTOS đóng block khi đủ 64 mẫu, khi gặp GAP, hoặc khi dừng ghi. Một block = một phiên, nên mỗi block tự giải mã được và mất một block không lan sang block khác.

##### Băng thông

|  | Giá trị |
| --- | --- |
| Bản rõ | 31,3 KB/s |
| Bản mã kể cả đóng gói | 34,7 KB/s |
| Một phút | 2,08 MB |
| File 60 giây | 2,08 MB |

Phụ phí đóng gói là 14 byte trên 128 byte dữ liệu, tức 11%.

#### Trình tự RTOS

##### Khởi tạo

1. `CTRL.SOFT_RESET`.
2. Lấy `ctr_start` từ khối đã đặt trước trong sNVM.
3. Ghi `KMASTER[0..7]`, rồi ghi `CTR = ctr_start`.
4. Đọc `STATUS` và kiểm `CTR_REJECTED = 0`. Nếu bị từ chối thì dừng lại — đừng ghi âm với `ctr` cũ.
5. `CTRL.RESEED_NOW`, chờ `STATUS.KEY_READY`.
6. Ghi `I2S_CFG` (SCK\_DIV = 24, CHANNEL = 0, SHIFT), `SRC_SEL`, `IRQ_THRESH`, `IRQ_EN`, `STARTUP_SKIP`.
7. `CTRL.ENABLE = 1`.

##### Vòng xử lý ngắt

1. Đọc `FIFO_LEVEL`, lấy mức out.
2. Đọc `OUT_DATA` đúng số lần đó. Bỏ từ nào có `VALID = 0`.
3. Nếu một từ có `GAP = 1`: đóng block đang mở, đọc `DROP_CNT`, lấy hiệu so với lần đọc trước, và mở block mới với `GAP_BEFORE = 1` và `drop_before` = hiệu đó.
4. Đóng block khi đủ 64 mẫu hoặc khi `ctr` đổi.
5. Tính CRC, gửi qua RPMsg (3 block ≈ 426 byte một tin).

##### Dừng

1. `CTRL.ENABLE = 0`.
2. Rút hết out\_fifo.
3. Đóng block dở.
4. Ghi `next_ctr` hiện tại vào sNVM nếu đã dùng qua ranh khối đặt trước.
5. `CTRL.KEY_CLEAR`.

##### Khi nào đọc CYCLES\_MAX

Đọc mỗi lần đóng file 60 giây và ghi vào log. Nếu giá trị vượt 1536 (nứa ngân sách) thì có chuyện bất thường — bình thường phải quanh 331.

#### Đồng hồ và tốc độ lấy mẫu

Một miền xung duy nhất: `clk` = 50 MHz cho cả lõi, FIFO, thanh ghi và bộ phát I2S. SCK sinh ra bằng chia tần, nên không có vợ đồng hồ nào phải bắt tay.

```
SCK = clk / (2 × (SCK_DIV + 1))
fs  = SCK / 64
```

| SCK\_DIV | SCK | fs | Ghi chú |
| --- | --- | --- | --- |
| 24 | 1,000 MHz | 15 625 Hz | **Chốt dùng giá trị này** — cả hai số đều chẵn |
| 23 | 1,0417 MHz | 16 276,04 Hz | Giá trị trong bản 31/10; fs không biểu diễn chính xác được |

Chọn 24 vì `fs_milli_hz` khi đó đúng `15625000`, không phải làm tròn. Chên lệch chất lượng giữa 15,6 kHz và 16,3 kHz là không đáng kể với tiếng nói.

**Không đuổi theo 49,152 MHz** để lấy đúng 16 kHz. PF\_CCC tạo tần số đó từ 125 MHz rất vướng, mà fs đã ghi trong header nên lấy mẫu lại trên laptop là chuyện nhỏ.

##### I2S

- Chuẩn Philips: khe 32 SCK mỗi kênh, 24 bit bù hai, MSB trước, trễ 1 SCK sau khi WS đổi.
- FPGA là master: phát SCK và WS. INMP441 là slave.
- `L/R` nối GND → micro phát dữ liệu trong nửa khung trái (WS thấp). `CHANNEL = 0`.
- Lấy mẫu SD ở cạnh lên SCK. Ở 1 MHz, nủa chu kỳ là 500 ns — dư biên độ rất nhiều.
- `STARTUP_SKIP` mặc định 4096 mẫu = 262 ms ở 15 625 Hz.

##### 24 → 16 bit

```
s16 = bão_hòa_16bit(s24 >>> (8 - SHIFT))
```

`SHIFT` = 0..8. Với `SHIFT = 0` thì lấy 16 bit cao, không khuếch đại — đây là mặc định đúng, vì nền nhiễu của INMP441 nằm quanh LSB. Phòng yên thì tăng lên 2–4, nhưng phải bão hòa chứ không để tràn. Đọc `CLIP_CNT` để biết `SHIFT` có quá cao không.

#### Bộ giải mã tham chiếu

Đoạn này đã chạy round-trip với golden model qua 8 tình huống và đều khớp: ba bộ dữ liệu bình thường, `ctr0` lệch, `ctr0` sát biên 2³², hai tình huống GAP, và mất 1 rồi 2 block.

```python
import struct
from dataclasses import replace
from refmodel.params import DEFAULT_PARAMS
from refmodel.cipher import CipherCore
from refmodel.framing import crc16_ccitt

P16 = replace(DEFAULT_PARAMS, N=16)

def decode_chau(path, k_master):
    data = open(path, "rb").read()
    assert data[:4] == b"CHAU", "khong phai file .chau"
    fs = struct.unpack(">I", data[12:16])[0] / 1000
    pos, samples, core, expect = 32, [], None, None
    while pos + 12 <= len(data):
        sync, ctr, idx0, cnt, flags, _, drop = struct.unpack(">HIBBBBH", data[pos:pos + 12])
        end = pos + 12 + 2 * cnt
        if sync != 0xA55A or cnt == 0 or cnt > 64 or end + 2 > len(data) \
           or crc16_ccitt(data[pos + 2:end]) != struct.unpack(">H", data[end:end + 2])[0]:
            pos += 1                      # tim sync ke tiep
            continue

        # (1) mat block SAU ma hoa: keystream DA tieu thu -> chay khong tai cho bat lai pha
        if expect != (ctr, idx0):
            lost = 0
            if expect is not None:
                lost = (ctr - expect[0]) * P16.RESEED_INTERVAL + (idx0 - expect[1])
            if core is None or not (0 < lost <= 64 * 4096):
                core = CipherCore(k_master, P16, ctr0=ctr)   # file moi / nhay xa
                core.advance(idx0)
            else:
                core.advance(lost)                           # giu nguyen mach keystream
                samples.extend([0] * lost)                   # lo thoi gian do mat block

        # (2) GAP: bo TRUOC ma hoa -> keystream LIEN MACH, chi chen lang, KHONG advance
        if flags & 1:
            samples.extend([0] * drop)

        for c in struct.unpack(f">{cnt}H", data[pos + 12:end]):
            p = core.decrypt(c)
            samples.append(p - 0x10000 if p & 0x8000 else p)
        expect = core.position
        pos = end + 2
    return fs, samples
```

Hai chỗ khác bản 31/10, cả hai đều cần thiết:

- Nhánh (1) tính số mẫu bị mất rồi `advance(lost)` trên core đang có, thay vì luôn dụng core mới. Dụng core mới chỉ đúng khi nhảy qua phiên khác; giữa phiên thì sẽ mất trạng thái LTS.
- Nhánh (2) là nhánh mới hoàn toàn. Thiếu nó thì bản WAV bị nén thời gian mỗi lần có GAP.

Ngưỡng `64 * 4096` phân biệt "mất vài block" với "đây là khối `ctr` đặt trước mới". Nhảy xa hơn thế thì không chèn lặng, vì đó là đoạn ghi âm khác chứ không phải lỗ trong cùng một đoạn.

#### Số liệu đã đo

Tất cả là số đo thật trên lõi đã verify, không phải ước lượng.

##### Chu kỳ mỗi mẫu

Mo phỏng 200 mẫu, N = 16, RESEED\_INTERVAL = 64:

|  | Chu kỳ |
| --- | --- |
| Mẫu thường, nhỏ nhất | 51 |
| Mẫu thường, lớn nhất | 68 |
| Mẫu thường, trung bình | 56 |
| Mẫu có reseed HMAC | 331 |
| Ngân sách ở 50 MHz / 15 625 Hz | 3200 |
| **Tỷ lệ dùng, xấu nhất** | **10,3%** |

Tài liệu 31/10 yêu cầu dưới 50% — đạt rất thoải mái. Lõi còn chịu được 48 kHz (32% ngân sách) nếu sau này muốn nâng.

##### Tổng hợp

Synplify Pro ME, Libero 2026.1, PA5SOC095T fcsg325 `-1`:

|  | Giá trị |
| --- | --- |
| LUT (sau P&R) | 5499 |
| Flip-flop (SLE) | 3390 |
| DSP (MACC\_PA) | 12 / 292 |
| LSRAM | 0 (sẽ thành \~4 block khi thêm out\_fifo) |
| Fmax ước lượng | 64,7 MHz |
| Slack ở 50 MHz | +4,533 ns |

Chia theo khối: `hmac_kdf` 1647 SLE (riêng `sha256_core` 1034), `lts_iter` 357 SLE + 12 DSP, `axi4l_slave_regs` 647 SLE, `fy_shuffle` 162 SLE, `permute_xor` 33 SLE, `core_fsm` 19 SLE.

Đường găng nằm trong `lts_step`: chuỗi 5 khối DSP nối tiếp rồi một bộ cộng 32 bit, 35 mức logic, 15,5 ns. Vì vậy **chốt chạy 50 MHz**. Muốn 100 MHz thì phải chia nhỏ phép nhân thành các tầng có thanh ghi, đổi độ trễ pipeline, kéo theo phải verify lại toàn bộ — không cần thiết cho ứng dụng này.

##### Trạng thái kiểm chứng lõi

`chaos_core` và các khối con đã khớp golden model trên Icarus, Verilator và ModelSim Pro 2025.3 — 18 cấu hình mỗi trình mô phỏng, 0 lỗi. Mutation testing: 31/32 và 29/29.

Mốc **M1** của tài liệu 31/10 (thanh ghi + `cipher_core` N=16, `SRC_SEL = REG`, khớp `enc_n16_default`) coi như đã xong, chỉ còn đổi bus và đổi bit layout theo bản này.

#### Tích hợp SoC (Discovery Kit) — chốt 12/11/2026

Khối `audio_crypt_top` đã gắn vào Discovery Kit Reference Design **v2026.04** của Microchip, qua Place & Route và timing đạt ở mọi corner. Phía OS dùng các số dưới đây cho device tree và driver.

| Mục | Giá trị |
| --- | --- |
| Bus | FIC\_3, APB3. Ô 5 của CoreAPB3 `FIC_3_0x4000_0xxx` |
| Địa chỉ gốc / kích thước | `0x4000_0500` / `0x100` (đến `0x4000_05FF`) |
| Ngắt | `MSS_INT_F2M[16]` (ngắt fabric 16 của MSS), mức cao |
| Xung / reset của khối | `FIC_3_CLK` = 50 MHz (OUT3 của CCC) / `RESETN_FIC_3_CLK` |
| HSS | v2026.04.1, `hss-envm-wrapper.mpfs-disco-kit.hex`, đã nạp vào eNVM trong job FlashPro Express |
| Linux | Yocto 2026.04 (cùng đợt với reference design) |
| Tên instance | `FIC_3_PERIPHERALS_0.AUDIO_CRYPT_0` |

Ba chân I2S lấy chỗ của GPIO18/19/20 trên header Raspberry Pi, tất cả Bank 1, `LVCMOS33`:

| Tín hiệu | Chân FPGA | Header RPi | Hướng | Nối tới INMP441 |
| --- | --- | --- | --- | --- |
| `I2S_SCK` | E10 | chân 12 (GPIO18) | ra | SCK |
| `I2S_WS` | B19 | chân 35 (GPIO19) | ra | WS |
| `I2S_SD` | B14 | chân 38 (GPIO20) | vào, kéo xuống | SD |
| 3,3 V / GND | — | chân 1 / chân 6 | — | VDD / GND, L/R nối GND |

**Hệ quả cho phía OS:** GPIO2 của MSS **chân 2, 12, 15 không còn nối ra header** (trước đây là GPIO18, GPIO19, GPIO20). Device tree không được khai báo ba chân này làm GPIO. Các GPIO2 khác giữ nguyên như reference design.

Ánh xạ `MSS_INT_F2M[16]` sang số nguồn ngắt PLIC: tra mục ngắt fabric 16 (`FABRIC_F2H_16`) trong tài liệu / HAL của MPFS — chưa kiểm trên board.

Mã nguồn tích hợp (trên máy thành viên mã hóa, chưa đưa lên repo): script Discovery Kit Reference Design v2026.04 đã vá, mọi chỗ sửa đánh dấu `# PBL5:`; RTL link thẳng từ `rtl/` của repo.

#### Việc còn mở

Tám điểm cần chốt trước khi viết code. Bảy điểm đầu không chặn nhau, có thể làm song song.

- [x] **Bus: FIC\_3 (APB3) hay FIC\_0 (AXI4-Lite)?** *Đã chốt 12/11: FIC\_3, `0x4000_0500`.* Đề nghị APB3/FIC\_3: khoảng 25 thanh ghi truy cập 15 nghìn lần/giây thì APB dư đủ, và bỏ được CoreAXI4Interconnect cùng câu hỏi AXI4 → AXI4-Lite. Giá phải trả là viết lại phần bắt tay bus, khoảng 100 dòng. **Cần mở MSS configurator xác nhận FIC\_3 có trong 2026.1.**
- [x] **Chân I2S.** *Đã chốt 12/11: đúng E10 / B19 / B14 = GPIO18/19/20 header RPi.* Bản 31/10 ghi SCK→E10, WS→B19, SD→B14. Phải đối chiếu với schematic Discovery Kit trong I/O Editor — gán sai chân thì mạch im lặng hoàn toàn, không báo lỗi gì.
- [x] **I/O standard cho 3 chân I2S.** *Đã chốt 12/11: `LVCMOS33`, Bank 1 = 3,3 V.* Project đang đặt mặc định `LVCMOS18`. Ba chân này phải khai báo rõ theo điện áp Bank 1 thực tế.
- [x] **Jumper J45 và nguồn micro.** *Đã chốt 12/11: Bank 1 ở 3,3 V; cấp INMP441 từ chân 1 header RPi.* INMP441 chạy 1,8–3,3 V nên không cần LDO: cấp nguyồn micro từ **cùng rail với VDDI của bank**, dù J45 ở 2,5 V hay 3,3 V.
- [ ] **Ai viết code sNVM?** Thuộc phần OS. Cần xác nhận FreeRTOS trên U54\_4 ghi được sNVM, vì cả chính sách `ctr` dựa vào đó.
- [ ] **Kích thước tin RPMsg.** 3 block × 142 = 426 byte. Bộ đệm RPMsg mặc định cho khoảng 496 byte payload nên vừa, nhưng nên kiểm lại trên cấu hình thực tế.
- [ ] **IRQ\_THRESH.** Mặc định 256 mẫu = 16,4 ms ở 15 625 Hz. Xác nhận RTOS phục vụ được nhịp này.
- [ ] **`SHIFT` ban đầu.** Đặt 0, ghi thử trong phòng thật rồi xem `CLIP_CNT` và biên độ mới điều chỉnh. Ghi giá trị đang dùng vào header file.

Ngoài ra, ba điểm cần nhớ khi viết báo cáo, không phải việc cần làm:

1. Mạt mã dòng đồng bộ không khuếch tán theo bản rõ. NSCR/UACI thấp là đúng thiết kế, đổi lại lỗi truyền không lan.
2. Phép đảo Fisher–Yates trong một mẫu 16 bit không thêm tính bí mật so với phép XOR — keystream đã mới mỗi mẫu. Vai trò của nó là khuếch tán trong mẫu. Nên nói thật điều này thay vì thổi phồng.
3. Không có xác thực mật mã. CRC16 không phải MAC: ai cũng có thể lật bit bản mã rồi tính lại CRC. Đây là giới hạn đã biết của phạm vi đề tài (chỉ bảo đảm tính bí mật), nên nêu rõ trong báo cáo.

---

## Phụ lục C. Kịch bản thử bằng U-Boot (khi có thẻ SD Linux 2026.04)


Khối ở `0x4000_0500`. U-Boot: `md.l <địa_chỉ> 1` = đọc 1 thanh ghi 32 bit, `mw.l <địa_chỉ> <giá_trị>` = ghi.
Khóa thử `00 01 02 … 1F`, ctr `0x1000` — **chỉ để thử, không dùng cho bản ghi thật**.
Giá trị mong đợi tính bằng golden model `refmodel` (N = 16).

Dán từng khối vào Tera Term, so kết quả với cột "mong đợi". Gửi lại log nếu có dòng lệch.

#### A. Khói (đọc được thanh ghi chưa)

```
md.l 0x40000560 1
md.l 0x40000500 2
```
Mong đợi: `40000560: 00020100` (VERSION) · `40000500: 00000100 00000000` (CTRL mặc định N_SEL = 1, STATUS = 0).

#### B. Nạp khóa thử

```
mw.l 0x40000500 0x80000000
mw.l 0x40000508 0x00010203
mw.l 0x4000050c 0x04050607
mw.l 0x40000510 0x08090a0b
mw.l 0x40000514 0x0c0d0e0f
mw.l 0x40000518 0x10111213
mw.l 0x4000051c 0x14151617
mw.l 0x40000520 0x18191a1b
mw.l 0x40000524 0x1c1d1e1f
mw.l 0x40000528 0x1000
md.l 0x40000504 1
mw.l 0x40000500 0x104
md.l 0x40000504 1
md.l 0x40000528 1
```
Mong đợi: STATUS lần 1 có bit 7 (CTR_REJECTED) = 0 · STATUS lần 2 có **bit 1 (KEY_READY) = 1**, tức `00000002` · CTR = `00001000`.

#### C. Chế độ REG — mã từng mẫu qua thanh ghi

```
mw.l 0x40000538 3
mw.l 0x4000052c 0x0000
md.l 0x40000530 1
mw.l 0x4000052c 0x1234
md.l 0x40000530 1
mw.l 0x4000052c 0xbeef
md.l 0x40000530 1
```
Mong đợi DATA_OUT lần lượt: `0000b44a` · `0000646d` · `0000f72c`.
Sai mà STATUS có bit 8 (CMD_IGN) = 1 → lệnh bị bỏ (chưa KEY_READY, hoặc SRC_SEL ≠ 3).

#### D. Luồng RAMP qua FIFO (giống hệt khi ghi âm thật, chỉ khác nguồn)

```
mw.l 0x40000500 0x80000000
mw.l 0x40000508 0x00010203
mw.l 0x4000050c 0x04050607
mw.l 0x40000510 0x08090a0b
mw.l 0x40000514 0x0c0d0e0f
mw.l 0x40000518 0x10111213
mw.l 0x4000051c 0x14151617
mw.l 0x40000520 0x18191a1b
mw.l 0x40000524 0x1c1d1e1f
mw.l 0x40000528 0x1000
mw.l 0x40000500 0x104
mw.l 0x40000538 1
mw.l 0x40000500 0x101; sleep 1; mw.l 0x40000500 0x100
md.l 0x4000053c 1
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do md.l 0x40000540 1; done
```
Mong đợi: FIFO_LEVEL nửa thấp = `0800` (out_fifo đầy 2048 từ sau 1 giây). 16 lần đọc OUT_DATA:

| # | Mong đợi | # | Mong đợi |
|---|---|---|---|
| 0 | `0040b44a` | 8 | `00484db2` |
| 1 | `00416ca0` | 9 | `0049b5a9` |
| 2 | `004228b1` | 10 | `004ac35e` |
| 3 | `00435137` | 11 | `004b0643` |
| 4 | `00448f0a` | 12 | `004cf30e` |
| 5 | `0045a093` | 13 | `004dade5` |
| 6 | `004684be` | 14 | `004e0fc2` |
| 7 | `004716bf` | 15 | `004fb9da` |

Đọc từ: `[31:24]` ctr thấp = `00` (ctr 0x1000) · bit 22 VALID = 1 · `[21:16]` idx = 0..15 · `[15:0]` bản mã.
Từ 0 trùng kết quả REG đầu tiên (`b44a`) vì cùng khóa, cùng ctr, bản rõ 0.

#### E. Micro INMP441 (tuỳ chọn, sau khi C và D đúng)

```
mw.l 0x40000538 0
mw.l 0x40000500 0x101; sleep 2
md.l 0x40000504 1
md.l 0x40000554 1
md.l 0x40000564 1
mw.l 0x40000500 0x100
for i in 0 1 2 3 4 5 6 7; do md.l 0x40000540 1; done
```
Mong đợi: STATUS bit 6 (I2S_RUNNING) = 1 khi đang bật · SAMPLE_CNT (0x554) tăng · OUT_DATA có VALID = 1, bản mã thay đổi.
Đo chân 12 header bằng oscilloscope: SCK 1 MHz; chân 35: WS 15,625 kHz.
(Đoạn D đã làm đầy out_fifo: chạy lại SOFT_RESET + khóa như D trước khi bật MIC, hoặc đọc hết FIFO trước.)

---

## Phụ lục D. Danh sách file (trong repo)

| Đường dẫn | Nội dung |
|---|---|
| `rtl/*.v` | 17 file RTL dùng trong SoC (top: `audio_crypt_top.v`) |
| `tb/tb_*.v` | Testbench từng khối; `tb_audio_crypt_top.v` lái toàn hệ qua APB3 như RTOS; `tb_cycles.v` đo chu kỳ |
| `tb/vectors/*.hex` | Vector golden cho testbench (sinh lại bằng `tools/gen_vec_batch*.py`, `tools/gen_sha256_vec.py`) |
| `tb/modelsim/` | Script ModelSim dùng trong project Libero cũ (`run_batch*.do`) + kết quả |
| `sim/run_sim.sh`, `sim/f/*.f` | Chạy mô phỏng ngoài Libero: `bash sim/run_sim.sh audio_crypt_top` (Icarus) hoặc `SIM=verilator …` |
| `refmodel/` | Golden model Python (SPEC 1.0.0), `python -m pytest -q refmodel` → 220 pass |
| `vectors/out/` | Bộ vector golden chuẩn; `python -m refmodel.gen_vectors --check vectors/out` |
| `tools/decode_chau.py` | Giải mã `.chau` → `.wav`: `python tools/decode_chau.py a.chau --key key.hex` |
| `tools/chau_roundtrip_test.py` | Kiểm bộ giải mã: 8 tình huống (GAP, mất block, ctr sát 2³²) |
| `fpga/soc/` | Reference Design v2026.04 đã vá + `pbl5_step4_hss_bitstream.tcl` + HSS hex; `README_PBL5.md` |
| `fpga/baremetal_test/` | `u54_1.c` (43 PASS trên board), `HUONG_DAN.md`, `TEST_UBOOT.md` (= Phụ lục C) |
| `docs/HOP_DONG_FPGA_RTOS.md` | Hợp đồng v1.0 (= Phụ lục B) |
| `docs/FPGA_RTL_TONG_QUAN.md` | Bản tóm tắt (= mục 1–12 của file này) |

Không đưa lên repo: project Libero sinh ra (`fpga/soc/MPFS_DISCOVERY/`), file `.job` (đính kèm ở GitHub Release nếu cần), khóa thật.
