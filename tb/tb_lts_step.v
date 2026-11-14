// tb_lts_step.v - doi chieu lts_step.v (pipeline 3 tang) voi lts_step.hex cua golden model. Verilog-2001.
//
// Moi dong hex = 132 bit, cot dau o bit cao nhat (manifest.json -> tables.lts_step.layout):
//   [131:100] x_in  [99:66] r_int  [65:34] x0  [33:2] x_out  [1] branch  [0] guarded
// Kiem tra: (1) gia tri + branch + guarded cua tung dong, (2) do tre dung 3 chu ky, (3) vld_o bam theo vld_i.
// Tham so:  +HEX=<file hex> (mac dinh "lts_step.hex" trong thu muc dang chay mo phong)
//           +GAP=0|1  (GAP=1: chen 1 chu ky trong giua hai mau, dua du lieu rac vao khe do)
`timescale 1ns/1ps
module tb_lts_step;
  parameter MAXROWS = 8192;
  parameter LAT     = 3;

  reg [131:0] mem [0:MAXROWS-1];
  reg         clk, rst_n, vld_i;
  reg  [31:0] x_i, xr_i, x0_i;
  wire        vld_o, branch_o, guarded_o;
  wire [31:0] x_o;

  lts_step dut (.clk_i(clk), .rst_n_i(rst_n), .vld_i(vld_i), .x_i(x_i), .xr_i(xr_i), .x0_i(x0_i),
                .vld_o(vld_o), .x_o(x_o), .branch_o(branch_o), .guarded_o(guarded_o));

  initial begin clk = 1'b0; rst_n = 1'b0; vld_i = 1'b0; x_i = 0; xr_i = 0; x0_i = 0; end
  always #5 clk = ~clk;

  reg [8*256-1:0] path;
  integer gap, rows, bad, n, t, r_chk, i, seed;
  reg [31:0] e_x, e_x0, e_xo;
  reg [33:0] e_r;
  reg        e_br, e_gd, exp_vld;

  // chi so dong du lieu o khe thoi gian s (hoac -1 neu la khe trong)
  function integer slot_row;
    input integer s;
    begin
      if (gap == 0) slot_row = (s < rows) ? s : -1;
      else          slot_row = (((s % 2) == 0) && ((s / 2) < rows)) ? (s / 2) : -1;
    end
  endfunction

  task drive;
    input integer s;
    integer rr;
    begin
      rr = slot_row(s);
      if (rr >= 0) begin
        {x_i, e_r, x0_i, e_xo, e_br, e_gd} = mem[rr];
        xr_i  = e_r[31:0];
        vld_i = 1'b1;
      end else begin
        vld_i = 1'b0;                                  // khe trong: dua du lieu rac, RTL khong duoc dung toi
        x_i = $random(seed); xr_i = $random(seed); x0_i = $random(seed);
      end
    end
  endtask

  initial begin
    seed = 1;
    if (!$value$plusargs("HEX=%s", path)) path = "lts_step.hex";
    if (!$value$plusargs("GAP=%d", gap))  gap  = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 132'd0;
    $readmemh(path, mem);
    rows = 0;
    while (rows < MAXROWS && mem[rows][99:66] != 34'd0) rows = rows + 1;   // r_int = 0 khong hop le => het du lieu
    bad = 0; n = 0;

    // r_int phai co dang 2^32 + xr (r in [1,2)); vector hien tai luon thoa
    for (i = 0; i < rows; i = i + 1) if (mem[i][99:98] != 2'b01) begin
      bad = bad + 1; $display("SAI dong %0d: r_int[33:32] != 01 (ngoai dai r in [1,2))", i + 1);
    end

    // reset 3 chu ky, trong luc do vld_o phai = 0
    repeat (3) @(posedge clk);
    #1; if (vld_o !== 1'b0) begin bad = bad + 1; $display("SAI: vld_o != 0 trong reset"); end
    rst_n = 1'b1;
    drive(0);

    for (t = 1; t <= ((gap != 0) ? 2 * rows : rows) + LAT + 1; t = t + 1) begin
      @(posedge clk); #1;
      r_chk = (t - LAT >= 0) ? slot_row(t - LAT) : -1;
      exp_vld = (r_chk >= 0);
      if (vld_o !== exp_vld) begin
        bad = bad + 1;
        if (bad <= 10) $display("SAI t=%0d: vld_o=%b, ky vong %b", t, vld_o, exp_vld);
      end
      if (exp_vld) begin
        {e_x, e_r, e_x0, e_xo, e_br, e_gd} = mem[r_chk];
        if (x_o !== e_xo || branch_o !== e_br || guarded_o !== e_gd) begin
          bad = bad + 1;
          if (bad <= 10)
            $display("SAI dong %0d: x=%08h r=%09h x0=%08h | RTL x'=%08h br=%b gd=%b | golden x'=%08h br=%b gd=%b",
                     r_chk + 1, e_x, e_r, e_x0, x_o, branch_o, guarded_o, e_xo, e_br, e_gd);
        end
        n = n + 1;
      end
      drive(t);
    end

    if (rows == 0)      $display("LOI: khong doc duoc vector tu %0s", path);
    else if (n != rows) $display("FAIL: chi kiem %0d/%0d dong", n, rows);
    else if (bad == 0)  $display("PASS: %0d/%0d dong khop golden (GAP=%0d, tre %0d chu ky)", n, rows, gap, LAT);
    else                $display("FAIL: %0d loi trong %0d dong (GAP=%0d)", bad, rows, gap);
    $finish;
  end
endmodule
