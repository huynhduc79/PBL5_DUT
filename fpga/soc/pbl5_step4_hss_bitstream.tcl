# pbl5_step4_hss_bitstream.tcl - PBL5 buoc 4: nap HSS (v2026.04.1) vao eNVM, sinh du lieu lap trinh,
# xuat job FlashPro Express (FABRIC + SNVM + ENVM).
# Chay khi project MPFS_DISCOVERY (thu muc nay) DANG MO va da qua Place and Route:  Ctrl+U -> chon file nay.
# Lam giong nhanh HSS_UPDATE cua MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl, chi khac la file hex da co san (khong can wget).
set here [file normalize [file dirname [info script]]]
set hex  "$here/script_support/hss-envm-wrapper.mpfs-disco-kit.hex"
set cfg  "$here/script_support/components/MSS/ENVM.cfg"
if {![file exists $hex]} { error "PBL5: khong thay file HSS $hex" }
source "$here/script_support/additional_configurations/functions.tcl"
file mkdir [file dirname $cfg]
create_eNVM_config $cfg $hex
puts "PBL5: eNVM <- $hex"
run_tool -name {GENERATEPROGRAMMINGDATA}
configure_envm -cfg_file $cfg
run_tool -name {GENERATEPROGRAMMINGDATA}
file mkdir "$here/fpe_job"
export_fpe_job MPFS_DISCOVERY "$here/fpe_job" "FABRIC SNVM ENVM" 0
save_project
puts "PBL5: xong - job FlashPro Express trong $here/fpe_job"
