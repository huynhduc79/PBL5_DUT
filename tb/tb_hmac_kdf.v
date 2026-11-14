// tb_hmac_kdf.v - kiem tra hmac_kdf.v (HMAC-SHA256 + kdf_params) voi kdf.hex cua golden. Verilog-2001.
// Moi dong hex = 610 bit: [609:354] k_master  [353:322] ctr  [321:66] k_session  [65:34] x0  [33:0] r_int
// Kiem tra: (1) k_session, x0, r_int cua tung dong, (2) do tre dung LAT chu ky tu start_i den done_o,
// (3) busy_o dung luc, done_o chi 1 chu ky, (4) dau ra giu nguyen den lan start ke tiep,
// (5) k_master_i / ctr_i doi SAU start khong anh huong (da chot), start_i luc ban bi bo qua (GAP=1),
// (6) reset giua chung huy phep tinh.
// Tham so: +HEX=<file> (mac dinh "kdf.hex")  +GAP=0|1
`timescale 1ns/1ps
module tb_hmac_kdf;
  parameter MAXROWS = 256;
  parameter LAT     = 269;        // start_i o chu ky 0 -> done_o o chu ky 269 (4 x 67 + 1)

  reg  [609:0] mem [0:MAXROWS-1];
  reg          clk, rst_n, start_i;
  reg  [255:0] k_master_i;
  reg  [31:0]  ctr_i;
  wire         busy_o, done_o;
  wire [255:0] k_session_o;
  wire [31:0]  x0_o;
  wire [33:0]  r_int_o;

  hmac_kdf dut (.clk_i(clk), .rst_n_i(rst_n), .start_i(start_i), .k_master_i(k_master_i), .ctr_i(ctr_i),
                .busy_o(busy_o), .done_o(done_o), .k_session_o(k_session_o), .x0_o(x0_o), .r_int_o(r_int_o));

  initial begin clk = 1'b0; rst_n = 1'b0; start_i = 1'b0; k_master_i = 256'd0; ctr_i = 32'd0; end
  always #5 clk = ~clk;

  reg [8*256-1:0] path;
  integer gap, rows, bad, nrun, r, cyc, k, i, seed;
  reg [255:0] e_km, e_ks;
  reg [31:0]  e_ctr, e_x0;
  reg [33:0]  e_r;

  task junk;                     // doi k_master_i / ctr_i va keo start_i bat ky luc dang ban
    begin
      k_master_i = {$random(seed), $random(seed), $random(seed), $random(seed),
                    $random(seed), $random(seed), $random(seed), $random(seed)};
      ctr_i      = $random(seed);
      start_i    = (gap != 0) && ($random(seed) & 1);
    end
  endtask

  task run_row;
    input integer row;
    begin
      {e_km, e_ctr, e_ks, e_x0, e_r} = mem[row];
      k_master_i = e_km; ctr_i = e_ctr; start_i = 1'b1;          // chu ky 0
      @(posedge clk); #1;
      start_i = 1'b0;
      if (gap != 0) junk; else begin k_master_i = ~e_km; ctr_i = ~e_ctr; end   // doi ngay sau start
      cyc = 1;
      while (!done_o && cyc < LAT + 30) begin
        if (busy_o !== 1'b1) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: busy_o != 1 o chu ky %0d", row + 1, cyc); end
        if (gap != 0) junk;
        @(posedge clk); #1;
        cyc = cyc + 1;
      end
      start_i = 1'b0;
      if (cyc != LAT) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: done_o o chu ky %0d, ky vong %0d", row + 1, cyc, LAT); end
      if (busy_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: busy_o != 0 khi done_o", row + 1); end
      if (k_session_o !== e_ks || x0_o !== e_x0 || r_int_o !== e_r) begin
        bad = bad + 1;
        if (bad <= 10) begin
          $display("SAI dong %0d: k_master=%064h ctr=%08h", row + 1, e_km, e_ctr);
          $display("     RTL    k_session=%064h x0=%08h r_int=%09h", k_session_o, x0_o, r_int_o);
          $display("     golden k_session=%064h x0=%08h r_int=%09h", e_ks, e_x0, e_r);
        end
      end
      nrun = nrun + 1;
      // sau done_o: dau ra giu nguyen, done_o ha xuong
      for (k = 0; k < ((gap != 0) ? 3 : 1); k = k + 1) begin
        start_i = 1'b0;
        @(posedge clk); #1;
        if (done_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: done_o keo dai hon 1 chu ky"); end
        if (k_session_o !== e_ks || x0_o !== e_x0 || r_int_o !== e_r) begin bad = bad + 1; if (bad <= 10) $display("SAI: dau ra thay doi luc nghi"); end
      end
    end
  endtask

  initial begin
    seed = 11;
    if (!$value$plusargs("HEX=%s", path)) path = "kdf.hex";
    if (!$value$plusargs("GAP=%d", gap))  gap  = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 610'd0;
    $readmemh(path, mem);
    rows = 0;
    while (rows < MAXROWS && mem[rows][33:0] != 34'd0) rows = rows + 1;
    bad = 0; nrun = 0;

    repeat (3) @(posedge clk);
    #1; if (busy_o !== 1'b0 || done_o !== 1'b0) begin bad = bad + 1; $display("SAI: busy_o/done_o != 0 trong reset"); end
    rst_n = 1'b1;
    @(posedge clk); #1;

    // reset giua chung: huy phep tinh, khong duoc phat done_o
    {e_km, e_ctr, e_ks, e_x0, e_r} = mem[0];
    k_master_i = e_km; ctr_i = e_ctr; start_i = 1'b1;
    @(posedge clk); #1; start_i = 1'b0;
    repeat (100) @(posedge clk);
    #1; rst_n = 1'b0;
    @(posedge clk); #1;
    if (busy_o !== 1'b0 || done_o !== 1'b0) begin bad = bad + 1; $display("SAI: reset giua chung khong dua busy_o/done_o ve 0"); end
    rst_n = 1'b1;
    for (k = 0; k < LAT + 20; k = k + 1) begin
      @(posedge clk); #1;
      if (done_o !== 1'b0 || busy_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: done_o/busy_o xuat hien sau khi huy bang reset"); end
    end

    for (r = 0; r < rows; r = r + 1) run_row(r);

    if (rows == 0)         $display("LOI: khong doc duoc vector tu %0s", path);
    else if (nrun != rows) $display("FAIL: chi kiem %0d/%0d dong", nrun, rows);
    else if (bad == 0)     $display("PASS: %0d/%0d dong khop golden (GAP=%0d, tre %0d chu ky, k_session + x0 + r_int)", nrun, rows, gap, LAT);
    else                   $display("FAIL: %0d loi trong %0d dong (GAP=%0d)", bad, rows, gap);
    $finish;
  end
endmodule
