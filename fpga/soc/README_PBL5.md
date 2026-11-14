# fpga/soc — Discovery Kit Reference Design v2026.04 + khối `audio_crypt_top`

Bản gốc: github.com/polarfire-soc/polarfire-soc-discovery-kit-reference-design, tag v2026.04 (giấy phép MIT, xem `LICENSE.md`).
Chỉ giữ các file cần cho luồng mặc định (không tham số). Mọi chỗ sửa đánh dấu `# PBL5:`. RTL **link** thẳng từ `rtl/` của repo (không chép).

## Dựng lại bitstream (Libero SoC 2026.1, Windows)

1. Clone repo vào **đường dẫn ngắn, không dấu cách** (script gốc từ chối nếu đường dẫn ≥ 90 ký tự), ví dụ `D:\pbl5\`.
2. Libero → Ctrl+U → `fpga/soc/MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl`, không tham số. Tạo project `fpga/soc/MPFS_DISCOVERY/`.
3. Synthesize → Place and Route → Verify Timing (kỳ vọng: đạt mọi corner, setup +3,5 ns ở 50 MHz).
4. Ctrl+U → `fpga/soc/pbl5_step4_hss_bitstream.tcl`: nạp HSS v2026.04.1 (`script_support/hss-envm-wrapper.mpfs-disco-kit.hex`, lấy từ release HSS chính thức) vào eNVM, xuất `fpga/soc/fpe_job/MPFS_DISCOVERY.job`.
5. Nạp: Libero *Run PROGRAM Action* hoặc FlashPro Express với file `.job`.

## Thay đổi so với bản gốc

| Thay đổi | File |
|---|---|
| Bật slot 5 của CoreAPB3 `FIC_3_0x4000_0xxx` → `0x4000_0500..0x4000_05FF` | `script_support/components/FIC_3_0x4000_0xxx.tcl` |
| Đưa slot 5 ra cổng bus `FIC_3_0x4000_05xx` | `script_support/components/FIC_3_ADDRESS_GENERATION.tcl` |
| Link 17 file RTL từ `rtl/` | `script_support/hdl_source.tcl` |
| Lõi HDL+ `audio_crypt_top` với giao diện APB slave `APB_TARGET` | `script_support/components/AUDIO_CRYPT_TOP.tcl` (+ `MPFS_DISCOVERY_KIT_recursive.tcl`) |
| Đặt `AUDIO_CRYPT_0` trong `FIC_3_PERIPHERALS`: PCLK = `FIC_3_CLK` 50 MHz, PRESETN = `RESETN_FIC_3_CLK` | `script_support/components/FIC_3_PERIPHERALS.tcl` |
| Bỏ BIBUF GPIO_2_2 / 2_12 / 2_15 của MSS (nhường chân cho I2S) | `script_support/components/MSS_WRAPPER.tcl` |
| Top: cổng `I2S_SCK` / `I2S_WS` / `I2S_SD` thay `RPI_GPIO18/19/20`; `irq_o` → `MSS_INT_F2M[16]` | `script_support/components/MPFS_DISCOVERY_KIT.tcl` |
| Chân: `I2S_SCK` E10, `I2S_WS` B19, `I2S_SD` B14 (kéo xuống), LVCMOS33 | `script_support/constraints/MPFS_DISCOVERY_RPi.pdc` |

Header Raspberry Pi: GPIO18 = chân 12 (SCK), GPIO19 = chân 35 (WS), GPIO20 = chân 38 (SD), 3V3 = chân 1, GND = chân 6. INMP441: L/R nối GND.
Phía Linux/RTOS: base `0x4000_0500`, ngắt `MSS_INT_F2M[16]`; GPIO2 chân 2, 12, 15 không còn ra header.
