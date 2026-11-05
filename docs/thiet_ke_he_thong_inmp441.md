# Thiết kế hệ thống: Ghi âm mã hóa chaos trên PolarFire SoC Discovery Kit

> Micro INMP441 → FPGA (thu I2S + mã hóa LTS) → FreeRTOS → Linux → Google Drive
>
> Board: PolarFire SoC Discovery Kit (MPFS095T-1FCSG325E, DDR4 1 GB, Ethernet VSC8221, microSD)
> Thuật toán: golden model `chaos_refmodel` **SPEC_VERSION 1.0.0** (LTS + Fisher–Yates + HMAC-SHA256), dùng **N = 16**
> Phiên bản tài liệu: 0.1 (bản nháp để hai người thống nhất)

---

## 0. Phân công

| Phần | Người phụ trách | Sản phẩm bàn giao |
|---|---|---|
| Khối FPGA: thu I2S, định dạng mẫu, FIFO, lõi mã hóa, thanh ghi, ngắt | **Bạn (mã hóa)** | RTL + testbench + bitstream Libero |
| Giải mã + phân tích bằng Python trên laptop | **Bạn (mã hóa)** | `decode_chau.py`, script phân tích (phổ, tương quan…) |
| Cấu hình AMP (HSS), FreeRTOS điều khiển FPGA, Linux, tải lên Drive | **Mình (OS)** | Payload HSS, firmware FreeRTOS, ảnh Linux, dịch vụ tải lên |
| **Hợp đồng giao tiếp** (mục 7 và 8) | **Cả hai cùng chốt** | Tài liệu này. Muốn đổi thì báo nhau và nâng phiên bản |

Hai người chỉ "chạm" nhau ở **bản đồ thanh ghi (mục 7)** và **định dạng file `.chau` (mục 8)**. Giữ đúng hai mục này thì mỗi người làm độc lập được.

---

## 1. Tóm tắt các quyết định

1. **FPGA tự thu dữ liệu micro, RTOS chỉ quản lý.** MSS của PolarFire SoC không có ngoại vi I2S. Đọc I2S (SCK ≈ 1 MHz) bằng phần mềm qua GPIO cũng không tin cậy. Vì vậy bộ thu I2S đặt trong fabric. FreeRTOS cấu hình, nạp khóa, bật/tắt và rút dữ liệu đã mã hóa ra.
2. **Giữ nguyên thuật toán SPEC 1.0.0, chỉ dùng N = 16.** INMP441 xuất 24 bit, fabric cắt còn 16 bit có dấu (mục 5). Không đổi thuật toán nên không phải sinh lại vector.
3. **Bản rõ và K_master không bao giờ ra khỏi miền FPGA + RTOS.** Linux (nối Internet) chỉ thấy bản mã. Đây là lý do kiến trúc dùng cả RTOS lẫn Linux.
4. **Trong FPGA xử lý dạng luồng (stream) từng mẫu. Từ RTOS trở đi xử lý theo đoạn (block = 1 phiên = 64 mẫu). Lên Drive là file theo đoạn thời gian (mặc định 60 s).** Lý do ở mục 3.
5. Tần số lấy mẫu mặc định **≈ 16 kHz, mono** (đủ cho giọng nói). Lưu lượng bản mã khoảng 35 KB/s, tức khoảng 2,1 MB/phút.

---

## 2. Kiến trúc tổng thể

```
 INMP441                     PolarFire SoC (MPFS095T)
┌────────┐   ┌───────────────────── FPGA fabric ──────────────────────┐
│ SCK  ◄─┼───┤ i2s_rx ─► sample_fmt ─► in_fifo ─► cipher_core(N=16) ─►│
│ WS   ◄─┼───┤ (master)   24→16 bit    (nhỏ)     LTS+FY+HMAC          │
│ SD   ──┼──►│            / nguồn test                 │              │
│ L/R=GND│   │                                         ▼              │
└────────┘   │                      regs (APB/AXI4-Lite) ◄── out_fifo  │
             └───────────────────────────┬────────────────────────────┘
                                FIC + ngắt fabric→MSS (F2M)
             ┌───────────────────────────┴────────────────────────────┐
             │ MSS (RISC-V)                                           │
             │  E51 : HSS (khởi động, nạp payload, cấu hình PMP)      │
             │  U54_4 : FreeRTOS ─ nạp khóa, điều khiển, rút out_fifo,│
             │          đóng block (64 mẫu) ── RPMsg/IHC ──┐          │
             │  U54_1..3 : Linux ◄─────────────────────────┘          │
             │          ghi file .chau (60 s/file) ─► rclone ─► Drive │
             └────────────────────────────────────────────────────────┘
                                         │ Ethernet (RJ45, VSC8221)
                                         ▼
                                   Google Drive ──► Laptop: Python giải mã + phân tích
```

