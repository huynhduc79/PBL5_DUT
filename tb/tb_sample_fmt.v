// tb_sample_fmt.v - doi chieu sample_fmt.v voi fmt_vec.hex (golden: refmodel/audio.py qua tools/gen_vec_batch6.py).
// Verilog-2001.
// Hai DUT chay cung kich thich: CW = 32 (cau hinh that) va CW = 4 (de kiem CLIP_CNT bao hoa, khong quay vong).
// Moi dong: dua 1 mau (vld = 1, kem clr neu co), sau canh kiem s16, clip, vld_o, CLIP_CNT cua ca hai DUT.
// Tham so: +GAP=0|1  (GAP=1: chen 1 chu ky vld = 0 voi s24 / shift rac; dau ra phai giu nguyen, vld_o = 0, dem dung yen).
`timescale 1ns/1ps
module tb_sample_fmt;
  parameter MAXROWS = 4096;

  reg         clk, rst_n, vld, clr;
  reg  [23:0] s24;
  reg  [3:0]  shift;
  wire [15:0] y32, y4;
  wire        v32, v4, c32, c4;
  wire [31:0] n32;
  wire [3:0]  n4;

  sample_fmt #(.CW(32)) dut (.clk_i(clk), .rst_n_i(rst_n), .s24_i(s24), .vld_i(vld), .shift_i(shift), .clip_clr_i(clr),
                             .s16_o(y32), .vld_o(v32), .clip_o(c32), .clip_cnt_o(n32));
  sample_fmt #(.CW(4))  dut4 (.clk_i(clk), .rst_n_i(rst_n), .s24_i(s24), .vld_i(vld), .shift_i(shift), .clip_clr_i(clr),
                              .s16_o(y4), .vld_o(v4), .clip_o(c4), .clip_cnt_o(n4));

  initial clk = 1'b0;
  always #10 clk = ~clk;

  reg  [83:0] mem [0:MAXROWS-1];
  integer     i, rows, bad, gap, seed;
  reg         e_ok, z, e_clr, e_clip;
  reg  [3:0]  e_sh, e_n4;
  reg  [23:0] e_s24;
  reg  [15:0] e_y, hold;
  reg  [31:0] e_n32, n32_hold;
  reg  [3:0]  n4_hold;

  initial begin
    bad = 0; rows = 0; seed = 6;
    rst_n = 1'b0; vld = 1'b0; clr = 1'b0; s24 = 24'd0; shift = 4'd0;
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 84'd0;
    $readmemh("fmt_vec.hex", mem);
    while (rows < MAXROWS && mem[rows][83] == 1'b1) rows = rows + 1;

    repeat (3) @(posedge clk);
    #1;
    if (v32 !== 1'b0 || n32 !== 32'd0 || n4 !== 4'd0) begin
      bad = bad + 1; $display("SAI: trang thai sau reset");
    end
    rst_n = 1'b1;

    for (i = 0; i < rows; i = i + 1) begin
      {e_ok, z, e_clr, e_clip, e_sh, e_s24, e_y, e_n32, e_n4} = mem[i];
      s24 = e_s24; shift = e_sh; clr = e_clr; vld = 1'b1;
      @(posedge clk); #1;
      if (v32 !== 1'b1 || y32 !== e_y || c32 !== e_clip || n32 !== e_n32 ||
          v4 !== 1'b1 || y4 !== e_y || c4 !== e_clip || n4 !== e_n4) begin
        bad = bad + 1;
        if (bad <= 10)
          $display("SAI dong %0d (shift=%0d s24=%h clr=%b): RTL s16=%h clip=%b cnt=%0d cnt4=%0d | golden s16=%h clip=%b cnt=%0d cnt4=%0d",
                   i + 1, e_sh, e_s24, e_clr, y32, c32, n32, n4, e_y, e_clip, e_n32, e_n4);
      end
      if (gap != 0) begin
        vld = 1'b0; clr = 1'b0; s24 = $random(seed); shift = $random(seed);
        hold = y32; n32_hold = n32; n4_hold = n4;
        @(posedge clk); #1;
        if (v32 !== 1'b0 || y32 !== hold || n32 !== n32_hold || n4 !== n4_hold || y4 !== hold) begin
          bad = bad + 1;
          if (bad <= 10) $display("SAI khe trong sau dong %0d: dau ra / bo dem thay doi khi vld = 0", i + 1);
        end
      end
    end
    vld = 1'b0; clr = 1'b0;
    @(posedge clk); #1;
    if (rows == 0)
      $display("LOI: khong doc duoc fmt_vec.hex");
    else if (bad == 0)
      $display("PASS: sample_fmt khop golden (%0d mau, SHIFT 0..15, bao hoa, CLIP_CNT 32 bit + bao hoa 4 bit, xoa) (GAP=%0d)",
               rows, gap);
    else
      $display("FAIL: sample_fmt %0d loi (GAP=%0d)", bad, gap);
    $finish;
  end
endmodule
