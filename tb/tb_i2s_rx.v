// tb_i2s_rx.v - kiem i2s_rx.v voi mo hinh micro INMP441 (chuan I2S Philips). Verilog-2001.
//
// Mo hinh inmp441_model dong vai HAI micro chung mot day SD (mot cai L/R = GND, mot cai L/R = VDD):
//   - Lay mau WS o canh len SCK; khi WS doi thi nap tu ke tiep cua kenh do tu i2s_frames.hex
//     (bo dem rieng cho trai / phai), roi phat MSB o canh xuong SCK KE TIEP (tre 1 SCK), 24 bit, MSB truoc.
//   - SD doi sau canh xuong SCK mot khoang DLY ns. Ngoai 24 bit du lieu (khe 0, 25..31) day SD la RAC (LFSR),
//     thay cho trang thai tro khang cao - de bat loi doc thua bit / lech 1 SCK.
//   Nho vay testbench bat duoc ca hai loi I2S kinh dien: tre 1 SCK (lech bit) va sai kenh.
// Kiem tra: tung mau s24 == i2s_exp.hex (golden: tools/gen_vec_batch5.py); chu ky SCK = 2*(div+1) clk, muc cao = div+1;
//   WS chi doi o canh xuong SCK, moi 32 SCK; khoang cach hai mau = 128*(div+1) clk; running_o; khi en = 0 thi
//   SCK = WS = running = sample_vld = 0.  div = SCK_DIV sau khi kep (>= 3).
// Tham so: +GAP=0|1
//   GAP=0: micro "that": SD doi 15 ns sau canh xuong va giu nguyen ca chu ky SCK.
//   GAP=1: cua so du lieu hep - kiem DUNG thoi diem lay mau. SD chi dung trong WIN = 15 ns, tu 5 ns truoc den 10 ns sau
//          thoi diem t_s = canh xuong + 20*(div-1) ns; ngoai cua so do SD bi DAO bit. t_s chinh la canh clk ma tang dong bo
//          thu nhat chup SD de dung o canh len SCK (canh len = canh xuong + 20*(div+1), tru 2 tang x 20 ns).
//          Ban lay mau o canh xuong, hay doi so tang dong bo, se sai o che do nay.
// File chua 2 module: inmp441_model va tb_i2s_rx (top mo phong).
`timescale 1ns/1ps
module inmp441_model #(
  parameter NF = 400
) (
  input  wire        sck,
  input  wire        ws,
  input  wire        restart,
  input  wire [31:0] dly,
  input  wire [31:0] win,
  output reg         sd
);
  reg [47:0] fr [0:NF-1];
  reg        ws_s, act, nx, ev;
  reg [23:0] word;
  reg [31:0] li, ri;
  reg [7:0]  ld_cnt, ld_seen;
  reg [4:0]  bp;
  reg [15:0] lfsr;

  initial begin
    $readmemh("i2s_frames.hex", fr);
    sd = 1'b0; nx = 1'b0; ev = 1'b0;
  end

  // canh len SCK: lay mau WS, phat hien doi kenh, nap tu moi
  always @(posedge sck or posedge restart) begin
    if (restart) begin
      ws_s <= 1'b0; li <= 0; ri <= 0; ld_cnt <= 8'd0; word <= 24'd0;
    end else begin
      ws_s <= ws;
      if (ws != ws_s) begin
        word   <= ws ? fr[ri % NF][23:0] : fr[li % NF][47:24];
        if (ws) ri <= ri + 1; else li <= li + 1;
        ld_cnt <= ld_cnt + 8'd1;
      end
    end
  end

  // canh xuong SCK: chon bit ke tiep (du lieu hoac rac)
  always @(negedge sck or posedge restart) begin
    if (restart) begin
      ld_seen <= 8'd0; act <= 1'b0; bp <= 5'd0; lfsr <= 16'hACE1;
    end else begin
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      if (ld_cnt != ld_seen) begin
        ld_seen <= ld_cnt; nx <= word[23]; bp <= 5'd22; act <= 1'b1;
      end else if (act) begin
        nx <= word[bp];
        if (bp == 5'd0) act <= 1'b0; else bp <= bp - 5'd1;
      end else begin
        nx <= lfsr[0];
      end
      ev <= ~ev;
    end
  end

  // tre ra chan SD; win != 0: chi giu bit dung trong win ns roi dao bit (cua so du lieu hep)
  always @(ev) begin
    #(dly);
    sd = nx;
    if (win != 0) begin
      #(win);
      sd = ~nx;
    end
  end
endmodule

module tb_i2s_rx;
  parameter NCASE = 8;
  parameter NEXP  = 1024;

  reg         clk, rst_n, en, ch, restart, mon_clr;
  reg  [11:0] div;
  reg  [31:0] skip, dly, win;
  wire        sck, ws, sd, running, vld;
  wire [23:0] smp;

  i2s_rx dut (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .sck_div_i(div), .channel_i(ch), .startup_skip_i(skip),
              .sd_i(sd), .sck_o(sck), .ws_o(ws), .running_o(running), .sample_o(smp), .sample_vld_o(vld));
  inmp441_model mic (.sck(sck), .ws(ws), .restart(restart), .dly(dly), .win(win), .sd(sd));

  initial begin clk = 1'b0; end
  always #10 clk = ~clk;                               // 50 MHz

  reg [79:0] cfg [0:NCASE-1];
  reg [23:0] expv [0:NEXP-1];

  // ---- bien do process chinh ghi (monitor chi doc)
  integer gap, c, base, nexp, eff, t, tmo, bad_main, ncases, total;
  reg     c_ok;
  reg [2:0] z3a, z3b;
  reg [11:0] c_div, c_eff;
  reg        c_ch;
  reg [31:0] c_skip;
  reg [15:0] c_n;

  // ---- bien do monitor ghi (process chinh chi doc)
  integer cyc, ocnt, bad_mon, nrise, nws, falls, last_rise, last_vld, have_vld;
  reg     prev_sck, prev_ws, en_prev;

  always @(posedge clk) begin
    cyc = cyc + 1;
    if (mon_clr) begin
      ocnt = 0; nrise = 0; nws = 0; falls = 0; have_vld = 0; prev_sck = 1'b0; prev_ws = 1'b0;
    end else if (!en_prev) begin
      if (sck !== 1'b0 || ws !== 1'b0 || running !== 1'b0 || vld !== 1'b0) begin
        bad_mon = bad_mon + 1;
        if (bad_mon <= 10) $display("SAI ca %0d: en = 0 nhung sck=%b ws=%b running=%b vld=%b", c, sck, ws, running, vld);
      end
      prev_sck = sck; prev_ws = ws;
    end else begin
      // SCK
      if (!prev_sck && sck) begin
        if (nrise > 0 && cyc - last_rise != 2 * (eff + 1)) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: chu ky SCK = %0d clk, ky vong %0d", c, cyc - last_rise, 2 * (eff + 1));
        end
        last_rise = cyc; nrise = nrise + 1;
      end
      if (prev_sck && !sck) begin
        falls = falls + 1;
        if (cyc - last_rise != eff + 1) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: SCK muc cao %0d clk, ky vong %0d", c, cyc - last_rise, eff + 1);
        end
      end
      // WS
      if (ws !== prev_ws) begin
        if (nws > 0 && !(prev_sck && !sck)) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: WS doi khong o canh xuong SCK", c);
        end
        if (nws > 0 && falls != 32) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: WS doi sau %0d SCK, ky vong 32", c, falls);
        end
        if (nws == 0 && ws !== 1'b1) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: khe dau tien phai la nua phai (WS = 1)", c);
        end
        nws = nws + 1; falls = 0;
      end
      // mau
      if (vld) begin
        if (ocnt < nexp) begin
          if (smp !== expv[base + ocnt]) begin
            bad_mon = bad_mon + 1;
            if (bad_mon <= 10) $display("SAI ca %0d mau %0d: RTL %06h, golden %06h", c, ocnt, smp, expv[base + ocnt]);
          end
        end
        if (have_vld && cyc - last_vld != 128 * (eff + 1)) begin
          bad_mon = bad_mon + 1;
          if (bad_mon <= 10) $display("SAI ca %0d: hai mau cach %0d clk, ky vong %0d", c, cyc - last_vld, 128 * (eff + 1));
        end
        have_vld = 1; last_vld = cyc; ocnt = ocnt + 1;
      end
      prev_sck = sck; prev_ws = ws;
    end
    en_prev = en;
  end

  initial begin
    cyc = 0; ocnt = 0; bad_mon = 0; nrise = 0; nws = 0; falls = 0; last_rise = 0; last_vld = 0; have_vld = 0;
    prev_sck = 1'b0; prev_ws = 1'b0; en_prev = 1'b0;
    rst_n = 1'b0; en = 1'b0; ch = 1'b0; div = 12'd24; skip = 32'd0; dly = 32'd15; win = 32'd0; restart = 1'b1; mon_clr = 1'b1;
    bad_main = 0; total = 0; base = 0; nexp = 0; eff = 3; c = 0;
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    for (c = 0; c < NCASE; c = c + 1) cfg[c] = 80'd0;
    $readmemh("i2s_cfg.hex", cfg);
    $readmemh("i2s_exp.hex", expv);
    ncases = 0;
    while (ncases < NCASE && cfg[ncases][79] == 1'b1) ncases = ncases + 1;

    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;

    base = 0;
    for (c = 0; c < ncases; c = c + 1) begin
      {c_ok, z3a, c_div, z3b, c_ch, c_eff, c_skip, c_n} = cfg[c];
      // dung han, dat lai micro va monitor, nap cau hinh
      en = 1'b0;
      repeat (4) @(posedge clk);
      #1;
      restart = 1'b1; mon_clr = 1'b1;
      div = c_div; ch = c_ch; skip = c_skip; nexp = c_n; eff = c_eff;
      dly = (gap != 0) ? (20 * (c_eff - 1) - 5) : 15;
      win = (gap != 0) ? 15 : 0;
      @(posedge clk); #1;
      restart = 1'b0; mon_clr = 1'b0;
      @(posedge clk); #1;
      en = 1'b1;
      tmo = (c_skip + c_n + 3) * 128 * (c_eff + 1) + 1000;
      t = 0;
      while (ocnt < nexp && t < tmo) begin
        @(posedge clk); #1;
        t = t + 1;
        if (t == 3 && running !== 1'b1) begin
          bad_main = bad_main + 1; $display("SAI ca %0d: running_o != 1 sau khi bat", c);
        end
        // doi cau hinh dau vao giua chung: khong duoc co tac dung (da chot luc bat) - nua sau van phai khop golden
        if (ocnt == nexp / 2) begin div = 12'd5; ch = ~c_ch; skip = 32'd0; end
      end
      if (ocnt < nexp) begin
        bad_main = bad_main + 1;
        $display("FAIL ca %0d: het thoi gian, moi nhan %0d/%0d mau", c, ocnt, nexp);
      end
      total = total + nexp;
      base = base + nexp;
    end
    en = 1'b0;
    repeat (6) @(posedge clk);
    #1;
    if (ncases == 0)
      $display("LOI: khong doc duoc i2s_cfg.hex");
    else if (bad_main + bad_mon == 0)
      $display("PASS: i2s_rx khop golden (%0d ca, %0d mau, %0d chu ky clk; kenh, STARTUP_SKIP, kep SCK_DIV, chu ky SCK/WS/fs, tat/bat) (GAP=%0d)",
               ncases, total, cyc, gap);
    else
      $display("FAIL: i2s_rx %0d loi (GAP=%0d)", bad_main + bad_mon, gap);
    $finish;
  end
endmodule
