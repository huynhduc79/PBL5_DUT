# Hợp đồng FPGA ↔ RTOS — Ghi âm mã hóa chaos (chốt v1.0)

Nov 6, 2026 · @Nguyễn Đức Anh Tuấn · cập nhật 12/11/2026: thêm mục **Tích hợp SoC** (địa chỉ gốc, ngắt, chân, phiên bản HSS)

Bản này chốt giao diện giữa khối FPGA và FreeRTOS: bản đồ thanh ghi, định dạng file `.chau`, và chính sách `ctr`. Mọi offset thanh ghi trong bản 31/10 giữ nguyên địa chỉ — phía OS không phải sửa gì đã viết. Ba thay đổi cần biết: block `.chau` dài thêm 2 byte, `ctr` phải lấy từ sNVM thay vì từ Linux, và cờ GAP có ngữ nghĩa khác với điều bộ giải mã hiện tại giả định.

## Phạm vi

Bản này thay thế mục "Hợp đồng FPGA ↔ RTOS" và mục "Định dạng file .chau" của tài liệu ngày 31/10. Mọi phần khác của tài liệu đó (kiến trúc, phần cứng INMP441, phân công, mốc) vẫn còn hiệu lực.

Ba thay đổi so với bản 31/10, xếp theo mức ảnh hưởng tới phía OS:

1. **`ctr` phải lấy từ sNVM, không từ Linux.** Đây là thay đổi bắt buộc, không phải tùy chọn: cách cũ có lỗ hổng dùng lại keystream. Chi tiết ở mục dưới.
2. **Block `.chau` dài thêm 2 byte.** Header block từ 10 lên 12 byte, thêm trường `drop_before`. Block đầy từ 140 lên 142 byte.
3. **Cờ GAP có nghĩa khác điều bộ giải mã cũ giả định.** GAP nghĩa là mất thời gian âm thanh, keystream vẫn liền mạch — không được gọi `advance()`.

Thanh ghi thì chỉ thêm, không dời: `0x00`–`0x60` giữ đúng offset và đúng ý nghĩa của bản 31/10. Thêm `CLIP_CNT` ở `0x64`, `DBG` ở `0x68`, ba trường mới trong CTRL và hai bit mới trong STATUS — tất cả ở vị trí bản cũ để trống.

Những gì bản này **không** đổi: thuật toán SPEC 1.0.0, N = 16, RESEED\_INTERVAL = 64, cách chia miền tin cậy, và việc chỉ bảo đảm tính bí mật (không xác thực).

## Chính sách ctr — chống dùng lại keystream

Đây là ràng buộc an toàn duy nhất mà cả hai bên phải tôn trọng. Mạt mã dòng đồng bộ: nếu một cặp `(K_master, ctr)` được dùng hai lần, XOR hai bản mã cho ra XOR hai bản rõ. Với âm thanh đó là mất trắng, không phải rò rỉ một phần.

Cách cũ (Linux giữ `last_ctr`) không đủ: Linux là miền dễ mất dữ liệu nhất (xóa thẻ SD, crash trước `fsync`, clone ảnh đĩa), và không ai cưỡng chế tính tăng. Trong lúc làm đồ án sẽ nạp lại bitstream hàng chục lần, gần như chắc chắn với `ctr = 0` mỗi lần.

### FreeRTOS: đặt trước khối ctr trong sNVM

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

### RTL: cưỡng chế tính tăng

Thanh ghi `CTR` chỉ nhận giá trị lến hơn giá trị hiện tại. Ghi giá trị nhỏ hơn hoặc bằng thì bị bỏ qua và dựng bit `STATUS.CTR_REJECTED`. Một bộ so sánh 32 bit — rẻ, và biến bất biến này thành tính chất của phần cứng thay vì lời hứa của phần mềm. Sau `SOFT_RESET` thì bộ so sánh được xóa, nên RTOS phải kiểm `CTR_REJECTED = 0` sau khi ghi.

