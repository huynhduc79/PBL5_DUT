// audio_crypt_top.v - khoi ghi am ma hoa hoan chinh trong fabric: APB3 slave + I2S (INMP441) + loi chaos. Verilog-2001.
//
//   INMP441 --I2S--> i2s_rx --s24--> sample_fmt --s16--+
//                                   test_src (RAMP/SINE)+--> stream_seq --> in_fifo 64x17 --> chaos_core --> out_fifo 2048x32
//   MSS (FIC_3, APB3) <--> apb3_slave_regs <--------------------------------------------------- OUT_DATA (pop) <--+
//
// Noi vao MSS: clk_i = xung fabric 50 MHz (PF_CCC), rst_n_i = reset tich cuc muc thap dong bo voi clk_i,
//   APB3 tu FIC_3 (chi dung paddr[7:0]; cua so 256 byte), irq_o vao ngat MSS (fabric -> MSS).
// Chan ra ngoai chip: chi i2s_sck_o, i2s_ws_o, i2s_sd_i.
// SOFT_RESET (CTRL[31]) reset toan bo khoi qua rst_int_n (1 chu ky).
// Phan xu loi ma hoa (mot lenh moi chu ky, core_fsm uu tien load_key hon start):
//   KEY_CLEAR (soft_rst loi) > RESEED_NOW (load_key) > start cua stream_seq | start cua thanh ghi (REG, khong dong thoi).
// Ban do thanh ghi va ngu nghia: apb3_slave_regs.v, docs/HOP_DONG_FPGA_RTOS.md.
module audio_crypt_top #(
  parameter RESEED_INTERVAL = 64,
  parameter OUT_AW          = 11      // out_fifo 2^OUT_AW tu (2048 = 131 ms o 15 625 Hz). Chi testbench moi doi.
) (
  input  wire        clk_i,
  input  wire        rst_n_i,
  // APB3 slave (FIC_3)
  input  wire        psel_i,
  input  wire        penable_i,
  input  wire        pwrite_i,
  input  wire [31:0] paddr_i,
  input  wire [31:0] pwdata_i,
  output wire [31:0] prdata_o,
  output wire        pready_o,
  output wire        pslverr_o,
  output wire        irq_o,
  // I2S toi INMP441
  output wire        i2s_sck_o,
  output wire        i2s_ws_o,
  input  wire        i2s_sd_i
);
  wire unused_ok = &{1'b0, paddr_i[31:8]};

  // ---- thanh ghi
  wire         soft_rst, enable, reseed, reg_start, reg_nsel, fifo_clr, key_clear, channel, clip_clr;
  wire [1:0]   reg_op, src_sel;
  wire [15:0]  reg_pt;
  wire [255:0] key;
  wire [31:0]  ctr0, startup_skip;
  wire [11:0]  sck_div;
  wire [3:0]   shift;
  wire         rst_int_n = rst_n_i & ~soft_rst;

  // ---- loi
  wire         c_busy, c_done, c_key_vld, c_err, c_start, c_nsel;
  wire [1:0]   c_op;
  wire [15:0]  c_pt, c_ct, c_idx;
  wire [31:0]  c_ctr_used, c_ctr_live;
  wire [7:0]   d_steps, d_refills, d_rejects;
  wire [3:0]   d_state;

  // ---- FIFO / luong
  wire         in_wr, in_rd, in_full, in_empty, in_rvld;
  wire [16:0]  in_wdata, in_rdata;
  wire [6:0]   in_level;
  wire         out_wr, out_rd, out_full, out_empty, out_rvld;
  wire [31:0]  out_wdata, out_rdata;
  wire [OUT_AW:0] out_level_w;
  wire [11:0]  out_level = out_level_w;          // FIFO_LEVEL[15:0]
  wire         st_req, st_ack, st_busy, st_drop, st_push;
  wire [15:0]  st_pt;

  // ---- nguon mau
  wire         i2s_run, i2s_vld, fmt_vld, ts_vld;
  wire [23:0]  i2s_s24;
  wire [15:0]  fmt_s16, ts_s16;
  wire [31:0]  clip_cnt;
  wire         fmt_clip;
  wire         src_mic = (src_sel == 2'd0);
  wire         src_vld = src_mic ? fmt_vld : ts_vld;
  wire [15:0]  src_s16 = src_mic ? fmt_s16 : ts_s16;

  apb3_slave_regs u_regs (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i[7:0]), .pwdata_i(pwdata_i),
    .prdata_o(prdata_o), .pready_o(pready_o), .pslverr_o(pslverr_o),
    .soft_rst_o(soft_rst), .enable_o(enable), .reseed_o(reseed), .reg_start_o(reg_start), .reg_op_o(reg_op),
    .reg_nsel_o(reg_nsel), .reg_pt_o(reg_pt), .fifo_clr_o(fifo_clr), .key_clear_o(key_clear), .key_o(key),
    .ctr0_o(ctr0), .sck_div_o(sck_div), .channel_o(channel), .shift_o(shift), .src_sel_o(src_sel),
    .startup_skip_o(startup_skip), .clip_clr_o(clip_clr), .irq_o(irq_o),
    .out_rd_en_o(out_rd), .out_rd_data_i(out_rdata), .out_rd_vld_i(out_rvld), .out_empty_i(out_empty),
    .out_full_i(out_full), .out_level_i(out_level), .in_level_i(in_level),
    .core_busy_i(c_busy), .stream_busy_i(st_busy), .core_key_vld_i(c_key_vld), .core_err_i(c_err),
    .core_start_i(c_start), .core_done_i(c_done), .core_ct_i(c_ct), .core_ctr_live_i(c_ctr_live),
    .dbg_steps_i(d_steps), .dbg_refills_i(d_refills), .dbg_rejects_i(d_rejects), .dbg_state_i(d_state),
    .i2s_running_i(i2s_run), .drop_i(st_drop), .push_i(st_push), .clip_cnt_i(clip_cnt)
  );

  // ---- phan xu lenh vao loi
  assign st_ack  = st_req & ~c_busy & c_key_vld & ~reseed & ~key_clear;
  assign c_start = reg_start | st_ack;
  assign c_op    = st_req ? 2'b00 : reg_op;              // luong: luon ENC
  assign c_nsel  = st_req ? 1'b1  : reg_nsel;            // luong: luon N = 16
  assign c_pt    = st_req ? st_pt : reg_pt;

  chaos_core #(.RESEED_INTERVAL(RESEED_INTERVAL)) u_core (
    .clk_i(clk_i), .rst_n_i(rst_int_n),
    .start_i(c_start), .soft_rst_i(key_clear), .load_key_i(reseed), .op_i(c_op), .n_sel_i(c_nsel),
    .key_i(key), .ctr0_i(ctr0), .pt_in_i(c_pt),
    .busy_o(c_busy), .done_o(c_done), .key_vld_o(c_key_vld), .err_wd_o(c_err),
    .ct_out_o(c_ct), .ctr_out_o(c_ctr_used), .idx_out_o(c_idx),
    .dbg_steps_o(d_steps), .dbg_refills_o(d_refills), .dbg_rejects_o(d_rejects), .dbg_state_o(d_state),
    .dbg_evt_vld_o(), .dbg_evt_id_o(),
    .tap_ctr_o(c_ctr_live), .tap_ksess_o(), .tap_x0_o(), .tap_r_o(), .tap_xprev_o(), .tap_x_o(), .tap_k_o(),
    .tap_pi_o(), .tap_in_o(), .tap_sh_o(), .tap_res_o(), .tap_op_o(), .tap_nsel_o(), .tap_fy_rng_o(),
    .tap_fy_b_o(), .tap_fy_cand_o(), .tap_fy_acc_o(), .tap_fy_i_o(), .tap_fy_j_o()
  );

  // ---- nguon
  i2s_rx u_i2s (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .en_i(enable & src_mic), .sck_div_i(sck_div), .channel_i(channel),
    .startup_skip_i(startup_skip), .sd_i(i2s_sd_i), .sck_o(i2s_sck_o), .ws_o(i2s_ws_o), .running_o(i2s_run),
    .sample_o(i2s_s24), .sample_vld_o(i2s_vld)
  );

  sample_fmt #(.CW(32)) u_fmt (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .s24_i(i2s_s24), .vld_i(i2s_vld), .shift_i(shift), .clip_clr_i(clip_clr),
    .s16_o(fmt_s16), .vld_o(fmt_vld), .clip_o(fmt_clip), .clip_cnt_o(clip_cnt)
  );

  test_src u_tsrc (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .en_i(enable), .mode_i(src_sel), .sck_div_i(sck_div),
    .sample_o(ts_s16), .sample_vld_o(ts_vld)
  );

  // ---- luong va FIFO
  stream_seq u_seq (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .en_i(enable), .clr_i(fifo_clr), .abort_i(key_clear),
    .src_vld_i(src_vld), .src_data_i(src_s16),
    .in_full_i(in_full), .in_wr_en_o(in_wr), .in_wr_data_o(in_wdata),
    .in_empty_i(in_empty), .in_rd_en_o(in_rd), .in_rd_data_i(in_rdata), .in_rd_vld_i(in_rvld),
    .out_full_i(out_full), .out_wr_en_o(out_wr), .out_wr_data_o(out_wdata),
    .core_req_o(st_req), .core_pt_o(st_pt), .core_ack_i(st_ack), .core_done_i(c_done), .core_ct_i(c_ct),
    .core_ctr_i(c_ctr_used[7:0]), .core_idx_i(c_idx[5:0]),
    .drop_o(st_drop), .push_o(st_push), .busy_o(st_busy)
  );

  sync_fifo #(.DW(17), .AW(6)) u_in_fifo (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .clr_i(fifo_clr), .wr_en_i(in_wr), .wr_data_i(in_wdata), .rd_en_i(in_rd),
    .rd_data_o(in_rdata), .rd_vld_o(in_rvld), .full_o(in_full), .empty_o(in_empty), .level_o(in_level)
  );

  sync_fifo #(.DW(32), .AW(OUT_AW)) u_out_fifo (
    .clk_i(clk_i), .rst_n_i(rst_int_n), .clr_i(fifo_clr), .wr_en_i(out_wr), .wr_data_i(out_wdata), .rd_en_i(out_rd),
    .rd_data_o(out_rdata), .rd_vld_o(out_rvld), .full_o(out_full), .empty_o(out_empty), .level_o(out_level_w)
  );

  wire unused_sig = &{1'b0, fmt_clip, c_idx[15:6], c_ctr_used[31:8]};
endmodule
