// test_src.v - nguon tin hieu thu cho lop vo am thanh: RAMP va SINE 1 kHz, khong can micro. Verilog-2001.
//
// mode_i (= SRC_SEL[1:0]): 1 = RAMP, 2 = SINE. Gia tri 0 (MIC) va 3 (REG) -> khoi nay im lang.
//   RAMP: RAMP_INIT, RAMP_INIT + 1, ... (16 bit, quay vong). Mac dinh RAMP_INIT = 0 -> giai ma phai ra 0, 1, 2, ...
//   SINE: bo tich luy pha 32 bit, pha += SINE_INC moi mau, mau = sine_lut(pha[31:24]).
//         SINE_INC = round(2^32 * 1000 / 15625) -> 1 kHz o fs = 15 625 Hz. Bien do 0x4000 (-6 dBFS).
// Nhip: mot mau moi 128 * (SCK_DIV_eff + 1) chu ky clk - CUNG nhip voi i2s_rx (SCK_DIV < MIN_DIV kep len MIN_DIV),
//   mau dau tien ra sau mot chu ky mau tinh tu luc bat.
// mode_i va sck_div_i duoc CHOT khi bat dau (en_i = 1 va mode la RAMP/SINE); doi luc dang chay khong co tac dung.
// en_i = 0: dung, khong co sample_vld_o; lan bat sau bat dau lai tu RAMP_INIT / pha 0.
// Mau ra la s16 da san sang cho loi ma hoa: KHONG di qua sample_fmt.
// Bit-exact voi refmodel/audio.py: ramp(), sine(), sample_period_clk().
// Bang sine_lut sinh tu refmodel/audio.py SINE_LUT (khong sua tay).
module test_src #(
  parameter        MIN_DIV   = 3,
  parameter [15:0] RAMP_INIT = 16'd0,
  parameter [31:0] SINE_INC  = 32'd274877907
) (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        en_i,
  input  wire [1:0]  mode_i,
  input  wire [11:0] sck_div_i,
  output wire [15:0] sample_o,
  output wire        sample_vld_o
);
  function [15:0] sine_lut;
    input [7:0] k;
    begin
      case (k)
      8'd0  : sine_lut = 16'h0000;
      8'd1  : sine_lut = 16'h0192;
      8'd2  : sine_lut = 16'h0324;
      8'd3  : sine_lut = 16'h04B5;
      8'd4  : sine_lut = 16'h0646;
      8'd5  : sine_lut = 16'h07D6;
      8'd6  : sine_lut = 16'h0964;
      8'd7  : sine_lut = 16'h0AF1;
      8'd8  : sine_lut = 16'h0C7C;
      8'd9  : sine_lut = 16'h0E06;
      8'd10 : sine_lut = 16'h0F8D;
      8'd11 : sine_lut = 16'h1112;
      8'd12 : sine_lut = 16'h1294;
      8'd13 : sine_lut = 16'h1413;
      8'd14 : sine_lut = 16'h1590;
      8'd15 : sine_lut = 16'h1709;
      8'd16 : sine_lut = 16'h187E;
      8'd17 : sine_lut = 16'h19EF;
      8'd18 : sine_lut = 16'h1B5D;
      8'd19 : sine_lut = 16'h1CC6;
      8'd20 : sine_lut = 16'h1E2B;
      8'd21 : sine_lut = 16'h1F8C;
      8'd22 : sine_lut = 16'h20E7;
      8'd23 : sine_lut = 16'h223D;
      8'd24 : sine_lut = 16'h238E;
      8'd25 : sine_lut = 16'h24DA;
      8'd26 : sine_lut = 16'h2620;
      8'd27 : sine_lut = 16'h2760;
      8'd28 : sine_lut = 16'h289A;
      8'd29 : sine_lut = 16'h29CE;
      8'd30 : sine_lut = 16'h2AFB;
      8'd31 : sine_lut = 16'h2C21;
      8'd32 : sine_lut = 16'h2D41;
      8'd33 : sine_lut = 16'h2E5A;
      8'd34 : sine_lut = 16'h2F6C;
      8'd35 : sine_lut = 16'h3076;
      8'd36 : sine_lut = 16'h3179;
      8'd37 : sine_lut = 16'h3274;
      8'd38 : sine_lut = 16'h3368;
      8'd39 : sine_lut = 16'h3453;
      8'd40 : sine_lut = 16'h3537;
      8'd41 : sine_lut = 16'h3612;
      8'd42 : sine_lut = 16'h36E5;
      8'd43 : sine_lut = 16'h37B0;
      8'd44 : sine_lut = 16'h3871;
      8'd45 : sine_lut = 16'h392B;
      8'd46 : sine_lut = 16'h39DB;
      8'd47 : sine_lut = 16'h3A82;
      8'd48 : sine_lut = 16'h3B21;
      8'd49 : sine_lut = 16'h3BB6;
      8'd50 : sine_lut = 16'h3C42;
      8'd51 : sine_lut = 16'h3CC5;
      8'd52 : sine_lut = 16'h3D3F;
      8'd53 : sine_lut = 16'h3DAF;
      8'd54 : sine_lut = 16'h3E15;
      8'd55 : sine_lut = 16'h3E72;
      8'd56 : sine_lut = 16'h3EC5;
      8'd57 : sine_lut = 16'h3F0F;
      8'd58 : sine_lut = 16'h3F4F;
      8'd59 : sine_lut = 16'h3F85;
      8'd60 : sine_lut = 16'h3FB1;
      8'd61 : sine_lut = 16'h3FD4;
      8'd62 : sine_lut = 16'h3FEC;
      8'd63 : sine_lut = 16'h3FFB;
      8'd64 : sine_lut = 16'h4000;
      8'd65 : sine_lut = 16'h3FFB;
      8'd66 : sine_lut = 16'h3FEC;
      8'd67 : sine_lut = 16'h3FD4;
      8'd68 : sine_lut = 16'h3FB1;
      8'd69 : sine_lut = 16'h3F85;
      8'd70 : sine_lut = 16'h3F4F;
      8'd71 : sine_lut = 16'h3F0F;
      8'd72 : sine_lut = 16'h3EC5;
      8'd73 : sine_lut = 16'h3E72;
      8'd74 : sine_lut = 16'h3E15;
      8'd75 : sine_lut = 16'h3DAF;
      8'd76 : sine_lut = 16'h3D3F;
      8'd77 : sine_lut = 16'h3CC5;
      8'd78 : sine_lut = 16'h3C42;
      8'd79 : sine_lut = 16'h3BB6;
      8'd80 : sine_lut = 16'h3B21;
      8'd81 : sine_lut = 16'h3A82;
      8'd82 : sine_lut = 16'h39DB;
      8'd83 : sine_lut = 16'h392B;
      8'd84 : sine_lut = 16'h3871;
      8'd85 : sine_lut = 16'h37B0;
      8'd86 : sine_lut = 16'h36E5;
      8'd87 : sine_lut = 16'h3612;
      8'd88 : sine_lut = 16'h3537;
      8'd89 : sine_lut = 16'h3453;
      8'd90 : sine_lut = 16'h3368;
      8'd91 : sine_lut = 16'h3274;
      8'd92 : sine_lut = 16'h3179;
      8'd93 : sine_lut = 16'h3076;
      8'd94 : sine_lut = 16'h2F6C;
      8'd95 : sine_lut = 16'h2E5A;
      8'd96 : sine_lut = 16'h2D41;
      8'd97 : sine_lut = 16'h2C21;
      8'd98 : sine_lut = 16'h2AFB;
      8'd99 : sine_lut = 16'h29CE;
      8'd100: sine_lut = 16'h289A;
      8'd101: sine_lut = 16'h2760;
      8'd102: sine_lut = 16'h2620;
      8'd103: sine_lut = 16'h24DA;
      8'd104: sine_lut = 16'h238E;
      8'd105: sine_lut = 16'h223D;
      8'd106: sine_lut = 16'h20E7;
      8'd107: sine_lut = 16'h1F8C;
      8'd108: sine_lut = 16'h1E2B;
      8'd109: sine_lut = 16'h1CC6;
      8'd110: sine_lut = 16'h1B5D;
      8'd111: sine_lut = 16'h19EF;
      8'd112: sine_lut = 16'h187E;
      8'd113: sine_lut = 16'h1709;
      8'd114: sine_lut = 16'h1590;
      8'd115: sine_lut = 16'h1413;
      8'd116: sine_lut = 16'h1294;
      8'd117: sine_lut = 16'h1112;
      8'd118: sine_lut = 16'h0F8D;
      8'd119: sine_lut = 16'h0E06;
      8'd120: sine_lut = 16'h0C7C;
      8'd121: sine_lut = 16'h0AF1;
      8'd122: sine_lut = 16'h0964;
      8'd123: sine_lut = 16'h07D6;
      8'd124: sine_lut = 16'h0646;
      8'd125: sine_lut = 16'h04B5;
      8'd126: sine_lut = 16'h0324;
      8'd127: sine_lut = 16'h0192;
      8'd128: sine_lut = 16'h0000;
      8'd129: sine_lut = 16'hFE6E;
      8'd130: sine_lut = 16'hFCDC;
      8'd131: sine_lut = 16'hFB4B;
      8'd132: sine_lut = 16'hF9BA;
      8'd133: sine_lut = 16'hF82A;
      8'd134: sine_lut = 16'hF69C;
      8'd135: sine_lut = 16'hF50F;
      8'd136: sine_lut = 16'hF384;
      8'd137: sine_lut = 16'hF1FA;
      8'd138: sine_lut = 16'hF073;
      8'd139: sine_lut = 16'hEEEE;
      8'd140: sine_lut = 16'hED6C;
      8'd141: sine_lut = 16'hEBED;
      8'd142: sine_lut = 16'hEA70;
      8'd143: sine_lut = 16'hE8F7;
      8'd144: sine_lut = 16'hE782;
      8'd145: sine_lut = 16'hE611;
      8'd146: sine_lut = 16'hE4A3;
      8'd147: sine_lut = 16'hE33A;
      8'd148: sine_lut = 16'hE1D5;
      8'd149: sine_lut = 16'hE074;
      8'd150: sine_lut = 16'hDF19;
      8'd151: sine_lut = 16'hDDC3;
      8'd152: sine_lut = 16'hDC72;
      8'd153: sine_lut = 16'hDB26;
      8'd154: sine_lut = 16'hD9E0;
      8'd155: sine_lut = 16'hD8A0;
      8'd156: sine_lut = 16'hD766;
      8'd157: sine_lut = 16'hD632;
      8'd158: sine_lut = 16'hD505;
      8'd159: sine_lut = 16'hD3DF;
      8'd160: sine_lut = 16'hD2BF;
      8'd161: sine_lut = 16'hD1A6;
      8'd162: sine_lut = 16'hD094;
      8'd163: sine_lut = 16'hCF8A;
      8'd164: sine_lut = 16'hCE87;
      8'd165: sine_lut = 16'hCD8C;
      8'd166: sine_lut = 16'hCC98;
      8'd167: sine_lut = 16'hCBAD;
      8'd168: sine_lut = 16'hCAC9;
      8'd169: sine_lut = 16'hC9EE;
      8'd170: sine_lut = 16'hC91B;
      8'd171: sine_lut = 16'hC850;
      8'd172: sine_lut = 16'hC78F;
      8'd173: sine_lut = 16'hC6D5;
      8'd174: sine_lut = 16'hC625;
      8'd175: sine_lut = 16'hC57E;
      8'd176: sine_lut = 16'hC4DF;
      8'd177: sine_lut = 16'hC44A;
      8'd178: sine_lut = 16'hC3BE;
      8'd179: sine_lut = 16'hC33B;
      8'd180: sine_lut = 16'hC2C1;
      8'd181: sine_lut = 16'hC251;
      8'd182: sine_lut = 16'hC1EB;
      8'd183: sine_lut = 16'hC18E;
      8'd184: sine_lut = 16'hC13B;
      8'd185: sine_lut = 16'hC0F1;
      8'd186: sine_lut = 16'hC0B1;
      8'd187: sine_lut = 16'hC07B;
      8'd188: sine_lut = 16'hC04F;
      8'd189: sine_lut = 16'hC02C;
      8'd190: sine_lut = 16'hC014;
      8'd191: sine_lut = 16'hC005;
      8'd192: sine_lut = 16'hC000;
      8'd193: sine_lut = 16'hC005;
      8'd194: sine_lut = 16'hC014;
      8'd195: sine_lut = 16'hC02C;
      8'd196: sine_lut = 16'hC04F;
      8'd197: sine_lut = 16'hC07B;
      8'd198: sine_lut = 16'hC0B1;
      8'd199: sine_lut = 16'hC0F1;
      8'd200: sine_lut = 16'hC13B;
      8'd201: sine_lut = 16'hC18E;
      8'd202: sine_lut = 16'hC1EB;
      8'd203: sine_lut = 16'hC251;
      8'd204: sine_lut = 16'hC2C1;
      8'd205: sine_lut = 16'hC33B;
      8'd206: sine_lut = 16'hC3BE;
      8'd207: sine_lut = 16'hC44A;
      8'd208: sine_lut = 16'hC4DF;
      8'd209: sine_lut = 16'hC57E;
      8'd210: sine_lut = 16'hC625;
      8'd211: sine_lut = 16'hC6D5;
      8'd212: sine_lut = 16'hC78F;
      8'd213: sine_lut = 16'hC850;
      8'd214: sine_lut = 16'hC91B;
      8'd215: sine_lut = 16'hC9EE;
      8'd216: sine_lut = 16'hCAC9;
      8'd217: sine_lut = 16'hCBAD;
      8'd218: sine_lut = 16'hCC98;
      8'd219: sine_lut = 16'hCD8C;
      8'd220: sine_lut = 16'hCE87;
      8'd221: sine_lut = 16'hCF8A;
      8'd222: sine_lut = 16'hD094;
      8'd223: sine_lut = 16'hD1A6;
      8'd224: sine_lut = 16'hD2BF;
      8'd225: sine_lut = 16'hD3DF;
      8'd226: sine_lut = 16'hD505;
      8'd227: sine_lut = 16'hD632;
      8'd228: sine_lut = 16'hD766;
      8'd229: sine_lut = 16'hD8A0;
      8'd230: sine_lut = 16'hD9E0;
      8'd231: sine_lut = 16'hDB26;
      8'd232: sine_lut = 16'hDC72;
      8'd233: sine_lut = 16'hDDC3;
      8'd234: sine_lut = 16'hDF19;
      8'd235: sine_lut = 16'hE074;
      8'd236: sine_lut = 16'hE1D5;
      8'd237: sine_lut = 16'hE33A;
      8'd238: sine_lut = 16'hE4A3;
      8'd239: sine_lut = 16'hE611;
      8'd240: sine_lut = 16'hE782;
      8'd241: sine_lut = 16'hE8F7;
      8'd242: sine_lut = 16'hEA70;
      8'd243: sine_lut = 16'hEBED;
      8'd244: sine_lut = 16'hED6C;
      8'd245: sine_lut = 16'hEEEE;
      8'd246: sine_lut = 16'hF073;
      8'd247: sine_lut = 16'hF1FA;
      8'd248: sine_lut = 16'hF384;
      8'd249: sine_lut = 16'hF50F;
      8'd250: sine_lut = 16'hF69C;
      8'd251: sine_lut = 16'hF82A;
      8'd252: sine_lut = 16'hF9BA;
      8'd253: sine_lut = 16'hFB4B;
      8'd254: sine_lut = 16'hFCDC;
      8'd255: sine_lut = 16'hFE6E;
      default: sine_lut = 16'h0000;
      endcase
    end
  endfunction

  localparam [11:0] MIN_DIV_W = MIN_DIV;
  localparam [1:0]  M_RAMP = 2'd1, M_SINE = 2'd2;

  reg        run_q, sine_q, vld_q;
  reg [19:0] per_q, cnt_q;                  // chu ky mau - 1, toi da 128 * 4096 - 1
  reg [15:0] ramp_q, smp_q;
  reg [31:0] ph_q;

  wire        is_test = (mode_i == M_RAMP) | (mode_i == M_SINE);
  wire [11:0] div_eff = (sck_div_i < MIN_DIV_W) ? MIN_DIV_W : sck_div_i;
  wire [12:0] div_p1  = {1'b0, div_eff} + 13'd1;
  wire        tick    = (cnt_q == per_q);

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      run_q  <= 1'b0;
      sine_q <= 1'b0;
      vld_q  <= 1'b0;
      per_q  <= 20'd0;
      cnt_q  <= 20'd0;
      ramp_q <= RAMP_INIT;
      ph_q   <= 32'd0;
      smp_q  <= 16'd0;
    end else if (!en_i) begin
      run_q  <= 1'b0;
      vld_q  <= 1'b0;
    end else if (!run_q) begin
      vld_q  <= 1'b0;
      if (is_test) begin
        run_q  <= 1'b1;
        sine_q <= (mode_i == M_SINE);
        per_q  <= {div_p1, 7'd0} - 20'd1;
        cnt_q  <= 20'd0;
        ramp_q <= RAMP_INIT;
        ph_q   <= 32'd0;
      end
    end else begin
      vld_q <= tick;
      cnt_q <= tick ? 20'd0 : cnt_q + 20'd1;
      if (tick) begin
        if (sine_q) begin
          smp_q <= sine_lut(ph_q[31:24]);
          ph_q  <= ph_q + SINE_INC;
        end else begin
          smp_q  <= ramp_q;
          ramp_q <= ramp_q + 16'd1;
        end
      end
    end
  end

  assign sample_o     = smp_q;
  assign sample_vld_o = vld_q;
endmodule