**Vùng tin cậy (trust boundary):**

| Miền | Thấy bản rõ? | Thấy K_master? | Nối mạng? |
|---|---|---|---|
| FPGA fabric | Có | Có (thanh ghi chỉ ghi) | Không |
| FreeRTOS (U54_4) | Không (chỉ thấy bản mã) | Có (nạp vào fabric) | Không |
| Linux (U54_1..3) | **Không** | **Không** | Có |
| Laptop giải mã | Có | Có | Có |

> Bản rõ chỉ tồn tại trong fabric (trừ chế độ debug `BYPASS`, xem mục 7). RTOS cũng chỉ nhận bản mã. Như vậy RTOS giữ vai trò quản lý khóa/điều phối, còn fabric là nơi duy nhất xử lý âm thanh gốc.

---

## 3. Stream hay từng đoạn?

**Trả lời ngắn:** stream bên trong FPGA, đoạn (block/file) ở các tầng phía trên.

| Tầng | Cách xử lý | Lý do |
|---|---|---|
| Micro → FPGA → lõi mã hóa | **Stream, từng mẫu** | I2S là luồng liên tục. Thuật toán là mật mã dòng đồng bộ, mã hóa từng mẫu khi mẫu tới. Độ trễ thấp và không cần bộ đệm lớn trong fabric. |
| FPGA → RTOS | **Rút theo lô** qua ngắt ngưỡng FIFO (vd. 256 mẫu ≈ 16 ms) | Ngắt mỗi mẫu (16 000 lần/s) là phí CPU. Ngắt theo ngưỡng chỉ khoảng 60 lần/s. |
| RTOS → Linux | **Block = 1 phiên = 64 mẫu** (mỗi block gắn `ctr`) | Block trùng ranh giới phiên nên **mỗi block tự giải mã được độc lập** chỉ với `K_master` + `ctr`. Mất block này không ảnh hưởng block khác. |
| Linux → Drive | **File 60 s** (`.chau`, khoảng 2,1 MB) | Drive là kho lưu file, không phải dịch vụ stream (không ghi nối vào file đang có). Mạng rớt thì file chờ trong hàng đợi và gửi sau. |

Định dạng block đã có thể stream được. Sau này nếu muốn nghe gần thời gian thực, Linux chỉ cần đẩy cùng các block đó qua MQTT/WebSocket thay vì gom vào file. Phần FPGA và RTOS không phải sửa.

---

## 4. Phần cứng micro INMP441

### 4.1 Đặc điểm cần biết (kiểm tra lại với datasheet INMP441)

- Giao tiếp **I2S chuẩn Philips**: mỗi kênh một khe 32 SCK, dữ liệu **24 bit bù hai, MSB trước**, MSB bắt đầu **1 chu kỳ SCK sau khi WS đổi mức**.
- INMP441 là **slave**: FPGA phải phát SCK và WS. `SCK = 64 × fs`.
- Micro xuất bit ở cạnh xuống SCK, **bên thu lấy mẫu ở cạnh lên SCK**.
- Chân **L/R**: nối GND thì micro xuất ở kênh trái (khi WS = 0). Khi đó nửa khe còn lại (WS = 1) để trống (tri-state).
- Sau khi cấp SCK, micro cần một khoảng thời gian khởi động (cỡ 2^18 chu kỳ SCK, khoảng 250 ms ở 1 MHz). Các mẫu trong khoảng này phải bỏ.
- Nguồn 1,8–3,3 V. Mức logic theo VDD.

