// sample_fmt.v - doi mau micro 24 bit sang 16 bit co bao hoa, dem so lan bao hoa (CLIP_CNT). Verilog-2001.
//
//   s16 = bao_hoa_16(s24 >>> (8 - SHIFT))      (docs/HOP_DONG_FPGA_RTOS.md, muc "24 -> 16 bit")
//   SHIFT = shift_i[3:0], 0..8; gia tri 9..15 duoc kep ve 8. ">>>" la dich phai so hoc (lam tron ve -vo cung).
//   SHIFT = 0: lay 16 bit cao, khong bao gio bao hoa. SHIFT = 8: lay 16 bit thap, bao hoa khi |s24| >= 2^15.
// Tre 1 chu ky: vld_i o canh k -> s16_o, clip_o, vld_o = 1 sau canh k. s16_o giu den mau ke tiep.
// clip_cnt_o: so mau bi bao hoa, bao hoa o 2^CW - 1 (khong quay vong). clip_clr_i (W xoa) xoa ve 0; neu cung
//   chu ky co mau bi bao hoa thi mau do duoc dem SAU khi xoa (ket qua = 1), nen khong mat su kien nao.
// Bit-exact voi refmodel/audio.py: sample_fmt().
module sample_fmt #(
  parameter CW = 32
) (
  input  wire          clk_i,
  input  wire          rst_n_i,
  input  wire [23:0]   s24_i,
  input  wire          vld_i,
  input  wire [3:0]    shift_i,
  input  wire          clip_clr_i,
  output wire [15:0]   s16_o,
  output wire          vld_o,
  output wire          clip_o,
  output wire [CW-1:0] clip_cnt_o
);
  wire [3:0]         sh_eff = (shift_i > 4'd8) ? 4'd8 : shift_i;
  wire [3:0]         rsh    = 4'd8 - sh_eff;                  // 0..8
  wire signed [23:0] x      = $signed(s24_i) >>> rsh;
  // x vua 16 bit khi 9 bit cao [23:15] deu bang bit dau
  wire               pos_ov = ~x[23] & (|x[22:15]);
  wire               neg_ov =  x[23] & ~(&x[22:15]);
  wire               ovf    = pos_ov | neg_ov;
  wire [15:0]        sat    = pos_ov ? 16'h7FFF : (neg_ov ? 16'h8000 : x[15:0]);
  wire               evt    = vld_i & ovf;

  reg [15:0]   s16_q;
  reg          vld_q, clip_q;
  reg [CW-1:0] cnt_q;

  wire [CW-1:0] cnt_base = clip_clr_i ? {CW{1'b0}} : cnt_q;
  wire          cnt_full = &cnt_base;

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      s16_q  <= 16'd0;
      vld_q  <= 1'b0;
      clip_q <= 1'b0;
      cnt_q  <= {CW{1'b0}};
    end else begin
      vld_q  <= vld_i;
      if (vld_i) begin
        s16_q  <= sat;
        clip_q <= ovf;
      end
      cnt_q <= (evt & ~cnt_full) ? cnt_base + 1'b1 : cnt_base;
    end
  end

  assign s16_o      = s16_q;
  assign vld_o      = vld_q;
  assign clip_o     = clip_q;
  assign clip_cnt_o = cnt_q;
endmodule
