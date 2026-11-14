# Hệ thống ghi âm mã hóa thời gian thực trên PolarFire SoC

*FPGA Implementation of a Chaos-based Real-time Audio Encryption Scheme with Hash-based Shuffling
on PolarFire SoC* — đồ án PBL5.

Micro I2S INMP441 nối thẳng vào FPGA fabric, mẫu âm thanh được mã hóa tại chỗ bằng lõi
LTS + Fisher–Yates + HMAC-SHA256, và chỉ bản mã mới đi tiếp lên vi xử lý RISC-V. Bản rõ
và khóa chủ không bao giờ rời khỏi fabric.

Tham số đã chốt: `N = 16`, `RESEED_INTERVAL = 64`, `W = 32`, `r ∈ [1, 2)`, xung 50 MHz,
`SCK_DIV = 24` cho tần số lấy mẫu 15 625 Hz chẵn.

## RTL: cách kiểm tra bằng golden model

Quy trình gồm 3 bước, mỗi bước có tiêu chí qua/trượt rõ ràng.

```
(1) python -m refmodel.selfcheck          golden đúng lý thuyết?      -> TONG KET: 25/25 dat
(2) testbench từng khối + vector .hex      RTL từng khối == golden?    -> PASS: n/n
(3) log trace RTL + refmodel.compare       cả lõi chạy đúng thứ tự?    -> ma thoat 0
```

Không có bước (1) thì RTL "khớp golden" chưa chứng minh gì về lý thuyết. Không có bước (2) thì lỗi ở lõi khó định vị.

## Danh sách file RTL (Verilog-2001, đuôi `.v`; viết lần lượt từ dưới lên)

Cấu trúc hiện tại (xem `README.md` ở thư mục gốc): RTL nằm trong `rtl/`,
testbench trong `tb/`, vector `.hex` trong
`tb/vectors/`. Thư mục `sim/` chỉ chứa `run_sim.sh` và `sim/f/<khối>.f`
(danh sách file trỏ sang các chỗ trên) — RTL không bị nhân đôi.

| # | File | Khối trong sơ đồ | Kiểm bằng | Trạng thái |
|---|---|---|---|---|
| 1 | `src/lts_step.v` | lts_step (pipeline 3 tầng) | `lts_step.hex` (2166 dòng) | **đợt 1, đạt** |
| 2 | `src/sha256_core.v` | sha256_core (1 vòng/chu kỳ, trễ 66 chu kỳ) | KAT FIPS 180-4 + 461 khối (`tb/vec/sha256_blocks.hex`, sinh bởi `tb/gen_sha256_vec.py`, đối chiếu hashlib) | **đợt 1, đạt** |
| 3 | `src/kdf_params.v` | param_extract (tổ hợp: K_session -> X0, r_int) | `kdf_words.hex` (33 dòng, có ca biên) | **đợt 1, đạt** |
| 4 | `src/hmac_kdf.v` | hmac_ctrl (4 khối SHA-256, trễ 269 chu kỳ) | `kdf.hex` (48 dòng) | **đợt 1, đạt** |
| 5 | `src/session_mgr.v` | session_mgr (ctr, smp_cnt, reseed_due) | cột ctr/idx của `enc_n8_default` (RI=64), `enc_ctrwrap` (RI=4, ctr tràn), `enc_reseed1` (RI=1) | **đợt 2, đạt** |
| 6 | `src/lts_iter.v` | lts_iter (giữ X, bọc lts_step, trễ 4 chu kỳ) | `lts_iter.hex`: 2468 bước LTS thật từ 7 trace + ca bẫy x0 | **đợt 2, đạt** |
| 7 | `src/fy_shuffle.v` | fy_shuffle (bitpool + rand_range + perm_regs) | `fy_ev.hex` + `fy_sum.hex`: 1884 hoán vị (1084 từ trace golden, 800 từ chuỗi x kích thích), từng sự kiện REFILL/DRAW/SWAP, watchdog | **đợt 2, đạt** |
| 8 | `src/permute_xor.v` | permute_xor | cột p, c, k, pi của `enc_*.csv` + DEC/SKIP | ✅ |
| 9 | `src/core_fsm.v` + `src/chaos_core.v` | core_fsm + ghép lõi | 9 bộ `core_*.hex` + trace (`tb_chaos_core.v`) | ✅ |
| 10 | `src/axi4l_slave_regs.v` + `src/chaos_cipher_top.v` | AXI4-Lite + top | `tb_chaos_cipher_top.v` (9 bộ qua bus) | ✅ |
| 11 | `src/chaos_cipher_top.v` | top (regs + core) | gộp với dòng 10 | ✅ |

