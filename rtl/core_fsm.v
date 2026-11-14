// core_fsm.v - FSM dieu khien xu ly tung mau cua loi mat ma (khong chua du lieu 32/64/256 bit). Verilog-2001.
//
// Chuoi trang thai cho mot mau (thu tu khop su kien trace cua golden, SPEC 5.3.4):
//   IDLE -> KS_GO -> KS_WAIT [LTS_KEYSTREAM] -> FY_INIT [FY_INIT] -> FY_LOOP [FY_REFILL/DRAW/SWAP...]
//        -> PX -> PXW [PERMUTE_XOR] -> CHK -> CHK2 [CHECK_RESEED] -> (reseed_due ? HMAC_GO -> HMAC_WAIT [RESEED_HMAC] : -) -> DONE [DONE] -> IDLE
// Nap khoa (load_key_i khi IDLE): ctr_ld, roi HMAC_GO -> HMAC_WAIT [RESEED_HMAC cua phien dau] -> IDLE, key_vld = 1.
// Quy uoc:
//   * start_i chi nhan khi IDLE va key_vld = 1; load_key_i chi nhan khi IDLE (uu tien hon start_i). Lenh bi bo qua khi busy
//     (khong co co bao loi): phan mem phai doi busy_o = 0 (khop thanh ghi trang thai).
//   * op_i, n_sel_i chot luc start nhan. op: 00 ENC, 01 DEC, 1x SKIP (bo qua du lieu, chi chay bu keystream/phien).
//   * soft_rst_i nhan o MOI trang thai: vao SOFT (1 chu ky, reset moi khoi con qua sub_rst_n_o), xoa key_vld, err_wd.
//     Sau do phai load_key lai (ctr cung ve 0 -> nap lai ctr0).
//   * busy_o = 1 o moi trang thai tru IDLE (ke ca khi nap khoa / RESEED_HMAC / DONE). done_o: xung 1 chu ky o DONE.
//   * err_wd_o: dinh (sticky) khi fy_shuffle bao watchdog trong mau hien tai; xoa luc nhan start moi hoac soft_rst.
// Ma trang thai (state_o): 0 IDLE, 1 HMAC_GO, 2 HMAC_WAIT, 3 KS_GO, 4 KS_WAIT, 5 FY_INIT, 6 FY_LOOP, 7 PX, 8 PXW,
//   9 CHK, 10 CHK2, 11 DONE, 12 SOFT.
module core_fsm (
  input  wire       clk_i,
  input  wire       rst_n_i,
  // tu thanh ghi
  input  wire       start_i,
  input  wire       soft_rst_i,
  input  wire       load_key_i,
  input  wire [1:0] op_i,
  input  wire       n_sel_i,
  // tu cac khoi
  input  wire       kdf_done_i,
  input  wire       x_vld_i,
  input  wire       fy_need_x_i,
  input  wire       fy_done_i,
  input  wire       fy_err_i,
  input  wire       px_done_i,
  input  wire       reseed_due_i,
  // sang thanh ghi
  output wire       busy_o,
  output wire       done_o,
  output wire       key_vld_o,
  output wire       err_wd_o,
  // sang cac khoi (xung to hop theo trang thai)
  output wire       start_acc_o,
  output wire       ctr_ld_o,
  output wire       kdf_start_o,
  output wire       x_load_o,
  output wire       step_en_o,
  output wire       ks_cap_o,
  output wire       fy_start_o,
  output wire       px_en_o,
  output wire       smp_done_o,
  output wire       sub_rst_n_o,
  output wire [1:0] op_q_o,
  output wire       n_sel_q_o,
  // quan sat
  output wire [3:0] state_o,
  output wire       ev_hmac_o,
  output wire       ev_ks_o,
  output wire       ev_init_o,
  output wire       ev_px_o,
  output wire       ev_chk_o,
  output wire       ev_done_o
);
  localparam [3:0] S_IDLE = 4'd0, S_HMAC_GO = 4'd1, S_HMAC_WAIT = 4'd2, S_KS_GO = 4'd3, S_KS_WAIT = 4'd4,
                   S_FY_INIT = 4'd5, S_FY_LOOP = 4'd6, S_PX = 4'd7, S_PXW = 4'd8, S_CHK = 4'd9,
                   S_CHK2 = 4'd10, S_DONE = 4'd11, S_SOFT = 4'd12;

  reg [3:0] st_q;
  reg       key_vld_q;
  reg       init_q;           // dang tinh KDF cua lan nap khoa (khong phai tai tao giua cac mau)
  reg       err_q;
  reg [1:0] op_q;
  reg       nsel_q;

  wire idle = (st_q == S_IDLE);

  assign start_acc_o = idle & start_i & key_vld_q & ~load_key_i & ~soft_rst_i;
  assign ctr_ld_o    = idle & load_key_i & ~soft_rst_i;
  assign kdf_start_o = (st_q == S_HMAC_GO);
  assign x_load_o    = (st_q == S_HMAC_WAIT) & kdf_done_i;
  assign step_en_o   = (st_q == S_KS_GO) | ((st_q == S_FY_LOOP) & fy_need_x_i);
  assign ks_cap_o    = (st_q == S_KS_WAIT) & x_vld_i;
  assign fy_start_o  = (st_q == S_FY_INIT);
  assign px_en_o     = (st_q == S_PX);
  assign smp_done_o  = (st_q == S_CHK);
  assign sub_rst_n_o = (st_q != S_SOFT);

  assign busy_o    = ~idle;
  assign done_o    = (st_q == S_DONE);
  assign key_vld_o = key_vld_q;
  assign err_wd_o  = err_q;
  assign op_q_o    = op_q;
  assign n_sel_q_o = nsel_q;
  assign state_o   = st_q;

  assign ev_hmac_o = (st_q == S_HMAC_WAIT) & kdf_done_i;
  assign ev_ks_o   = (st_q == S_KS_WAIT) & x_vld_i;
  assign ev_init_o = (st_q == S_FY_INIT);
  assign ev_px_o   = (st_q == S_PXW) & px_done_i;
  assign ev_chk_o  = (st_q == S_CHK2);
  assign ev_done_o = (st_q == S_DONE);

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      st_q      <= S_IDLE;
      key_vld_q <= 1'b0;
      init_q    <= 1'b0;
      err_q     <= 1'b0;
      op_q      <= 2'b00;
      nsel_q    <= 1'b0;
    end else if (soft_rst_i && st_q != S_SOFT) begin
      st_q      <= S_SOFT;
      key_vld_q <= 1'b0;
      init_q    <= 1'b0;
      err_q     <= 1'b0;
    end else begin
      case (st_q)
        S_IDLE: begin
          if (load_key_i) begin
            key_vld_q <= 1'b0;
            init_q    <= 1'b1;
            st_q      <= S_HMAC_GO;
          end else if (start_i && key_vld_q) begin
            op_q   <= op_i;
            nsel_q <= n_sel_i;
            err_q  <= 1'b0;
            st_q   <= S_KS_GO;
          end
        end
        S_HMAC_GO:   st_q <= S_HMAC_WAIT;
        S_HMAC_WAIT: if (kdf_done_i) begin
          if (init_q) begin
            init_q    <= 1'b0;
            key_vld_q <= 1'b1;
            st_q      <= S_IDLE;
          end else begin
            st_q <= S_DONE;
          end
        end
        S_KS_GO:     st_q <= S_KS_WAIT;
        S_KS_WAIT:   if (x_vld_i) st_q <= S_FY_INIT;
        S_FY_INIT:   st_q <= S_FY_LOOP;
        S_FY_LOOP:   if (fy_done_i) begin
          if (fy_err_i) err_q <= 1'b1;
          st_q <= S_PX;
        end
        S_PX:        st_q <= S_PXW;
        S_PXW:       if (px_done_i) st_q <= S_CHK;
        S_CHK:       st_q <= S_CHK2;
        S_CHK2:      st_q <= reseed_due_i ? S_HMAC_GO : S_DONE;
        S_DONE:      st_q <= S_IDLE;
        S_SOFT:      st_q <= S_IDLE;
        default:     st_q <= S_IDLE;
      endcase
    end
  end
endmodule
