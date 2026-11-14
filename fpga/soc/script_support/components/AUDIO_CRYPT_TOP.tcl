# PBL5: loi HDL+ cho audio_crypt_top: cong APB3 slave + xung/reset/ngat/I2S
create_hdl_core -file [file join [file normalize [file join [pwd] .. .. .. rtl]] audio_crypt_top.v] -module {audio_crypt_top} -library {work} -package {}
hdl_core_add_bif -hdl_core_name {audio_crypt_top} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {APB_TARGET} -signal_map {\
"PADDR:paddr_i" \
"PENABLE:penable_i" \
"PWRITE:pwrite_i" \
"PRDATA:prdata_o" \
"PWDATA:pwdata_i" \
"PREADY:pready_o" \
"PSLVERR:pslverr_o" \
"PSELx:psel_i" }