### 4.2 Đấu nối (đề xuất: dùng chân I2S/PCM của header Raspberry Pi J10)

Theo bảng 7-1 trong User Guide của Discovery Kit. Các chân dưới đây thuộc **GPIO Bank 1 của fabric** (không phải Bank 2 của MSS):

| INMP441 | Header J10 (chân vật lý) | Tên trên RPi | Chân FPGA | Hướng |
|---|---|---|---|---|
| VDD | 1 hoặc 17 | 3.3V | — | nguồn |
| GND | 6 / 9 / 14… | GND | — | — |
| SCK | **12** | GPIO18 / PCM_CLK | **E10** | FPGA → mic |
| WS | **35** | GPIO19 / PCM_FS | **B19** | FPGA → mic |
| SD | **38** | GPIO20 / PCM_DIN | **B14** | mic → FPGA |
| L/R | GND | — | — | chọn kênh trái |

- Jumper **J45 phải ở 1–2 (3,3 V)** cho Bank 1 (mặc định của board).
- ⚠️ **Rủi ro cần kiểm tra sớm:** User Guide ghi J45 ở 2–3 (2,5 V) "cho MIPI RX và Ethernet", trong khi Bank 1 cần 3,3 V cho micro. Mình (OS) sẽ thử Linux + Ethernet với J45 mặc định trước. Nếu Ethernet cần 2,5 V, phương án dự phòng là cấp INMP441 bằng 2,5 V (micro hỗ trợ 1,8–3,3 V) qua một LDO nhỏ.
- Dây nối ngắn (< 15 cm). Nên thêm điện trở 33–100 Ω nối tiếp trên SCK nếu thấy nhiễu.

---

## 5. Thuật toán mã hóa áp dụng cho âm thanh

### 5.1 Giữ nguyên SPEC 1.0.0 với N = 16

Mỗi mẫu âm thanh 16 bit đi qua đúng thuật toán trong `docs/SPEC.md`:
`x ← LTS(x)`, `k ← 16 bit thấp của x`, `π ← FisherYates(...)`, `C ← gather(P, π) XOR k`. Mỗi 64 mẫu làm một lần `UpdateSession` (HMAC-SHA256 → X0, r mới).

`cipher_core.sv` đã có giao diện `sample_valid / ready / sample_done / sample_out / sample_ctr / sample_idx`. Chỉ cần **khởi tạo với `N = 16`** và bỏ khối `uart_framing` (thay bằng FIFO + thanh ghi, mục 6).

### 5.2 Chuyển mẫu 24 → 16 bit (khối `sample_fmt`, trong fabric)

```
s24  = mẫu 24 bit có dấu từ I2S
s16  = bão_hòa_16bit( s24 >>> (8 - SHIFT) )      # SHIFT = 0..8, mặc định 0
P    = s16 biểu diễn dạng không dấu 16 bit (bù hai)  → đầu vào cipher_core
```

- `SHIFT = 0`: lấy 16 bit cao, không khuếch đại.
- Tín hiệu INMP441 thường nhỏ, nên tăng `SHIFT` (2–4) để khuếch đại số. Khi đó phải **bão hòa** (kẹp về 0x7FFF / 0x8000), không được để tràn vòng.
- 8 bit thấp của INMP441 phần lớn là nhiễu (SNR khoảng 61 dB, tức khoảng 10 bit hiệu dụng), nên mất chúng không đáng kể.
- **Không đổi N lên 24.** Làm vậy phải đổi SPEC, sinh lại vector, sửa Fisher–Yates cho 24 vị trí bit.

### 5.3 Ngân sách thời gian (kiểm tra thời gian thực)

- Đồng hồ fabric 50 MHz, fs khoảng 16,28 kHz → **khoảng 3070 chu kỳ cho mỗi mẫu**.
- Theo SPEC, N = 16 cần trung bình 3,41 vòng LTS/mẫu (tối đa 6), cộng thêm một lần HMAC mỗi 64 mẫu.
- **Yêu cầu:** số chu kỳ xấu nhất cho một mẫu (kể cả mẫu có reseed) **< 50 % ngân sách**. Lõi phải xuất số đo này ra thanh ghi `CYCLES_MAX` để đưa vào báo cáo.
- Nếu có lúc HMAC chậm, `in_fifo` sẽ hấp thụ. Độ sâu 64 mẫu là quá đủ.

