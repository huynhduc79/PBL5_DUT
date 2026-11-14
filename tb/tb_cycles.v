// tb_cycles.v - do so chu ky moi mau cua chaos_core voi N=16, RESEED_INTERVAL=64.
// Muc dich: kiem tra ngan sach thoi gian cho ung dung ghi am (fs = 15625 Hz, clk 50 MHz => 3200 chu ky/mau).
`timescale 1ns/1ps
module tb_cycles;
  reg clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  reg         start = 1'b0, soft_rst = 1'b0, load_key = 1'b0;
  reg [1:0]   op = 2'b00;
  reg         n_sel = 1'b1;              // N = 16
  reg [255:0] key = 256'h0001020304050607_08090a0b0c0d0e0f_1011121314151617_18191a1b1c1d1e1f;
  reg [31:0]  ctr0 = 32'd0;
  reg [15:0]  pt = 16'h1234;

  wire busy, done, key_vld, err_wd;
  wire [15:0] ct, idx;
  wire [31:0] ctr;
  wire [7:0]  dsteps, drefills, drejects;
  wire [3:0]  dstate, devt;
  wire        devt_vld;

  chaos_core #(.RESEED_INTERVAL(64)) u (
    .clk_i(clk), .rst_n_i(rst_n),
    .start_i(start), .soft_rst_i(soft_rst), .load_key_i(load_key),
    .op_i(op), .n_sel_i(n_sel), .key_i(key), .ctr0_i(ctr0), .pt_in_i(pt),
    .busy_o(busy), .done_o(done), .key_vld_o(key_vld), .err_wd_o(err_wd),
    .ct_out_o(ct), .ctr_out_o(ctr), .idx_out_o(idx),
    .dbg_steps_o(dsteps), .dbg_refills_o(drefills), .dbg_rejects_o(drejects),
    .dbg_state_o(dstate), .dbg_evt_vld_o(devt_vld), .dbg_evt_id_o(devt),
    .tap_ctr_o(), .tap_ksess_o(), .tap_x0_o(), .tap_r_o(), .tap_xprev_o(), .tap_x_o(),
    .tap_k_o(), .tap_pi_o(), .tap_in_o(), .tap_sh_o(), .tap_res_o(), .tap_op_o(),
    .tap_nsel_o(), .tap_fy_rng_o(), .tap_fy_b_o(), .tap_fy_cand_o(), .tap_fy_acc_o(),
    .tap_fy_i_o(), .tap_fy_j_o()
  );

  integer n_cyc;
  integer i;
  integer cmin, cmax, csum;
  integer cmin_nr, cmax_nr, csum_nr, n_nr;   // mau khong reseed
  integer cmax_r, n_r;                       // mau co reseed
  reg     saw_reseed;

  task tick; begin @(posedge clk); #1; end endtask

  // dem chu ky tu khi dat start den khi done, va ghi nhan co su kien RESEED_HMAC hay khong
  task do_sample; begin
    start = 1'b1; tick; start = 1'b0;
    n_cyc = 0; saw_reseed = 1'b0;
    while (!done) begin
      if (devt_vld && devt == 4'd1) saw_reseed = 1'b1;
      tick; n_cyc = n_cyc + 1;
    end
    if (devt_vld && devt == 4'd1) saw_reseed = 1'b1;
  end endtask

  initial begin
    cmin = 1000000; cmax = 0; csum = 0;
    cmin_nr = 1000000; cmax_nr = 0; csum_nr = 0; n_nr = 0;
    cmax_r = 0; n_r = 0;

    tick; tick; rst_n = 1'b1; tick; tick;
    load_key = 1'b1; tick; load_key = 1'b0;
    while (!key_vld) tick;

    for (i = 0; i < 200; i = i + 1) begin
      pt = pt + 16'h1111;
      do_sample;
      csum = csum + n_cyc;
      if (n_cyc < cmin) cmin = n_cyc;
      if (n_cyc > cmax) cmax = n_cyc;
      if (saw_reseed) begin
        n_r = n_r + 1;
        if (n_cyc > cmax_r) cmax_r = n_cyc;
      end else begin
        n_nr = n_nr + 1;
        csum_nr = csum_nr + n_cyc;
        if (n_cyc < cmin_nr) cmin_nr = n_cyc;
        if (n_cyc > cmax_nr) cmax_nr = n_cyc;
      end
      tick;
    end

    $display("N=16 RI=64, %0d mau:", 200);
    $display("  tat ca      : min=%0d  max=%0d  tb=%0d", cmin, cmax, csum / 200);
    $display("  khong reseed: min=%0d  max=%0d  tb=%0d  (%0d mau)", cmin_nr, cmax_nr, csum_nr / n_nr, n_nr);
    $display("  co reseed   : max=%0d  (%0d mau)", cmax_r, n_r);
    $display("  ngan sach 50MHz/15625Hz = 3200 chu ky => dung %0d%% (xau nhat)", (cmax * 100) / 3200);
    $finish;
  end
endmodule
