// tb_sync_fifo.v - doi chieu sync_fifo.v voi vector chu ky-chinh xac cua FifoModel (tools/gen_vec_batch5.py). Verilog-2001.
//
// Chay song song hai cau hinh dung trong thiet ke: AW=6 DW=16 (in_fifo, fifo_a6.hex) va AW=11 DW=32 (out_fifo, fifo_a11.hex).
// Moi dong hex 84 bit: [83] hop_le [81] clr [80] wr [79] rd [78:47] wd [46:35] level [34] full [33] empty [32] rd_vld [31:0] rd_data
// Moi chu ky kiem: level, full, empty, rd_vld; rd_data khi rd_vld = 1 (va phai GIU NGUYEN khi rd_vld = 0).
// Tham so: +GAP=0|1  (GAP=1: chen 1 chu ky nghi sau moi dong; trong khe do wr_en = rd_en = 0, wr_data la rac,
//                     trang thai phai dung yen va rd_vld = 0).
// File chua 2 module: fifo_chk (mot cau hinh) va tb_sync_fifo (top mo phong).
`timescale 1ns/1ps
module fifo_chk #(
  parameter DW      = 16,
  parameter AW      = 6,
  parameter MAXROWS = 20000,
  parameter FILE    = "fifo_a6.hex"
) (
  input  wire clk,
  input  wire go,
  output reg  done,
  output reg  [31:0] bad,
  output reg  [31:0] rows
);
  reg  [83:0]   mem [0:MAXROWS-1];
  reg           rst_n, clr, wr, rd;
  reg  [DW-1:0] wd;
  wire [DW-1:0] rdata;
  wire          rvld, full, empty;
  wire [AW:0]   lvl;

  sync_fifo #(.DW(DW), .AW(AW)) dut (
    .clk_i(clk), .rst_n_i(rst_n), .clr_i(clr), .wr_en_i(wr), .wr_data_i(wd), .rd_en_i(rd),
    .rd_data_o(rdata), .rd_vld_o(rvld), .full_o(full), .empty_o(empty), .level_o(lvl)
  );

  integer       i, gap, seed;
  reg           e_ok, e_clr, e_wr, e_rd, e_full, e_empty, e_rvld, z;
  reg  [31:0]   e_wd, e_rd_d;
  reg  [11:0]   e_lvl;
  reg  [DW-1:0] hold;
  reg  [AW:0]   lvl_hold;

  task chk;
    input integer line;
    input         ef, ee, ev;
    input [AW:0]  el;
    input [DW-1:0] ed;
    input         chk_data;
    begin
      if (lvl !== el || full !== ef || empty !== ee || rvld !== ev || (chk_data && rdata !== ed)) begin
        bad = bad + 1;
        if (bad <= 10)
          $display("SAI AW=%0d dong %0d: RTL lvl=%0d full=%b empty=%b vld=%b data=%h | golden lvl=%0d full=%b empty=%b vld=%b data=%h",
                   AW, line, lvl, full, empty, rvld, rdata, el, ef, ee, ev, ed);
      end
    end
  endtask

  initial begin
    done = 1'b0; bad = 0; rows = 0; seed = AW;
    rst_n = 1'b0; clr = 1'b0; wr = 1'b0; rd = 1'b0; wd = {DW{1'b0}};
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 84'd0;
    $readmemh(FILE, mem);
    while (rows < MAXROWS && mem[rows][83] == 1'b1) rows = rows + 1;
    wait (go === 1'b1);

    repeat (3) @(posedge clk);
    #1;
    if (lvl !== 0 || full !== 1'b0 || empty !== 1'b1 || rvld !== 1'b0) begin
      bad = bad + 1; $display("SAI AW=%0d: trang thai sau reset sai", AW);
    end
    rst_n = 1'b1;

    for (i = 0; i < rows; i = i + 1) begin
      {e_ok, z, e_clr, e_wr, e_rd, e_wd, e_lvl, e_full, e_empty, e_rvld, e_rd_d} = mem[i];
      clr = e_clr; wr = e_wr; rd = e_rd; wd = e_wd[DW-1:0];
      hold = rdata;
      @(posedge clk); #1;
      chk(i + 1, e_full, e_empty, e_rvld, e_lvl[AW:0], e_rvld ? e_rd_d[DW-1:0] : hold, 1'b1);
      if (gap != 0) begin
        clr = 1'b0; wr = 1'b0; rd = 1'b0; wd = $random(seed);
        hold = rdata; lvl_hold = lvl;
        @(posedge clk); #1;
        chk(i + 1, e_full, e_empty, 1'b0, lvl_hold, hold, 1'b1);
      end
    end
    clr = 1'b0; wr = 1'b0; rd = 1'b0;
    done = 1'b1;
  end
endmodule

module tb_sync_fifo;
  reg  clk, go;
  wire d6, d11;
  wire [31:0] b6, b11, r6, r11;
  integer gap;

  initial begin clk = 1'b0; go = 1'b0; end
  always #10 clk = ~clk;                               // 50 MHz

  fifo_chk #(.DW(16), .AW(6),  .MAXROWS(8192),  .FILE("fifo_a6.hex"))  c6  (.clk(clk), .go(go), .done(d6),  .bad(b6),  .rows(r6));
  fifo_chk #(.DW(32), .AW(11), .MAXROWS(32768), .FILE("fifo_a11.hex")) c11 (.clk(clk), .go(go), .done(d11), .bad(b11), .rows(r11));

  initial begin
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    #1 go = 1'b1;
    wait (d6 === 1'b1 && d11 === 1'b1);
    #1;
    if (r6 == 0 || r11 == 0)
      $display("LOI: khong doc duoc fifo_a6.hex / fifo_a11.hex (%0d / %0d dong)", r6, r11);
    else if (b6 == 0 && b11 == 0)
      $display("PASS: sync_fifo khop golden (64x16: %0d chu ky, 2048x32: %0d chu ky; level, full, empty, rd_vld, rd_data) (GAP=%0d)",
               r6, r11, gap);
    else
      $display("FAIL: sync_fifo %0d loi (64x16) + %0d loi (2048x32) (GAP=%0d)", b6, b11, gap);
    $finish;
  end
endmodule