### 5.4 Lưu ý khi phân tích và viết báo cáo

1. **Không có tính khuếch tán theo bản rõ.** Đây là mật mã dòng đồng bộ: đổi 1 mẫu bản rõ chỉ đổi đúng 1 mẫu bản mã. Vì vậy **NSCR/UACI theo bản rõ sẽ rất thấp, và điều này đúng theo thiết kế**, không phải lỗi. Đổi lại, lỗi truyền không lan sang mẫu khác. Khi viết báo cáo nên trình bày rõ đánh đổi này, đừng so NSCR với các bài mã hóa ảnh/âm thanh kiểu khối.
2. **Tuyệt đối không dùng lại keystream.** Cùng `K_master` + cùng `ctr` mà mã hóa hai đoạn âm thanh khác nhau thì `C1 XOR C2` làm lộ thông tin. Vì vậy:
   - `ctr` bắt đầu của mỗi lần ghi phải **lớn hơn mọi ctr đã dùng**. RTOS/Linux lưu ctr cuối cùng trên thẻ nhớ và cộng thêm biên an toàn khi khởi động lại.
   - `ctr` 32 bit với 64 mẫu/phiên ở 16 kHz cho khoảng **199 ngày ghi liên tục**. Trước khi quay vòng phải đổi `K_master`.
3. Không có xác thực/toàn vẹn mật mã (chỉ có CRC chống lỗi). Ghi vào phần "giới hạn" của báo cáo, giống mục 8 của SPEC.

---

## 6. Khối FPGA cần làm (phần của bạn)

```
              ┌────────────── audio_crypt_top ───────────────────────────┐
 SD  ───────► │ i2s_rx ──► sample_fmt ──┐                                │
 SCK,WS ◄──── │ (bộ chia từ clk 50 MHz)   ├─► src_mux ─► in_fifo(64x16) ─┐ │
              │ test_src (ramp/sine) ───┘    ▲ DATA_IN (chế độ thanh ghi)│ │
              │                                                        ▼ │
              │     cipher_core #(N=16) ◄── k_master, ctr_init, init     │
              │            │ sample_done, C, ctr, idx                    │
              │            ▼                                             │
              │     pack_word ─► out_fifo(1024x32) ─► OUT_DATA (đọc=pop) │
              │     regs + irq_gen ◄──► APB (FIC3) hoặc AXI4-Lite (FIC0) │
              └──────────────────────────────────────────────────────────┘
                                        irq ─► MSS_INT_F2M[x]
```

### 6.1 Yêu cầu từng khối

**`i2s_rx`**
- Là master: tạo `SCK = clk / (2 × (SCK_DIV + 1))` và `WS` (lật mỗi 32 SCK).
- **Không dùng SCK làm clock.** Toàn bộ khối chạy ở clk fabric. SCK chỉ là tín hiệu dữ liệu được tạo bằng bộ đếm. Lấy mẫu `SD` ở chu kỳ clk ứng với cạnh lên SCK, qua 2 flip-flop đồng bộ.
- Lấy 24 bit (bit 1..24 sau cạnh WS) của kênh đã chọn (`CHANNEL`), phát `valid` một chu kỳ mỗi mẫu.
- Bỏ `STARTUP_SKIP` mẫu đầu tiên sau khi `ENABLE` (micro đang khởi động).
- Với clk 50 MHz và `SCK_DIV = 23`: SCK = 1,0417 MHz, fs = 16 276 Hz. Nếu dùng CCC tạo 49,152 MHz thì `SCK_DIV = 23` cho đúng 16 000 Hz. Cách nào cũng được. **fs thực tế ghi vào header file** (mục 8).

**`test_src`**: nguồn thử nghiệm thay micro, để kiểm tra đầu-cuối từng bit (bit-exact):
- `RAMP`: 0, 1, 2, …, 65535, 0, … (mỗi mẫu tăng 1).
- `SINE`: sin 1 kHz từ LUT, biên độ khoảng 0x4000.

