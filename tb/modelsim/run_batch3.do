# run_batch3.do - chay testbench dot 3 (chaos_core: 9 bo vector x 2 che do GAP), ghi ket qua vao sim_result_batch3.txt.
# Cach dung: trong ModelSim Transcript go:   do run_batch3.do
# Tuy chon: set SETS {0 7 8}   (danh sach bo can chay)  /  set GAPS {0}  /  set TRACE 1  truoc khi go do (mac dinh: tat ca, khong trace).
#   0 enc_n8_default  1 enc_n16_default  2 enc_reseed1  3 enc_ctrwrap  4 enc_key00  5 enc_keyff  6 enc_keyrnd  7 ops_n8_ri4  8 ops_n16_ri64

cd {D:/BachKhoa/HK1 (Sem9) - 2026-2027/PBL5/libero/chaos_crypto/simulation}
if {![info exists SETS]}  { set SETS {0 1 2 3 4 5 6 7 8} }
if {![info exists GAPS]}  { set GAPS {0 1} }
if {![info exists TRACE]} { set TRACE 0 }
transcript file sim_result_batch3.txt
vlib manual_lib

echo "=== chaos_core : bien dich ==="
vlog -work manual_lib ../hdl/sha256_core.v ../hdl/kdf_params.v ../hdl/hmac_kdf.v ../hdl/session_mgr.v ../hdl/lts_step.v ../hdl/lts_iter.v ../hdl/fy_shuffle.v ../hdl/permute_xor.v ../hdl/core_fsm.v ../hdl/chaos_core.v ../stimulus/tb_chaos_core.v

foreach s $SETS {
  foreach g $GAPS {
    echo "=== chaos_core : SET=$s GAP=$g ==="
    vsim -c -onfinish stop manual_lib.tb_chaos_core +SET=$s +GAP=$g +TRACE=$TRACE
    run -all
    quit -sim
  }
}
echo "=== XONG ==="
transcript file ""
