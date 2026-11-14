# run_batch6.do - chay testbench dot 6 (sample_fmt, test_src) x 2 che do GAP, ghi vao sim_result_batch6.txt.
# Cach dung: trong ModelSim Transcript go:   do run_batch6.do
# Tuy chon (dat truoc khi go do):  set TBS6 {tb_test_src}  /  set GAPS6 {1}.
# (Moi dot dung bien rieng TBS<n>/GAPS<n> va xoa sau khi chay: chay dot nay xong khong lam lech dot khac.)
# Vector (sinh boi tools/gen_vec_batch6.py tu refmodel/audio.py, nam san trong thu muc simulation):
#   tb_sample_fmt : fmt_vec.hex
#   tb_test_src   : tsrc_cfg.hex, tsrc_exp.hex
# Ket qua mong doi: 4 dong PASS.

cd {D:/BachKhoa/HK1 (Sem9) - 2026-2027/PBL5/libero/chaos_crypto/simulation}
if {![info exists TBS6]}  { set TBS6 {tb_sample_fmt tb_test_src} }
if {![info exists GAPS6]} { set GAPS6 {0 1} }
transcript file sim_result_batch6.txt
vlib manual_lib

echo "=== dot 6 : bien dich ==="
vlog -work manual_lib ../hdl/sample_fmt.v ../hdl/test_src.v ../stimulus/tb_sample_fmt.v ../stimulus/tb_test_src.v

foreach tb $TBS6 {
  foreach g $GAPS6 {
    echo "=== $tb : GAP=$g ==="
    vsim -c -onfinish stop manual_lib.$tb +GAP=$g
    run -all
    quit -sim
  }
}
echo "=== XONG ==="
unset -nocomplain TBS6 GAPS6
transcript file ""