**`in_fifo`** (khoảng 64 × 16 bit): khi đầy thì **bỏ mẫu ở đầu vào** (trước khi mã hóa), tăng `DROP_CNT` và đặt cờ `GAP` cho mẫu kế tiếp được mã hóa.
> Bỏ mẫu **trước** mã hóa thì không tốn keystream, nên bên giải mã không bao giờ lệch đồng bộ.

**`cipher_core`**: dùng lại nguyên, `N = 16`, `RESEED_INTERVAL = 64`. Khi `out_fifo` đầy thì **dừng nhận mẫu** (backpressure qua `ready`). **Không được bỏ mẫu ở đầu ra.**

**`out_fifo`** (khoảng 1024 × 32 bit, 2 LSRAM): mỗi mẫu mã hóa xong ghi một từ 32 bit (mục 7.2).

**`regs` + `irq_gen`**: theo mục 7. Bus APB qua FIC3 là đơn giản nhất, AXI4-Lite qua FIC0 cũng được. Báo mình địa chỉ base sau khi cấu hình MSS.

### 6.2 Yêu cầu bảo mật trong RTL

- `KMASTER[0..7]` **chỉ ghi**: đọc luôn trả 0.
- `SOFT_RESET` và `CTRL.ENABLE = 0` không xóa khóa. Bit `KEY_CLEAR` xóa khóa về 0.
- Chế độ `BYPASS` (xuất bản rõ, chỉ để debug) phải được bật bằng **generic/parameter lúc tổng hợp** `ENABLE_BYPASS = 0` mặc định. Bản build demo/bảo vệ không có đường này.

---

## 7. Hợp đồng giao tiếp FPGA ↔ RTOS (bản đồ thanh ghi)

Mở rộng từ bản đồ ở mục 5.3.3 của báo cáo và giữ tương thích các offset cũ. Tất cả thanh ghi rộng 32 bit. W1C = ghi 1 để xóa.

### 7.1 Bảng thanh ghi

| Offset | Tên | Truy cập | Mô tả |
|---|---|---|---|
| 0x00 | `CTRL` | R/W | bit0 `ENABLE` (bắt đầu thu + mã hóa liên tục) · bit2 `RESEED_NOW` (xung: `init_session` với `KMASTER` + `CTR` hiện tại) · bit3 `FIFO_CLR` (xung) · bit4 `KEY_CLEAR` (xung) · bit5 `BYPASS` (chỉ khi `ENABLE_BYPASS = 1`) · bit31 `SOFT_RESET` (xung) |
| 0x04 | `STATUS` | R / W1C | bit0 `BUSY` · bit1 `KEY_READY` (phiên đã khởi tạo) · bit2 `ERROR` · bit3 `IN_OVF` (dính, W1C) · bit4 `OUT_FULL` · bit5 `OUT_GE_THRESH` · bit6 `I2S_RUNNING` |
| 0x08–0x24 | `KMASTER[0..7]` | **W** | K_master 256 bit. `KMASTER[0]` = 4 byte đầu (big-endian, giống `w1` trong SPEC). Đọc trả 0 |
| 0x28 | `CTR` | R/W | Ghi: `ctr_init` cho lần `RESEED_NOW` kế tiếp. Đọc: ctr hiện tại của lõi |
| 0x2C | `DATA_IN` | W | Chế độ thanh ghi (`SRC_SEL = 3`): ghi 1 mẫu 16 bit để mã hóa |
| 0x30 | `DATA_OUT` | R | (giữ để tương thích). Kết quả gần nhất ở chế độ thanh ghi |
| 0x34 | `I2S_CFG` | R/W | [11:0] `SCK_DIV` · [12] `CHANNEL` (0 = trái) · [19:16] `SHIFT` (0..8) |
| 0x38 | `SRC_SEL` | R/W | 0 = MIC · 1 = RAMP · 2 = SINE · 3 = REG (`DATA_IN`) |
| 0x3C | `FIFO_LEVEL` | R | [15:0] số từ trong `out_fifo` · [31:16] số mẫu trong `in_fifo` |
| 0x40 | `OUT_DATA` | R (pop) | Đọc = lấy 1 từ ra khỏi `out_fifo` (định dạng 7.2). FIFO rỗng thì trả từ có `VALID = 0` |
| 0x44 | `IRQ_THRESH` | R/W | Phát ngắt khi `out level ≥ IRQ_THRESH` (mặc định 256) |
| 0x48 | `IRQ_EN` | R/W | bit0 `THRESH` · bit1 `IN_OVF` · bit2 `ERROR` |
| 0x4C | `IRQ_STATUS` | R / W1C | Cùng bố cục với `IRQ_EN` |
| 0x50 | `DROP_CNT` | R / W(xóa) | Số mẫu micro bị bỏ ở `in_fifo` (bão hòa) |
| 0x54 | `SAMPLE_CNT` | R | Tổng số mẫu đã mã hóa (quay vòng 2^32) |
| 0x58 | `CYCLES_MAX` | R / W(xóa) | Số chu kỳ clk lớn nhất cho 1 mẫu (từ lúc nhận mẫu đến `sample_done`, kể cả reseed) |
| 0x5C | `STARTUP_SKIP` | R/W | Số mẫu bỏ sau `ENABLE` (mặc định 4096) |
| 0x60 | `VERSION` | R | [31:16] phiên bản khối · [15:0] SPEC (0x0100 = 1.0.0) |

