# Thử `audio_crypt_top` trên board không cần thẻ SD / OS (bare-metal qua JTAG)

`u54_1.c` chạy trên U54_1, nạp vào LIM qua cổng debug J4. Thử 5 phần A–E, in PASS/FAIL ra UART (COM của U54_1, 115200 8N1).
Kết quả 14/11/2026: **43 PASS, 0 FAIL**. Giá trị mong đợi lấy từ golden `refmodel` (khóa thử 00..1F, ctr 0x1000).

1. FPGA đã nạp bitstream của `fpga/soc` (boot mode 1, có HSS).
2. Cài **SoftConsole** (v2022.2 trở lên). Khai báo biến môi trường `FPGENPROG` = đường dẫn `fpgenprog.exe` của Libero
   (vd. `<Libero>/Designer/bin64/fpgenprog.exe`) nếu công cụ boot mode báo không tìm thấy.
3. Lấy ví dụ `driver-examples/mss/mss-mmuart/mpfs-mmuart-interrupt` từ `polarfire-soc-bare-metal-examples`,
   chép `u54_1.c` này đè `src/application/hart1/u54_1.c`. Chép thêm 2 file
   `PolarFire-SoC-Discovery-kit-program idle boot mode 0.launch` / `... non-secure boot mode 1.launch`
   (trong `applications/mpfs-blank-baremetal/launch_configs/external_tools/`) vào thư mục project.
4. SoftConsole: Import project; chuột phải → Build Configurations → Set Active → **Discovery-Kit-LIM-Debug**; Build.
5. Run → External Tools → **PolarFire-SoC-Discovery-kit-program idle boot mode 0** (đưa board về boot mode 0).
6. Run → Debug Configurations → **mpfs-mmuart-interrupt hw all-harts debug** → Debug → Resume (F8).
7. Xem UART của U54_1. Cuối bài in `KET QUA: x PASS, y FAIL`.
   Gõ **m** = bật I2S liên tục để đo: chân 12 SCK 1 MHz, chân 35 WS 15,625 kHz (GND que đo: chân 6).
8. Xong: chạy lại *Run PROGRAM Action* trong Libero để board về boot mode 1 (HSS).

Phần E thu 8192 mẫu micro rồi **giải mã lại ngay trên board** bằng chế độ REG/DEC; chưa cắm micro thì in "Toàn 0".
