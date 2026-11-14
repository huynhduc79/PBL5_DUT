// lts_step.v - mot buoc Logistic-Tent System, pipeline 3 tang, bit-exact voi refmodel/lts.py (lts_step_ex).
// Verilog-2001 thuan (khong dung SystemVerilog) de Libero SoC / ModelSim / Synplify deu doc duoc.
//
// Quy uoc (SPEC 1.0.0): X la Q0.32; r_int la Q2.32 voi r in [1,2) => r_int = 2^32 + xr, chi can xr (32 bit).
// Bay-guard: x_next <= 1 -> x_next = x0 (x0 >= 2, do khoi KDF dam bao).
//
// Cong thuc (3 phep nhan 32x32, moi so cong/tru lay modulo 2^32):
//   prod  = (x*(1-x)) >> 32
//   t1    = prod + ((xr*prod) >> 32)              (r*prod, vi r = 1 + xr/2^32)
//   h2    = (2^32 - xr) >> 1                      ((4-r)/2 = 1 + h2/2^32)
//   base  = (x < 2^31) ? x : (1-x)
//   t2    = base + ((h2*base) >> 32)
//   x'    = (t1 + t2) mod 2^32 ;  x' <= 1 -> x0
//
// Pipeline (do tre co dinh 3 chu ky, nhan mot mau moi MOI chu ky):
//   tang 1: m1 = x*(1-x)                       -> prod, base, h2
//   tang 2: m2 = xr*prod ; m3 = h2*base        -> t1, t2
//   tang 3: cong, bay-guard                    -> x_o, branch_o, guarded_o
// Chi cac bit valid co reset; du lieu khong reset (khong can).
module lts_step (
  input  wire        clk_i,
  input  wire        rst_n_i,      // dong bo, tich cuc thap
  input  wire        vld_i,
  input  wire [31:0] x_i,          // trang thai hien tai
  input  wire [31:0] xr_i,         // r_int[31:0]  (r_int = 2^32 + xr)
  input  wire [31:0] x0_i,         // X0 cua phien (thay the khi gap bay)
  output wire        vld_o,        // = vld_i tre 3 chu ky
  output wire [31:0] x_o,          // x'
  output wire        branch_o,     // 0: x < 0.5, 1: x >= 0.5
  output wire        guarded_o     // 1: bay-guard kich hoat
);
  // ---------------------------------------------------------------- tang 1
  wire [31:0] omx;
  wire [63:0] m1;
  wire [32:0] hs;
  assign omx = 32'd0 - x_i;                         // (1 - x) mod 2^32 ; x = 0 cho 0, khong anh huong ket qua
  assign m1  = x_i * omx;
  assign hs  = 33'h1_0000_0000 - {1'b0, xr_i};      // 2^32 - xr  (can 33 bit vi xr = 0)

  reg        v1, v2, v3;
  reg        br1;
  reg [31:0] prod1, base1, h2_1, xr1, x0_1;
  always @(posedge clk_i) begin
    prod1 <= m1[63:32];
    base1 <= x_i[31] ? omx : x_i;
    h2_1  <= hs[32:1];
    xr1   <= xr_i;
    x0_1  <= x0_i;
    br1   <= x_i[31];
  end

  // ---------------------------------------------------------------- tang 2
  wire [63:0] m2, m3;
  assign m2 = xr1  * prod1;
  assign m3 = h2_1 * base1;

  reg        br2;
  reg [31:0] t1_2, t2_2, x0_2;
  always @(posedge clk_i) begin
    t1_2 <= prod1 + m2[63:32];
    t2_2 <= base1 + m3[63:32];
    x0_2 <= x0_1;
    br2  <= br1;
  end

  // ---------------------------------------------------------------- tang 3
  wire [31:0] nxt;
  wire        trap;
  assign nxt  = t1_2 + t2_2;
  assign trap = (nxt <= 32'd1);

  reg [31:0] x_q;
  reg        br_q, gd_q;
  always @(posedge clk_i) begin
    x_q  <= trap ? x0_2 : nxt;
    br_q <= br2;
    gd_q <= trap;
  end

  assign x_o       = x_q;
  assign branch_o  = br_q;
  assign guarded_o = gd_q;

  // ---------------------------------------------------------------- valid
  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
    end else begin
      v1 <= vld_i; v2 <= v1; v3 <= v2;
    end
  end
  assign vld_o = v3;
endmodule