### 7.2 Định dạng một từ trong `out_fifo` / `OUT_DATA`

```
 31            24  23    22     21      16 15                     0
┌────────────────┬─────┬───────┬──────────┬────────────────────────┐
│   ctr[7:0]     │ GAP │ VALID │ idx[5:0] │     C[15:0] (bản mã)    │
└────────────────┴─────┴───────┴──────────┴────────────────────────┘
```

- `ctr`, `idx` là giá trị **dùng để mã hóa chính mẫu này** (trước `UpdateSession`), đúng như SPEC.
- `GAP = 1`: ngay trước mẫu này đã có mẫu micro bị bỏ ở `in_fifo`.
- `VALID = 0`: FIFO rỗng, bỏ qua từ này.
- RTOS tự giữ `ctr` đầy đủ 32 bit (nó biết `ctr_init`) và dùng `ctr[7:0]` để kiểm tra/khôi phục. Vì `out_fifo` không bao giờ bỏ mẫu nên không thể nhảy quá 256 phiên.

### 7.3 Trình tự RTOS sử dụng (để bạn viết testbench giống thật)

```
1. CTRL.SOFT_RESET
2. ghi KMASTER[0..7], ghi CTR = ctr_start
3. CTRL.RESEED_NOW  → chờ STATUS.KEY_READY
4. ghi I2S_CFG, SRC_SEL, IRQ_THRESH, IRQ_EN, STARTUP_SKIP
5. CTRL.ENABLE = 1
6. mỗi ngắt THRESH: đọc FIFO_LEVEL, đọc OUT_DATA n lần → đóng block (mục 8.2)
7. dừng: CTRL.ENABLE = 0, rút hết out_fifo, đóng block dở dang
```

---

## 8. Định dạng file ghi âm mã hóa `.chau` (hợp đồng Linux ↔ Python)

Mọi trường nhiều byte đều **big-endian** (giống SPEC). Tên file: `rec_YYYYMMDD_HHMMSS_<ctr_hex8>.chau`.

### 8.1 Header file (32 byte, do Linux ghi)

| Offset | Kích thước | Trường | Giá trị |
|---|---|---|---|
| 0 | 4 | `magic` | `b"CHAU"` |
| 4 | 1 | `format_version` | 1 |
| 5 | 3 | `spec_version` | 1, 0, 0 |
| 8 | 1 | `N` | 16 |
| 9 | 1 | `channels` | 1 |
| 10 | 1 | `shift` | giá trị `SHIFT` đang dùng |
| 11 | 1 | `source` | 0 MIC · 1 RAMP · 2 SINE |
| 12 | 4 | `fs_milli_hz` | fs thực × 1000 (vd. 16276042) |
| 16 | 8 | `start_unix` | thời điểm mở file (giây, theo NTP của Linux) |
| 24 | 4 | `key_id` | số thứ tự khóa do nhóm tự đặt (không phải khóa) |
| 28 | 4 | `first_ctr` | ctr của block đầu tiên |