## Chạy một khối trên máy (Icarus Verilog hoặc Verilator)

Từ thư mục gốc dự án (Linux/macOS/WSL):
```
bash sim/run_sim.sh lts_step            # Icarus Verilog (-g2001)  -> PASS: 2166/2166 ...
bash sim/run_sim.sh fy_shuffle +GAP=1   # có khe trống, dữ liệu rác trong khe
SIM=verilator bash sim/run_sim.sh hmac_kdf +GAP=1
```
Khối hợp lệ: `lts_step`, `sha256_core`, `kdf_params`, `hmac_kdf`, `session_mgr`, `lts_iter`, `fy_shuffle`.
Script chép mọi `.hex` trong `tb/vectors/` vào `sim/_build/run/` rồi chạy ở đó (giống Libero: testbench đọc file theo tên trần).
`tools/gen_vec_batch2.py` sinh lại `lts_iter.hex`, `fy_ev.hex`, `fy_sum.hex` từ golden + trace (chạy từ thư mục gốc dự án).

## Chạy trong Libero SoC (ModelSim) — đã chạy đủ, 18/18 cấu hình đạt trên ModelSim Pro 2025.3
- Tạo từng file RTL (Create HDL, Verilog, **tên không đuôi**), dán nội dung, lưu. Testbench tạo ở Stimulus, cũng dán đè template.
- Các `.hex` đã nằm sẵn trong thư mục `simulation` của dự án Libero.
  Mỗi testbench cần: `lts_step`: `lts_step.hex` | `sha256_core`: `sha256_blocks.hex` | `kdf_params`: `kdf_words.hex` | `hmac_kdf`: `kdf.hex` |
  `session_mgr`: `enc_n8_default.hex`, `enc_ctrwrap.hex`, `enc_reseed1.hex` | `lts_iter`: `lts_iter.hex` | `fy_shuffle`: `fy_ev.hex`, `fy_sum.hex`.
- `tb_session_mgr.v` chứa 2 module (`sess_chk` và `tb_session_mgr`); top mô phỏng là `tb_session_mgr`.
- Thêm `+GAP=1` vào dòng `vsim` để chạy chế độ có khe trống. Kết quả mong đợi: dòng `PASS: ...`; sai thì in `SAI ...` / `FAIL ...`.

### Quy ước phải giữ trong RTL (đã được vector kiểm)
- `X` là Q0.32. `r_int` 34 bit = `2^32 + xr`, nên RTL chỉ cần `xr = r_int[31:0]`.
- 3 phép nhân 32x32 (SPEC mục 4.3.2; selfcheck B4 kiểm công thức này với golden). Mọi cộng/trừ lấy modulo 2^32, không cần mở rộng bit.
- Nhánh: `x < 0.5` là `x[31] == 0`. Đúng bằng 0.5 (`x = 0x80000000`) thuộc nhánh cao. Vector có ca này, đổi nhánh sẽ bị bắt.
- Bẫy: `x_next <= 1` thì `x_next = X0`. Khối KDF phải đảm bảo `X0 >= 2`.
- Keystream là **N bit THẤP** của X. BitPool nạp từ bit 0 lên. Lấy bit cao sẽ lệch (chi2 hàng nghìn).

