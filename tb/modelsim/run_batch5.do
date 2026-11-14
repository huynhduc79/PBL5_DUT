# run_batch5.do - chay testbench dot 5 (sync_fifo, i2s_rx) x 2 che do GAP, ghi vao sim_result_batch5.txt.
# Cach dung: trong ModelSim Transcript go:   do run_batch5.do
# Tuy chon (dat truoc khi go do):  set TBS5 {tb_i2s_rx}  /  set GAPS5 {1}.
# (Moi dot dung bien rieng TBS<n>/GAPS<n> va xoa sau khi chay: chay dot nay xong khong lam lech dot khac.)
# Vector (sinh boi tools/gen_vec_batch5.py, nam san trong thu muc simulation):
#   tb_sync_fifo : fifo_a6.hex (64 x 16), fifo_a11.hex (2048 x 32)
#   tb_i2s_rx    : i2s_frames.hex, i2s_cfg.hex, i2s_exp.hex
# Ket qua mong doi: 4 dong PASS.

cd {D:/BachKhoa/HK1 (Sem9) - 2026-2027/PBL5/libero/chaos_crypto/simulation}
if {![info exists TBS5]}  { set TBS5 {tb_sync_fifo tb_i2s_rx} }
if {![info exists GAPS5]} { set GAPS5 {0 1} }
transcript file sim_result_batch5.txt
vlib manual_lib

echo "=== dot 5 : bien dich ==="
vlog -work manual_lib ../hdl/sync_fifo.v ../hdl/i2s_rx.v ../stimulus/tb_sync_fifo.v ../stimulus/tb_i2s_rx.v

foreach tb $TBS5 {
  foreach g $GAPS5 {
    echo "=== $tb : GAP=$g ==="
    vsim -c -onfinish stop manual_lib.$tb +GAP=$g
    run -all
    quit -sim
  }
}
echo "=== XONG ==="
unset -nocomplain TBS5 GAPS5
transcript file ""
