# run_batch7.do - chay testbench toan he audio_crypt_top (APB3 + I2S + loi + FIFO) x 2 che do GAP,
# ghi vao sim_result_batch7.txt.
# Cach dung: trong ModelSim Transcript go:   do run_batch7.do
# Tuy chon (dat truoc khi go do):  set GAPS7 {1}
# (Moi dot dung bien rieng TBS<n>/GAPS<n> va xoa sau khi chay: chay dot nay xong khong lam lech dot khac.)
# Vector (sinh boi tools/gen_vec_batch7.py, nam san trong thu muc simulation):
#   top_cfg.hex top_key.hex top_reg.hex top_ramp.hex top_sine.hex top_mic.hex top_clip.hex
#   top_ovf_a11.hex top_ovf_a7.hex  va i2s_frames.hex (mo hinh INMP441, dung chung voi dot 5).
# Moi lan chay ~2-5 phut (2 300 mau qua out_fifo 2048 tu). Ket qua mong doi: 2 dong PASS.

cd {D:/BachKhoa/HK1 (Sem9) - 2026-2027/PBL5/libero/chaos_crypto/simulation}
if {![info exists GAPS7]} { set GAPS7 {0 1} }
transcript file sim_result_batch7.txt
vlib manual_lib

echo "=== dot 7 : bien dich ==="
vlog -work manual_lib ../hdl/sha256_core.v ../hdl/kdf_params.v ../hdl/hmac_kdf.v ../hdl/session_mgr.v \
  ../hdl/lts_step.v ../hdl/lts_iter.v ../hdl/fy_shuffle.v ../hdl/permute_xor.v ../hdl/core_fsm.v ../hdl/chaos_core.v \
  ../hdl/sync_fifo.v ../hdl/i2s_rx.v ../hdl/sample_fmt.v ../hdl/test_src.v ../hdl/stream_seq.v \
  ../hdl/apb3_slave_regs.v ../hdl/audio_crypt_top.v \
  ../stimulus/tb_i2s_rx.v ../stimulus/tb_audio_crypt_top.v

foreach g $GAPS7 {
  echo "=== tb_audio_crypt_top : GAP=$g ==="
  vsim -c -onfinish stop manual_lib.tb_audio_crypt_top +GAP=$g
  run -all
  quit -sim
}
echo "=== XONG ==="
unset -nocomplain GAPS7
transcript file ""
