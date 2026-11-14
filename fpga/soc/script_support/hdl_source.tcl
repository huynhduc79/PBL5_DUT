#Importing and Linking all the HDL source files used in the design
import_files -library work -hdl_source hdl/apb_arbiter.v
import_files -library work -hdl_source hdl/APB_PASS_THROUGH.v

# PBL5: lien ket (link) RTL tu thu muc rtl/ cua repo (khong chep). Luc nay thu muc hien hanh = fpga/soc/script_support (script chinh cd vao day).
set PBL5_RTL [file normalize [file join [pwd] .. .. .. rtl]]
create_links -hdl_source [file join $PBL5_RTL sync_fifo.v]
create_links -hdl_source [file join $PBL5_RTL i2s_rx.v]
create_links -hdl_source [file join $PBL5_RTL sample_fmt.v]
create_links -hdl_source [file join $PBL5_RTL test_src.v]
create_links -hdl_source [file join $PBL5_RTL stream_seq.v]
create_links -hdl_source [file join $PBL5_RTL apb3_slave_regs.v]
create_links -hdl_source [file join $PBL5_RTL sha256_core.v]
create_links -hdl_source [file join $PBL5_RTL kdf_params.v]
create_links -hdl_source [file join $PBL5_RTL hmac_kdf.v]
create_links -hdl_source [file join $PBL5_RTL session_mgr.v]
create_links -hdl_source [file join $PBL5_RTL lts_step.v]
create_links -hdl_source [file join $PBL5_RTL lts_iter.v]
create_links -hdl_source [file join $PBL5_RTL fy_shuffle.v]
create_links -hdl_source [file join $PBL5_RTL permute_xor.v]
create_links -hdl_source [file join $PBL5_RTL core_fsm.v]
create_links -hdl_source [file join $PBL5_RTL chaos_core.v]
create_links -hdl_source [file join $PBL5_RTL audio_crypt_top.v]
