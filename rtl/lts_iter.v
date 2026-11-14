// lts_iter.v - bo lap LTS: giu trang thai X cua phien, moi step_en tinh X <- LTS(X) bang lts_step (pipeline 3 tang). Verilog-2001.
//
// Giao tiep:
//   x_load_i : xung; nap X <- x0_i va luu (x0, xr) cua phien moi. Chi dung khi busy_o = 0.
//   step_en_i: xung 1 chu ky khi busy_o = 0; bat dau mot buoc. (bi bo qua neu busy_o = 1)
//   x_vld_o  : xung 1 chu ky, DUNG 4 chu ky sau step_en_i; luc do x_o = X moi; x_o giu nguyen den buoc ke tiep.
//   busy_o   : 1 tu sau step_en_i den chu ky ngay truoc x_vld_o. Co the dat step_en_i NGAY trong chu ky x_vld_o
//              (busy_o = 0) de chay lien tiep, mot buoc moi 4 chu ky.
//   guarded_o: giu cung x_o; 1 neu buoc nay kich hoat bay-guard (x' <= 1 -> X0).
// Quy uoc: X la Q0.32; r_int = 2^32 + xr; x0 >= 2 (do kdf_params dam bao).
module lts_iter (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        x_load_i,
  input  wire [31:0] x0_i,
  input  wire [31:0] xr_i,
  input  wire        step_en_i,
  output wire        busy_o,
  output wire        x_vld_o,
  output wire [31:0] x_o,
  output wire        guarded_o
);
  reg [31:0] x_q, x0_q, xr_q;
  reg        busy_q, vld_q, gd_q;

  wire        go = step_en_i & ~busy_q;
  wire        s_vld, s_br, s_gd;
  wire [31:0] s_x;

  lts_step u_step (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .vld_i(go), .x_i(x_q), .xr_i(xr_q), .x0_i(x0_q),
    .vld_o(s_vld), .x_o(s_x), .branch_o(s_br), .guarded_o(s_gd)
  );

  always @(posedge clk_i) begin
    if (x_load_i && !busy_q) begin
      x_q  <= x0_i;
      x0_q <= x0_i;
      xr_q <= xr_i;
    end else if (s_vld) begin
      x_q  <= s_x;
      gd_q <= s_gd;
    end
  end

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      busy_q <= 1'b0;
      vld_q  <= 1'b0;
    end else begin
      vld_q <= s_vld;
      if (go)         busy_q <= 1'b1;
      else if (s_vld) busy_q <= 1'b0;
    end
  end

  assign busy_o    = busy_q;
  assign x_vld_o   = vld_q;
  assign x_o       = x_q;
  assign guarded_o = gd_q;
endmodule

