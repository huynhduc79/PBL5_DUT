// chaos_core.v - loi mat ma dong hon loan: ghep hmac_kdf + session_mgr + lts_iter + fy_shuffle + permute_xor + core_fsm.
// Verilog-2001. Chua co bus: chaos_cipher_top (dot 4) noi cac thanh ghi AXI4-Lite vao cac cong "tu/sang thanh ghi".
//
// Bit-exact voi refmodel/cipher.py: CipherCore (ENC / DEC / SKIP = advance), RESEED_INTERVAL la tham so bien dich.
// Luong dieu khien: xem core_fsm.v. Cac cong tap_* / ev_* chi de mo phong va ILA (khong co chuc nang); khi noi vao top va
// de ho, trinh tong hop se cat chung.
//
// Tu thanh ghi:  start_i, soft_rst_i, load_key_i (xung 1 chu ky; chi nhan khi busy_o = 0), op_i (00 ENC / 01 DEC / 1x SKIP),
//                n_sel_i (0: N = 8, 1: N = 16; chot luc start), key_i (giu on dinh tu load_key_i den het lan dung khoa -
//                hmac_kdf doc key_i moi lan tai tao phien), ctr0_i (chot luc load_key_i), pt_in_i (chot luc start;
//                ENC: ban ro, DEC: ban ma).
// Sang thanh ghi: busy_o, done_o (xung), key_vld_o, err_wd_o, ct_out_o (ENC: ban ma, DEC: ban ro; giu den mau ke tiep),
//                ctr_out_o / idx_out_o (ctr, idx DA DUNG cho mau vua xong), dbg_steps_o (= 1 + so lan nap, bao hoa 255),
//                dbg_refills_o, dbg_rejects_o, dbg_state_o (ma trang thai core_fsm), dbg_evt_vld_o / dbg_evt_id_o.
// Ma su kien dbg_evt_id_o: 1 RESEED_HMAC, 2 LTS_KEYSTREAM, 3 FY_INIT, 4 FY_REFILL, 5 FY_DRAW, 6 FY_SWAP, 7 PERMUTE_XOR,
//                8 CHECK_RESEED, 9 DONE (0 = khong co su kien). Moi su kien dung 1 chu ky; cac su kien khong trung nhau.
module chaos_core #(
  parameter RESEED_INTERVAL = 64
) (
  input  wire         clk_i,
  input  wire         rst_n_i,
  // tu thanh ghi
  input  wire         start_i,
  input  wire         soft_rst_i,
  input  wire         load_key_i,
  input  wire [1:0]   op_i,
  input  wire         n_sel_i,
  input  wire [255:0] key_i,
  input  wire [31:0]  ctr0_i,
  input  wire [15:0]  pt_in_i,
  // sang thanh ghi
  output wire         busy_o,
  output wire         done_o,
  output wire         key_vld_o,
  output wire         err_wd_o,
  output wire [15:0]  ct_out_o,
  output wire [31:0]  ctr_out_o,
  output wire [15:0]  idx_out_o,
  output wire [7:0]   dbg_steps_o,
  output wire [7:0]   dbg_refills_o,
  output wire [7:0]   dbg_rejects_o,
  output wire [3:0]   dbg_state_o,
  output wire         dbg_evt_vld_o,
  output wire [3:0]   dbg_evt_id_o,
  // trace taps (mo phong / ILA)
  output wire [31:0]  tap_ctr_o,       // ctr dua vao KDF
  output wire [255:0] tap_ksess_o,
  output wire [31:0]  tap_x0_o,
  output wire [33:0]  tap_r_o,
  output wire [31:0]  tap_xprev_o,     // X truoc buoc LTS dang xong (hop le o chu ky x_vld)
  output wire [31:0]  tap_x_o,         // X moi
  output wire [15:0]  tap_k_o,         // keystream da chot
  output wire [63:0]  tap_pi_o,
  output wire [15:0]  tap_in_o,        // du lieu vao da chot
  output wire [15:0]  tap_sh_o,
  output wire [15:0]  tap_res_o,
  output wire [1:0]   tap_op_o,
  output wire         tap_nsel_o,
  output wire [4:0]   tap_fy_rng_o,
  output wire [2:0]   tap_fy_b_o,
  output wire [3:0]   tap_fy_cand_o,
  output wire         tap_fy_acc_o,
  output wire [3:0]   tap_fy_i_o,
  output wire [3:0]   tap_fy_j_o
);
  // ---- hang so dan xuat (khai bao ham truoc khi dung)
  function integer calc_cnt_w;
    input integer ri;
    integer v, n;
    begin
      v = ri - 1;
      n = 0;
      while (v > 0) begin
        n = n + 1;
        v = v >> 1;
      end
      calc_cnt_w = (n < 1) ? 1 : n;
    end
  endfunction
  localparam CNT_W = calc_cnt_w(RESEED_INTERVAL);

  // ---- day noi
  wire        sub_rst_n;
  wire        start_acc, ctr_ld, kdf_start, x_load, step_en, ks_cap, fy_start, px_en, smp_done;
  wire [1:0]  op_q;
  wire        nsel_q;
  wire        ev_hmac, ev_ks, ev_init, ev_px, ev_chk, ev_done;

  wire        reseed_due;
  wire [31:0] kdf_ctr;
  wire        kdf_busy, kdf_done;
  wire [255:0] k_session;
  wire [31:0] kdf_x0;
  wire [33:0] kdf_r;

  wire        lts_busy, x_vld, guarded;
  wire [31:0] x_o;

  wire        fy_need_x, fy_busy, fy_done, fy_err;
  wire [63:0] pi;
  wire [7:0]  fy_refills, fy_rejects;
  wire        ev_refill, ev_draw, ev_acc, ev_swap;
  wire [4:0]  ev_rng;
  wire [2:0]  ev_b;
  wire [3:0]  ev_cand, ev_i, ev_j;

  wire        px_done;
  wire [15:0] px_res, px_sh, ks;

  reg  [15:0] d_q;
  reg  [31:0] xprev_q;

  wire        core_rst_n = rst_n_i & sub_rst_n;

  // ---- FSM
  core_fsm u_fsm (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .start_i(start_i), .soft_rst_i(soft_rst_i), .load_key_i(load_key_i), .op_i(op_i), .n_sel_i(n_sel_i),
    .kdf_done_i(kdf_done), .x_vld_i(x_vld), .fy_need_x_i(fy_need_x), .fy_done_i(fy_done), .fy_err_i(fy_err),
    .px_done_i(px_done), .reseed_due_i(reseed_due),
    .busy_o(busy_o), .done_o(done_o), .key_vld_o(key_vld_o), .err_wd_o(err_wd_o),
    .start_acc_o(start_acc), .ctr_ld_o(ctr_ld), .kdf_start_o(kdf_start), .x_load_o(x_load), .step_en_o(step_en),
    .ks_cap_o(ks_cap), .fy_start_o(fy_start), .px_en_o(px_en), .smp_done_o(smp_done), .sub_rst_n_o(sub_rst_n),
    .op_q_o(op_q), .n_sel_q_o(nsel_q),
    .state_o(dbg_state_o),
    .ev_hmac_o(ev_hmac), .ev_ks_o(ev_ks), .ev_init_o(ev_init), .ev_px_o(ev_px), .ev_chk_o(ev_chk), .ev_done_o(ev_done)
  );

  // ---- phien
  session_mgr #(.RESEED_INTERVAL(RESEED_INTERVAL), .CNT_W(CNT_W)) u_sess (
    .clk_i(clk_i), .rst_n_i(core_rst_n),
    .ctr_ld_i(ctr_ld), .ctr0_i(ctr0_i),
    .smp_done_i(smp_done), .kdf_start_i(kdf_start),
    .reseed_due_o(reseed_due), .kdf_ctr_o(kdf_ctr),
    .ctr_out_o(ctr_out_o), .idx_out_o(idx_out_o)
  );

  // ---- KDF
  hmac_kdf u_kdf (
    .clk_i(clk_i), .rst_n_i(core_rst_n),
    .start_i(kdf_start), .k_master_i(key_i), .ctr_i(kdf_ctr),
    .busy_o(kdf_busy), .done_o(kdf_done),
    .k_session_o(k_session), .x0_o(kdf_x0), .r_int_o(kdf_r)
  );

  // ---- LTS
  lts_iter u_lts (
    .clk_i(clk_i), .rst_n_i(core_rst_n),
    .x_load_i(x_load), .x0_i(kdf_x0), .xr_i(kdf_r[31:0]),
    .step_en_i(step_en),
    .busy_o(lts_busy), .x_vld_o(x_vld), .x_o(x_o), .guarded_o(guarded)
  );

  // ---- Fisher-Yates
  fy_shuffle u_fy (
    .clk_i(clk_i), .rst_n_i(core_rst_n),
    .fy_start_i(fy_start), .n_sel_i(nsel_q), .x_i(x_o), .x_vld_i(x_vld),
    .fy_need_x_o(fy_need_x), .fy_busy_o(fy_busy), .fy_done_o(fy_done), .err_wd_o(fy_err),
    .pi_o(pi), .dbg_refills_o(fy_refills), .dbg_rejects_o(fy_rejects),
    .ev_refill_o(ev_refill), .ev_draw_o(ev_draw), .ev_rng_o(ev_rng), .ev_b_o(ev_b), .ev_cand_o(ev_cand),
    .ev_acc_o(ev_acc), .ev_swap_o(ev_swap), .ev_i_o(ev_i), .ev_j_o(ev_j)
  );

  // ---- hoan vi + XOR
  permute_xor u_px (
    .clk_i(clk_i), .rst_n_i(core_rst_n),
    .n_sel_i(nsel_q), .ks_cap_i(ks_cap), .x_i(x_o),
    .px_en_i(px_en), .op_i(op_q), .pi_i(pi), .d_i(d_q),
    .px_done_o(px_done), .res_o(px_res), .sh_o(px_sh), .k_o(ks)
  );

  always @(posedge clk_i) begin
    if (start_acc) d_q <= pt_in_i;
    xprev_q <= x_o;
  end

  // ---- cong ra
  wire [8:0] steps_w = {1'b0, fy_refills} + 9'd1;
  assign dbg_steps_o   = steps_w[8] ? 8'hFF : steps_w[7:0];
  assign dbg_refills_o = fy_refills;
  assign dbg_rejects_o = fy_rejects;
  assign ct_out_o      = px_res;

  assign dbg_evt_id_o  = ev_hmac   ? 4'd1 : ev_ks    ? 4'd2 : ev_init   ? 4'd3 : ev_refill ? 4'd4 :
                         ev_draw   ? 4'd5 : ev_swap  ? 4'd6 : ev_px     ? 4'd7 : ev_chk    ? 4'd8 :
                         ev_done   ? 4'd9 : 4'd0;
  assign dbg_evt_vld_o = (dbg_evt_id_o != 4'd0);

  assign tap_ctr_o     = kdf_ctr;
  assign tap_ksess_o   = k_session;
  assign tap_x0_o      = kdf_x0;
  assign tap_r_o       = kdf_r;
  assign tap_xprev_o   = xprev_q;
  assign tap_x_o       = x_o;
  assign tap_k_o       = ks;
  assign tap_pi_o      = pi;
  assign tap_in_o      = d_q;
  assign tap_sh_o      = px_sh;
  assign tap_res_o     = px_res;
  assign tap_op_o      = op_q;
  assign tap_nsel_o    = nsel_q;
  assign tap_fy_rng_o  = ev_rng;
  assign tap_fy_b_o    = ev_b;
  assign tap_fy_cand_o = ev_cand;
  assign tap_fy_acc_o  = ev_acc;
  assign tap_fy_i_o    = ev_i;
  assign tap_fy_j_o    = ev_j;
endmodule
