// tb_sha256_core.v - kiem tra sha256_core.v. Verilog-2001.
//
// Nguon vector: sha256_blocks.hex (sinh boi tb/gen_sha256_vec.py, doi chieu hashlib).
// Moi dong = 770 bit: [769] valid  [768] first  [767:256] blk  [255:0] H sau khoi.
// Kiem tra: (1) H sau MOI khoi (ca khi xich khoi), (2) do tre dung 66 chu ky, (3) busy_o / done_o dung luc,
// (4) h_o giu nguyen khi nghi, (5) start_i / blk_i / first_i "rac" luc dang ban bi bo qua,
// (6) reset giua chung huy phep nen dang chay, (7) 3 vi du FIPS 180-4 viet cung trong TB (khong qua file hex).
// Tham so:  +HEX=<file> (mac dinh "sha256_blocks.hex")   +GAP=0|1
//           (GAP=0: start ngay chu ky done_o; GAP=1: nghi 0..3 chu ky + nhieu luc ban)
`timescale 1ns/1ps
module tb_sha256_core;
  parameter MAXROWS = 2048;
  parameter LAT     = 66;

  reg  [769:0] mem [0:MAXROWS-1];
  reg          clk, rst_n, start_i, first_i;
  reg  [511:0] blk_i;
  wire         busy_o, done_o;
  wire [255:0] h_o;

  sha256_core dut (.clk_i(clk), .rst_n_i(rst_n), .start_i(start_i), .first_i(first_i), .blk_i(blk_i),
                   .busy_o(busy_o), .done_o(done_o), .h_o(h_o));

  initial begin clk = 1'b0; rst_n = 1'b0; start_i = 1'b0; first_i = 1'b0; blk_i = 512'd0; end
  always #5 clk = ~clk;

  // 3 vi du FIPS 180-4 / NIST (gia tri ghi cung, khong lay tu file)
  localparam [255:0] KAT_ABC   = 256'hba7816bf_8f01cfea_414140de_5dae2223_b00361a3_96177a9c_b410ff61_f20015ad;
  localparam [255:0] KAT_EMPTY = 256'he3b0c442_98fc1c14_9afbf4c8_996fb924_27ae41e4_649b934c_a495991b_7852b855;
  localparam [255:0] KAT_448   = 256'h248d6a61_d20638b8_e5c02693_0c3e6039_a33ce459_64ff2167_f6ecedd4_19db06c1;

  reg [8*256-1:0] path;
  integer gap, rows, bad, nblk, r, cyc, k, i, seed;
  reg           v_f, f_f;
  reg [511:0]   b_f;
  reg [255:0]   e_f;

  task junk_inputs;                       // du lieu rac tren cong vao luc dang ban
    begin
      blk_i   = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed), $random(seed),
                 $random(seed), $random(seed), $random(seed), $random(seed), $random(seed), $random(seed),
                 $random(seed), $random(seed), $random(seed), $random(seed)};
      first_i = $random(seed);
      start_i = (gap != 0) && ($random(seed) & 1);
    end
  endtask

  // chay mot khoi; vao task ngay sau canh len + #1 (cac ngo vao duoc doi luc nay)
  task run_block;
    input integer row;
    begin
      {v_f, f_f, b_f, e_f} = mem[row];
      start_i = 1'b1; first_i = f_f; blk_i = b_f;                       // chu ky 0
      @(posedge clk); #1;
      start_i = 1'b0;
      cyc = 1;
      while (!done_o && cyc < LAT + 20) begin
        if (busy_o !== 1'b1) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: busy_o != 1 o chu ky %0d", row + 1, cyc); end
        junk_inputs;
        @(posedge clk); #1;
        cyc = cyc + 1;
      end
      start_i = 1'b0;
      if (cyc != LAT) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: done_o o chu ky %0d, ky vong %0d", row + 1, cyc, LAT); end
      if (busy_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: dong %0d: busy_o != 0 khi done_o", row + 1); end
      if (h_o !== e_f) begin
        bad = bad + 1;
        if (bad <= 10) $display("SAI: dong %0d (first=%0b): RTL %064h | ky vong %064h", row + 1, f_f, h_o, e_f);
      end
      nblk = nblk + 1;
      // KAT viet cung: dong 0 = "abc", 1 = rong, 3 = thong diep 448 bit
      if (row == 0 && h_o !== KAT_ABC)   begin bad = bad + 1; $display("SAI: KAT 'abc' sai"); end
      if (row == 1 && h_o !== KAT_EMPTY) begin bad = bad + 1; $display("SAI: KAT thong diep rong sai"); end
      if (row == 3 && h_o !== KAT_448)   begin bad = bad + 1; $display("SAI: KAT 448 bit sai"); end
    end
  endtask

  initial begin
    seed = 7;
    if (!$value$plusargs("HEX=%s", path)) path = "sha256_blocks.hex";
    if (!$value$plusargs("GAP=%d", gap))  gap  = 0;
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 770'd0;
    $readmemh(path, mem);
    rows = 0;
    while (rows < MAXROWS && mem[rows][769]) rows = rows + 1;
    bad = 0; nblk = 0;

    // ---- reset ban dau
    repeat (3) @(posedge clk);
    #1; if (busy_o !== 1'b0 || done_o !== 1'b0) begin bad = bad + 1; $display("SAI: busy_o/done_o != 0 trong reset"); end
    rst_n = 1'b1;
    @(posedge clk); #1;

    // ---- reset giua chung: huy phep nen, khong duoc phat done_o
    {v_f, f_f, b_f, e_f} = mem[0];
    start_i = 1'b1; first_i = f_f; blk_i = b_f;
    @(posedge clk); #1; start_i = 1'b0;
    repeat (20) @(posedge clk);
    #1; rst_n = 1'b0;
    @(posedge clk); #1;
    if (busy_o !== 1'b0 || done_o !== 1'b0) begin bad = bad + 1; $display("SAI: reset giua chung khong dua busy_o/done_o ve 0"); end
    rst_n = 1'b1;
    for (k = 0; k < LAT + 10; k = k + 1) begin
      @(posedge clk); #1;
      if (done_o !== 1'b0 || busy_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: done_o/busy_o xuat hien sau khi huy bang reset"); end
    end

    // ---- cac khoi
    for (r = 0; r < rows; r = r + 1) begin
      run_block(r);
      if (gap != 0) begin                              // nghi 0..3 chu ky: h_o phai giu, done_o chi 1 chu ky
        k = {$random(seed)} % 4;
        start_i = 1'b0;
        repeat (k) begin
          @(posedge clk); #1;
          if (done_o !== 1'b0 || busy_o !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI: done_o keo dai hon 1 chu ky hoac busy_o != 0 luc nghi"); end
          if (h_o !== e_f) begin bad = bad + 1; if (bad <= 10) $display("SAI: h_o thay doi luc nghi"); end
        end
      end
    end

    if (rows == 0)                 $display("LOI: khong doc duoc vector tu %0s", path);
    else if (nblk != rows)         $display("FAIL: chi kiem %0d/%0d khoi", nblk, rows);
    else if (bad == 0)             $display("PASS: %0d/%0d khoi khop (GAP=%0d, tre %0d chu ky, 3 KAT FIPS, reset giua chung)", nblk, rows, gap, LAT);
    else                           $display("FAIL: %0d loi trong %0d khoi (GAP=%0d)", bad, rows, gap);
    $finish;
  end
endmodule
