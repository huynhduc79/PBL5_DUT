// tb_kdf_params.v - kiem tra kdf_params.v (to hop) voi kdf_words.hex. Verilog-2001.
// Moi dong hex = 322 bit: [321:66] k_session  [65:34] x0  [33:0] r_int  (manifest.json -> tables.kdf_words.layout)
// Gom ca ca bien: k_session toan 0 / toan 1 (X0 bi ep len 2), k_session co XOR(w1..w4) = 0 hoac 1, ...
// Tham so: +HEX=<file> (mac dinh "kdf_words.hex")
`timescale 1ns/1ps
module tb_kdf_params;
  parameter MAXROWS = 1024;
  reg  [321:0] mem [0:MAXROWS-1];
  reg  [255:0] ks;
  wire [31:0]  x0;
  wire [33:0]  r_int;
  kdf_params dut (.k_session_i(ks), .x0_o(x0), .r_int_o(r_int));

  reg [8*256-1:0] path;
  integer rows, bad, i;
  reg [255:0] e_ks;
  reg [31:0]  e_x0;
  reg [33:0]  e_r;

  initial begin
    if (!$value$plusargs("HEX=%s", path)) path = "kdf_words.hex";
    for (i = 0; i < MAXROWS; i = i + 1) mem[i] = 322'd0;
    $readmemh(path, mem);
    rows = 0;
    while (rows < MAXROWS && mem[rows][33:0] != 34'd0) rows = rows + 1;   // r_int = 0 khong hop le => het du lieu
    bad = 0;
    for (i = 0; i < rows; i = i + 1) begin
      {e_ks, e_x0, e_r} = mem[i];
      ks = e_ks; #1;
      if (x0 !== e_x0 || r_int !== e_r) begin
        bad = bad + 1;
        if (bad <= 10) $display("SAI dong %0d: k_session=%064h | RTL x0=%08h r_int=%09h | golden x0=%08h r_int=%09h",
                                i + 1, e_ks, x0, r_int, e_x0, e_r);
      end
    end
    if (rows == 0)     $display("LOI: khong doc duoc vector tu %0s", path);
    else if (bad == 0) $display("PASS: %0d/%0d dong khop golden (kdf_params)", rows, rows);
    else               $display("FAIL: %0d loi trong %0d dong", bad, rows);
    $finish;
  end
endmodule
