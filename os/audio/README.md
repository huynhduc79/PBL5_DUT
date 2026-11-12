# PBL5 – Phần OS (bản cuối): INMP441 → FPGA → FreeRTOS → Linux → Google Drive

Driver lõi `audio_crypt_top` (FPGA, `VERSION 0x0002_0100`), quản lý khóa/ctr trong sNVM, giao thức RPMsg và daemon Linux.
Viết theo tài liệu "PBL5 – Tình trạng FPGA và giao tiếp FPGA ↔ RTOS" (12/11/2026).

- Hướng dẫn đầy đủ (thiết kế, các bước lên board, việc cần chốt): **[HUONG_DAN_OS.md](HUONG_DAN_OS.md)**
- Chạy thử trên PC:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Test -RefModel D:\PBL5\chaos_refmodel_v1.0.0\chaos_project
```

| Thư mục | Nội dung |
|---|---|
| `common/` | Dùng chung board + PC: `acore_*` (driver), `ctr_store` (sNVM), `app_audio` (lệnh/giao thức), `chau_block` |
| `freertos/app/` | Lớp dán U54_4: MMIO FIC_3, PLIC, sNVM, RPMsg, task |
| `linux/` | `chaosd.py`, systemd, `chaos-upload.sh` (rclone) |
| `sim/` | Mô hình thanh ghi FPGA + RTOS giả để test không cần board |
| `tests/`, `tools/` | Test đầu-cuối, `verify_chau.py` |

Bí mật (`*.key`, `kmaster.h`, `rclone.conf`, `nvm.bin`) không bao giờ commit (xem `.gitignore`).
