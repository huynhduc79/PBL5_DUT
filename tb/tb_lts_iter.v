// tb_lts_iter.v - kiem tra lts_iter.v voi chuoi buoc LTS that trich tu trace golden (lts_iter.hex). Verilog-2001.
// Moi dong hex = 130 bit (xem tb/gen_vec_batch2.py): [129:128] loai (0 nap, 1 buoc, 3 het)
//   nap : [127:96] x0  [95:64] xr          buoc: [127:96] x_vao  [31:0] x_ra
// Kiem tra: (1) sau nap, x_o = x0 ; (2) moi buoc: x_o truoc buoc = x_vao, x_o sau buoc = x_ra,
// (3) x_vld_o DUNG 4 chu ky sau step_en_i, dung 1 chu ky, busy_o = 1 o chu ky 1..3, (4) co the dat step_en_i ngay trong
// chu ky x_vld_o (GAP=0 chay lien tiep), (5) step_en_i / x_load_i luc ban bi bo qua (GAP=1).
// Tham so: +GAP=0|1
`timescale 1ns/1ps
module tb_lts_iter;
  parameter MAXROWS = 8192;
  parameter LAT     = 4;

  reg [129:0] mem [0:MAXROWS-1];
  reg         clk, rst_n, x_load, step_en;
  reg  [31:0] x0, xr;
  wire        busy, x_vld, gd;
  wire [31:0] x_o;

  lts_iter dut (.clk_i(clk), .rst_n_i(rst_n), .x_load_i(x_load), .x0_i(x0), .xr_i(xr), .step_en_i(step_en),
                .busy_o(busy), .x_vld_o(x_vld), .x_o(x_o), .guarded_o(gd));

  initial begin clk = 1'b0; rst_n = 1'b0; x_load = 1'b0; step_en = 1'b0; x0 = 0; xr = 0; end
  always #5 clk = ~clk;

  reg [8*256-1:0] path;
  integer gap, rows, bad, r, cyc, k, i, seed, nstep, nload, wait_n;
  reg [1:0]  ty;
  reg [31:0] a, b, d;
  reg        first_back2back;

  initial begin
    seed = 3;
    if (!$value$plusargs("HEX=%s", path)) path = "lts_iter.hex";
    if (!$value$plusargs("GAP=%d", gap))  gap  = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = {2'd3, 128'd0};
    $readmemh(path, mem);
    rows = 0;
    while (rows < MAXROWS && mem[rows][129:128] != 2'd3) rows = rows + 1;
    bad = 0; nstep = 0; nload = 0;

    repeat (3) @(posedge clk);
    #1; if (busy !== 1'b0 || x_vld !== 1'b0) begin bad = bad + 1; $display("SAI: busy/x_vld != 0 trong reset"); end
    rst_n = 1'b1;
    @(posedge clk); #1;

    for (r = 0; r < rows; r = r + 1) begin
      ty = mem[r][129:128]; a = mem[r][127:96]; b = mem[r][95:64]; d = mem[r][31:0];
      if (gap != 0) begin                       // nghi ngau nhien truoc moi thao tac
        wait_n = {$random(seed)} % 4;
        repeat (wait_n) begin x0 = $random(seed); xr = $random(seed); @(posedge clk); #1; end
      end
      if (ty == 2'd0) begin                     // nap phien moi
        x0 = a; xr = b; x_load = 1'b1;
        @(posedge clk); #1; x_load = 1'b0;
        x0 = $random(seed); xr = $random(seed);
        if (x_o !== a) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: sau nap x_o=%08h ky vong x0=%08h", r + 1, x_o, a); end
        nload = nload + 1;
      end else begin                            // mot buoc
        if (x_o !== a) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: x_o truoc buoc=%08h ky vong %08h", r + 1, x_o, a); end
        if (busy !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: busy_o != 0 luc ranh", r + 1); end
        step_en = 1'b1;                         // chu ky 0
        @(posedge clk); #1; step_en = 1'b0;
        cyc = 1;
        while (!x_vld && cyc < LAT + 10) begin
          if (busy !== 1'b1) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: busy_o != 1 o chu ky %0d", r + 1, cyc); end
          if (gap != 0) begin step_en = $random(seed); x_load = $random(seed); x0 = $random(seed); xr = $random(seed); end
          @(posedge clk); #1; step_en = 1'b0; x_load = 1'b0;
          cyc = cyc + 1;
        end
        if (cyc != LAT) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: x_vld_o o chu ky %0d, ky vong %0d", r + 1, cyc, LAT); end
        if (busy !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: busy_o != 0 khi x_vld_o", r + 1); end
        if (x_o !== d) begin
          bad = bad + 1;
          if (bad <= 10) $display("SAI dong %0d: x_vao=%08h | RTL x'=%08h | golden x'=%08h", r + 1, a, x_o, d);
        end
        nstep = nstep + 1;
        // GAP=0: de nguyen, vong ke tiep dat step_en_i ngay trong chu ky x_vld_o. GAP=1: kiem x_vld_o chi 1 chu ky.
        if (gap != 0) begin
          @(posedge clk); #1;
          if (x_vld !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI dong %0d: x_vld_o keo dai > 1 chu ky", r + 1); end
        end
      end
    end

    if (rows == 0)                       $display("LOI: khong doc duoc vector tu %0s", path);
    else if (bad == 0)                   $display("PASS: %0d buoc LTS + %0d lan nap khop golden (GAP=%0d, tre %0d chu ky)", nstep, nload, gap, LAT);
    else                                 $display("FAIL: %0d loi trong %0d dong (GAP=%0d)", bad, rows, gap);
    $finish;
  end
endmodule