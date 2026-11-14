// fy_shuffle.v - hoan vi Fisher-Yates (Durstenfeld) dieu khien boi bit hon loan: bitpool + rand_range + perm_regs. Verilog-2001.
// Bit-exact voi refmodel/fisher_yates.py: fisher_yates_from_chaos (muc 4.3.4 - 4.3.5, SPEC 1.0.0).
//
// Thuat toan (i = N-1 .. 1):  rng = i + 1 ;  b = bitlen(rng - 1) = bitlen(i)
//   rut b bit tu bitpool (bit cu nhat ra truoc, la bit THAP cua X) -> cand ;  cand >= rng thi loai (reject), rut lai
//   cand < rng thi hoan doi pi[i] <-> pi[cand].
// Bitpool bat dau RONG moi lan fy_start. Khi thieu bit (cnt < b) phat fy_need_x_o va doi x_vld_i; moi lan nap them 32 bit
// cua X moi (bit 0 vao truoc). Bit du cua lan nap truoc van dung tiep trong cung hoan vi.
//
// Giao tiep:
//   fy_start_i : xung khi dang ranh (fy_busy_o = 0). n_sel_i chot luc do: 0 -> N = 8, 1 -> N = 16.
//   fy_need_x_o: xung to hop 1 chu ky; core_fsm noi thanh step_en cua lts_iter. fy_shuffle doi x_vld_i roi chot x_i.
//                x_i chi duoc doc o chu ky co x_vld_i = 1 (lts_iter giu x_o on dinh, nhung khong can).
//   fy_done_o  : xung 1 chu ky; luc do pi_o day du va giu nguyen den fy_start ke tiep.
//   pi_o       : nibble i (pi_o[4*i +: 4]) = pi[i]; chi 4*N bit thap co nghia (N = 8: nibble 8..15 giu gia tri khoi tao).
//   err_wd_o   : 1 neu so lan nap > 64 trong mot hoan vi (watchdog, D5); khi do bo hoan vi, fy_done_o van phat.
//   dbg_refills_o / dbg_rejects_o : so lan nap / loai trong hoan vi nay (bao hoa 255), giu den fy_start ke tiep.
// Cong ev_* chi de mo phong / ILA (khong co chuc nang): xung to hop trong chu ky hanh dong xay ra, theo thu tu
// REFILL -> DRAW -> SWAP giong trace cua golden.
module fy_shuffle (
  input  wire        clk_i,
  input  wire        rst_n_i,
  input  wire        fy_start_i,
  input  wire        n_sel_i,
  input  wire [31:0] x_i,
  input  wire        x_vld_i,
  output wire        fy_need_x_o,
  output wire        fy_busy_o,
  output reg         fy_done_o,
  output reg         err_wd_o,
  output wire [63:0] pi_o,
  output wire [7:0]  dbg_refills_o,
  output wire [7:0]  dbg_rejects_o,
  // trace taps
  output wire        ev_refill_o,
  output wire        ev_draw_o,
  output wire [4:0]  ev_rng_o,
  output wire [2:0]  ev_b_o,
  output wire [3:0]  ev_cand_o,
  output wire        ev_acc_o,
  output wire        ev_swap_o,
  output wire [3:0]  ev_i_o,
  output wire [3:0]  ev_j_o
);
  localparam [1:0] S_IDLE = 2'd0, S_DRAW = 2'd1, S_WAITX = 2'd2, S_SWAP = 2'd3;
  localparam [63:0] PI_ID = 64'hFEDCBA9876543210;

  reg [1:0]  st_q;
  reg [3:0]  i_q;                 // chi so dang hoan vi, N-1 .. 1
  reg [3:0]  cand_q;              // ung vien da chap nhan, cho S_SWAP
  reg [63:0] pool_q;              // bitpool: bit cu nhat o bit 0
  reg [6:0]  cnt_q;               // so bit hop le trong pool
  reg [63:0] pi_q;
  reg [7:0]  refills_q, rejects_q;

  // ---- rand_range (to hop): b = bitlen(i), cand = b bit thap cua pool
  wire [2:0] b      = i_q[3] ? 3'd4 : i_q[2] ? 3'd3 : i_q[1] ? 3'd2 : 3'd1;
  wire [3:0] msk    = (4'd1 << b) - 4'd1;             // 4 bit: b = 4 -> 0 - 1 = 4'hF
  wire [3:0] cand_w = pool_q[3:0] & msk;
  wire       have   = (cnt_q >= {4'd0, b});
  wire       acc_w  = (cand_w <= i_q);                // cand < rng = i + 1

  // ---- hoan doi pi[i] <-> pi[cand]
  wire [3:0] pi_a = pi_q[4*i_q    +: 4];
  wire [3:0] pi_c = pi_q[4*cand_q +: 4];

  assign fy_need_x_o = (st_q == S_DRAW) && !have;
  assign fy_busy_o   = (st_q != S_IDLE);
  assign pi_o        = pi_q;
  assign dbg_refills_o = refills_q;
  assign dbg_rejects_o = rejects_q;

  assign ev_refill_o = (st_q == S_WAITX) && x_vld_i && (refills_q < 8'd64);
  assign ev_draw_o   = (st_q == S_DRAW) && have;
  assign ev_rng_o    = {1'b0, i_q} + 5'd1;
  assign ev_b_o      = b;
  assign ev_cand_o   = cand_w;
  assign ev_acc_o    = acc_w;
  assign ev_swap_o   = (st_q == S_SWAP);
  assign ev_i_o      = i_q;
  assign ev_j_o      = cand_q;

  // du lieu (khong reset)
  always @(posedge clk_i) begin
    case (st_q)
      S_IDLE: if (fy_start_i) begin
        pi_q      <= PI_ID;
        pool_q    <= 64'd0;
        cnt_q     <= 7'd0;
        refills_q <= 8'd0;
        rejects_q <= 8'd0;
        i_q       <= n_sel_i ? 4'd15 : 4'd7;
      end
      S_DRAW: if (have) begin
        pool_q <= pool_q >> b;
        cnt_q  <= cnt_q - {4'd0, b};
        if (acc_w) cand_q <= cand_w;
        else if (rejects_q != 8'hFF) rejects_q <= rejects_q + 8'd1;
      end
      S_WAITX: if (x_vld_i && refills_q < 8'd64) begin
        pool_q    <= pool_q | ({32'd0, x_i} << cnt_q);
        cnt_q     <= cnt_q + 7'd32;
        refills_q <= refills_q + 8'd1;
      end
      S_SWAP: begin
        pi_q[4*i_q    +: 4] <= pi_c;
        pi_q[4*cand_q +: 4] <= pi_a;
        i_q <= i_q - 4'd1;
      end
      default: ;
    endcase
  end

  // dieu khien (co reset)
  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      st_q      <= S_IDLE;
      fy_done_o <= 1'b0;
      err_wd_o  <= 1'b0;
    end else begin
      fy_done_o <= 1'b0;
      case (st_q)
        S_IDLE: if (fy_start_i) begin
          err_wd_o <= 1'b0;
          st_q     <= S_DRAW;
        end
        S_DRAW: begin
          if (!have)      st_q <= S_WAITX;
          else if (acc_w) st_q <= S_SWAP;
        end
        S_WAITX: if (x_vld_i) begin
          if (refills_q < 8'd64) st_q <= S_DRAW;
          else begin
            err_wd_o  <= 1'b1;               // watchdog: nap qua 64 lan
            fy_done_o <= 1'b1;
            st_q      <= S_IDLE;
          end
        end
        S_SWAP: begin
          if (i_q == 4'd1) begin
            fy_done_o <= 1'b1;
            st_q      <= S_IDLE;
          end else st_q <= S_DRAW;
        end
        default: st_q <= S_IDLE;
      endcase
    end
  end
endmodule

