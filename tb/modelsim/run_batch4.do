# run_batch4.do - chay testbench dot 4 (chaos_cipher_top qua AXI4-Lite: 9 bo vector x 2 che do GAP), ghi vao sim_result_batch4.txt.
# Cach dung: trong ModelSim Transcript go:   do run_batch4.do
# Tuy chon (dat truoc khi go do):  set SETS {0 7 8}  /  set GAPS {1}.  Dung lai cac file core_*.hex cua dot 3 (cung thu muc simulation).
#   0 enc_n8_default  1 enc_n16_default  2 enc_reseed1  3 enc_ctrwrap  4 enc_key00  5 enc_keyff  6 enc_keyrnd  7 ops_n8_ri4  8 ops_n16_ri64

cd {D:/BachKhoa/HK1 (Sem9) - 2026-2027/PBL5/libero/chaos_crypto/simulation}
if {![info exists SETS]}  { set SETS {0 1 2 3 4 5 6 7 8} }
if {![info exists GAPS]}  { set GAPS {0 1} }
transcript file sim_result_batch4.txt
vlib manual_lib

echo "=== chaos_cipher_top : bien dich ==="
vlog -work manual_lib ../hdl/sha256_core.v ../hdl/kdf_params.v ../hdl/hmac_kdf.v ../hdl/session_mgr.v ../hdl/lts_step.v ../hdl/lts_iter.v ../hdl/fy_shuffle.v ../hdl/permute_xor.v ../hdl/core_fsm.v ../hdl/chaos_core.v ../hdl/axi4l_slave_regs.v ../hdl/chaos_cipher_top.v ../stimulus/tb_chaos_cipher_top.v

foreach s $SETS {
  foreach g $GAPS {
    echo "=== chaos_cipher_top : SET=$s GAP=$g ==="
    vsim -c -onfinish stop manual_lib.tb_chaos_cipher_top +SET=$s +GAP=$g
    run -all
    quit -sim
  }
}
echo "=== XONG ==="
transcript file ""
