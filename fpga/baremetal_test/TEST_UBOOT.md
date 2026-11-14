# Thử khối audio_crypt_top trên board bằng U-Boot (không cần FreeRTOS, không cần micro)

Khối ở `0x4000_0500`. U-Boot: `md.l <địa_chỉ> 1` = đọc 1 thanh ghi 32 bit, `mw.l <địa_chỉ> <giá_trị>` = ghi.
Khóa thử `00 01 02 … 1F`, ctr `0x1000` — **chỉ để thử, không dùng cho bản ghi thật**.
Giá trị mong đợi tính bằng golden model `refmodel` (N = 16).

Dán từng khối vào Tera Term, so kết quả với cột "mong đợi". Gửi lại log nếu có dòng lệch.

## A. Khói (đọc được thanh ghi chưa)

```
md.l 0x40000560 1
md.l 0x40000500 2
```
Mong đợi: `40000560: 00020100` (VERSION) · `40000500: 00000100 00000000` (CTRL mặc định N_SEL = 1, STATUS = 0).

## B. Nạp khóa thử

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

## C. Chế độ REG — mã từng mẫu qua thanh ghi

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

## D. Luồng RAMP qua FIFO (giống hệt khi ghi âm thật, chỉ khác nguồn)

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

## E. Micro INMP441 (tuỳ chọn, sau khi C và D đúng)

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
