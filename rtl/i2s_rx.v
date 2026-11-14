// i2s_rx.v - bo thu I2S master cho micro INMP441 (chuan Philips). Verilog-2001.
// FPGA phat SCK va WS bang chia tan trong mien clk_i (50 MHz) - KHONG dung SCK lam xung; SD duoc dong bo 2 tang.
//
//   SCK = clk / (2 * (SCK_DIV + 1))      fs = SCK / 64      SCK_DIV = 24 -> SCK 1 MHz, fs 15 625 Hz
//   Moi kenh 1 khe 32 SCK. WS = 0: kenh trai, WS = 1: kenh phai. WS doi o canh xuong SCK.
//   Du lieu 24 bit bu hai, MSB truoc, tre 1 SCK sau khi WS doi: bit khe 1 = MSB ... khe 24 = LSB; khe 0, 25..31 bo qua.
//   SD lay mau o canh len SCK (thuc te: gia tri SD da dong bo 2 tang tai chu ky clk dua SCK len 1).
//
// Cau hinh (sck_div_i, channel_i, startup_skip_i) duoc CHOT khi en_i chuyen 0 -> 1; doi luc dang chay khong co tac dung.
//   sck_div_i < MIN_DIV duoc kep len MIN_DIV: nua chu ky SCK phai >= 4 clk de bo dong bo 2 tang kip thay SD moi
//   (INMP441 cho SCK toi da ~3,1 MHz, tuc SCK_DIV >= 7 o 50 MHz, nen gioi han nay khong anh huong su dung thuc).
//   channel_i: 0 = trai (L/R noi GND, cau hinh cua de tai), 1 = phai.
//   startup_skip_i: so tu dau tien cua kenh da chon bi bo sau khi bat (micro can thoi gian on dinh); mac dinh 4096 o thanh ghi.
//     Cac tu bi bo o day KHONG phai mau bi mat: chua co thoi gian am thanh nao, nen khong tinh vao DROP_CNT / GAP.
// Khi en_i = 1: khe dau tien la nua phai (WS = 1) de tu dau tien cua kenh trai co canh xuong WS dung chuan.
// Khi en_i = 0: SCK = WS = 0, moi bo dem ve 0 (micro tu ngu sau ~ 2^18 chu ky SCK khong co xung).
// sample_vld_o: xung 1 chu ky, sample_o (s24) giu den tu ke tiep. Khoang cach 2 xung = 128 * (SCK_DIV + 1) chu ky clk.
module i2s_rx #(
  parameter MIN_DIV = 3
) (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        en_i,
  input  wire [11:0] sck_div_i,
  input  wire        channel_i,
  input  wire [31:0] startup_skip_i,
  input  wire        sd_i,
  output wire        sck_o,
  output wire        ws_o,
  output wire        running_o,
  output wire [23:0] sample_o,
  output wire        sample_vld_o
);
  localparam [11:0] MIN_DIV_W = MIN_DIV;

  reg        run_q, ch_q, sck_q, ws_q, vld_q;
  reg [11:0] div_q, dcnt_q;
  reg [5:0]  bit_q;                  // vi tri trong khung 64 SCK: [5] = nua (0 trai / 1 phai), [4:0] = khe
  reg [31:0] skip_q, skcnt_q;
  reg [1:0]  sd_sync_q;
  reg [22:0] sh_q;                  // 23 bit da nhan; bit thu 24 lay thang tu SD luc ghep tu
  reg [23:0] smp_q;

  wire        tick  = (dcnt_q == div_q);
  wire        rise  = run_q & tick & ~sck_q;
  wire        fall  = run_q & tick &  sck_q;
  wire [4:0]  slot  = bit_q[4:0];
  wire        mine  = (bit_q[5] == ch_q);
  wire        cap   = rise & mine & (slot >= 5'd1) & (slot <= 5'd24);
  wire        last  = rise & mine & (slot == 5'd24);
  wire [23:0] word  = {sh_q, sd_sync_q[1]};
  wire [5:0]  bit_n = bit_q + 6'd1;

  // ---- dong bo SD vao mien clk_i
  always @(posedge clk_i) begin
    if (!rst_n_i) sd_sync_q <= 2'b00;
    else          sd_sync_q <= {sd_sync_q[0], sd_i};
  end

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      run_q   <= 1'b0;
      ch_q    <= 1'b0;
      div_q   <= MIN_DIV_W;
      skip_q  <= 32'd0;
      skcnt_q <= 32'd0;
      dcnt_q  <= 12'd0;
      sck_q   <= 1'b0;
      ws_q    <= 1'b0;
      bit_q   <= 6'd0;
      sh_q    <= 23'd0;
      smp_q   <= 24'd0;
      vld_q   <= 1'b0;
    end else if (!en_i) begin
      run_q   <= 1'b0;
      skcnt_q <= 32'd0;
      dcnt_q  <= 12'd0;
      sck_q   <= 1'b0;
      ws_q    <= 1'b0;
      bit_q   <= 6'd0;
      vld_q   <= 1'b0;
    end else if (!run_q) begin
      // bat dau: chot cau hinh, vao nua phai cua khung
      run_q   <= 1'b1;
      ch_q    <= channel_i;
      div_q   <= (sck_div_i < MIN_DIV_W) ? MIN_DIV_W : sck_div_i;
      skip_q  <= startup_skip_i;
      skcnt_q <= 32'd0;
      dcnt_q  <= 12'd0;
      sck_q   <= 1'b0;
      ws_q    <= 1'b1;
      bit_q   <= 6'd32;
      vld_q   <= 1'b0;
    end else begin
      vld_q  <= 1'b0;
      dcnt_q <= tick ? 12'd0 : dcnt_q + 12'd1;
      if (tick) sck_q <= ~sck_q;
      if (fall) begin
        bit_q <= bit_n;
        ws_q  <= bit_n[5];
      end
      if (cap) sh_q <= word[22:0];
      if (last) begin
        if (skcnt_q < skip_q) begin
          skcnt_q <= skcnt_q + 32'd1;
        end else begin
          smp_q <= word;
          vld_q <= 1'b1;
        end
      end
    end
  end

  assign sck_o        = sck_q;
  assign ws_o         = ws_q;
  assign running_o    = run_q;
  assign sample_o     = smp_q;
  assign sample_vld_o = vld_q;
endmodule
