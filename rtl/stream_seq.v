// stream_seq.v - dieu phoi luong ghi am: nguon mau -> in_fifo -> loi ma hoa -> out_fifo. Verilog-2001.
//
// NGO VAO (moi mau tu nguon, src_vld_i):
//   in_fifo con cho  -> day {gap_pend, s16} vao in_fifo, gap_pend <= 0.
//   in_fifo day      -> BO mau (TRUOC ma hoa): drop_o = 1, gap_pend <= 1. Mau duoc day ke tiep mang GAP = 1.
//   en_i = 0: khong nhan mau moi; xoa gap_pend (lan bat sau la ban ghi moi, khong phai lo thoi gian).
// NGO RA (moi lan dung mot mau, khong chong cheo):
//   IDLE  : in_fifo khong rong & out_fifo CHUA day -> doc in_fifo. KHONG phu thuoc en_i: tat ENABLE thi ngung nhan mau
//           moi nhung van ma hoa NOT moi mau da thu (in_fifo tu rut het) -> RTOS "tat roi rut out_fifo" lay du phan cuoi
//           ban ghi, va lan bat sau khong lan mau cu vao ban ghi moi.
//           (Kiem out_fifo truoc khi lay mau: out_fifo day thi dung ma hoa, mau don lai o in_fifo roi bi bo o ngo vao
//            -> moi mat mat deu xay ra TRUOC ma hoa, keystream / idx luon lien mach.)
//   WAITD : nhan du lieu tu in_fifo (doc tre 1 chu ky).
//   REQ   : giu core_req_o = 1 (ENC, N = 16) den khi core_ack_i (loi nhan start; cho ca khi chua co khoa).
//           clr_i (FIFO_CLR): bo mau dang giu (chua ma hoa -> khong ton keystream) va ve IDLE.
//   RUN   : cho core_done_i. Mau da bat dau ma hoa thi LUON duoc day ra out_fifo vi keystream da tieu thu.
//           Chi abort_i (loi bi reset: KEY_CLEAR) moi huy.
// busy_o = dang xu ly mot mau HOAC in_fifo con mau: khoi thanh ghi chan lenh che do REG cho den khi rut xong.
//   PUSH  : day tu {ctr[7:0], GAP, VALID = 1, idx[5:0], C[15:0]} (ctr / idx DA DUNG cho chinh mau nay), ve IDLE.
//           Co full cua out_fifo la thanh ghi cap nhat ngay canh day, nen o IDLE ke tiep da phan anh tu vua day.
// push_o = xung day out_fifo (dem SAMPLE_CNT); drop_o = xung bo mau (dem DROP_CNT, bat IN_OVF).
module stream_seq (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        en_i,
  input  wire        clr_i,
  input  wire        abort_i,
  // nguon mau
  input  wire        src_vld_i,
  input  wire [15:0] src_data_i,
  // in_fifo (DW = 17: {gap, s16})
  input  wire        in_full_i,
  output wire        in_wr_en_o,
  output wire [16:0] in_wr_data_o,
  input  wire        in_empty_i,
  output wire        in_rd_en_o,
  input  wire [16:0] in_rd_data_i,
  input  wire        in_rd_vld_i,
  // out_fifo (DW = 32)
  input  wire        out_full_i,
  output wire        out_wr_en_o,
  output wire [31:0] out_wr_data_o,
  // loi ma hoa
  output wire        core_req_o,
  output wire [15:0] core_pt_o,
  input  wire        core_ack_i,
  input  wire        core_done_i,
  input  wire [15:0] core_ct_i,
  input  wire [7:0]  core_ctr_i,          // 8 bit thap cua ctr da dung
  input  wire [5:0]  core_idx_i,          // idx da dung (0..63)
  // su kien
  output wire        drop_o,
  output wire        push_o,
  output wire        busy_o
);
  localparam [2:0] S_IDLE = 3'd0, S_WAITD = 3'd1, S_REQ = 3'd2, S_RUN = 3'd3, S_PUSH = 3'd4;

  reg [2:0]  st_q;
  reg        gap_pend_q, gap_q;
  reg [15:0] pt_q;

  // ---- ngo vao
  wire take   = en_i & src_vld_i;
  wire drop   = take & in_full_i;
  wire accept = take & ~in_full_i;

  always @(posedge clk_i) begin
    if (!rst_n_i)         gap_pend_q <= 1'b0;
    else if (!en_i)       gap_pend_q <= 1'b0;
    else if (drop)        gap_pend_q <= 1'b1;
    else if (accept)      gap_pend_q <= 1'b0;
  end

  // ---- ngo ra
  wire pop = (st_q == S_IDLE) & ~clr_i & ~in_empty_i & ~out_full_i;

  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      st_q  <= S_IDLE;
      gap_q <= 1'b0;
      pt_q  <= 16'd0;
    end else if (abort_i) begin
      st_q  <= S_IDLE;
    end else begin
      case (st_q)
        S_IDLE:  if (pop) st_q <= S_WAITD;
        S_WAITD: begin
                   if (in_rd_vld_i) begin
                     gap_q <= in_rd_data_i[16];
                     pt_q  <= in_rd_data_i[15:0];
                   end
                   st_q <= clr_i ? S_IDLE : S_REQ;
                 end
        S_REQ:   if (clr_i)           st_q <= S_IDLE;
                 else if (core_ack_i) st_q <= S_RUN;
        S_RUN:   if (core_done_i) st_q <= S_PUSH;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  assign in_wr_en_o    = accept;
  assign in_wr_data_o  = {gap_pend_q, src_data_i};
  assign in_rd_en_o    = pop;
  assign out_wr_en_o   = (st_q == S_PUSH);
  assign out_wr_data_o = {core_ctr_i, gap_q, 1'b1, core_idx_i, core_ct_i};
  assign core_req_o    = (st_q == S_REQ) & ~clr_i;
  assign core_pt_o     = pt_q;
  assign drop_o        = drop;
  assign push_o        = (st_q == S_PUSH);
  assign busy_o        = (st_q != S_IDLE) | ~in_empty_i;
endmodule
