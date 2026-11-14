// kdf_params.v - tach (X0, r_int) tu K_session, to hop thuan tuy (khong clock). Verilog-2001.
// Bit-exact voi refmodel/kdf.py: params_from_session_key (cong thuc 4.4 - 4.6, SPEC 1.0.0).
//
//   (w1..w8) = K_session cat 8 tu 32 bit, w1 = k_session_i[255:224] (4 byte dau, big-endian)
//   X0       = w1^w2^w3^w4 ; neu X0 < 2 thi X0 = 2         (bay-guard cua lts_step can X0 >= 2)
//   r_int    = 2^32 + (w5^w6^w7^w8)                          (R_MIN = 1, R_SPAN = 1, r thuoc [1,2))
module kdf_params (
  input  wire [255:0] k_session_i,
  output wire [31:0]  x0_o,
  output wire [33:0]  r_int_o        // = {2'b01, w5^w6^w7^w8}; lts_step chi can r_int_o[31:0]
);
  wire [31:0] w1 = k_session_i[255:224];
  wire [31:0] w2 = k_session_i[223:192];
  wire [31:0] w3 = k_session_i[191:160];
  wire [31:0] w4 = k_session_i[159:128];
  wire [31:0] w5 = k_session_i[127:96];
  wire [31:0] w6 = k_session_i[95:64];
  wire [31:0] w7 = k_session_i[63:32];
  wire [31:0] w8 = k_session_i[31:0];
  wire [31:0] x0_raw = w1 ^ w2 ^ w3 ^ w4;

  assign x0_o    = (x0_raw < 32'd2) ? 32'd2 : x0_raw;
  assign r_int_o = {2'b01, w5 ^ w6 ^ w7 ^ w8};
endmodule

