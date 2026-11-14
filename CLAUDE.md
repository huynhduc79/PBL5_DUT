# PBL5 – Ghi âm mã hóa chaos trên PolarFire SoC

File này được Claude Code của **cả hai thành viên** đọc mỗi khi mở repo. Quyết định nào đã chốt thì ghi vào đây hoặc `docs/`, không chỉ để trong chat.

## Dự án
- Board: PolarFire SoC Discovery Kit (MPFS095T-1FCSG325E), DDR4 1 GB, Ethernet VSC8221.
- Luồng: micro INMP441 (I2S) → FPGA (thu + mã hóa) → FreeRTOS (U54_4) → Linux (U54_1..3) → Google Drive.
- Thuật toán: golden model `refmodel/`, **SPEC_VERSION 1.0.0**, dùng **N = 16**, RESEED_INTERVAL = 64.
- Thiết kế chi tiết: `docs/thiet_ke_he_thong_inmp441.md`.

## Phân công (ai sở hữu thư mục nào)
| Thư mục | Chủ sở hữu | Ghi chú |
|---|---|---|
| `refmodel/`, `rtl/`, `tb/`, `tools/decode_chau.py`, `analysis/` | Thành viên mã hóa | Không sửa nếu không báo trước |
| `os/hss/`, `os/freertos/`, `os/linux/` | Thành viên OS | Không sửa nếu không báo trước |
| `docs/` | Cả hai | Sửa qua PR |

Claude: khi được yêu cầu sửa file **không thuộc thư mục của người đang dùng**, hãy nhắc người đó và đề xuất mở issue/PR thay vì sửa thẳng.

## Hợp đồng giao tiếp (KHÔNG tự ý đổi)
- **Bản chốt v1.0: `docs/HOP_DONG_FPGA_RTOS.md`** — bản đồ thanh ghi, từ `OUT_DATA`, định dạng `.chau`, chính sách `ctr`, địa chỉ gốc `0x4000_0500`, ngắt `MSS_INT_F2M[16]`, chân I2S.
- Mục 7, 8 của `docs/thiet_ke_he_thong_inmp441.md` là bản nháp cũ; chỗ nào khác nhau thì theo `HOP_DONG_FPGA_RTOS.md`.
- Muốn đổi: sửa tài liệu trong một PR riêng, cả hai duyệt, tăng phiên bản tài liệu; nếu đổi thuật toán thì nâng `SPEC_VERSION` và sinh lại vector (`python -m refmodel.gen_vectors vectors/out`).

## Quy ước
- Mọi số nhiều byte: **big-endian**. Bit 0 = LSB. `ctr`/`idx` là giá trị dùng để mã hóa chính mẫu đó (trước UpdateSession).
- Nhánh: `fpga/<việc>`, `os/<việc>`, `docs/<việc>`; gộp vào `main` qua Pull Request, người kia review.
- Commit message tiếng Việt hoặc tiếng Anh đều được, ngắn gọn, nêu thư mục bị ảnh hưởng.
- Bảo mật: **không commit** `K_master`, `*.key`, `key.hex`, token rclone, cấu hình `rclone.conf`.
- Không dùng lại keystream: `ctr` bắt đầu mỗi lần ghi phải lớn hơn mọi ctr đã dùng với cùng khóa.

## Lệnh thường dùng
```
python -m pytest -q                                   # test refmodel (kỳ vọng: tất cả pass)
python -m refmodel.gen_vectors --check vectors/out    # kiểm tra vector golden không bị đổi
python tools/decode_chau.py <file.chau> --key key.hex # giải mã file ghi âm
```

## Trạng thái hiện tại (cập nhật khi xong mốc)
- [x] M0 – chốt mục 7, 8 của tài liệu thiết kế → `docs/HOP_DONG_FPGA_RTOS.md` v1.0
- [x] M1 – thanh ghi + cipher_core N=16, khớp `enc_n16_default` (mô phỏng + board 14/11/2026: 43/43 PASS)
- [ ] M2 – RAMP/SINE + FIFO + ngắt, giải mã đúng RAMP (phần FPGA xong trên board; còn đường RTOS → `.chau` → `decode_chau.py`)
- [ ] M3 – INMP441 + AMP Linux/RPMsg
- [ ] M4 – Drive, chạy 1 giờ, DROP_CNT = 0

## Câu hỏi đang mở
Xem mục 12 của tài liệu thiết kế. Khi chốt, ghi kết quả vào đây.