## Cách viết testbench cho khối kế tiếp

Mọi file `.hex` có chung cách đọc: mỗi dòng là một từ rộng, cột đầu ở bit cao nhất, bố cục nằm trong
`vectors/out/manifest.json -> tables.<tên>.layout`. Mẫu để sao chép là `tb/tb_lts_step.v`:

1. `$readmemh` vào mảng rộng (`reg [W-1:0] mem [0:MAX-1]`).
2. Đếm số dòng hợp lệ trước khi lặp. Với Verilator 5.49, `break` trong vòng lặp có `#1` làm mất giá trị biến đếm; vòng đếm trước tránh được lỗi này.
3. Tách trường bằng phép gán ghép `{x, r_int, ...} = mem[i];`, so sánh bằng `!==`, in tối đa 10 dòng sai kèm số dòng.
4. Mô phỏng 2 trạng thái (Verilator) không có `X`: ô chưa nạp bằng 0, nên cần dấu hết dữ liệu hợp lệ (ví dụ `r_int = 0`).

Thứ tự khuyến nghị: SHA-256 -> HMAC -> KDF -> Fisher–Yates -> lõi -> khung. Mỗi khối chỉ tích hợp sau khi khối trước qua.

## Log trace của lõi

Khi lõi chạy, testbench (hoặc ILA/UART trên board) in mỗi sự kiện một dòng:

```
<số_mẫu>,<TÊN_SỰ_KIỆN>,<trường1>,<trường2>,...
```
số hex thường, cờ 0/1, hoán vị nối bằng dấu chấm. Chỉ cần in tập con sự kiện (ví dụ `LTS_KEYSTREAM`, `PERMUTE_XOR`, `DONE`); so sánh chỉ xét các tên có trong log RTL. So sánh:

```
python -m refmodel.compare trace vectors/out/trace_enc_n8_default.txt log_rtl.txt
python -m refmodel.compare csv   vectors/out/enc_n8_default.csv      rtl_out.csv --cols c,k
```
Mã thoát 0 là khớp, 1 là lệch (báo sự kiện lệch đầu tiên và khối RTL nghi ngờ), 2 là lỗi file.

Bộ vector nên chạy đủ, vì mỗi bộ bắt một loại lỗi:
- `enc_n8_default`, `enc_n16_default`: đường chính.
- `enc_reseed1`: tái tạo phiên sau mỗi mẫu (lỗi chốt `ctr`, `X0`).
- `enc_ctrwrap`: `ctr` tràn 2^32.
- `enc_key00`, `enc_keyff`, `enc_keyrnd`: khóa biên (lỗi thứ tự byte, HMAC với khóa đặc biệt).

## Lớp vỏ âm thanh — đợt 5 (sync_fifo, i2s_rx) đã xong

```
python tools/gen_vec_batch5.py          # fifo_a6.hex, fifo_a11.hex, i2s_frames.hex, i2s_cfg.hex, i2s_exp.hex
bash sim/run_sim.sh sync_fifo +GAP=1    # PASS: sync_fifo khop golden (64x16 ..., 2048x32 ...)
bash sim/run_sim.sh i2s_rx +GAP=1       # PASS: i2s_rx khop golden (8 ca, 285 mau ...)
python tools/mutate5.py                 # TONG KET: 27 / 27 (+ 2 tuong duong)
```
Trong ModelSim: `do run_batch5.do`.

## Lớp vỏ âm thanh — đợt 6 (sample_fmt, test_src) đã xong

```
python tools/gen_vec_batch6.py          # fmt_vec.hex, tsrc_cfg.hex, tsrc_exp.hex (tu refmodel/audio.py)
bash sim/run_sim.sh sample_fmt +GAP=1   # PASS: sample_fmt khop golden (876 mau ...)
bash sim/run_sim.sh test_src +GAP=1     # PASS: test_src khop golden (8 ca, 2510 mau x 2 DUT ...)
python tools/mutate6.py                 # TONG KET: 29 / 29
```
Trong ModelSim: `do run_batch6.do`.

