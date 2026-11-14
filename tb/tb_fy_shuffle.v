// tb_fy_shuffle.v - kiem tra fy_shuffle.v voi chuoi su kien Fisher-Yates cua golden. Verilog-2001.
//
// Du lieu (tb/gen_vec_batch2.py): fy_ev.hex = dong su kien theo thu tu (REFILL / DRAW / SWAP), fy_sum.hex = ket qua moi mau.
//   1084 mau lay tu trace golden (N = 8 va 16, LTS that) + 800 mau chuoi x kich thich (0, 1, 0xFFFFFFFF, ngau nhien ...).
// TB dong vai lts_iter: khi fy_need_x_o = 1 thi sau DLY chu ky cap x_vld_i = 1 cung x lay tu dong REFILL ke tiep cua fy_ev.hex.
// Kiem tra moi mau: (1) pi_o (4N bit thap), dbg_refills_o, dbg_rejects_o, err_wd_o = 0, fy_done_o chi 1 chu ky,
// (2) tung su kien ev_refill / ev_draw / ev_swap dung thu tu va dung noi dung (rng, b, cand, acc, i, j),
// (3) moi mau dung dung so su kien (refills + draws + swaps), (4) fy_start_i luc ban bi bo qua (GAP=1),
// (5) watchdog: x = 0xFFFFFFFF mai thi rng = 7 luon bi loai -> err_wd_o = 1 sau dung 64 lan nap, fy_done_o van phat.
// Tham so: +GAP=0|1   (GAP=1: DLY ngau nhien 1..6 chu ky, x_i rac khi x_vld_i = 0, fy_start_i rac luc ban)
`timescale 1ns/1ps
module tb_fy_shuffle;
  parameter MAXEV  = 65536;
  parameter MAXSUM = 4096;

  reg [39:0] ev  [0:MAXEV-1];
  reg [81:0] sm  [0:MAXSUM-1];

  reg         clk, rst_n, fy_start, n_sel, x_vld;
  reg  [31:0] x_i;
  wire        need, busy, done, err;
  wire [63:0] pi_o;
  wire [7:0]  nref, nrej;
  wire        e_ref, e_draw, e_acc, e_swap;
  wire [4:0]  e_rng;
  wire [2:0]  e_b;
  wire [3:0]  e_cand, e_i, e_j;

  fy_shuffle dut (.clk_i(clk), .rst_n_i(rst_n), .fy_start_i(fy_start), .n_sel_i(n_sel), .x_i(x_i), .x_vld_i(x_vld),
                  .fy_need_x_o(need), .fy_busy_o(busy), .fy_done_o(done), .err_wd_o(err), .pi_o(pi_o),
                  .dbg_refills_o(nref), .dbg_rejects_o(nrej),
                  .ev_refill_o(e_ref), .ev_draw_o(e_draw), .ev_rng_o(e_rng), .ev_b_o(e_b), .ev_cand_o(e_cand), .ev_acc_o(e_acc),
                  .ev_swap_o(e_swap), .ev_i_o(e_i), .ev_j_o(e_j));

  initial begin clk = 1'b0; rst_n = 1'b0; fy_start = 1'b0; n_sel = 1'b0; x_vld = 1'b0; x_i = 32'd0; end
  always #5 clk = ~clk;

  reg [8*256-1:0] p_ev, p_sum;
  reg        cyc_run;             // 1 trong luc dang chay mot hoan vi (khai bao truoc khi dung: ModelSim yeu cau)
  integer gap, nsum, bad, s, i, seed, ptr, ptr0, nev_exp, nev_got, nref_ev, ndraw_ev, nswap_ev, dly, cnt_dly, pend, wd_ref;
  integer N, nsamp_n8, nsamp_n16, cyc;
  reg        e_n16, wd_mode;
  reg [7:0]  e_ref_n, e_rej_n;
  reg [63:0] e_pi, pi_mask;
  reg [39:0] row;
  reg [31:0] xq;                       // x se cap cho lan nap dang cho
  reg        done_seen;

  // ---------------------------------------------------------------- mo hinh lts_iter + giam sat su kien
  // Cac cong ev_* la to hop nen duoc lay mau o canh XUONG cua clk (cac ngo vao da on dinh tu canh len truoc).
  always @(negedge clk) begin
    if (rst_n && cyc_run) begin
      if (e_ref) begin
        nref_ev = nref_ev + 1; nev_got = nev_got + 1;
        if (!wd_mode) begin
          row = ev[ptr];
          if (row[39:38] !== 2'd0 || row[31:0] !== x_i) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: REFILL x=%08h, golden: loai %0d x=%08h", s + 1, x_i, row[39:38], row[31:0]); end
          ptr = ptr + 1;
        end
      end
      if (e_draw) begin
        ndraw_ev = ndraw_ev + 1; nev_got = nev_got + 1;
        row = ev[ptr];
        if (!wd_mode && (row[39:38] !== 2'd1 || row[4:0] !== e_rng || row[7:5] !== e_b || row[11:8] !== e_cand || row[12] !== e_acc)) begin
          bad = bad + 1;
          if (bad <= 10) $display("SAI mau %0d: DRAW rng=%0d b=%0d cand=%0d acc=%b | golden: loai %0d rng=%0d b=%0d cand=%0d acc=%b",
                                  s + 1, e_rng, e_b, e_cand, e_acc, row[39:38], row[4:0], row[7:5], row[11:8], row[12]);
        end
        if (!wd_mode) ptr = ptr + 1;
      end
      if (e_swap) begin
        nswap_ev = nswap_ev + 1; nev_got = nev_got + 1;
        row = ev[ptr];
        if (!wd_mode && (row[39:38] !== 2'd2 || row[3:0] !== e_i || row[7:4] !== e_j)) begin
          bad = bad + 1;
          if (bad <= 10) $display("SAI mau %0d: SWAP i=%0d j=%0d | golden: loai %0d i=%0d j=%0d", s + 1, e_i, e_j, row[39:38], row[3:0], row[7:4]);
        end
        if (!wd_mode) ptr = ptr + 1;
      end
    end
  end

  // x_vld sau DLY chu ky ke tu luc fy_need_x_o = 1 (lay mau o canh len, ngay truoc khi DUT doi trang thai)
  always @(posedge clk) begin
    if (!rst_n || !cyc_run) begin x_vld <= 1'b0; pend = 0; end
    else begin
      x_vld <= 1'b0;
      if (gap != 0 && !x_vld) x_i <= $random(seed);
      if (pend > 0) begin
        cnt_dly = cnt_dly - 1;
        if (cnt_dly == 0) begin
          x_vld <= 1'b1;
          if (wd_mode) x_i <= 32'hFFFFFFFF;
          else begin
            row = ev[ptr];                                  // dong ke tiep phai la REFILL
            x_i <= row[31:0];
            if (row[39:38] !== 2'd0) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: DUT xin x nhung golden khong co REFILL o day", s + 1); end
          end
          pend = 0;
        end
      end
      if (need) begin
        if (pend > 0) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: fy_need_x_o khi dang cho x", s + 1); end
        pend = 1;
        dly = (gap != 0) ? 1 + ({$random(seed)} % 6) : 4;
        cnt_dly = dly;
      end
    end
  end

  task start_pulse;
    input nsel;
    begin
      n_sel = nsel; fy_start = 1'b1;
      @(posedge clk); #1; fy_start = 1'b0;
      if (gap != 0) n_sel = $random(seed);              // n_sel rac sau khi da chot
    end
  endtask

  // chay mot hoan vi, doi fy_done_o; tra ve trong done_seen
  task run_one;
    input nsel;
    integer guard, extra;
    begin
      nref_ev = 0; ndraw_ev = 0; nswap_ev = 0; nev_got = 0; ptr0 = ptr;
      cyc_run = 1'b1;
      start_pulse(nsel);
      guard = 0; done_seen = 1'b0;
      while (!done && guard < 4000) begin
        if (gap != 0 && ($random(seed) & 1)) fy_start = 1'b1; else fy_start = 1'b0;   // fy_start luc ban: phai bi bo qua
        @(posedge clk); #1; fy_start = 1'b0;
        guard = guard + 1;
      end
      if (!done) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: khong thay fy_done_o (treo)", s + 1); end
      else done_seen = 1'b1;
      if (busy !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: fy_busy_o != 0 khi fy_done_o", s + 1); end
      cyc_run = 1'b0;
      @(posedge clk); #1;
      if (done !== 1'b0) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: fy_done_o keo dai hon 1 chu ky", s + 1); end
    end
  endtask

  initial begin
    seed = 5; cyc_run = 1'b0; wd_mode = 1'b0; ptr = 0;
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    for (i = 0; i < MAXEV;  i = i + 1) ev[i] = 40'hFFFFFFFFFF;
    for (i = 0; i < MAXSUM; i = i + 1) sm[i] = 82'd0;
    $readmemh("fy_ev.hex", ev);
    $readmemh("fy_sum.hex", sm);
    nsum = 0;
    while (nsum < MAXSUM && sm[nsum][81]) nsum = nsum + 1;
    bad = 0; nsamp_n8 = 0; nsamp_n16 = 0;

    repeat (3) @(posedge clk);
    #1; if (busy !== 1'b0 || done !== 1'b0) begin bad = bad + 1; $display("SAI: busy/done != 0 trong reset"); end
    rst_n = 1'b1;
    @(posedge clk); #1;

    for (s = 0; s < nsum; s = s + 1) begin
      e_n16 = sm[s][80]; e_ref_n = sm[s][79:72]; e_rej_n = sm[s][71:64]; e_pi = sm[s][63:0];
      N = e_n16 ? 16 : 8;
      pi_mask = e_n16 ? 64'hFFFFFFFFFFFFFFFF : 64'h00000000FFFFFFFF;
      nev_exp = e_ref_n + ((N - 1) + e_rej_n) + (N - 1);
      run_one(e_n16);
      if (done_seen) begin
        if ((pi_o & pi_mask) !== e_pi) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d (N=%0d): pi RTL %016h | golden %016h", s + 1, N, pi_o & pi_mask, e_pi); end
        if (nref !== e_ref_n) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: dbg_refills=%0d, golden %0d", s + 1, nref, e_ref_n); end
        if (nrej !== e_rej_n) begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: dbg_rejects=%0d, golden %0d", s + 1, nrej, e_rej_n); end
        if (err !== 1'b0)     begin bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: err_wd_o = 1", s + 1); end
        if (nev_got != nev_exp || ptr - ptr0 != nev_exp) begin
          bad = bad + 1; if (bad <= 10) $display("SAI mau %0d: so su kien RTL %0d, golden %0d (con tro %0d)", s + 1, nev_got, nev_exp, ptr - ptr0);
        end
      end
      if (e_n16) nsamp_n16 = nsamp_n16 + 1; else nsamp_n8 = nsamp_n8 + 1;
      if (gap != 0) repeat ({$random(seed)} % 3) @(posedge clk);
    end

    // ---- watchdog: x = 0xFFFFFFFF mai -> rng = 7 (b = 3, cand = 7) luon bi loai, N = 8
    wd_mode = 1'b1; s = nsum;
    run_one(1'b0);
    if (!done_seen || err !== 1'b1)  begin bad = bad + 1; $display("SAI: watchdog khong bao err_wd_o"); end
    if (nref !== 8'd64)              begin bad = bad + 1; $display("SAI: watchdog: dbg_refills=%0d, ky vong 64", nref); end
    wd_mode = 1'b0;
    // sau watchdog, mot hoan vi binh thuong phai chay lai duoc va xoa err_wd_o
    ptr0 = 0; s = 0;
    e_n16 = sm[0][80]; e_pi = sm[0][63:0]; pi_mask = 64'h00000000FFFFFFFF;
    ptr = 0;
    run_one(e_n16);
    if (err !== 1'b0 || (pi_o & pi_mask) !== e_pi) begin bad = bad + 1; $display("SAI: sau watchdog khong chay lai binh thuong"); end

    if (nsum == 0)       $display("LOI: khong doc duoc vector fy_sum.hex");
    else if (bad == 0)   $display("PASS: %0d hoan vi khop golden (N=8: %0d, N=16: %0d; pi, refills, rejects, tung su kien REFILL/DRAW/SWAP; watchdog) (GAP=%0d)", nsum, nsamp_n8, nsamp_n16, gap);
    else                 $display("FAIL: %0d loi trong %0d hoan vi (GAP=%0d)", bad, nsum, gap);
    $finish;
  end
  initial begin #2000000000; $display("FAIL: het gio (treo)"); $finish; end
endmodule