### Khóa thử khi phát triển

Dùng `key_id = 0` cho khóa dev và không bao giờ dùng lại nó cho bản ghi thật. Khi trạng thái bộ đếm bị nghi ngờ thì đổi `K_master` và tăng `key_id`, không tìm cách cứu bộ đếm.

Kèm một script quét thư mục `.chau` tìm khoảng `[first_ctr, first_ctr + n)` chồng nhau trong cùng một `key_id`. Vừa là lưới an toàn, vừa là thứ đưa vào báo cáo.

## Bản đồ thanh ghi

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

### CTRL (`0x00`)

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

### STATUS (`0x04`)

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

## Từ 32 bit OUT\_DATA

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

## Hai kiểu mất dữ liệu

Đây là chỗ dễ sai nhất trong cả hệ thống. Hai kiểu mất dữ liệu đòi hỏi bộ giải mã xử lý **ngược nhau**, và nếu lẫn thì bản giải mã lệch pha âm thầm — không có lỗi nào báo ra, chỉ là tiếng ồn từ điểm lệch trở đi.

|  | Bỏ trước mã hóa | Mất sau mã hóa |
| --- | --- | --- |
| Nguyên nhân | in\_fifo đầy (RTOS trễ, out\_fifo back-pressure) | Mất tin RPMsg, mất block trong file, CRC sai |
| Lõi mật mã có chạy mẫu đó? | **Không** | **Có** |
| `ctr`/`idx` có tiến? | Không — keystream liền mạch | Có — keystream đã bị tiêu thụ |
| Báo hiệu | `GAP` = 1 trong từ OUT\_DATA; `DROP_CNT` tăng | `idx0` của block không nối tiếp block trước |
| Bộ giải mã phải làm | Chèn `drop_before` mẫu lặng. **Không gọi `advance()`** | **Gọi `advance()`** cho đúng số mẫu bị mất, rồi chèn lặng |

### Nghĩa là gì

Mẫu bị bỏ **trước** khi mã hóa thì lõi không hề sinh keystream cho nó. Nên `idx` chỉ đếm **mẫu đã mã hóa**, và luôn liên tục. Cờ `GAP` vì vậy không phải lệnh "nhảy keystream", mà là "ở đây có một lỗ trên trục thời gian".

Ngược lại, block đã rời FPGA rồi mới mất thì keystream đã tiêu thụ. Bộ giải mã phải chạy không tải đúng số mẫu đó để bắt lại pha.

### Trách nhiệm phía RTOS

Khi đọc được một từ có `GAP = 1`, RTOS đọc `DROP_CNT`, lấy hiệu so với lần đọc trước, và ghi hiệu đó vào trường `drop_before` của block sắp đóng. Đó là lý do block dài thêm 2 byte: FPGA không đủ chỗ trong từ 32 bit để nói đã bỏ bao nhiêu mẫu.

Trên thực tế việc bỏ mẫu gần như không xảy ra: lõi chỉ dùng 11% ngân sách thời gian và out\_fifo đệm 126 ms. Nhưng đã chốt hợp đồng thì phải chốt cả đường biên.

## Định dạng file `.chau`

Mọi trường nhiều byte là big-endian. Tên file: `rec_YYYYMMDD_HHMMSS_<ctr_hex8>.chau`.

### Header — 32 byte, Linux ghi

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

### Block — RTOS tạo, Linux ghi nguyên văn

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

### Băng thông

|  | Giá trị |
| --- | --- |
| Bản rõ | 31,3 KB/s |
| Bản mã kể cả đóng gói | 34,7 KB/s |
| Một phút | 2,08 MB |
| File 60 giây | 2,08 MB |

Phụ phí đóng gói là 14 byte trên 128 byte dữ liệu, tức 11%.

## Trình tự RTOS

### Khởi tạo