## Toàn hệ — đợt 7 (stream_seq, apb3_slave_regs, audio_crypt_top) đã xong

```
python tools/gen_vec_batch7.py               # top_*.hex (CipherCore + refmodel/audio.py)
bash sim/run_sim.sh audio_crypt_top +GAP=1   # PASS: audio_crypt_top khop golden qua APB3 (...)
python tools/mutate7.py                      # TONG KET: 39 / 39 (+ 1 tuong duong); out_fifo 128 tu cho nhanh
```
Trong ModelSim: `do run_batch7.do` (moi lan chay vai phut).

## Lớp vỏ âm thanh — kế hoạch ban đầu

Lõi mã hóa đã xong và đã verify. Phần còn lại là sáu khối bọc quanh nó:

| Khối | Yêu cầu |
|---|---|
| `i2s_rx.v` | Master: `SCK = clk/(2(SCK_DIV+1))`, WS lật mỗi 32 SCK. Không dùng SCK làm clock; lấy mẫu SD ở cạnh lên. Bỏ `STARTUP_SKIP` mẫu đầu |
| `sample_fmt.v` | `s16 = bão_hòa_16(s24 >>> (8 - SHIFT))`, đếm `CLIP_CNT` |
| `test_src.v` | RAMP và SINE 1 kHz để kiểm tra bit-exact không cần micro |
| `sync_fifo.v` | Một module tham số hóa: in_fifo 64×16, out_fifo 2048×32 (dùng LSRAM) |
| `stream_seq.v` | Rút in_fifo, xung `start`, gói từ 32 bit, đo `CYCLES_MAX` |
| `audio_crypt_top.v` | Nối tất cả |

Khối thanh ghi hiện là `axi4l_slave_regs.v` (AXI4-Lite, đã verify). Kế hoạch đổi sang APB3 qua
FIC_3 — FIC_3 là giao diện APB chỉ có initiator với MSS làm chủ, đúng cho khối thanh ghi nằm
trong fabric, và bỏ được CoreAXI4Interconnect. Bản AXI4-Lite giữ lại làm phương án thay thế.

Testbench cho `i2s_rx` phải mô phỏng luôn con INMP441 (tự lái SD theo SCK/WS) để kiểm bit-exact:
lỗi trễ 1 SCK và lỗi sai kênh là hai lỗi I2S kinh điển.

## Trên bo mạch (PolarFire SoC Discovery Kit)

1. Chạy cùng bộ `enc_*` trong mô phỏng hậu-tổng-hợp (post-synthesis) trước khi nạp bo.
2. Nạp `K_master` cố định cho thử nghiệm. Đặt `SRC_SEL = 1` (RAMP) để kiểm tra đường dữ liệu
   mà chưa cần micro: bản giải mã phải ra đúng 0, 1, 2, …
3. Chuyển `SRC_SEL = 0` (micro), ghi một đoạn, lấy tệp `.chau` về.
4. Giải mã bằng `decode_chau.py`: xuất `*_dec.wav` (nghe được) và `*_enc.wav` (phải là nhiễu).
   Nếu bản giải mã nghe rõ thì chuỗi micro → lõi → FIFO → phần mềm đã đúng từ đầu đến cuối.

Lưu ý về `ctr`: mỗi lần nạp lại bitstream phải cấp `ctr` lớn hơn mọi giá trị đã dùng với cùng
khóa. Dùng `key_id = 0` cho khóa thử và không bao giờ dùng lại nó cho bản ghi thật — dùng lại
cặp `(K_master, ctr)` làm lộ hoàn toàn quan hệ giữa hai bản rõ.
