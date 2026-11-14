// hmac_kdf.v - dan xuat tham so phien: K_session = HMAC-SHA256(K_master, "session" || ctr), roi tach X0, r_int.
// Verilog-2001 thuan. Bit-exact voi refmodel/kdf.py (cong thuc 4.3 - 4.6 cua SPEC 1.0.0).
//
//   K_session = HMAC-SHA256(K_master, 'session' || ctr)         ctr 32 bit, big-endian
//   (w1..w8)  = K_session cat 8 tu 32 bit, w1 la 4 byte dau (big-endian)
//   X0        = w1^w2^w3^w4 ;  neu X0 < 2 thi X0 = 2         (2 dong nay tinh trong kdf_params.v)
//   r_int     = 2^32 + (w5^w6^w7^w8)        (R_MIN = 1, R_SPAN = 1 => (2^32 * x) >> 32 = x)
//
// HMAC (FIPS 198-1) voi khoa 32 byte < 64 byte (khoi SHA-256): K0 = K_master || 32 byte 0.
//   khoi 1 = K0 ^ ipad (0x36)            first=1
//   khoi 2 = 'session' || ctr || 0x80 || 0... || do dai (64+11)*8 = 600 bit        first=0   -> inner
//   khoi 3 = K0 ^ opad (0x5c)            first=1
//   khoi 4 = inner(32 byte) || 0x80 || 0... || do dai (64+32)*8 = 768 bit          first=0   -> K_session
// 4 khoi x 66 chu ky = 264 chu ky cong them ~4 chu ky dieu khien (~2.7 us o 100 MHz). Chi chay 1 lan / 64 mau.
//
// Giao tiep:
//   start_i : xung 1 chu ky khi busy_o = 0; chot k_master_i va ctr_i luc do (khong can giu on dinh sau do).
//   done_o  : xung 1 chu ky; cung chu ky do k_session_o, x0_o, r_int_o hop le va giu den lan start_i ke tiep.
//   Thu tu byte: k_master_i[255:248] la byte dau tien cua khoa (chuoi hex cua kdf.csv doc tu trai sang phai).
module hmac_kdf (
  input  wire         clk_i,
  input  wire         rst_n_i,
  input  wire         start_i,
  input  wire [255:0] k_master_i,
  input  wire [31:0]  ctr_i,
  output wire         busy_o,
  output reg          done_o,
  output reg  [255:0] k_session_o,
  output reg  [31:0]  x0_o,
  output reg  [33:0]  r_int_o          // = {2'b01, w5^w6^w7^w8}; lts_step chi can r_int_o[31:0]
);
  localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1, S_WAIT = 2'd2;

  reg [1:0]   st_q;
  reg [1:0]   ph_q;                    // 0..3: khoi dang xu ly
  reg [255:0] key_q;
  reg [31:0]  ctr_q;
  reg [255:0] inner_q;

  // ---- loi SHA-256
  reg          sha_start;
  reg          sha_first;
  reg  [511:0] sha_blk;
  wire         sha_done;
  wire [255:0] sha_h;

  sha256_core u_sha (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .start_i(sha_start), .first_i(sha_first), .blk_i(sha_blk),
    .busy_o(), .done_o(sha_done), .h_o(sha_h)
  );

  // ---- 4 khoi (to hop theo ph_q)
  wire [511:0] k0     = {key_q, 256'd0};
  wire [511:0] ipad_b = k0 ^ {64{8'h36}};
  wire [511:0] opad_b = k0 ^ {64{8'h5c}};
  // 'session' = 73 65 73 73 69 6f 6e
  wire [511:0] msg_b  = {56'h73657373696f6e, ctr_q, 8'h80, 352'd0, 64'd600};
  wire [511:0] fin_b  = {inner_q, 8'h80, 184'd0, 64'd768};

  always @* begin
    case (ph_q)
      2'd0:    begin sha_blk = ipad_b; sha_first = 1'b1; end
      2'd1:    begin sha_blk = msg_b;  sha_first = 1'b0; end
      2'd2:    begin sha_blk = opad_b; sha_first = 1'b1; end
      default: begin sha_blk = fin_b;  sha_first = 1'b0; end
    endcase
    sha_start = (st_q == S_ISSUE);
  end

  // ---- tach tham so tu ket qua HMAC cuoi (sha_h tai chu ky sha_done o khoi 4)
  wire [31:0] x0_c;
  wire [33:0] r_int_c;
  kdf_params u_params (.k_session_i(sha_h), .x0_o(x0_c), .r_int_o(r_int_c));

  assign busy_o = (st_q != S_IDLE);

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      st_q   <= S_IDLE;
      ph_q   <= 2'd0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (st_q)
        S_IDLE: if (start_i) begin
          key_q <= k_master_i;
          ctr_q <= ctr_i;
          ph_q  <= 2'd0;
          st_q  <= S_ISSUE;
        end
        S_ISSUE: st_q <= S_WAIT;                      // sha_start = 1 trong chu ky nay
        S_WAIT: if (sha_done) begin
          if (ph_q == 2'd1) inner_q <= sha_h;
          if (ph_q == 2'd3) begin
            k_session_o <= sha_h;
            x0_o        <= x0_c;
            r_int_o     <= r_int_c;
            done_o      <= 1'b1;
            st_q        <= S_IDLE;
          end else begin
            ph_q <= ph_q + 2'd1;
            st_q <= S_ISSUE;
          end
        end
        default: st_q <= S_IDLE;
      endcase
    end
  end
endmodule