1. `CTRL.SOFT_RESET`.
2. Lấy `ctr_start` từ khối đã đặt trước trong sNVM.
3. Ghi `KMASTER[0..7]`, rồi ghi `CTR = ctr_start`.
4. Đọc `STATUS` và kiểm `CTR_REJECTED = 0`. Nếu bị từ chối thì dừng lại — đừng ghi âm với `ctr` cũ.
5. `CTRL.RESEED_NOW`, chờ `STATUS.KEY_READY`.
6. Ghi `I2S_CFG` (SCK\_DIV = 24, CHANNEL = 0, SHIFT), `SRC_SEL`, `IRQ_THRESH`, `IRQ_EN`, `STARTUP_SKIP`.
7. `CTRL.ENABLE = 1`.

### Vòng xử lý ngắt

1. Đọc `FIFO_LEVEL`, lấy mức out.
2. Đọc `OUT_DATA` đúng số lần đó. Bỏ từ nào có `VALID = 0`.
3. Nếu một từ có `GAP = 1`: đóng block đang mở, đọc `DROP_CNT`, lấy hiệu so với lần đọc trước, và mở block mới với `GAP_BEFORE = 1` và `drop_before` = hiệu đó.
4. Đóng block khi đủ 64 mẫu hoặc khi `ctr` đổi.
5. Tính CRC, gửi qua RPMsg (3 block ≈ 426 byte một tin).

### Dừng

1. `CTRL.ENABLE = 0`.
2. Rút hết out\_fifo.
3. Đóng block dở.
4. Ghi `next_ctr` hiện tại vào sNVM nếu đã dùng qua ranh khối đặt trước.
5. `CTRL.KEY_CLEAR`.

### Khi nào đọc CYCLES\_MAX

Đọc mỗi lần đóng file 60 giây và ghi vào log. Nếu giá trị vượt 1536 (nứa ngân sách) thì có chuyện bất thường — bình thường phải quanh 331.

## Đồng hồ và tốc độ lấy mẫu

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

### I2S

- Chuẩn Philips: khe 32 SCK mỗi kênh, 24 bit bù hai, MSB trước, trễ 1 SCK sau khi WS đổi.
- FPGA là master: phát SCK và WS. INMP441 là slave.
- `L/R` nối GND → micro phát dữ liệu trong nửa khung trái (WS thấp). `CHANNEL = 0`.
- Lấy mẫu SD ở cạnh lên SCK. Ở 1 MHz, nủa chu kỳ là 500 ns — dư biên độ rất nhiều.
- `STARTUP_SKIP` mặc định 4096 mẫu = 262 ms ở 15 625 Hz.

### 24 → 16 bit

```
s16 = bão_hòa_16bit(s24 >>> (8 - SHIFT))
```

`SHIFT` = 0..8. Với `SHIFT = 0` thì lấy 16 bit cao, không khuếch đại — đây là mặc định đúng, vì nền nhiễu của INMP441 nằm quanh LSB. Phòng yên thì tăng lên 2–4, nhưng phải bão hòa chứ không để tràn. Đọc `CLIP_CNT` để biết `SHIFT` có quá cao không.

## Bộ giải mã tham chiếu

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

## Số liệu đã đo

Tất cả là số đo thật trên lõi đã verify, không phải ước lượng.

### Chu kỳ mỗi mẫu

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

### Tổng hợp

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

### Trạng thái kiểm chứng lõi

`chaos_core` và các khối con đã khớp golden model trên Icarus, Verilator và ModelSim Pro 2025.3 — 18 cấu hình mỗi trình mô phỏng, 0 lỗi. Mutation testing: 31/32 và 29/29.

Mốc **M1** của tài liệu 31/10 (thanh ghi + `cipher_core` N=16, `SRC_SEL = REG`, khớp `enc_n16_default`) coi như đã xong, chỉ còn đổi bus và đổi bit layout theo bản này.

## Tích hợp SoC (Discovery Kit) — chốt 12/11/2026

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

## Việc còn mở

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
