#!/usr/bin/env bash
# Chay mot testbench Verilog-2001 ngoai Libero (Icarus hoac Verilator).
# Chay TU THU MUC GOC REPO:
#     bash sim/run_sim.sh chaos_core
#     bash sim/run_sim.sh chaos_core +GAP=1
#     SIM=verilator bash sim/run_sim.sh chaos_core
#
# RTL va testbench KHONG duoc nhan doi o day: danh sach file trong sim/f/<khoi>.f tro thang
# sang rtl/ va tb/.
# Vector .hex doc tu tb/vectors/ (testbench doc theo ten tran,
# nen script chay trong sim/_build/run sau khi chep .hex vao do - giong cach Libero chay).
set -euo pipefail
name="${1:?cach dung: bash sim/run_sim.sh <ten_khoi> [plusargs...]}"; shift || true
sim="${SIM:-iverilog}"
root="$(pwd)"
[ -d "$root/rtl" ] || { echo "Phai chay tu thu muc goc repo"; exit 1; }
build="$root/sim/_build"; run="$build/run"
mkdir -p "$run"; cp -f "$root"/tb/vectors/*.hex "$run"/
if [ "$sim" = "iverilog" ]; then
  iverilog -g2001 -Wall -Wno-timescale -s "tb_${name}" -o "$build/${name}.vvp" -c "sim/f/${name}.f"
  (cd "$run" && vvp -n "$build/${name}.vvp" "$@") | grep -E "PASS|FAIL|SAI|LOI|chu ky|mau"
else
  rm -rf "$build/obj_${name}"
  verilator --binary --timing -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-INITIALDLY -Wno-BLKSEQ \
    -Wno-STMTDLY -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
    -Wno-WIDTHCONCAT -Wno-LATCH -Wno-SYNCASYNCNET -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY \
    --Mdir "$build/obj_${name}" --top-module "tb_${name}" -f "sim/f/${name}.f" \
    > "$build/${name}.log" 2>&1 || { cat "$build/${name}.log"; exit 1; }
  (cd "$run" && "$build/obj_${name}/Vtb_${name}" "$@") | grep -E "PASS|FAIL|SAI|LOI|chu ky|mau"
fi
