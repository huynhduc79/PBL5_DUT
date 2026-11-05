# program.tcl - nap bitstream da build vao board qua FlashPro5 tich hop (cong USB-C J4).
#   libero.exe SCRIPT:scripts/program.tcl LOGFILE:program.log
set here [file normalize [file dirname [info script]]/..]
open_project -file "$here/work/libero/dht22_uart.prjx"
run_tool -name {PROGRAMDEVICE}
close_project
puts "PROGRAM_OK"
