// tb_chaos_core.v - kiem tra chaos_core.v (loi mat ma day du) voi golden model. Verilog-2001.
//
// Du lieu (tb/gen_vec_batch3.py): core_<bo>.hex (moi mau: op, du lieu vao, du lieu ra, ctr, idx, k, pi, refills, rejects),
// core_<bo>_cfg.hex (khoa, ctr0, RESEED_INTERVAL, n_sel). 9 bo, chon bang +SET=0..8:
//   0 enc_n8_default  1 enc_n16_default  2 enc_reseed1  3 enc_ctrwrap  4 enc_key00  5 enc_keyff  6 enc_keyrnd  (ENC)
//   7 ops_n8_ri4 (N = 8, RI = 4, ctr tran, ENC/DEC/SKIP xen ke)    8 ops_n16_ri64 (N = 16, RI = 64, ENC/DEC/SKIP xen ke)
// RESEED_INTERVAL la tham so bien dich nen top co 3 "harness" (RI = 64, 4, 1); bo nao co cfg khop RI thi chay, 2 bo kia dung yen.
// Moi harness kiem tra:
//   (1) truoc khi nap khoa: start bi bo qua (busy van 0);  nap khoa -> key_vld = 1 sau RESEED_HMAC
//   (2) moi mau: ct_out (ENC: C, DEC: P, SKIP: 0), ctr_out, idx_out, keystream k, pi (4N bit thap), dbg_refills, dbg_rejects,
//       dbg_steps = refills + 1, err_wd = 0, done dung 1 chu ky, busy = 0 khi xong
//   (3) chuoi su kien (dbg_evt_*): dung thu tu va dung so luong (1 KS, 1 INIT, refills REFILL, rejects + N-1 DRAW, N-1 SWAP,
//       1 PX tru SKIP, 1 CHECK, 1 RESEED_HMAC dung o mau cuoi phien, 1 DONE)
//   (4) soft_rst giua mau: busy ve 0, key_vld ve 0, start sau soft_rst bi bo qua; nap khoa lai thi 3 mau dau cua bo cho lai
//       dung ket qua cu
// Tham so: +SET=n  +GAP=0|1 (GAP=1: nghi ngau nhien giua cac mau, op/n_sel/pt_in rac luc start = 0, start / load_key /
//   soft_rst rac... khong: chi start / load_key rac luc busy = 1)  +TRACE=1 (in tung su kien dang "T:<mau>,<TEN>,<truong>..." de
//   so sanh voi golden: python -m refmodel.compare trace  trace_<bo>.txt  log.txt  (sau khi bo tien to "T:" va dau "# ")
`timescale 1ns/1ps

module core_harness #(
  parameter RI = 64
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        go,
  input  wire [3:0]  set_idx,
  input  wire        gap,
  input  wire        trace_en,
  output reg         fin,
  output reg         active,
  output reg [31:0]  nbad,
  output reg [31:0]  nrows_done
);
  parameter MAXROWS = 512;

  reg [178:0] rows [0:MAXROWS-1];
  reg [320:0] cfgm [0:0];
  reg [8*40-1:0] f_rows, f_cfg;

  reg         start, soft_rst, load_key, n_sel;
  reg  [1:0]  op;
  reg  [255:0] key;
  reg  [31:0] ctr0;
  reg  [15:0] pt;

  wire        busy, done, key_vld, err_wd;
  wire [15:0] ct_out;
  wire [31:0] ctr_out;
  wire [15:0] idx_out;
  wire [7:0]  d_steps, d_refills, d_rejects;
  wire [3:0]  d_state;
  wire        evv;
  wire [3:0]  evi;
  wire [31:0] t_ctr, t_x0, t_xprev, t_x;
  wire [255:0] t_ks;
  wire [33:0] t_r;
  wire [15:0] t_k, t_in, t_sh, t_res;
  wire [63:0] t_pi;
  wire [1:0]  t_op;
  wire        t_nsel, t_acc;
  wire [4:0]  t_rng;
  wire [2:0]  t_b;
  wire [3:0]  t_cand, t_i, t_j;

  chaos_core #(.RESEED_INTERVAL(RI)) dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .start_i(start), .soft_rst_i(soft_rst), .load_key_i(load_key), .op_i(op), .n_sel_i(n_sel),
    .key_i(key), .ctr0_i(ctr0), .pt_in_i(pt),
    .busy_o(busy), .done_o(done), .key_vld_o(key_vld), .err_wd_o(err_wd),
    .ct_out_o(ct_out), .ctr_out_o(ctr_out), .idx_out_o(idx_out),
    .dbg_steps_o(d_steps), .dbg_refills_o(d_refills), .dbg_rejects_o(d_rejects),
    .dbg_state_o(d_state), .dbg_evt_vld_o(evv), .dbg_evt_id_o(evi),
    .tap_ctr_o(t_ctr), .tap_ksess_o(t_ks), .tap_x0_o(t_x0), .tap_r_o(t_r), .tap_xprev_o(t_xprev), .tap_x_o(t_x),
    .tap_k_o(t_k), .tap_pi_o(t_pi), .tap_in_o(t_in), .tap_sh_o(t_sh), .tap_res_o(t_res), .tap_op_o(t_op), .tap_nsel_o(t_nsel),
    .tap_fy_rng_o(t_rng), .tap_fy_b_o(t_b), .tap_fy_cand_o(t_cand), .tap_fy_acc_o(t_acc), .tap_fy_i_o(t_i), .tap_fy_j_o(t_j)
  );

  // ---------------------------------------------------------------- bien kiem tra
  integer r, nrows, cyc, to, seed, k_i, gp, extra;
  integer smp;                          // chi so mau dang xu ly (cho nhan trace)
  integer n_hmac, n_ks, n_init, n_ref, n_draw, n_swap, n_px, n_chk, n_done, prev_ev, seq_bad;
  integer exp_ref, exp_rej, nn;
  integer in_load, in_smp, soft_phase;
  reg         done_d;
  reg         smp_fin;                  // da thay su kien DONE cua mau hien tai
  reg         chk_en;                   // dang kiem tra mau (khong kiem o giai doan nap khoa / soft_rst)
  reg [178:0] row;
  reg [1:0]   e_op;
  reg [15:0]  e_din, e_dout, e_k;
  reg [31:0]  e_ctr;
  reg [15:0]  e_idx;
  reg [63:0]  e_pi, pi_mask;
  reg [7:0]   e_ref, e_rej;
  reg [15:0]  nmask;
  reg [3:0]   cur_set;
  integer     cur_n;

  function ok_next;
    input integer prev;
    input integer nxt;
    begin
      case (prev)
        0:  ok_next = (nxt == 2) || (nxt == 1);           // dau mau: LTS_KEYSTREAM (1 chi cho phep o nap khoa, kiem rieng)
        2:  ok_next = (nxt == 3);
        3:  ok_next = (nxt == 4);
        4:  ok_next = (nxt == 5);
        5:  ok_next = (nxt == 4) || (nxt == 5) || (nxt == 6);
        6:  ok_next = (nxt == 4) || (nxt == 5) || (nxt == 7);
        7:  ok_next = (nxt == 8);
        8:  ok_next = (nxt == 1) || (nxt == 9);
        1:  ok_next = (nxt == 9) || (nxt == 2);
        default: ok_next = 1'b0;
      endcase
    end
  endfunction

  // in nibble pi theo dang "a.b.c" (pi[0] truoc)
  task show_pi;
    input [63:0] p;
    input integer n;
    integer q;
    begin
      for (q = 0; q < n; q = q + 1) begin
        if (q != 0) $write(".");
        $write("%h", p[4*q +: 4]);
      end
    end
  endtask

  // ---------------------------------------------------------------- giam sat su kien
  // Goi moi chu ky tu tac vu tick (cung tien trinh voi chuong trinh chinh: moi bien chi co MOT tien trinh ghi, de moi
  // trinh mo phong - ke ca Verilator - xu ly nhu nhau). Lay mau sau canh len 1 ns: khi do moi ngo ra to hop cua chu ky nay on dinh.
  task monitor;
    begin
    if (rst_n && active) begin
      if (done && done_d) begin
        nbad = nbad + 1;
        if (nbad <= 10) $display("SAI: done keo dai hon 1 chu ky");
      end
      done_d = done;
      if (evv) begin
        // ---- trace
        if (trace_en) begin
          case (evi)
            4'd1: begin
              if (in_load) $write("T:0,RESEED_HMAC,%h,%h,%h,%h\n", t_ctr, t_ks, t_x0, t_r);
              else if (chk_en) $write("T:%0d,RESEED_HMAC,%h,%h,%h,%h\n", smp, t_ctr, t_ks, t_x0, t_r);
            end
            4'd2: if (chk_en) $write("T:%0d,LTS_KEYSTREAM,%h,%h,%h\n", smp, t_xprev, t_x, t_x & nmask);
            4'd3: if (chk_en) $write("T:%0d,FY_INIT,%0h\n", smp, cur_n);
            4'd4: if (chk_en) $write("T:%0d,FY_REFILL,%h,%h\n", smp, t_xprev, t_x);
            4'd5: if (chk_en) $write("T:%0d,FY_DRAW,%h,%h,%h,%h\n", smp, t_rng, t_b, t_cand, t_acc);
            4'd6: if (chk_en) $write("T:%0d,FY_SWAP,%h,%h\n", smp, t_i, t_j);
            4'd7: if (chk_en && t_op[1] == 1'b0) begin
              $write("T:%0d,PERMUTE_XOR,", smp);
              show_pi(t_pi, cur_n);
              if (t_op == 2'b00) $write(",%h,%h,%h\n", t_in, t_sh, t_res);
              else               $write(",%h,%h,%h\n", t_res, t_sh, t_in);
            end
            4'd8: if (chk_en) $write("T:%0d,CHECK_RESEED,%h\n", smp, idx_out + 16'd1);
            4'd9: if (chk_en) $write("T:%0d,DONE,%h\n", smp, t_res);
            default: ;
          endcase
        end
        // ---- thu tu + dem
        if (chk_en && !in_load) begin
          if (!ok_next(prev_ev, evi)) begin
            seq_bad = seq_bad + 1;
            if (seq_bad <= 5) $display("SAI mau %0d: su kien %0d khong duoc phep sau su kien %0d", smp, evi, prev_ev);
          end
          prev_ev = evi;
          case (evi)
            4'd1: n_hmac = n_hmac + 1;
            4'd2: n_ks   = n_ks + 1;
            4'd3: n_init = n_init + 1;
            4'd4: n_ref  = n_ref + 1;
            4'd5: n_draw = n_draw + 1;
            4'd6: n_swap = n_swap + 1;
            4'd7: n_px   = n_px + 1;
            4'd8: n_chk  = n_chk + 1;
            4'd9: n_done = n_done + 1;
            default: ;
          endcase
        end
      end
      // ---- ket thuc mau: kiem tra ket qua
      if (chk_en && done && !in_load) begin
        nn = cur_n;
        if (ct_out !== e_dout) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: op=%0d ct_out=%h, golden %h (vao %h)", smp, e_op, ct_out, e_dout, e_din);
        end
        if (ctr_out !== e_ctr || idx_out !== e_idx) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: (ctr,idx)=(%h,%h), golden (%h,%h)", smp, ctr_out, idx_out, e_ctr, e_idx);
        end
        if (t_k !== e_k) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: k=%h, golden %h", smp, t_k, e_k);
        end
        if ((t_pi & pi_mask) !== (e_pi & pi_mask)) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: pi=%h, golden %h", smp, t_pi & pi_mask, e_pi & pi_mask);
        end
        if (d_refills !== e_ref || d_rejects !== e_rej) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: refills/rejects = %0d/%0d, golden %0d/%0d", smp, d_refills, d_rejects, e_ref, e_rej);
        end
        if (d_steps !== (e_ref + 8'd1) || err_wd !== 1'b0) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: dbg_steps=%0d (can %0d) err_wd=%b", smp, d_steps, e_ref + 1, err_wd);
        end
        // so luong su kien
        exp_ref = e_ref;
        if (n_ks !== 1 || n_init !== 1 || n_ref !== exp_ref || n_draw !== (e_rej + nn - 1) || n_swap !== (nn - 1) ||
            n_px !== 1 || n_chk !== 1 || n_done !== 1 ||
            n_hmac !== (((e_idx + 1) == RI) ? 1 : 0)) begin
          nbad = nbad + 1;
          if (nbad <= 10) $display("SAI mau %0d: dem su kien ks=%0d init=%0d ref=%0d(%0d) draw=%0d(%0d) swap=%0d(%0d) px=%0d chk=%0d hmac=%0d done=%0d",
                                   smp, n_ks, n_init, n_ref, exp_ref, n_draw, e_rej + nn - 1, n_swap, nn - 1, n_px, n_chk, n_hmac, n_done);
        end
        if (seq_bad != 0) nbad = nbad + 1;
        smp_fin = 1'b1;
      end
    end
    end
  endtask

  // ---------------------------------------------------------------- tac vu
  task tick;
    begin
      @(posedge clk);
      #1;
      monitor;
    end
  endtask

  task clear_counts;
    begin
      n_hmac = 0; n_ks = 0; n_init = 0; n_ref = 0; n_draw = 0; n_swap = 0; n_px = 0; n_chk = 0; n_done = 0;
      prev_ev = 0; seq_bad = 0; smp_fin = 1'b0;
    end
  endtask

  task idle_cycles;
    input integer n;
    integer q;
    begin
      for (q = 0; q < n; q = q + 1) begin
        if (gap) begin                      // rac tren cac ngo vao khi dang ranh
          op = $random(seed); n_sel = $random(seed); pt = $random(seed);
        end
        tick;
      end
    end
  endtask

  // nap khoa va doi RESEED_HMAC dau tien xong
  task do_load_key;
    begin
      in_load = 1; chk_en = 0;
      key = cfgm[0][255:0]; ctr0 = cfgm[0][287:256];
      load_key = 1; tick; load_key = 0;
      if (key_vld) begin nbad = nbad + 1; $display("SAI: key_vld khong ha xuong khi nap khoa"); end
      to = 0;
      while (!key_vld && to < 2000) begin
        tick; to = to + 1;
        if (gap && busy && ($random(seed) & 3) == 0) begin start = 1; load_key = 1; tick; start = 0; load_key = 0; end
      end
      if (!key_vld) begin nbad = nbad + 1; $display("SAI: key_vld khong len sau nap khoa"); end
      tick;
      if (busy) begin nbad = nbad + 1; $display("SAI: busy van 1 sau khi nap khoa xong"); end
      in_load = 0;
    end
  endtask

  // xu ly mot hang cua bo vector (da nap vao row, smp)
  task do_row;
    begin
      op = e_op; n_sel = cfgm[0][320]; pt = e_din;
      clear_counts;
      chk_en = 1;
      start = 1; tick; start = 0;
      if (gap) begin op = $random(seed); n_sel = $random(seed); pt = $random(seed); end
      to = 0;
      while (!smp_fin && to < 20000) begin
        if (gap && busy && ($random(seed) & 7) == 0) begin
          if ($random(seed) & 1) begin start = 1; end else begin load_key = 1; end
          tick; start = 0; load_key = 0;
        end else tick;
        to = to + 1;
      end
      chk_en = 0;
      if (!smp_fin) begin
        nbad = nbad + 1;
        $display("SAI mau %0d: qua thoi gian (state=%0d)", smp, d_state);
      end
      tick;
      if (busy) begin nbad = nbad + 1; if (nbad <= 10) $display("SAI mau %0d: busy khong ve 0 sau done", smp); end
    end
  endtask

  task load_row;
    input integer idx;
    begin
      row = rows[idx];
      e_op = row[177:176]; e_din = row[175:160]; e_dout = row[159:144]; e_ctr = row[143:112]; e_idx = row[111:96];
      e_k = row[95:80]; e_pi = row[79:16]; e_ref = row[15:8]; e_rej = row[7:0];
    end
  endtask

  // ---------------------------------------------------------------- chuong trinh chinh
  initial begin
    fin = 0; active = 0; nbad = 0; nrows_done = 0;
    start = 0; soft_rst = 0; load_key = 0; op = 0; n_sel = 0; key = 256'd0; ctr0 = 32'd0; pt = 16'd0;
    done_d = 0; in_load = 0; chk_en = 0; smp_fin = 0; smp = 0; seed = 12345; cur_n = 8; nmask = 16'h00FF;
    n_hmac = 0; n_ks = 0; n_init = 0; n_ref = 0; n_draw = 0; n_swap = 0; n_px = 0; n_chk = 0; n_done = 0; prev_ev = 0; seq_bad = 0;
    @(posedge go);
    #1;
    case (set_idx)
      4'd0: begin f_rows = "core_enc_n8_default.hex";  f_cfg = "core_enc_n8_default_cfg.hex";  end
      4'd1: begin f_rows = "core_enc_n16_default.hex";  f_cfg = "core_enc_n16_default_cfg.hex"; end
      4'd2: begin f_rows = "core_enc_reseed1.hex";      f_cfg = "core_enc_reseed1_cfg.hex";      end
      4'd3: begin f_rows = "core_enc_ctrwrap.hex";      f_cfg = "core_enc_ctrwrap_cfg.hex";      end
      4'd4: begin f_rows = "core_enc_key00.hex";        f_cfg = "core_enc_key00_cfg.hex";        end
      4'd5: begin f_rows = "core_enc_keyff.hex";        f_cfg = "core_enc_keyff_cfg.hex";        end
      4'd6: begin f_rows = "core_enc_keyrnd.hex";       f_cfg = "core_enc_keyrnd_cfg.hex";       end
      4'd7: begin f_rows = "core_ops_n8_ri4.hex";       f_cfg = "core_ops_n8_ri4_cfg.hex";       end
      default: begin f_rows = "core_ops_n16_ri64.hex";  f_cfg = "core_ops_n16_ri64_cfg.hex";     end
    endcase
    for (r = 0; r < MAXROWS; r = r + 1) rows[r] = 179'd0;
    cfgm[0] = 321'd0;
    $readmemh(f_cfg, cfgm);
    if (cfgm[0][319:288] === RI) begin
      active = 1;
      $readmemh(f_rows, rows);
      nrows = 0;
      while (nrows < MAXROWS && rows[nrows][178] === 1'b1) nrows = nrows + 1;
      cur_n  = cfgm[0][320] ? 16 : 8;
      nmask  = cfgm[0][320] ? 16'hFFFF : 16'h00FF;
      pi_mask = cfgm[0][320] ? 64'hFFFFFFFFFFFFFFFF : 64'h00000000FFFFFFFF;

      // (1) start truoc khi nap khoa phai bi bo qua
      key = cfgm[0][255:0]; ctr0 = cfgm[0][287:256]; n_sel = cfgm[0][320];
      idle_cycles(3);
      start = 1; tick; start = 0;
      idle_cycles(3);
      if (busy || key_vld) begin nbad = nbad + 1; $display("SAI: start truoc khi co khoa khong bi bo qua"); end

      // (2) nap khoa, chay toan bo bo vector
      if (trace_en) smp = 0;
      do_load_key;
      for (r = 0; r < nrows; r = r + 1) begin
        smp = r;
        load_row(r);
        idle_cycles(gap ? ($random(seed) & 7) : 0);
        do_row;
        nrows_done = nrows_done + 1;
      end

      // (3) soft_rst giua mau, start sau soft_rst bi bo qua, nap lai khoa -> 3 mau dau lap lai
      if (nrows >= 3) begin
        smp = 0;
        load_row(0);
        op = e_op; n_sel = cfgm[0][320]; pt = e_din;
        chk_en = 0;
        start = 1; tick; start = 0;
        for (k_i = 0; k_i < 30; k_i = k_i + 1) tick;
        if (!busy) begin nbad = nbad + 1; $display("SAI: busy = 0 giua mau"); end
        soft_rst = 1; tick; soft_rst = 0;
        tick; tick; tick;
        if (busy || key_vld || err_wd) begin nbad = nbad + 1; $display("SAI: sau soft_rst busy=%b key_vld=%b err_wd=%b", busy, key_vld, err_wd); end
        start = 1; tick; start = 0;
        idle_cycles(4);
        if (busy) begin nbad = nbad + 1; $display("SAI: start sau soft_rst khong bi bo qua"); end
        do_load_key;
        for (r = 0; r < 3; r = r + 1) begin
          smp = r;
          load_row(r);
          do_row;
        end
        // nap khoa lai khi key_vld = 1 (khong qua soft_rst): phien ve ctr0, 3 mau dau lai dung
        do_load_key;
        for (r = 0; r < 3; r = r + 1) begin
          smp = r;
          load_row(r);
          do_row;
        end
      end

      if (nbad == 0)
        $display("PASS: bo %0d, RI=%0d, N=%0d: %0d mau khop golden (ct, ctr, idx, k, pi, refills, rejects, su kien) %0s",
                 set_idx, RI, cur_n, nrows_done, gap ? "(GAP=1)" : "(GAP=0)");
      else
        $display("FAIL: bo %0d, RI=%0d: %0d loi", set_idx, RI, nbad);
    end
    fin = 1;
  end
endmodule

module tb_chaos_core;
  reg        clk, rst_n, go, gap, trace_en;
  reg [3:0]  set_idx;
  integer    set_i, gap_i, tr_i;
  wire       f0, f1, f2, a0, a1, a2;
  wire [31:0] b0, b1, b2, n0, n1, n2;

  core_harness #(.RI(64)) h0 (.clk(clk), .rst_n(rst_n), .go(go), .set_idx(set_idx), .gap(gap), .trace_en(trace_en),
                              .fin(f0), .active(a0), .nbad(b0), .nrows_done(n0));
  core_harness #(.RI(4))  h1 (.clk(clk), .rst_n(rst_n), .go(go), .set_idx(set_idx), .gap(gap), .trace_en(trace_en),
                              .fin(f1), .active(a1), .nbad(b1), .nrows_done(n1));
  core_harness #(.RI(1))  h2 (.clk(clk), .rst_n(rst_n), .go(go), .set_idx(set_idx), .gap(gap), .trace_en(trace_en),
                              .fin(f2), .active(a2), .nbad(b2), .nrows_done(n2));

  initial begin clk = 1'b0; rst_n = 1'b0; go = 1'b0; end
  always #5 clk = ~clk;

  initial begin
    set_i = 0; gap_i = 0; tr_i = 0;
    if (!$value$plusargs("SET=%d", set_i)) set_i = 0;
    if (!$value$plusargs("GAP=%d", gap_i)) gap_i = 0;
    if (!$value$plusargs("TRACE=%d", tr_i)) tr_i = 0;
    set_idx = set_i;
    gap = (gap_i != 0);
    trace_en = (tr_i != 0);
    #52 rst_n = 1'b1;
    #20 go = 1'b1;
    wait (f0 && f1 && f2);
    #20;
    if (!(a0 || a1 || a2)) $display("FAIL: khong harness nao khop cfg cua bo %0d", set_idx);
    else if (b0 + b1 + b2 != 0) $display("FAIL: tong %0d loi", b0 + b1 + b2);
    $finish;
  end
endmodule