### 8.2 Block (lặp lại đến hết file, do RTOS tạo, Linux ghi nguyên văn)

| Offset | Kích thước | Trường | Ghi chú |
|---|---|---|---|
| 0 | 2 | `sync` | `0xA55A` |
| 2 | 4 | `ctr` | ctr của phiên |
| 6 | 1 | `idx0` | idx của mẫu đầu tiên trong block (thường là 0) |
| 7 | 1 | `count` | số mẫu, 1..64 |
| 8 | 1 | `flags` | bit0 `GAP_BEFORE` · bit1 `TEST_SOURCE` |
| 9 | 1 | `reserved` | 0 |
| 10 | 2 × count | `C[]` | bản mã 16 bit |
| 10 + 2·count | 2 | `crc16` | CRC-16/CCITT-FALSE trên `ctr … C[]` (không gồm `sync`). Dùng `refmodel.framing.crc16_ccitt` |

Quy tắc RTOS đóng block: hết 64 mẫu (idx quay về 0, ctr tăng), **hoặc** gặp `GAP`, **hoặc** dừng ghi. Block đầy dài 140 byte cho 64 mẫu (overhead khoảng 9 %).

### 8.3 Mã mẫu đọc + giải mã (tham khảo cho `decode_chau.py`)

```python
import struct
from dataclasses import replace
from refmodel.params import DEFAULT_PARAMS
from refmodel.cipher import CipherCore
from refmodel.framing import crc16_ccitt

P16 = replace(DEFAULT_PARAMS, N=16)

def decode_chau(path: str, k_master: bytes):
    data = open(path, "rb").read()
    assert data[:4] == b"CHAU"
    fs = struct.unpack(">I", data[12:16])[0] / 1000
    pos, samples, core, expect = 32, [], None, None
    while pos + 10 <= len(data):
        sync, ctr, idx0, cnt, flags, _ = struct.unpack(">HIBBBB", data[pos:pos + 10])
        end = pos + 10 + 2 * cnt
        if sync != 0xA55A or end + 2 > len(data) \
           or crc16_ccitt(data[pos + 2:end]) != struct.unpack(">H", data[end:end + 2])[0]:
            pos += 1                                   # mất đồng bộ: dò sync tiếp
            continue
        if expect != (ctr, idx0):                      # đầu file / có mất block: khởi tạo lại
            core = CipherCore(k_master, P16, ctr0=ctr)
            core.advance(idx0)
        for c in struct.unpack(f">{cnt}H", data[pos + 10:end]):
            p = core.decrypt(c)
            samples.append(p - 0x10000 if p & 0x8000 else p)   # về int16 có dấu
        expect = core.position
        pos = end + 2
    return fs, samples
```

---

## 9. Phần Python trên laptop (phần của bạn)

**Bắt buộc**
1. `decode_chau.py <file.chau> --key key.hex` sinh ra:
   - `*_dec.wav`: âm thanh đã giải mã (int16, fs lấy từ header).
   - `*_enc.wav`: bản mã đọc như PCM int16, để nghe và vẽ phổ "tiếng nhiễu".
2. Kiểm tra bit-exact: với file `source = RAMP`, bản giải mã phải đúng là 0, 1, 2, … (mod 65536), trừ chỗ có `GAP_BEFORE`.

**Phân tích để so sánh bản rõ và bản mã** (gợi ý cho chương đánh giá)
- Dạng sóng và **histogram** (bản mã phải gần phân bố đều trên 65 536 mức).
- **Phổ / spectrogram** (bản mã phải phẳng như nhiễu trắng).
- **Tương quan mẫu kề nhau** (bản rõ khoảng 0,9+, bản mã khoảng 0).
- Entropy (gần 16 bit/mẫu), monobit/runs, NIST SP 800-22 trên luồng bản mã.
- **Độ nhạy khóa:** giải mã với khóa sai 1 bit thì kết quả phải là nhiễu (vẽ spectrogram).
- **Chất lượng khôi phục:** SNR/so sánh với bản ghi gốc. Bản ghi gốc lấy bằng build có `BYPASS` hoặc qua nguồn SINE đã biết. Bản giải mã phải trùng 100 %.
- Nhắc lại mục 5.4.1: không cần chứng minh NSCR/UACI cao.

