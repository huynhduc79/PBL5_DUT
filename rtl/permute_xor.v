// permute_xor.v - hoan vi bit theo pi roi XOR keystream (ma hoa) / XOR roi hoan vi nguoc (giai ma). Verilog-2001.
// Bit-exact voi refmodel/cipher.py: encrypt / decrypt, refmodel/fisher_yates.py: gather_bits / scatter_bits.
//
//   ENC (op = 2'b00): sh = gather(P, pi)  ( sh[i] = P[pi[i]] ) ;  C = sh ^ k
//   DEC (op = 2'b01): sh = C ^ k          ;  P = scatter(sh, pi)  ( P[pi[i]] = sh[i] )
//   SKIP (op = 2'b10 hoac 2'b11): khong tinh gi, sh = res = 0 (chay bu de dong bo, golden: CipherCore.advance)
//   Chi N bit thap co nghia (N = 8 neu n_sel_i = 0, N = 16 neu n_sel_i = 1); bit cao cua res / sh = 0.
//
// Keystream k = N bit THAP cua X (SPEC 4.10 da sua), chot vao ks_q khi ks_cap_i = 1 (chu ky x_vld cua buoc LTS_KEYSTREAM);
// cac buoc LTS sau (nap bit cho Fisher-Yates) khong lam doi ks_q.
//
// Giao tiep:
//   ks_cap_i : xung; ks_q <= x_i[15:0] & mask(n_sel_i)
//   px_en_i  : xung 1 chu ky; tinh tren op_i, pi_i, d_i va ks_q hien tai
//   px_done_o: xung 1 chu ky, sau px_en_i 1 chu ky; luc do res_o, sh_o hop le va giu den px_en_i ke tiep
//   d_i      : ENC = ban ro P, DEC = ban ma C ;  res_o: ENC = C, DEC = P
//   pi_i     : nibble i = pi[i] (pi_i[4*i +: 4]) - dung dinh dang pi_o cua fy_shuffle
module permute_xor (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        n_sel_i,
  input  wire        ks_cap_i,
  input  wire [31:0] x_i,
  input  wire        px_en_i,
  input  wire [1:0]  op_i,
  input  wire [63:0] pi_i,
  input  wire [15:0] d_i,
  output reg         px_done_o,
  output reg  [15:0] res_o,
  output reg  [15:0] sh_o,
  output wire [15:0] k_o
);
  reg  [15:0] ks_q;
  reg  [15:0] gat_w;
  reg  [15:0] sct_w;
  reg  [15:0] sx_w;
  integer     gi;
  integer     si;

  wire [15:0] mask = n_sel_i ? 16'hFFFF : 16'h00FF;
  wire [15:0] dm   = d_i & mask;
  wire        dec  = (op_i == 2'b01);
  wire        enc  = (op_i == 2'b00);

  // gather: gat[i] = d[pi[i]]
  always @* begin
    gat_w = 16'd0;
    for (gi = 0; gi < 16; gi = gi + 1)
      if (n_sel_i || gi < 8) gat_w[gi] = dm[pi_i[4*gi +: 4]];
  end

  // scatter: sct[pi[i]] = (d ^ k)[i]
  always @* begin
    sx_w  = dm ^ ks_q;
    sct_w = 16'd0;
    for (si = 0; si < 16; si = si + 1)
      if (n_sel_i || si < 8) sct_w[pi_i[4*si +: 4]] = sx_w[si];
  end

  always @(posedge clk_i) begin
    if (ks_cap_i) ks_q <= x_i[15:0] & mask;
  end

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      px_done_o <= 1'b0;
      res_o     <= 16'd0;
      sh_o      <= 16'd0;
    end else begin
      px_done_o <= px_en_i;
      if (px_en_i) begin
        if (enc) begin
          sh_o  <= gat_w;
          res_o <= (gat_w ^ ks_q) & mask;
        end else if (dec) begin
          sh_o  <= sx_w;
          res_o <= sct_w & mask;
        end else begin
          sh_o  <= 16'd0;
          res_o <= 16'd0;
        end
      end
    end
  end

  assign k_o = ks_q;
endmodule
