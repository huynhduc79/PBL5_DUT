// tb_session_mgr.v - kiem tra session_mgr.v voi cot ctr / idx cua cac bo vector golden. Verilog-2001.
//
// Ba phien ban tham so duoc kiem song song (moi cai co DUT rieng):
//   enc_n8_default.hex : RESEED_INTERVAL = 64, ctr0 = 0           (400 mau, 7 phien)
//   enc_ctrwrap.hex    : RESEED_INTERVAL = 4,  ctr0 = 0xFFFFFFFE  (ctr tran 2^32)
//   enc_reseed1.hex    : RESEED_INTERVAL = 1,  ctr0 = 0           (tai tao sau MOI mau)
// Moi dong hex (N = 8) = 120 bit: [119:88] ctr  [87:72] idx  ... (cac cot con lai khong dung o day).
// Kiem tra moi mau: ctr_out/idx_out = (ctr, idx) da DUNG (truoc cap nhat), reseed_due_o dung luc, kdf_ctr_o dung,
// reseed_due_o giu den kdf_start_i, ctr_ld_i xoa het. Tham so: +GAP=0|1 (GAP=1: nghi ngau nhien, du lieu rac).
`timescale 1ns/1ps
module sess_chk #(
  parameter RI    = 64,
  parameter CNT_W = 6,
  parameter ROWS  = 400,
  parameter [8*40-1:0] FILE = "enc_n8_default.hex"
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        go,
  input  wire [31:0] gap,
  output reg         done,
  output reg  [31:0] bad
);
  reg  [119:0] mem [0:1023];
  reg          ctr_ld, smp_done, kdf_start;
  reg  [31:0]  ctr0;
  wire         due;
  wire [31:0]  kctr, cout;
  wire [15:0]  iout;

  session_mgr #(.RESEED_INTERVAL(RI), .CNT_W(CNT_W)) dut (
    .clk_i(clk), .rst_n_i(rst_n), .ctr_ld_i(ctr_ld), .ctr0_i(ctr0), .smp_done_i(smp_done),
    .kdf_start_i(kdf_start), .reseed_due_o(due), .kdf_ctr_o(kctr), .ctr_out_o(cout), .idx_out_o(iout));

  integer r, k, seed, i;
  reg [8*40-1:0] fname;
  reg [31:0] e_ctr, n_ctr;
  reg [15:0] e_idx;
  reg        e_due;

  initial begin ctr_ld = 0; smp_done = 0; kdf_start = 0; ctr0 = 0; done = 0; bad = 0; end

  task err; input [8*40-1:0] msg; begin bad = bad + 1; if (bad <= 5) $display("SAI (RI=%0d): %0s  hang %0d", RI, msg, r + 1); end endtask

  task idle;                                 // nghi n chu ky (gap=1 thi dua rac vao cac ngo vao du lieu)
    input integer n;
    integer q;
    begin
      for (q = 0; q < n; q = q + 1) begin
        if (gap != 0) ctr0 = $random(seed);
        @(posedge clk); #1;
      end
    end
  endtask

  initial begin : main
    seed = RI + 5;
    for (i = 0; i < 1024; i = i + 1) mem[i] = 120'd0;
    fname = FILE;
    $readmemh(fname, mem);
    wait (go);
    @(posedge clk); #1;
    // nap ctr0 = ctr cua dong dau
    ctr0 = mem[0][119:88]; ctr_ld = 1'b1;
    @(posedge clk); #1; ctr_ld = 1'b0;
    if (kctr !== mem[0][119:88] || due !== 1'b0) begin r = -1; err("ctr_ld: kdf_ctr/due sai"); end

    for (r = 0; r < ROWS; r = r + 1) begin
      e_ctr = mem[r][119:88]; e_idx = mem[r][87:72];
      e_due = (e_idx == RI - 1);
      if (gap != 0) idle({$random(seed)} % 4);
      smp_done = 1'b1;                                   // chu ky 0
      @(posedge clk); #1; smp_done = 1'b0;
      if (cout !== e_ctr)  err("ctr_out sai");
      if (iout !== e_idx)  err("idx_out sai");
      if (due  !== e_due)  err("reseed_due sai");
      if (kctr !== (e_due ? e_ctr + 32'd1 : e_ctr)) err("kdf_ctr sai");
      if (e_due) begin
        if (r + 1 < ROWS && mem[r + 1][119:88] !== e_ctr + 32'd1) err("vector: ctr ke tiep khong = ctr + 1");
        k = (gap != 0) ? {$random(seed)} % 4 : 0;
        idle(k);
        if (due !== 1'b1) err("reseed_due khong giu den kdf_start");
        kdf_start = 1'b1; @(posedge clk); #1; kdf_start = 1'b0;
        if (due !== 1'b0) err("kdf_start khong xoa reseed_due");
        if (kctr !== e_ctr + 32'd1) err("kdf_ctr doi sau kdf_start");
      end else if (r + 1 < ROWS && mem[r + 1][119:88] !== e_ctr) err("vector: ctr thay doi giua phien");
    end

    // nap lai ctr0 khac giua chung: xoa cnt + due
    ctr0 = 32'hDEADBEEF; ctr_ld = 1'b1; @(posedge clk); #1; ctr_ld = 1'b0;
    if (kctr !== 32'hDEADBEEF || due !== 1'b0) begin r = ROWS; err("ctr_ld lan 2 sai"); end
    smp_done = 1'b1; @(posedge clk); #1; smp_done = 1'b0;
    if (cout !== 32'hDEADBEEF || iout !== 16'd0) begin r = ROWS; err("sau ctr_ld: (ctr, idx) dau tien sai"); end
    done = 1'b1;
  end
endmodule

module tb_session_mgr;
  reg clk, rst_n, go;
  integer gap;
  wire d0, d1, d2;
  wire [31:0] b0, b1, b2;

  initial begin clk = 1'b0; rst_n = 1'b0; go = 1'b0; end
  always #5 clk = ~clk;

  sess_chk #(.RI(64), .CNT_W(6), .ROWS(400), .FILE("enc_n8_default.hex")) c0 (.clk(clk), .rst_n(rst_n), .go(go), .gap(gap), .done(d0), .bad(b0));
  sess_chk #(.RI(4),  .CNT_W(2), .ROWS(24),  .FILE("enc_ctrwrap.hex"))    c1 (.clk(clk), .rst_n(rst_n), .go(go), .gap(gap), .done(d1), .bad(b1));
  sess_chk #(.RI(1),  .CNT_W(1), .ROWS(40),  .FILE("enc_reseed1.hex"))    c2 (.clk(clk), .rst_n(rst_n), .go(go), .gap(gap), .done(d2), .bad(b2));

  initial begin
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk); #1 go = 1'b1;
    wait (d0 && d1 && d2);
    @(posedge clk);
    if (b0 + b1 + b2 == 0) $display("PASS: session_mgr khop golden (RI=64: 400 mau, RI=4: 24 mau co ctr tran, RI=1: 40 mau, GAP=%0d)", gap);
    else                   $display("FAIL: %0d loi (RI=64: %0d, RI=4: %0d, RI=1: %0d) (GAP=%0d)", b0 + b1 + b2, b0, b1, b2, gap);
    $finish;
  end
  initial begin #50000000; $display("FAIL: het gio (treo)"); $finish; end
endmodule