---

## 10. Phần OS (mình làm, ghi ra để bạn nắm)

- **HSS (E51):** khởi động AMP. Payload gồm Linux (U-Boot + kernel) cho U54_1..3 và FreeRTOS cho U54_4. Dành riêng vùng DDR cho FreeRTOS và bộ đệm RPMsg trong device tree. Cấu hình để Linux **không ánh xạ** vùng địa chỉ thanh ghi của khối mã hóa và không nhận ngắt F2M đó.
- **FreeRTOS (U54_4):**
  - Task `crypto_ctrl`: provisioning khóa, `RESEED_NOW`, cấu hình.
  - ISR + task `drain`: rút `out_fifo`, khôi phục ctr đầy đủ, đóng block.
  - Task `link`: gửi block sang Linux qua RPMsg (gom 3 block = 420 B trong 1 tin nhắn ≤ 496 B), đệm vòng vài giây trong RAM nếu Linux chậm.
  - Lệnh điều khiển từ Linux: `START / STOP / STATUS / SET_SRC`, nhưng **không bao giờ có lệnh đọc khóa**.
- **Linux (U54_1..3):**
  - Daemon `chau-writer`: nhận block từ `/dev/rpmsg*`, ghi file 60 s.
  - Dịch vụ `rclone move` đẩy các file đã đóng lên Google Drive. Token OAuth nằm ở Linux, chấp nhận được vì chỉ có bản mã.
  - Lưu `last_ctr` để lần ghi sau bắt đầu từ ctr mới (mục 5.4.2).
- **Khóa:** giai đoạn đầu nhúng trong ảnh FreeRTOS (chỉ để demo, lưu ý payload nằm trên thẻ nhớ). Hướng nâng cấp: lưu trong **sNVM** của PolarFire SoC hoặc nhập qua UART riêng của RTOS.

---

## 11. Kiểm thử và mốc bàn giao

| Mốc | Bạn (FPGA/Python) | Mình (OS) | Tiêu chí đạt |
|---|---|---|---|
| **M0** | Đọc và chốt tài liệu này | Đọc và chốt tài liệu này | Hai bên thống nhất mục 7, 8 |
| **M1** | Bitstream có `regs` + `cipher_core` N = 16, `SRC_SEL = REG` | Bare-metal/FreeRTOS ghi `DATA_IN`, đọc `DATA_OUT` | Khớp vector golden `enc_n16_*` của refmodel |
| **M2** | Thêm `test_src` RAMP/SINE + FIFO + ngắt | RTOS rút FIFO, tạo file `.chau` (tạm xuất qua UART/SD) | `decode_chau.py` trả lại đúng RAMP, không mất mẫu |
| **M3** | Thêm `i2s_rx` + INMP441 | AMP: Linux nhận qua RPMsg, ghi file | Nghe được `*_dec.wav` rõ giọng, `*_enc.wav` là nhiễu |
| **M4** | Script phân tích, số liệu tài nguyên / `CYCLES_MAX` | rclone lên Drive, chạy liên tục 1 giờ | File trên Drive giải mã được, `DROP_CNT = 0` |

**Testbench gợi ý (phía bạn):** viết mô hình INMP441 (BFM) phát chuỗi 24 bit đã biết theo chuẩn I2S, cho chạy qua `audio_crypt_top`, đọc `OUT_DATA` và so với `CipherCore(N=16)` của refmodel từng mẫu (cả `ctr`, `idx`).

---

## 12. Câu hỏi mở / cần chốt

1. Chọn bus thanh ghi: **APB/FIC3** hay **AXI4-Lite/FIC0**? Địa chỉ base là bao nhiêu?
2. Dùng ngắt F2M số mấy?
3. fs: dùng 50 MHz (fs ≈ 16 276 Hz) hay tạo 49,152 MHz bằng CCC (fs = 16 000 Hz)?
4. J45 / điện áp Bank 1 khi chạy Ethernet (mục 4.2). Mình kiểm tra trước.
5. Có cần stereo (2 micro, L/R khác nhau) không? Hiện tại thiết kế mono. Stereo thì `CHANNEL` → bit chọn cả hai và `channels = 2` trong header.
