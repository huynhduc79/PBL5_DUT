// sha256_core.v - loi nen SHA-256 (FIPS 180-4), xu ly MOT khoi 512 bit moi lan, lap 1 vong/chu ky.
// Verilog-2001 thuan.
//
// Vai tro: khoi con cua hmac_kdf. Loi chi nen (compression) mot khoi; viec chen padding va noi cac khoi
// (HMAC: khoi ipad, khoi thong diep, khoi opad, khoi ket qua trong) do hmac_kdf dam nhiem.
//
// Giao tiep:
//   start_i  : xung 1 chu ky khi busy_o = 0; blk_i va first_i duoc chot tai canh len clk cua chu ky do.
//   first_i  : 1 = khoi dau cua thong diep (H bat dau tu IV); 0 = noi tiep H hien co (xich khoi).
//   blk_i    : khoi 512 bit theo thu tu byte big-endian: W0 = blk_i[511:480] ... W15 = blk_i[31:0].
//   done_o   : xung 1 chu ky khi nen xong; ngay luc do h_o = H0..H7 moi (H0 = h_o[255:224]) va giu nguyen
//              den lan start_i ke tiep. Co the dat start_i ngay trong chu ky done_o (busy_o = 0).
//   Do tre   : start_i o chu ky 0  ->  done_o o chu ky 66 (1 nap + 64 vong + 1 cong H).
//
// Cau truc: thanh ghi a..h, thanh ghi H, cua so 16 tu W (mot thanh ghi dich 512 bit, dich 32 bit moi chu ky,
// tu moi chen o duoi), bo dem vong t_q 0..63, bang hang K. Chi FSM va done_o co reset (dong bo, tich cuc thap).
module sha256_core (
  input  wire         clk_i,
  input  wire         rst_n_i,
  input  wire         start_i,
  input  wire         first_i,
  input  wire [511:0] blk_i,
  output wire         busy_o,
  output reg          done_o,
  output wire [255:0] h_o
);
  localparam [255:0] IV = 256'h6a09e667_bb67ae85_3c6ef372_a54ff53a_510e527f_9b05688c_1f83d9ab_5be0cd19;

  localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;

  // ---------------------------------------------------------------- ham SHA-256
  function [31:0] rotr;                     // quay phai n bit (n la hang so khi goi)
    input [31:0] x;
    input integer n;
    begin
      rotr = (x >> n) | (x << (32 - n));
    end
  endfunction

  function [31:0] ch;
    input [31:0] e, f, g;
    begin ch = (e & f) ^ (~e & g); end
  endfunction

  function [31:0] maj;
    input [31:0] a, b, c;
    begin maj = (a & b) ^ (a & c) ^ (b & c); end
  endfunction

  function [31:0] bsig0;
    input [31:0] x;
    begin bsig0 = rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22); end
  endfunction

  function [31:0] bsig1;
    input [31:0] x;
    begin bsig1 = rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25); end
  endfunction

  function [31:0] ssig0;
    input [31:0] x;
    begin ssig0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3); end
  endfunction

  function [31:0] ssig1;
    input [31:0] x;
    begin ssig1 = rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10); end
  endfunction

  // K[t]: 32 bit dau phan thap phan cua can bac 3 cua 64 so nguyen to dau tien (FIPS 180-4, muc 4.2.2)
  function [31:0] k_const;
    input [5:0] t;
    begin
      case (t)
      6'd0 : k_const = 32'h428a2f98;
      6'd1 : k_const = 32'h71374491;
      6'd2 : k_const = 32'hb5c0fbcf;
      6'd3 : k_const = 32'he9b5dba5;
      6'd4 : k_const = 32'h3956c25b;
      6'd5 : k_const = 32'h59f111f1;
      6'd6 : k_const = 32'h923f82a4;
      6'd7 : k_const = 32'hab1c5ed5;
      6'd8 : k_const = 32'hd807aa98;
      6'd9 : k_const = 32'h12835b01;
      6'd10: k_const = 32'h243185be;
      6'd11: k_const = 32'h550c7dc3;
      6'd12: k_const = 32'h72be5d74;
      6'd13: k_const = 32'h80deb1fe;
      6'd14: k_const = 32'h9bdc06a7;
      6'd15: k_const = 32'hc19bf174;
      6'd16: k_const = 32'he49b69c1;
      6'd17: k_const = 32'hefbe4786;
      6'd18: k_const = 32'h0fc19dc6;
      6'd19: k_const = 32'h240ca1cc;
      6'd20: k_const = 32'h2de92c6f;
      6'd21: k_const = 32'h4a7484aa;
      6'd22: k_const = 32'h5cb0a9dc;
      6'd23: k_const = 32'h76f988da;
      6'd24: k_const = 32'h983e5152;
      6'd25: k_const = 32'ha831c66d;
      6'd26: k_const = 32'hb00327c8;
      6'd27: k_const = 32'hbf597fc7;
      6'd28: k_const = 32'hc6e00bf3;
      6'd29: k_const = 32'hd5a79147;
      6'd30: k_const = 32'h06ca6351;
      6'd31: k_const = 32'h14292967;
      6'd32: k_const = 32'h27b70a85;
      6'd33: k_const = 32'h2e1b2138;
      6'd34: k_const = 32'h4d2c6dfc;
      6'd35: k_const = 32'h53380d13;
      6'd36: k_const = 32'h650a7354;
      6'd37: k_const = 32'h766a0abb;
      6'd38: k_const = 32'h81c2c92e;
      6'd39: k_const = 32'h92722c85;
      6'd40: k_const = 32'ha2bfe8a1;
      6'd41: k_const = 32'ha81a664b;
      6'd42: k_const = 32'hc24b8b70;
      6'd43: k_const = 32'hc76c51a3;
      6'd44: k_const = 32'hd192e819;
      6'd45: k_const = 32'hd6990624;
      6'd46: k_const = 32'hf40e3585;
      6'd47: k_const = 32'h106aa070;
      6'd48: k_const = 32'h19a4c116;
      6'd49: k_const = 32'h1e376c08;
      6'd50: k_const = 32'h2748774c;
      6'd51: k_const = 32'h34b0bcb5;
      6'd52: k_const = 32'h391c0cb3;
      6'd53: k_const = 32'h4ed8aa4a;
      6'd54: k_const = 32'h5b9cca4f;
      6'd55: k_const = 32'h682e6ff3;
      6'd56: k_const = 32'h748f82ee;
      6'd57: k_const = 32'h78a5636f;
      6'd58: k_const = 32'h84c87814;
      6'd59: k_const = 32'h8cc70208;
      6'd60: k_const = 32'h90befffa;
      6'd61: k_const = 32'ha4506ceb;
      6'd62: k_const = 32'hbef9a3f7;
      6'd63: k_const = 32'hc67178f2;
        default: k_const = 32'h0;
      endcase
    end
  endfunction

  // ---------------------------------------------------------------- trang thai
  reg [1:0]   st_q;
  reg [5:0]   t_q;
  reg [31:0]  a_q, b_q, c_q, d_q, e_q, f_q, g_q, h_q;     // bien lam viec a..h
  reg [255:0] hh_q;                                         // H0..H7 (gia tri chuoi)
  reg [511:0] w_q;                                          // cua so W_t .. W_(t+15); W_t o [511:480]

  assign busy_o = (st_q != S_IDLE);
  assign h_o    = hh_q;

  // ---------------------------------------------------------------- tinh toan 1 vong
  wire [31:0] w0   = w_q[511:480];       // W_t
  wire [31:0] w1   = w_q[479:448];       // W_(t+1)
  wire [31:0] w9   = w_q[223:192];       // W_(t+9)
  wire [31:0] w14  = w_q[63:32];         // W_(t+14)

  wire [31:0] t1   = h_q + bsig1(e_q) + ch(e_q, f_q, g_q) + k_const(t_q) + w0;
  wire [31:0] t2   = bsig0(a_q) + maj(a_q, b_q, c_q);
  wire [31:0] w_new = ssig1(w14) + w9 + ssig0(w1) + w0;   // W_(t+16)

  wire [255:0] hbase = first_i ? IV : hh_q;

  always @(posedge clk_i) begin
    case (st_q)
      S_IDLE: if (start_i) begin
        hh_q <= hbase;
        {a_q, b_q, c_q, d_q, e_q, f_q, g_q, h_q} <= hbase;
        w_q  <= blk_i;
        t_q  <= 6'd0;
      end
      S_RUN: begin
        h_q <= g_q;  g_q <= f_q;  f_q <= e_q;  e_q <= d_q + t1;
        d_q <= c_q;  c_q <= b_q;  b_q <= a_q;  a_q <= t1 + t2;
        w_q <= {w_q[479:0], w_new};
        t_q <= t_q + 6'd1;
      end
      S_FIN: begin
        hh_q <= {hh_q[255:224] + a_q, hh_q[223:192] + b_q, hh_q[191:160] + c_q, hh_q[159:128] + d_q,
                 hh_q[127:96]  + e_q, hh_q[95:64]   + f_q, hh_q[63:32]   + g_q, hh_q[31:0]    + h_q};
      end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- FSM + done (co reset)
  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      st_q   <= S_IDLE;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (st_q)
        S_IDLE:  if (start_i) st_q <= S_RUN;
        S_RUN:   if (t_q == 6'd63) st_q <= S_FIN;
        S_FIN:   begin st_q <= S_IDLE; done_o <= 1'b1; end
        default: st_q <= S_IDLE;
      endcase
    end
  end
endmodule

