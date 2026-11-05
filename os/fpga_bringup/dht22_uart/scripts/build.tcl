# build.tcl - tao project Libero, tong hop, place & route, xuat file nap cho dht22_uart_top.
#
# Chay tu thu muc dht22_uart/ (xem README):
#   libero.exe SCRIPT:scripts/build.tcl LOGFILE:build.log
#   libero.exe SCRIPT:scripts/build.tcl "SCRIPT_ARGS:program" LOGFILE:build.log   # nap luon vao board
#
# Ket qua: work/libero/  (project), out/dht22_uart.job (dung cho FlashPro Express)

set here     [file normalize [file dirname [info script]]/..]
set proj_dir "$here/work/libero"
set out_dir  "$here/out"
set top      dht22_uart_top
set do_program [expr {[info exists argv] && [lsearch -exact $argv program] >= 0}]

file delete -force $proj_dir
file mkdir $out_dir

new_project -location $proj_dir -name dht22_uart -project_description {PBL5 DHT22 -> UART bring-up} \
    -block_mode 0 -standalone_peripheral_initialization 0 -instantiate_in_smartdesign 1 \
    -ondemand_build_dh 1 -use_relative_path 0 -linked_files_root_dir_env {} -hdl {VERILOG} \
    -family {PolarFireSoC} -die {MPFS095T} -package {FCSG325} -speed {-1} -die_voltage {1.0} \
    -part_range {EXT} -adv_options {IO_DEFT_STD:LVCMOS 1.8V} -adv_options {TEMPR:EXT} \
    -adv_options {VOLTR:EXT}

project_settings -verilog_mode {SYSTEM_VERILOG}

# Lien ket (khong copy) de sua file trong repo la Libero thay ngay
foreach f {dht22_reader.sv uart_tx.sv line_printer.sv dht22_uart_top.sv} {
    create_links -convert_EDN_to_HDL 0 -library {work} -hdl_source "$here/hdl/$f"
}
create_links -io_pdc "$here/constraints/io.pdc"
create_links -sdc    "$here/constraints/timing.sdc"

build_design_hierarchy
set_root -module "$top\::work"

organize_tool_files -tool {SYNTHESIZE} -file "$here/constraints/timing.sdc" \
    -module "$top\::work" -input_type {constraint}
organize_tool_files -tool {PLACEROUTE} -file "$here/constraints/io.pdc" \
    -file "$here/constraints/timing.sdc" -module "$top\::work" -input_type {constraint}
organize_tool_files -tool {VERIFYTIMING} -file "$here/constraints/timing.sdc" \
    -module "$top\::work" -input_type {constraint}

run_tool -name {SYNTHESIZE}
run_tool -name {PLACEROUTE}
run_tool -name {VERIFYTIMING}
run_tool -name {GENERATEPROGRAMMINGDATA}
run_tool -name {GENERATEPROGRAMMINGFILE}

export_prog_job -job_file_name {dht22_uart} -export_dir $out_dir \
    -bitstream_file_type {TRUSTED_FACILITY} -bitstream_file_components {FABRIC}
save_project

if {$do_program} {
    run_tool -name {PROGRAMDEVICE}
}
puts "BUILD_OK: $out_dir/dht22_uart.job"
