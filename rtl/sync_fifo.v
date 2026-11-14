// sync_fifo.v - FIFO dong bo mot mien xung, tham so hoa. Verilog-2001.
// Dung cho ca hai hang doi cua lop vo am thanh:
//   in_fifo  : DW = 16, AW = 6   (64 x 16)    - giua i2s_rx/sample_fmt va loi ma hoa
//   out_fifo : DW = 32, AW = 11  (2048 x 32)  - giua stream_seq va thanh ghi OUT_DATA (suy ra LSRAM)
// Do sau = 2^AW (luy thua 2).
//
// Hanh vi (bit-exact voi FifoModel trong tools/gen_vec_batch5.py):
//   - Doc kieu chuan (khong FWFT): rd_en_i duoc nhan o canh k thi rd_data_o hop le sau canh k, kem rd_vld_o = 1
//     trong dung 1 chu ky. rd_data_o giu gia tri den lan doc ke tiep.
//   - Ghi khi day bi bo (wr_en_i & full_o); doc khi rong bi bo (rd_en_i & empty_o, rd_vld_o = 0).
//     Doc va ghi cung chu ky: moi lenh xet theo trang thai TRUOC canh (day: chi doc nhan; rong: chi ghi nhan).
//   - clr_i (dong bo) xoa con tro va muc, uu tien hon wr / rd cung chu ky. Noi dung RAM khong xoa.
//   - full_o, empty_o, level_o la ham cua thanh ghi dem (khong co duong to hop tu wr_en_i / rd_en_i).
// Bo nho khong co reset va doc qua thanh ghi -> Synplify suy ra RAM1K20 (LSRAM) / RAM64x12 (uSRAM).
module sync_fifo #(
  parameter DW = 16,
  parameter AW = 6
) (
  input  wire          clk_i,
  input  wire          rst_n_i,
  input  wire          clr_i,
  input  wire          wr_en_i,
  input  wire [DW-1:0] wr_data_i,
  input  wire          rd_en_i,
  output wire [DW-1:0] rd_data_o,
  output wire          rd_vld_o,
  output wire          full_o,
  output wire          empty_o,
  output wire [AW:0]   level_o
);
  localparam [AW:0] DEPTH = {1'b1, {AW{1'b0}}};

  reg [DW-1:0] mem [0:(1 << AW) - 1];
  reg [AW-1:0] wptr_q, rptr_q;
  reg [AW:0]   cnt_q;
  reg [DW-1:0] rdata_q;
  reg          rvld_q;

  wire full  = (cnt_q == DEPTH);
  wire empty = (cnt_q == {(AW+1){1'b0}});
  wire do_wr = wr_en_i & ~full  & ~clr_i;
  wire do_rd = rd_en_i & ~empty & ~clr_i;

  // ---- bo nho: ghi dong bo, doc qua thanh ghi (khong reset de suy ra RAM)
  always @(posedge clk_i) begin
    if (do_wr) mem[wptr_q] <= wr_data_i;
  end

  always @(posedge clk_i) begin
    if (do_rd) rdata_q <= mem[rptr_q];
  end

  // ---- con tro va bo dem
  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      wptr_q <= {AW{1'b0}};
      rptr_q <= {AW{1'b0}};
      cnt_q  <= {(AW+1){1'b0}};
      rvld_q <= 1'b0;
    end else if (clr_i) begin
      wptr_q <= {AW{1'b0}};
      rptr_q <= {AW{1'b0}};
      cnt_q  <= {(AW+1){1'b0}};
      rvld_q <= 1'b0;
    end else begin
      if (do_wr) wptr_q <= wptr_q + 1'b1;
      if (do_rd) rptr_q <= rptr_q + 1'b1;
      if (do_wr & ~do_rd)      cnt_q <= cnt_q + 1'b1;
      else if (do_rd & ~do_wr) cnt_q <= cnt_q - 1'b1;
      rvld_q <= do_rd;
    end
  end

  assign rd_data_o = rdata_q;
  assign rd_vld_o  = rvld_q;
  assign full_o    = full;
  assign empty_o   = empty;
  assign level_o   = cnt_q;
endmodule
