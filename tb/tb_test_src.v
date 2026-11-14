// tb_test_src.v - doi chieu test_src.v voi tsrc_exp.hex (golden: refmodel/audio.py qua tools/gen_vec_batch6.py).
// Verilog-2001.
// Hai DUT cung kich thich: dut0 cau hinh that; dut1 RAMP_INIT = 0xFFF8 (kiem RAMP quay vong 0xFFFF -> 0) va
//   SINE_INC = 2^24 (moi mau sang 1 o -> quet ca 256 o bang sin; buoc 1 kHz chi di qua 125 o, toan chi so chan).
// Moi ca (tsrc_cfg.hex): tat, nap mode / SCK_DIV, bat, thu n mau va so voi golden. Kiem them:
//   - khoang cach hai mau = 128 * (div + 1) clk (div sau khi kep); mau dau ra trong vong 1 chu ky mau sau khi bat;
//   - hai DUT ra mau cung chu ky;
//   - mode 0 (MIC) / 3 (REG): khong co mau nao trong 5 chu ky mau;
//   - doi mode / SCK_DIV giua chung: khong co tac dung (nua sau van khop golden);
//   - en = 0: khong co sample_vld; bat lai thi RAMP / pha bat dau lai.
// Tham so: +GAP=0|1 (GAP=1: giu en = 0 lau hon giua cac ca va doi mode / SCK_DIV dau vao lien tuc luc dang chay).
`timescale 1ns/1ps
module tb_test_src;
  parameter NCASE = 16;
  parameter NEXP  = 4096;

  reg         clk, rst_n, en, mon_clr;
  reg  [1:0]  mode;
  reg  [11:0] div;
  wire [15:0] s0, s1;
  wire        v0, v1;

  test_src                           dut0 (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .mode_i(mode), .sck_div_i(div),
                                           .sample_o(s0), .sample_vld_o(v0));
  test_src #(.RAMP_INIT(16'hFFF8), .SINE_INC(32'h01000000))
                                     dut1 (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .mode_i(mode), .sck_div_i(div),
                                           .sample_o(s1), .sample_vld_o(v1));

  initial clk = 1'b0;
  always #10 clk = ~clk;

  reg [63:0] cfg [0:NCASE-1];
  reg [31:0] expv [0:NEXP-1];

  // ---- process chinh ghi
  integer gap, c, ncases, base, nexp, per, t, tmo, bad_main, total, seed;
  reg     c_ok;
  reg [2:0]  z3;
  reg [1:0]  c_mode, z2;
  reg [11:0] c_div, c_eff;
  reg [15:0] z16, c_n;

  // ---- monitor ghi
  integer cyc, ocnt, bad_mon, last_vld, en_cyc;
  reg     en_prev;

  always @(posedge clk) begin
    cyc = cyc + 1;
    if (en && !en_prev) en_cyc = cyc;
    if (mon_clr) begin
      ocnt = 0;
    end else begin
      if (v0 !== v1) begin
        bad_mon = bad_mon + 1;
        if (bad_mon <= 10) $display("SAI ca %0d: hai DUT ra mau lech chu ky", c);
      end
      if (v0 === 1'b1) begin
        if (!en_prev) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: co mau khi en = 0", c);
        end
        if (ocnt >= nexp) begin
          if (nexp == 0) begin
            bad_mon = bad_mon + 1;
            if (bad_mon <= 10) $display("SAI ca %0d: mode %0d phai im lang nhung co mau", c, c_mode);
          end
        end else begin
          if (s0 !== expv[base + ocnt][31:16] || s1 !== expv[base + ocnt][15:0]) begin
            bad_mon = bad_mon + 1;
            if (bad_mon <= 10) $display("SAI ca %0d mau %0d: RTL %h / %h, golden %h / %h", c, ocnt, s0, s1,
                                        expv[base + ocnt][31:16], expv[base + ocnt][15:0]);
          end
        end
        if (ocnt == 0 && cyc - en_cyc > per + 3) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: mau dau ra sau %0d clk (> 1 chu ky mau %0d)", c, cyc - en_cyc, per);
        end
        if (ocnt > 0 && cyc - last_vld != per) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: hai mau cach %0d clk, ky vong %0d", c, cyc - last_vld, per);
        end
        last_vld = cyc; ocnt = ocnt + 1;
      end
    end
    en_prev = en;
  end

  initial begin
    cyc = 0; ocnt = 0; bad_mon = 0; last_vld = 0; en_cyc = 0; en_prev = 1'b0;
    rst_n = 1'b0; en = 1'b0; mode = 2'd0; div = 12'd24; mon_clr = 1'b1;
    bad_main = 0; total = 0; base = 0; nexp = 0; per = 512; c = 0; c_mode = 2'd0; seed = 7;
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    for (c = 0; c < NCASE; c = c + 1) cfg[c] = 64'd0;
    $readmemh("tsrc_cfg.hex", cfg);
    $readmemh("tsrc_exp.hex", expv);
    ncases = 0;
    while (ncases < NCASE && cfg[ncases][63] == 1'b1) ncases = ncases + 1;

    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;

    base = 0;
    for (c = 0; c < ncases; c = c + 1) begin
      {c_ok, z3, c_mode, z2, c_div, c_eff, z16, c_n} = cfg[c];
      en = 1'b0;
      repeat ((gap != 0) ? 50 : 4) @(posedge clk);
      #1;
      mon_clr = 1'b1;
      mode = c_mode; div = c_div; nexp = c_n; per = 128 * (c_eff + 1);
      @(posedge clk); #1;
      mon_clr = 1'b0;
      en = 1'b1;
      if (c_n == 0) begin
        repeat (5 * per) @(posedge clk);
        #1;
      end else begin
        tmo = (c_n + 2) * per + 100;
        t = 0;
        while (ocnt < nexp && t < tmo) begin
          @(posedge clk); #1;
          t = t + 1;
          if (gap != 0 && ocnt > 0) begin
            mode = $random(seed); div = $random(seed);       // dang chay: dau vao rac, khong duoc anh huong
          end else if (ocnt == nexp / 2) begin
            mode = (c_mode == 2'd1) ? 2'd2 : 2'd1; div = 12'd5;
          end
        end
        if (ocnt < nexp) begin
          bad_main = bad_main + 1;
          $display("FAIL ca %0d: het thoi gian, moi nhan %0d/%0d mau", c, ocnt, nexp);
        end
      end
      total = total + c_n;
      base = base + c_n;
    end
    en = 1'b0;
    repeat (4) @(posedge clk);
    #1;
    if (ncases == 0)
      $display("LOI: khong doc duoc tsrc_cfg.hex");
    else if (bad_main + bad_mon == 0)
      $display("PASS: test_src khop golden (%0d ca, %0d mau x 2 DUT; RAMP + quay vong, SINE 1 kHz + du 256 o bang, nhip fs, im lang o MIC/REG, chot cau hinh) (GAP=%0d)",
               ncases, total, gap);
    else
      $display("FAIL: test_src %0d loi (GAP=%0d)", bad_main + bad_mon, gap);
    $finish;
  end
endmodule
