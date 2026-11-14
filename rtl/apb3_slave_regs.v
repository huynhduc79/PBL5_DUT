// apb3_slave_regs.v - APB3 slave + thanh ghi dieu khien / trang thai cua khoi ghi am ma hoa. Verilog-2001.
// Ban do thanh ghi: docs/HOP_DONG_FPGA_RTOS.md (chot v1.0). Cua so 256 byte, chi giai ma paddr[7:2]. Moi truy cap 32 bit.
// Dia chi khong anh xa: doc 0, ghi bo qua. pslverr_o luon 0 (tranh ngoai le bus tren RISC-V).
// pready_o = 1 ngay o pha ACCESS, TRU doc OUT_DATA (0x40): them 1 chu ky cho (FIFO doc qua thanh ghi). Lay tu khoi
//   out_fifo chi xay ra o chu ky ACCESS dau tien cua lan doc do va chi khi FIFO khong rong; rong thi tra 0 (VALID = 0).
//
//  0x00 CTRL       R/W  [0] ENABLE  [1] START (xung)  [2] RESEED_NOW (xung)  [3] FIFO_CLR (xung)  [4] KEY_CLEAR (xung)
//                       [5] BYPASS (khong tong hop: doc 0)  [7:6] OP  [8] N_SEL (mac dinh 1)  [31] SOFT_RESET (xung)
//  0x04 STATUS     R/W1C [0] BUSY [1] KEY_READY [2] ERROR* [3] IN_OVF* [4] OUT_FULL [5] OUT_GE_THRESH [6] I2S_RUNNING
//                       [7] CTR_REJECTED* [8] CMD_IGN*        (* = W1C)
//  0x08..0x24 KMASTER[0..7] W   KMASTER[0] = K[255:224]. Doc 0.
//  0x28 CTR        R/W  Ghi: chi nhan khi la lan ghi DAU TIEN sau reset/SOFT_RESET, hoac LON HON moi ctr da ghi va moi ctr
//                       loi da dung / dang dung (ctr cua phien hien tai khi KEY_READY); nguoc lai bo qua, bat CTR_REJECTED.
//                       Doc: KEY_READY ? ctr cua phien hien tai : ctr da ghi.
//  0x2C DATA_IN    W    SRC_SEL = 3, ENABLE = 0, KEY_READY = 1, loi ranh: chot [15:0] va start 1 mau (OP, N_SEL). Khac -> CMD_IGN.
//  0x30 DATA_OUT   R    [15:0] ket qua mau gan nhat cua loi
//  0x34 I2S_CFG    R/W  [11:0] SCK_DIV (mac dinh 24)  [12] CHANNEL  [19:16] SHIFT
//  0x38 SRC_SEL    R/W  [1:0] 0 MIC  1 RAMP  2 SINE  3 REG
//  0x3C FIFO_LEVEL R    [15:0] muc out_fifo  [31:16] muc in_fifo
//  0x40 OUT_DATA   R    lay 1 tu khoi out_fifo (xem tren)
//  0x44 IRQ_THRESH R/W  mac dinh 256
//  0x48 IRQ_EN     R/W  [0] THRESH [1] IN_OVF [2] ERROR
//  0x4C IRQ_STATUS R/W1C cung bit. THRESH dat lai moi chu ky muc out >= IRQ_THRESH; IN_OVF khi bo mau; ERROR khi loi
//                       bao watchdog (canh len). irq_o = |(IRQ_STATUS & IRQ_EN) (qua thanh ghi).
//  0x50 DROP_CNT   R / W xoa   0x54 SAMPLE_CNT R (so tu da day vao out_fifo)   0x58 CYCLES_MAX R / W xoa
//  0x5C STARTUP_SKIP R/W (mac dinh 4096)   0x60 VERSION R = 0x0002_0100   0x64 CLIP_CNT R / W xoa (bo dem o sample_fmt)
//  0x68 DBG        R    [7:0] steps [15:8] refills [23:16] rejects [27:24] trang thai core_fsm
//
// Lenh:
//  START: nhu DATA_IN nhung khong doi du lieu (dung cho OP = SKIP).
//  RESEED_NOW: nap khoa phien tu KMASTER va CTR. Chi nhan khi loi ranh VA CTR da duoc ghi (nhan) ke tu lan nap truoc
//    -> khong the nap lai cung mot ctr hai lan (chong dung lai keystream). Khac -> CMD_IGN.
//  KEY_CLEAR: xoa KMASTER va reset loi (xoa khoa phien, ke ca dang xu ly mot mau).
//  SOFT_RESET: soft_rst_o = xung 1 chu ky reset toan khoi (ke ca chinh khoi nay va bo so sanh CTR).
//  Moi bit xung doc ve 0. Mot lan ghi CTRL co nhieu bit xung: KEY_CLEAR > RESEED_NOW > START (bit thua -> CMD_IGN).
//  Cac lenh (reseed_o, reg_start_o, key_clear_o, fifo_clr_o, clip_clr_o) la xung TO HOP o dung chu ky ACCESS cua lan ghi,
//  dieu kien xet o cung chu ky do -> khong co khe 1 chu ky de stream_seq chen vao giua kiem tra va lenh. Top phan xu:
//  key_clear / reseed uu tien hon start cua stream_seq (core_fsm cung uu tien load_key hon start).
//  reg_pt_o / reg_op_o / reg_nsel_o lay gia tri cua chinh lan ghi do (loi chot luc start).
// CYCLES_MAX: so chu ky tu canh loi nhan start den chu ky done_o (cung dinh nghia voi sim/tb_cycles.v), lay max.
module apb3_slave_regs #(
  parameter [15:0] BLOCK_VER = 16'h0002,
  parameter [15:0] SPEC_VER  = 16'h0100
) (
  input  wire         clk_i,
  input  wire         rst_n_i,
  // APB3
  input  wire         psel_i,
  input  wire         penable_i,
  input  wire         pwrite_i,
  input  wire [7:0]   paddr_i,
  input  wire [31:0]  pwdata_i,
  output wire [31:0]  prdata_o,
  output wire         pready_o,
  output wire         pslverr_o,
  // dieu khien
  output wire         soft_rst_o,
  output wire         enable_o,
  output wire         reseed_o,
  output wire         reg_start_o,
  output wire [1:0]   reg_op_o,
  output wire         reg_nsel_o,
  output wire [15:0]  reg_pt_o,
  output wire         fifo_clr_o,
  output wire         key_clear_o,
  output wire [255:0] key_o,
  output wire [31:0]  ctr0_o,
  output wire [11:0]  sck_div_o,
  output wire         channel_o,
  output wire [3:0]   shift_o,
  output wire [1:0]   src_sel_o,
  output wire [31:0]  startup_skip_o,
  output wire         clip_clr_o,
  output wire         irq_o,
  // out_fifo (doc)
  output wire         out_rd_en_o,
  input  wire [31:0]  out_rd_data_i,
  input  wire         out_rd_vld_i,
  input  wire         out_empty_i,
  input  wire         out_full_i,
  input  wire [11:0]  out_level_i,
  input  wire [6:0]   in_level_i,
  // trang thai
  input  wire         core_busy_i,
  input  wire         stream_busy_i,
  input  wire         core_key_vld_i,
  input  wire         core_err_i,
  input  wire         core_start_i,
  input  wire         core_done_i,
  input  wire [15:0]  core_ct_i,
  input  wire [31:0]  core_ctr_live_i,
  input  wire [7:0]   dbg_steps_i,
  input  wire [7:0]   dbg_refills_i,
  input  wire [7:0]   dbg_rejects_i,
  input  wire [3:0]   dbg_state_i,
  input  wire         i2s_running_i,
  input  wire         drop_i,
  input  wire         push_i,
  input  wire [31:0]  clip_cnt_i
);
  // ---- giai ma dia chi
  localparam [5:0] A_CTRL = 6'h00, A_STATUS = 6'h01, A_CTR = 6'h0A, A_DIN = 6'h0B, A_DOUT = 6'h0C, A_I2S = 6'h0D,
                   A_SRC = 6'h0E, A_LVL = 6'h0F, A_OUT = 6'h10, A_THR = 6'h11, A_IEN = 6'h12, A_IST = 6'h13,
                   A_DROP = 6'h14, A_SCNT = 6'h15, A_CYC = 6'h16, A_SKIP = 6'h17, A_VER = 6'h18, A_CLIP = 6'h19,
                   A_DBG = 6'h1A;

  wire [5:0] a      = paddr_i[7:2];
  wire       unused_ok = &{1'b0, paddr_i[1:0]};   // truy cap luon 32 bit: paddr[1:0] bo qua
  wire       acc    = psel_i & penable_i;
  wire       wr     = acc & pwrite_i;
  wire       is_out = (a == A_OUT);
  reg        pop_ph_q;                       // dang o chu ky cho cua lan doc OUT_DATA
  wire       pop1   = acc & ~pwrite_i & is_out & ~pop_ph_q;

  // ---- thanh ghi
  reg         srst_q;
  reg         en_q, nsel_q;
  reg  [1:0]  op_q, src_q;
  reg  [255:0] key_q;
  reg  [31:0] ctr_wr_q, ctr_max_q, thr_q, skip_q, drop_q, scnt_q, cyc_max_q, cyc_q;
  reg         ctr_has_q, ctr_fresh_q;
  reg  [15:0] pt_q;
  reg  [11:0] div_q;
  reg         ch_q;
  reg  [3:0]  sh_q;
  reg  [2:0]  ien_q, ist_q;
  reg         st_err_q, st_ovf_q, st_rej_q, st_ign_q, err_d_q, irq_q, cyc_run_q;

  wire        out_ge   = ({20'd0, out_level_i} >= thr_q);
  wire        core_idle = ~core_busy_i & ~stream_busy_i;

  // lenh tu lan ghi hien tai
  wire        w_ctrl   = wr & (a == A_CTRL);
  wire        w_kclr   = w_ctrl & pwdata_i[4];
  wire        w_reseed = w_ctrl & pwdata_i[2] & ~pwdata_i[4];
  wire        reseed_ok = w_reseed & ~core_busy_i & ctr_fresh_q;
  wire        w_start  = w_ctrl & pwdata_i[1] & ~pwdata_i[2] & ~pwdata_i[4];
  wire        start_ctrl_ok = w_start & ~(en_q | pwdata_i[0]) & (src_q == 2'd3) & core_key_vld_i & core_idle;
  wire        w_din    = wr & (a == A_DIN);
  wire        din_ok   = w_din & ~en_q & (src_q == 2'd3) & core_key_vld_i & core_idle;
  wire        w_ctr    = wr & (a == A_CTR);
  wire [31:0] ctr_floor = (core_key_vld_i && core_ctr_live_i > ctr_max_q) ? core_ctr_live_i : ctr_max_q;
  wire        ctr_ok   = w_ctr & (~ctr_has_q | (pwdata_i > ctr_floor));
  wire        ign_evt  = (w_reseed & ~reseed_ok) | (w_ctrl & pwdata_i[1] & ~start_ctrl_ok) | (w_din & ~din_ok);
  wire        err_rise = core_err_i & ~err_d_q;

  always @(posedge clk_i) begin
    if (!rst_n_i || srst_q) begin
      srst_q <= 1'b0;
      en_q <= 1'b0; nsel_q <= 1'b1; op_q <= 2'b00; src_q <= 2'd0;
      key_q <= 256'd0;
      ctr_wr_q <= 32'd0; ctr_max_q <= 32'd0; ctr_has_q <= 1'b0; ctr_fresh_q <= 1'b0;
      pt_q <= 16'd0;
      div_q <= 12'd24; ch_q <= 1'b0; sh_q <= 4'd0;
      thr_q <= 32'd256; ien_q <= 3'd0; ist_q <= 3'd0;
      skip_q <= 32'd4096;
      drop_q <= 32'd0; scnt_q <= 32'd0; cyc_max_q <= 32'd0; cyc_q <= 32'd0; cyc_run_q <= 1'b0;
      st_err_q <= 1'b0; st_ovf_q <= 1'b0; st_rej_q <= 1'b0; st_ign_q <= 1'b0; err_d_q <= 1'b0; irq_q <= 1'b0;
      pop_ph_q <= 1'b0;
    end else begin
      err_d_q   <= core_err_i;

      // pha cho cua doc OUT_DATA
      if (pop1)     pop_ph_q <= 1'b1;
      else if (acc) pop_ph_q <= 1'b0;

      // ---- ghi
      if (wr) begin
        case (a)
          A_CTRL: begin
            en_q   <= pwdata_i[0];
            op_q   <= pwdata_i[7:6];
            nsel_q <= pwdata_i[8];
            if (pwdata_i[31]) srst_q <= 1'b1;
          end
          A_STATUS: begin
            if (pwdata_i[2]) st_err_q <= 1'b0;
            if (pwdata_i[3]) st_ovf_q <= 1'b0;
            if (pwdata_i[7]) st_rej_q <= 1'b0;
            if (pwdata_i[8]) st_ign_q <= 1'b0;
          end
          6'h02: key_q[255:224] <= pwdata_i;
          6'h03: key_q[223:192] <= pwdata_i;
          6'h04: key_q[191:160] <= pwdata_i;
          6'h05: key_q[159:128] <= pwdata_i;
          6'h06: key_q[127:96]  <= pwdata_i;
          6'h07: key_q[95:64]   <= pwdata_i;
          6'h08: key_q[63:32]   <= pwdata_i;
          6'h09: key_q[31:0]    <= pwdata_i;
          A_I2S:  begin div_q <= pwdata_i[11:0]; ch_q <= pwdata_i[12]; sh_q <= pwdata_i[19:16]; end
          A_SRC:  src_q <= pwdata_i[1:0];
          A_THR:  thr_q <= pwdata_i;
          A_IEN:  ien_q <= pwdata_i[2:0];
          A_SKIP: skip_q <= pwdata_i;
          default: ;
        endcase
      end

      // ---- lenh
      if (w_kclr)    key_q       <= 256'd0;
      if (reseed_ok) ctr_fresh_q <= 1'b0;
      if (din_ok)    pt_q        <= pwdata_i[15:0];
      if (ign_evt)   st_ign_q    <= 1'b1;

      // ---- CTR: tang nghiem ngat
      if (ctr_ok) begin
        ctr_wr_q    <= pwdata_i;
        ctr_max_q   <= pwdata_i;
        ctr_has_q   <= 1'b1;
        ctr_fresh_q <= 1'b1;
      end else begin
        if (w_ctr) st_rej_q <= 1'b1;
        ctr_max_q <= ctr_floor;                   // nho ctr cao nhat loi da dung, ke ca sau KEY_CLEAR
      end

      // ---- bo dem (ghi xoa uu tien, su kien cung chu ky van duoc dem)
      if (wr && a == A_DROP) drop_q <= {31'd0, drop_i};
      else if (drop_i && drop_q != 32'hFFFFFFFF) drop_q <= drop_q + 32'd1;
      if (push_i && scnt_q != 32'hFFFFFFFF) scnt_q <= scnt_q + 32'd1;

      if (core_start_i) begin
        cyc_q <= 32'd0; cyc_run_q <= 1'b1;
      end else if (cyc_run_q) begin
        if (core_done_i) cyc_run_q <= 1'b0;
        else             cyc_q <= cyc_q + 32'd1;
      end
      if (wr && a == A_CYC)                                cyc_max_q <= 32'd0;
      else if (cyc_run_q && core_done_i && cyc_q > cyc_max_q) cyc_max_q <= cyc_q;

      // ---- trang thai / ngat
      if (err_rise) st_err_q <= 1'b1;
      if (drop_i)   st_ovf_q <= 1'b1;
      if (wr && a == A_IST) ist_q <= ist_q & ~pwdata_i[2:0];
      if (out_ge)   ist_q[0] <= 1'b1;
      if (drop_i)   ist_q[1] <= 1'b1;
      if (err_rise) ist_q[2] <= 1'b1;
      irq_q <= |(ist_q & ien_q);
    end
  end

  // ---- doc
  wire [31:0] status_w = {23'd0, st_ign_q, st_rej_q, i2s_running_i, out_ge, out_full_i, st_ovf_q, st_err_q,
                          core_key_vld_i, core_busy_i};
  reg  [31:0] rmux;
  always @(*) begin
    case (a)
      A_CTRL:   rmux = {23'd0, nsel_q, op_q, 5'd0, en_q};
      A_STATUS: rmux = status_w;
      A_CTR:    rmux = core_key_vld_i ? core_ctr_live_i : ctr_wr_q;
      A_DOUT:   rmux = {16'd0, core_ct_i};
      A_I2S:    rmux = {12'd0, sh_q, 3'd0, ch_q, div_q};
      A_SRC:    rmux = {30'd0, src_q};
      A_LVL:    rmux = {9'd0, in_level_i, 4'd0, out_level_i};
      A_OUT:    rmux = out_rd_vld_i ? out_rd_data_i : 32'd0;
      A_THR:    rmux = thr_q;
      A_IEN:    rmux = {29'd0, ien_q};
      A_IST:    rmux = {29'd0, ist_q};
      A_DROP:   rmux = drop_q;
      A_SCNT:   rmux = scnt_q;
      A_CYC:    rmux = cyc_max_q;
      A_SKIP:   rmux = skip_q;
      A_VER:    rmux = {BLOCK_VER, SPEC_VER};
      A_CLIP:   rmux = clip_cnt_i;
      A_DBG:    rmux = {4'd0, dbg_state_i, dbg_rejects_i, dbg_refills_i, dbg_steps_i};
      default:  rmux = 32'd0;
    endcase
  end

  assign prdata_o       = (acc & ~pwrite_i) ? rmux : 32'd0;
  assign pready_o       = ~pop1;
  assign pslverr_o      = 1'b0;
  assign out_rd_en_o    = pop1 & ~out_empty_i;

  assign soft_rst_o     = srst_q;
  assign enable_o       = en_q;
  assign reseed_o       = reseed_ok;
  assign reg_start_o    = start_ctrl_ok | din_ok;
  assign reg_op_o       = w_ctrl ? pwdata_i[7:6] : op_q;
  assign reg_nsel_o     = w_ctrl ? pwdata_i[8] : nsel_q;
  assign reg_pt_o       = w_din ? pwdata_i[15:0] : pt_q;
  assign fifo_clr_o     = w_ctrl & pwdata_i[3];
  assign key_clear_o    = w_kclr;
  assign key_o          = key_q;
  assign ctr0_o         = ctr_wr_q;
  assign sck_div_o      = div_q;
  assign channel_o      = ch_q;
  assign shift_o        = sh_q;
  assign src_sel_o      = src_q;
  assign startup_skip_o = skip_q;
  assign clip_clr_o     = wr & (a == A_CLIP);
  assign irq_o          = irq_q;
endmodule
