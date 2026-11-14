// session_mgr.v - quan ly phien: bo dem phien ctr, bo dem mau trong phien, co "den han tai tao phien". Verilog-2001.
// Bit-exact voi refmodel/cipher.py: SessionManager (muc 4.2.6, UpdateSession).
//
// Hanh vi (golden):  moi mau xong (smp_done):  smp_cnt++ ;  den RESEED_INTERVAL mau thi ctr++ (modulo 2^32), smp_cnt = 0,
// va can tai tao phien (KDF voi ctr moi).  ctr_out/idx_out luu (ctr, idx) da DUNG de ma hoa mau vua xong
// (gia tri TRUOC khi cap nhat, D4) va giu nguyen den smp_done ke tiep.
//
// Giao tiep:
//   ctr_ld_i    : xung; nap ctr_q <= ctr0_i, smp_cnt <= 0, reseed_due <= 0  (khi nap khoa / khoi dong lai)
//   smp_done_i  : xung 1 chu ky khi mot mau da ma hoa xong (CHECK_RESEED cua FSM)
//   kdf_start_i : xung khi FSM bat dau tinh KDF; xoa reseed_due_o
//   kdf_ctr_o   : ctr dua vao KDF (= ctr_q; sau smp_done thu RESEED_INTERVAL thi da la ctr + 1)
//   reseed_due_o: 1 = mau ke tiep phai dung phien moi (FSM phai chay RESEED_HMAC truoc)
// Tham so: RESEED_INTERVAL (mac dinh 64), CNT_W = so bit cua smp_cnt, phai thoa 2^CNT_W >= RESEED_INTERVAL
//   (64 -> 6, 4 -> 2, 1 -> 1). Mac dinh khop SPEC 1.0.0.
module session_mgr #(
  parameter RESEED_INTERVAL = 64,
  parameter CNT_W           = 6
) (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        ctr_ld_i,
  input  wire [31:0] ctr0_i,
  input  wire        smp_done_i,
  input  wire        kdf_start_i,
  output wire        reseed_due_o,
  output wire [31:0] kdf_ctr_o,
  output wire [31:0] ctr_out_o,
  output wire [15:0] idx_out_o
);
  reg [31:0]        ctr_q;
  reg [CNT_W-1:0]   smp_cnt_q;
  reg               due_q;
  reg [31:0]        ctr_o_q;
  reg [15:0]        idx_o_q;

  wire last = ({{(32-CNT_W){1'b0}}, smp_cnt_q} == (RESEED_INTERVAL - 1));

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      ctr_q     <= 32'd0;
      smp_cnt_q <= {CNT_W{1'b0}};
      due_q     <= 1'b0;
      ctr_o_q   <= 32'd0;
      idx_o_q   <= 16'd0;
    end else if (ctr_ld_i) begin
      ctr_q     <= ctr0_i;
      smp_cnt_q <= {CNT_W{1'b0}};
      due_q     <= 1'b0;
    end else begin
      if (kdf_start_i) due_q <= 1'b0;
      if (smp_done_i) begin
        ctr_o_q <= ctr_q;                         // gia tri DA DUNG, truoc khi cap nhat
        idx_o_q <= {{(16-CNT_W){1'b0}}, smp_cnt_q};
        if (last) begin
          ctr_q     <= ctr_q + 32'd1;             // quay vong modulo 2^32
          smp_cnt_q <= {CNT_W{1'b0}};
          due_q     <= 1'b1;
        end else begin
          smp_cnt_q <= smp_cnt_q + 1'b1;
        end
      end
    end
  end

  assign reseed_due_o = due_q;
  assign kdf_ctr_o    = ctr_q;
  assign ctr_out_o    = ctr_o_q;
  assign idx_out_o    = idx_o_q;
endmodule

