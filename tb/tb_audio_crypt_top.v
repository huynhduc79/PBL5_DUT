// tb_audio_crypt_top.v - kiem audio_crypt_top tu dau den cuoi qua APB3, dung nhu RTOS se dung. Verilog-2001.
// Golden: tools/gen_vec_batch7.py (refmodel.cipher.CipherCore + refmodel.audio). Mo hinh micro: inmp441_model
// (trong tb_i2s_rx.v, bien dich kem). Moi tu OUT_DATA doc ra duoc so voi golden tung bit.
//
// Cac pha:
//   A  gia tri mac dinh, VERSION, dia chi khong anh xa, KMASTER doc 0, PSLVERR = 0, PREADY chi thap o OUT_DATA
//   B  chinh sach CTR: lan ghi dau luon nhan, sau do phai tang nghiem ngat (so voi ctr da ghi va ctr loi dang dung);
//      RESEED_NOW chi nhan mot lan cho moi lan ghi CTR; SOFT_RESET xoa bo so sanh
//   C  che do REG: DATA_IN -> DATA_OUT (ENC qua ranh phien 64, SKIP bang START, DEC), CMD_IGN khi ban / sai che do,
//      khong day gi vao out_fifo, doc lai ctr phien
//   D  luong RAMP theo ngat IRQ THRESH, voi CTRL dat OP = DEC, N_SEL = 0 (luong phai ep ENC, N = 16); I2S phai dung;
//      tat roi bat lai: (ctr, idx) tu dau sau khi bat lai phai noi tiep tu cuoi (keystream lien mach)
//   E  luong SINE; F  luong MIC (INMP441 -> i2s_rx -> sample_fmt), CLIP_CNT
//   G  tran: out_fifo day -> ngung ma hoa -> in_fifo day -> bo dung DROP mau; tu ke tiep GAP = 1, keystream lien mach,
//      ctr quay vong qua 2^32; STATUS / IRQ_STATUS IN_OVF, DROP_CNT
//   H  IRQ THRESH dung nguong >= va bi chan khi IRQ_EN = 0; KEY_CLEAR giua luong (khong treo, KMASTER bi xoa that:
//      nap lai khong ghi khoa phai ra ban ma cua K = 0); FIFO_CLR; OUT_DATA rong -> VALID = 0; CYCLES_MAX
//   I  bat luong khi CHUA co khoa: in_fifo day -> bo mau; tat ngay sau lan bo dau tien (in_fifo day), roi nap khoa:
//      luong phai ma hoa NOT 65 mau da thu du ENABLE = 0; bat lai: RAMP tu 0, keystream noi tiep, GAP = 0
//      (co GAP khong duoc treo sang ban ghi sau). Golden top_nokey.hex.
// Moi lan SOFT_RESET kiem STATUS = 0 va FIFO_LEVEL = 0 (khoa, luong, FIFO deu da reset).
// Tham so: +GAP=0|1  (GAP=1: chen 0..3 chu ky nghi giua cac giao dich APB va doc STATUS xen ke)
//   OUT_AW (tham so Verilog, mac dinh 11 = cau hinh that; mutation testing dung 7 cho nhanh).
`timescale 1ns/1ps
module tb_audio_crypt_top;
  parameter OUT_AW = 11;
  localparam OUT_DEPTH = 1 << OUT_AW;

  // ---- dia chi
  localparam [7:0] R_CTRL = 8'h00, R_STATUS = 8'h04, R_KM0 = 8'h08, R_CTR = 8'h28, R_DIN = 8'h2C, R_DOUT = 8'h30,
                   R_I2S = 8'h34, R_SRC = 8'h38, R_LVL = 8'h3C, R_OUT = 8'h40, R_THR = 8'h44, R_IEN = 8'h48,
                   R_IST = 8'h4C, R_DROP = 8'h50, R_SCNT = 8'h54, R_CYC = 8'h58, R_SKIP = 8'h5C, R_VER = 8'h60,
                   R_CLIP = 8'h64, R_DBG = 8'h68;

  reg         clk, rst_n, psel, penable, pwrite, mic_restart;
  reg  [31:0] paddr, pwdata;
  wire [31:0] prdata;
  wire        pready, pslverr, irq, sck, ws, sd;

  audio_crypt_top #(.OUT_AW(OUT_AW)) dut (
    .clk_i(clk), .rst_n_i(rst_n), .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
    .pwdata_i(pwdata), .prdata_o(prdata), .pready_o(pready), .pslverr_o(pslverr), .irq_o(irq),
    .i2s_sck_o(sck), .i2s_ws_o(ws), .i2s_sd_i(sd)
  );
  inmp441_model #(.NF(400)) mic (.sck(sck), .ws(ws), .restart(mic_restart), .dly(32'd15), .win(32'd0), .sd(sd));

  initial clk = 1'b0;
  always #10 clk = ~clk;                               // 50 MHz

  // ---- golden
  reg [31:0] cfg   [0:31];
  reg [31:0] key   [0:7];
  reg [35:0] regv  [0:255];
  reg [31:0] g_ramp[0:511];
  reg [31:0] g_sine[0:511];
  reg [31:0] g_mic [0:511];
  reg [15:0] g_clip[0:511];
  reg [31:0] g_ovf [0:4095];
  reg [31:0] g_nokey[0:511];
  reg [31:0] gold  [0:4095];                           // bang dang dung cho pha luong hien tai
  integer    ngold;

  integer bad, gap, seed, i, k, n, t, cnt, phase;
  reg [31:0] rd, rd2, ctrl_lv;
  // (khai bao truoc moi task: ModelSim bat khai bao truoc khi dung)
  reg     mon_clr;
  integer cyc, c_start_at, mon_cyc_max;
  reg     mon_run;
  integer c_reg, c_ramp, c_sine, c_mic, c_ovf, n_drop, n_ramp, n_sine, n_mic, mic_shift, mic_skip, sdiv, n_reg,
          ctr_reg_end, n_extra, thr, first_gap, lin, g_extra;
  reg [31:0] last_w, prev_w, zkey_word, nokey_word, ctr_nokey;       // rd2 bi rdr ghi de khi GAP = 1: khong dung de giu gia tri
  reg [3:0]  kind;
  reg [15:0] vin, vout;

  // ---------------------------------------------------------------- tien ich
  task err;
    input [8*72-1:0] msg;
    begin
      bad = bad + 1;
      if (bad <= 12) $display("SAI pha %0d: %0s", phase, msg);
    end
  endtask

  task idle_gap;
    integer m;
    begin
      if (gap != 0) begin
        m = $random(seed) & 3;
        repeat (m) @(posedge clk);
      end
    end
  endtask

  // giao dich APB3: SETUP 1 chu ky, ACCESS den khi PREADY = 1 (lay mau ngay truoc canh len)
  task apb;
    input        w;
    input [7:0]  a;
    input [31:0] d;
    output [31:0] q;
    integer waits;
    begin
      @(posedge clk); #1;
      psel = 1'b1; penable = 1'b0; pwrite = w; paddr = {24'hA5A5A5, a}; pwdata = w ? d : $random(seed);
      @(posedge clk); #1;
      penable = 1'b1;
      waits = 0;
      @(posedge clk);
      while (pready !== 1'b1 && waits <= 4) begin
        waits = waits + 1;
        @(posedge clk);
      end
      if (waits > 4) err("PREADY treo");
      q = prdata;
      if (pslverr !== 1'b0) err("PSLVERR = 1");
      if (a == R_OUT && !w && waits != 1) err("doc OUT_DATA phai co dung 1 chu ky cho");
      if (!(a == R_OUT && !w) && waits != 0) err("PREADY thap o thanh ghi thuong");
      #1;
      psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
      idle_gap;
    end
  endtask

  task wr;
    input [7:0]  a;
    input [31:0] d;
    reg   [31:0] dummy;
    begin apb(1'b1, a, d, dummy); end
  endtask

  task rdr;
    input  [7:0]  a;
    output [31:0] q;
    begin
      apb(1'b0, a, 32'd0, q);
      if (gap != 0 && ($random(seed) & 1)) apb(1'b0, R_STATUS, 32'd0, rd2);   // doc xen ke, khong co tac dung phu
    end
  endtask

  task chk_reg;
    input [7:0]  a;
    input [31:0] mask;
    input [31:0] val;
    input [8*72-1:0] msg;
    reg   [31:0] q;
    begin
      rdr(a, q);
      if ((q & mask) !== (val & mask)) begin
        err(msg);
        if (bad <= 12) $display("      dia chi %02h: doc %08h, ky vong %08h (mask %08h)", a, q, val, mask);
      end
    end
  endtask

  task ctrl;                                           // ghi CTRL giu cac truong muc trong ctrl_lv
    input [31:0] pulses;
    begin wr(R_CTRL, ctrl_lv | pulses); end
  endtask

  task wait_key_ready;
    begin
      t = 0; rd = 0;
      while (!rd[1] && t < 200) begin rdr(R_STATUS, rd); t = t + 1; end
      if (!rd[1]) err("KEY_READY khong len");
    end
  endtask

  task soft_reset;
    begin
      wr(R_CTRL, 32'h8000_0000);
      ctrl_lv = 32'h100;
      chk_reg(R_STATUS, 32'hFFFFFFFF, 32'h0, "SOFT_RESET: STATUS phai = 0 (khoa, loi, luong da reset)");
      chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "SOFT_RESET: FIFO phai rong");
      mon_clr = 1'b1; @(posedge clk); #1 mon_clr = 1'b0;
    end
  endtask

  task load_key;
    input [31:0] c0;
    begin
      for (k = 0; k < 8; k = k + 1) wr(R_KM0 + 4 * k, key[k]);
      wr(R_CTR, c0);
      chk_reg(R_STATUS, 32'h80, 32'h0, "CTR bi tu choi khi nap khoa");
      ctrl(32'h4);                                     // RESEED_NOW
      wait_key_ready;
    end
  endtask

  // doc het nhung gi dang co trong out_fifo, so voi gold[cnt..]
  task drain;
    integer m, j;
    begin
      rdr(R_LVL, rd);
      m = rd[15:0];
      for (j = 0; j < m; j = j + 1) begin
        rdr(R_OUT, rd);
        if (cnt >= ngold) err("nhieu tu hon golden");
        else if (rd !== gold[cnt]) begin
          err("tu OUT_DATA khac golden");
          if (bad <= 12) $display("      tu %0d: RTL %08h, golden %08h", cnt, rd, gold[cnt]);
        end
        cnt = cnt + 1;
        last_w = rd;
      end
    end
  endtask

  // chay luong voi nguon hien tai cho den khi doc du nmin tu, roi tat va rut het
  task run_stream;
    input integer nmin;
    begin
      cnt = 0;
      ctrl_lv = 32'h041;                               // ENABLE + OP = DEC + N_SEL = 0: luong van phai ENC, N = 16
      ctrl(32'h0);
      t = 0;
      while (cnt < nmin && t < (nmin + 20) * 1100) begin
        @(posedge clk);
        if (irq === 1'b1) begin
          drain;
          wr(R_IST, 32'h1);
        end
        t = t + 1;
      end
      if (cnt < nmin) err("luong khong du tu (ngat THRESH khong den?)");
      chk_reg(R_STATUS, 32'h40, 32'h0, "I2S phai dung khi nguon khong phai MIC");
      ctrl_lv = 32'h100;
      ctrl(32'h0);                                     // tat
      repeat (1200) @(posedge clk);                    // mau dang bay xong
      drain;
      chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "sau khi tat + rut: ca in_fifo va out_fifo phai rong");
      chk_reg(R_SCNT, 32'hFFFFFFFF, cnt, "SAMPLE_CNT khac so tu doc duoc");
    end
  endtask

  // ---------------------------------------------------------------- monitor doc lap: CYCLES_MAX
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (mon_clr) begin
      mon_cyc_max = 0; mon_run = 1'b0;
    end else begin
      if (dut.c_done && mon_run) begin
        if (cyc - c_start_at - 1 > mon_cyc_max) mon_cyc_max = cyc - c_start_at - 1;
        mon_run = 1'b0;
      end
      if (dut.c_start) begin c_start_at = cyc; mon_run = 1'b1; end
    end
  end

  // ---------------------------------------------------------------- kich ban

  initial begin
    bad = 0; seed = 7; phase = 0; cyc = 0; mon_cyc_max = 0; mon_run = 1'b0; c_start_at = 0; mon_clr = 1'b0;
    rst_n = 1'b0; psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = 32'd0; pwdata = 32'd0; mic_restart = 1'b1;
    ctrl_lv = 32'h100;
    if (!$value$plusargs("GAP=%d", gap)) gap = 0;
    $readmemh("top_cfg.hex", cfg);
    $readmemh("top_key.hex", key);
    $readmemh("top_reg.hex", regv);
    $readmemh("top_ramp.hex", g_ramp);
    $readmemh("top_sine.hex", g_sine);
    $readmemh("top_mic.hex", g_mic);
    $readmemh("top_clip.hex", g_clip);
    $readmemh("top_nokey.hex", g_nokey);
    if (OUT_AW == 11) $readmemh("top_ovf_a11.hex", g_ovf);
    else              $readmemh("top_ovf_a7.hex", g_ovf);
    c_reg = cfg[0]; c_ramp = cfg[1]; c_sine = cfg[2]; c_mic = cfg[3]; c_ovf = cfg[4]; n_drop = cfg[5];
    n_ramp = cfg[6]; n_sine = cfg[7]; n_mic = cfg[8]; mic_shift = cfg[9]; mic_skip = cfg[10]; sdiv = cfg[11];
    n_reg = cfg[12]; ctr_reg_end = cfg[13]; n_extra = cfg[14]; thr = cfg[15]; g_extra = cfg[16]; zkey_word = cfg[17]; ctr_nokey = cfg[18]; nokey_word = cfg[19];

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    mic_restart = 1'b0;

    // ================================================================ A
    phase = 1;
    chk_reg(R_VER,  32'hFFFFFFFF, 32'h0002_0100, "VERSION");
    chk_reg(R_CTRL, 32'hFFFFFFFF, 32'h0000_0100, "CTRL mac dinh (N_SEL = 1)");
    chk_reg(R_STATUS, 32'hFFFFFFFF, 32'h0, "STATUS mac dinh");
    chk_reg(R_I2S,  32'hFFFFFFFF, 32'd24, "I2S_CFG mac dinh (SCK_DIV = 24)");
    chk_reg(R_THR,  32'hFFFFFFFF, 32'd256, "IRQ_THRESH mac dinh");
    chk_reg(R_SKIP, 32'hFFFFFFFF, 32'd4096, "STARTUP_SKIP mac dinh");
    chk_reg(R_SRC,  32'hFFFFFFFF, 32'd0, "SRC_SEL mac dinh");
    chk_reg(8'h6C,  32'hFFFFFFFF, 32'd0, "dia chi khong anh xa 0x6C");
    chk_reg(8'hFC,  32'hFFFFFFFF, 32'd0, "dia chi khong anh xa 0xFC");
    wr(R_KM0, 32'hDEADBEEF);
    chk_reg(R_KM0,  32'hFFFFFFFF, 32'd0, "KMASTER phai doc ve 0");
    chk_reg(R_OUT,  32'hFFFFFFFF, 32'd0, "OUT_DATA rong -> 0 (VALID = 0)");
    wr(R_I2S, 32'h000F_1FFF);
    chk_reg(R_I2S,  32'hFFFFFFFF, 32'h000F_1FFF, "I2S_CFG doc lai");
    wr(8'h70, 32'hFFFFFFFF);                           // ghi dia chi khong anh xa: khong anh huong
    chk_reg(R_CTRL, 32'hFFFFFFFF, 32'h0000_0100, "ghi dia chi la lam doi CTRL");
    if (irq !== 1'b0) err("irq_o phai = 0 luc dau");

    // ================================================================ B
    phase = 2;
    soft_reset;
    chk_reg(R_I2S,  32'hFFFFFFFF, 32'd24, "SOFT_RESET khong tra I2S_CFG ve mac dinh");
    wr(R_CTR, 32'd100);
    chk_reg(R_STATUS, 32'h80, 32'h0,   "ghi CTR dau tien bi tu choi");
    chk_reg(R_CTR,  32'hFFFFFFFF, 32'd100, "doc CTR");
    wr(R_CTR, 32'd100);
    chk_reg(R_STATUS, 32'h80, 32'h80,  "ghi CTR bang gia tri cu phai bi tu choi");
    chk_reg(R_CTR,  32'hFFFFFFFF, 32'd100, "CTR bi doi du bi tu choi");
    wr(R_STATUS, 32'h80);
    chk_reg(R_STATUS, 32'h80, 32'h0,   "W1C CTR_REJECTED");
    wr(R_CTR, 32'd50);
    chk_reg(R_STATUS, 32'h80, 32'h80,  "ghi CTR nho hon phai bi tu choi");
    wr(R_STATUS, 32'h80);
    wr(R_CTR, 32'd101);
    chk_reg(R_STATUS, 32'h80, 32'h0,   "ghi CTR lon hon bi tu choi");
    for (k = 0; k < 8; k = k + 1) wr(R_KM0 + 4 * k, key[k]);
    ctrl(32'h4);
    wait_key_ready;
    chk_reg(R_CTR,  32'hFFFFFFFF, 32'd101, "doc CTR sau RESEED (ctr phien)");
    ctrl(32'h4);                                       // RESEED lan 2 khong ghi CTR moi
    chk_reg(R_STATUS, 32'h100, 32'h100, "RESEED khong co CTR moi phai bi bo qua (CMD_IGN)");
    wr(R_STATUS, 32'h100);
    wr(R_CTR, 32'd101);
    chk_reg(R_STATUS, 32'h80, 32'h80,  "ghi CTR = ctr phien dang dung phai bi tu choi");
    wr(R_STATUS, 32'h80);
    ctrl(32'h10);                                      // KEY_CLEAR
    chk_reg(R_STATUS, 32'h2, 32'h0,    "KEY_CLEAR khong xoa KEY_READY");
    wr(R_CTR, 32'd101);
    chk_reg(R_STATUS, 32'h80, 32'h80,  "sau KEY_CLEAR van phai nho ctr da dung");
    wr(R_STATUS, 32'h80);
    soft_reset;
    wr(R_CTR, 32'd0);
    chk_reg(R_STATUS, 32'h80, 32'h0,   "sau SOFT_RESET lan ghi CTR dau (= 0) phai duoc nhan");

    // ================================================================ C
    phase = 3;
    soft_reset;
    load_key(c_reg);
    wr(R_SRC, 32'd3);
    wr(R_DIN, 32'h1234);                               // OP chua dat: mac dinh ENC -> mau nay khong co trong golden
    chk_reg(R_STATUS, 32'h100, 32'h0, "lenh DATA_IN hop le bi danh dau CMD_IGN");
    // lam lai tu dau de khop golden
    soft_reset;
    load_key(c_reg);
    wr(R_SRC, 32'd3);
    for (i = 0; i < n_reg; i = i + 1) begin
      {kind, vin, vout} = regv[i];
      if (kind == 4'd1) begin
        ctrl_lv = 32'h180;                             // OP = SKIP, N_SEL = 1
        ctrl(32'h2);                                   // START
      end else begin
        ctrl_lv = (kind == 4'd2) ? 32'h140 : 32'h100;  // DEC / ENC
        if (i == 0 || regv[i - 1][35:32] != kind) ctrl(32'h0);
        wr(R_DIN, {16'h0, vin});
        if (i == 5) begin
          wr(R_DIN, 32'hFFFF);                         // ngay sau: loi dang ban -> phai bi bo qua
          chk_reg(R_STATUS, 32'h100, 32'h100, "DATA_IN luc ban phai bat CMD_IGN");
          wr(R_STATUS, 32'h100);
        end
      end
      t = 0; rd = 1;
      while (rd[0] && t < 2000) begin rdr(R_STATUS, rd); t = t + 1; end
      if (rd[0]) err("BUSY khong ve 0 (che do REG)");
      begin                                            // SKIP: loi ra 0 (golden vout = 0)
        rdr(R_DOUT, rd);
        if (rd[15:0] !== vout) begin
          err("DATA_OUT khac golden (che do REG)");
          if (bad <= 12) $display("      buoc %0d loai %0d vao %04h: RTL %04h, golden %04h", i, kind, vin, rd[15:0], vout);
        end
      end
    end
    chk_reg(R_CTR, 32'hFFFFFFFF, ctr_reg_end, "ctr phien sau che do REG");
    chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "che do REG khong duoc day vao FIFO");
    chk_reg(R_SCNT, 32'hFFFFFFFF, 32'h0, "SAMPLE_CNT phai = 0 o che do REG");
    chk_reg(R_STATUS, 32'h100, 32'h0, "CMD_IGN bat sai trong che do REG");
    wr(R_SRC, 32'd1);
    ctrl_lv = 32'h100;
    wr(R_DIN, 32'h1);
    chk_reg(R_STATUS, 32'h100, 32'h100, "DATA_IN khi SRC_SEL != 3 phai bi bo qua");
    wr(R_STATUS, 32'h100);
    chk_reg(R_CYC, 32'hFFFFFFFF, mon_cyc_max, "CYCLES_MAX khac monitor (REG)");
    if (mon_cyc_max < 300 || mon_cyc_max > 400) err("CYCLES_MAX ngoai khoang mau co reseed (300..400)");
    rdr(R_DBG, rd);
    if (rd[7:0] == 8'd0) err("DBG.steps = 0");
    wr(R_SRC, 32'd3);
    wr(R_CTR, ctr_reg_end + 32'd5);
    chk_reg(R_STATUS, 32'h80, 32'h0, "CTR moi bi tu choi (truoc thu RESEED luc ban)");
    wr(R_DIN, 32'h5555);
    ctrl(32'h4);                                       // RESEED_NOW trong luc loi dang ban
    chk_reg(R_STATUS, 32'h100, 32'h100, "RESEED luc loi ban phai bi bo qua (CMD_IGN)");
    wr(R_STATUS, 32'h100);
    repeat (500) @(posedge clk);
    ctrl(32'h4);                                       // ranh roi: CTR van con 'moi' -> phai nhan
    wait_key_ready;
    chk_reg(R_STATUS, 32'h100, 32'h0, "RESEED hop le bi bo qua");
    chk_reg(R_CTR, 32'hFFFFFFFF, ctr_reg_end + 32'd5, "ctr phien sau RESEED");

    // ================================================================ D  RAMP
    phase = 4;
    soft_reset;
    load_key(c_ramp);
    wr(R_I2S, sdiv); wr(R_SRC, 32'd1); wr(R_THR, thr); wr(R_IEN, 32'h1);
    for (i = 0; i < 512; i = i + 1) gold[i] = g_ramp[i];
    ngold = n_ramp + g_extra;
    run_stream(n_ramp);
    chk_reg(R_DROP, 32'hFFFFFFFF, 32'h0, "DROP_CNT phai = 0 (RAMP)");
    chk_reg(R_CTR, 32'hFFFFFFFF, c_ramp + cnt / 64, "ctr phien sau luong RAMP");
    chk_reg(R_CYC, 32'hFFFFFFFF, mon_cyc_max, "CYCLES_MAX khac monitor (RAMP)");
    // bat lai khong nap khoa: keystream phai noi tiep (mau dang bay luc tat da duoc day ra)
    prev_w = last_w;
    ctrl_lv = 32'h101; ctrl(32'h0);
    t = 0; rd = 0;
    while (rd[15:0] == 0 && t < 100000) begin rdr(R_LVL, rd); t = t + 1; end
    rdr(R_OUT, rd);
    if (rd[21:16] !== ((prev_w[21:16] + 6'd1) & 6'h3F) ||
        rd[31:24] !== (prev_w[31:24] + ((prev_w[21:16] == 6'd63) ? 8'd1 : 8'd0)) || rd[23] !== 1'b0) begin
      err("bat lai: (ctr, idx) khong noi tiep tu cuoi truoc khi tat");
      if (bad <= 12) $display("      truoc %08h, sau %08h", prev_w, rd);
    end
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    ctrl(32'h8);

    // ================================================================ E  SINE
    phase = 5;
    soft_reset;
    load_key(c_sine);
    wr(R_I2S, sdiv); wr(R_SRC, 32'd2); wr(R_THR, thr); wr(R_IEN, 32'h1);
    for (i = 0; i < 512; i = i + 1) gold[i] = g_sine[i];
    ngold = n_sine + g_extra;
    run_stream(n_sine);

    // ================================================================ F  MIC
    phase = 6;
    soft_reset;
    load_key(c_mic);
    mic_restart = 1'b1; @(posedge clk); #1 mic_restart = 1'b0;
    wr(R_I2S, (mic_shift << 16) | sdiv); wr(R_SRC, 32'd0); wr(R_SKIP, mic_skip); wr(R_THR, thr); wr(R_IEN, 32'h1);
    for (i = 0; i < 512; i = i + 1) gold[i] = g_mic[i];
    ngold = n_mic + g_extra;
    cnt = 0;
    ctrl_lv = 32'h101; ctrl(32'h0);
    repeat (600) @(posedge clk);
    chk_reg(R_STATUS, 32'h40, 32'h40, "I2S_RUNNING phai = 1 khi dang ghi MIC");
    t = 0;
    while (cnt < n_mic && t < 200000) begin
      @(posedge clk);
      if (irq === 1'b1) begin drain; wr(R_IST, 32'h1); end
      t = t + 1;
    end
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    drain;
    rdr(R_LVL, rd);
    lin = rd[31:16];
    if (rd !== 32'd0) err("tat ENABLE: in_fifo phai tu rut het, out_fifo da doc het");
    rdr(R_CLIP, rd);
    if (rd < g_clip[cnt + lin] || rd > g_clip[cnt + lin + 2]) begin
      err("CLIP_CNT khac golden");
      if (bad <= 12) $display("      CLIP_CNT %0d, ky vong %0d..%0d", rd, g_clip[cnt + lin], g_clip[cnt + lin + 2]);
    end
    if (g_clip[cnt] == 0) err("kich ban MIC khong co mau nao bi bao hoa");
    chk_reg(R_STATUS, 32'h40, 32'h0, "I2S_RUNNING phai = 0 sau khi tat");
    wr(R_CLIP, 32'h0);
    chk_reg(R_CLIP, 32'hFFFFFFFF, 32'h0, "ghi xoa CLIP_CNT");
    ctrl(32'h8);                                       // FIFO_CLR
    chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "FIFO_CLR khong xoa in_fifo");

    // ================================================================ G  tran + GAP
    phase = 7;
    soft_reset;
    load_key(c_ovf);
    wr(R_I2S, sdiv); wr(R_SRC, 32'd1); wr(R_THR, 32'hFFFF_FFFF); wr(R_IEN, 32'h2);
    for (i = 0; i < 4096; i = i + 1) gold[i] = g_ovf[i];
    first_gap = OUT_DEPTH + 64;
    ngold = first_gap + n_extra + g_extra;
    cnt = 0;
    ctrl_lv = 32'h101; ctrl(32'h0);
    t = 0; rd = 0;
    while (rd < n_drop && t < 1000000) begin rdr(R_DROP, rd); t = t + 1; end
    if (rd != n_drop) err("khong dung lai dung DROP mau bi bo");
    chk_reg(R_STATUS, 32'h18, 32'h18, "STATUS.OUT_FULL / IN_OVF phai = 1 khi tran");
    chk_reg(R_LVL, 32'hFFFFFFFF, (32'd64 << 16) | OUT_DEPTH, "FIFO_LEVEL luc tran");
    chk_reg(R_IST, 32'h2, 32'h2, "IRQ_STATUS.IN_OVF");
    if (irq !== 1'b1) err("irq_o phai = 1 (IN_OVF da bat)");
    while (cnt < first_gap + n_extra) drain;
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    drain;
    chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "tran: sau khi tat, mau con trong in_fifo phai duoc ma hoa va rut het");
    chk_reg(R_DROP, 32'hFFFFFFFF, n_drop, "DROP_CNT sau khi rut");
    chk_reg(R_STATUS, 32'h18, 32'h08, "sau khi rut: IN_OVF giu 1 (W1C), OUT_FULL ve 0");
    chk_reg(R_SCNT, 32'hFFFFFFFF, cnt, "SAMPLE_CNT (tran)");
    wr(R_DROP, 32'h0);
    chk_reg(R_DROP, 32'hFFFFFFFF, 32'h0, "ghi xoa DROP_CNT");
    wr(R_IST, 32'h1);                                  // W1C chi bit THRESH: IN_OVF phai con
    chk_reg(R_IST, 32'h2, 32'h2, "W1C IRQ_STATUS xoa ca bit khong ghi 1");
    wr(R_STATUS, 32'h8); wr(R_IST, 32'h2);
    chk_reg(R_STATUS, 32'h8, 32'h0, "W1C IN_OVF");
    @(posedge clk); @(posedge clk);
    if (irq !== 1'b0) err("irq_o phai ve 0 sau W1C");

    // ================================================================ H  nguong IRQ, KEY_CLEAR giua luong, FIFO_CLR
    phase = 8;
    soft_reset;
    load_key(32'd10);
    wr(R_I2S, sdiv); wr(R_SRC, 32'd1); wr(R_THR, 32'd16);          // IRQ_EN = 0 (mac dinh)
    ctrl_lv = 32'h101; ctrl(32'h0);
    t = 0; rd = 0;
    while (rd[15:0] < 16 && t < 100000) begin rdr(R_LVL, rd); t = t + 1; end
    if (rd[15:0] != 16) err("muc out_fifo nhay qua 16 (khong kiem duoc nguong)");
    chk_reg(R_IST, 32'h1, 32'h1, "IRQ_STATUS.THRESH phai bat khi muc = nguong (>=)");
    chk_reg(R_STATUS, 32'h20, 32'h20, "STATUS.OUT_GE_THRESH khi muc = nguong");
    if (irq !== 1'b0) err("irq_o = 1 du IRQ_EN = 0");
    t = 0; rd = 0;
    while (rd[15:0] < 70 && t < 100000) begin rdr(R_LVL, rd); t = t + 1; end
    t = 0; rd = 0;
    while (!rd[0] && t < 100000) begin apb(1'b0, R_STATUS, 32'd0, rd); t = t + 1; end   // cho loi BAN
    ctrl(32'h10);                                      // KEY_CLEAR ngay giua mot mau
    chk_reg(R_STATUS, 32'h2, 32'h0, "KEY_CLEAR giua luong: KEY_READY van = 1");
    rdr(R_LVL, rd);
    repeat (3000) @(posedge clk);
    rdr(R_LVL, rd2);
    if (rd2[15:0] != rd[15:0]) err("van ma hoa sau KEY_CLEAR");
    chk_reg(R_STATUS, 32'h1, 32'h0, "loi treo BUSY sau KEY_CLEAR");
    wr(R_CTR, 32'd11);
    chk_reg(R_STATUS, 32'h80, 32'h80, "ctr da dung (11) duoc ghi lai sau KEY_CLEAR");
    wr(R_STATUS, 32'h80);
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    ctrl(32'h8);                                       // FIFO_CLR
    chk_reg(R_LVL, 32'hFFFFFFFF, 32'h0, "FIFO_CLR");
    chk_reg(R_OUT, 32'hFFFFFFFF, 32'h0, "OUT_DATA sau FIFO_CLR phai = 0");
    wr(R_CTR, 32'd1000);
    chk_reg(R_STATUS, 32'h80, 32'h0, "CTR moi lon hon bi tu choi");
    ctrl(32'h4);                                       // RESEED, KHONG ghi lai KMASTER -> K = 0
    wait_key_ready;
    ctrl_lv = 32'h101; ctrl(32'h0);
    t = 0; rd = 0;
    while (rd[15:0] == 0 && t < 100000) begin rdr(R_LVL, rd); t = t + 1; end
    rdr(R_OUT, rd);
    if (rd !== zkey_word) begin
      err("tu dau sau KEY_CLEAR + RESEED khac golden K = 0 (KMASTER chua bi xoa?)");
      if (bad <= 12) $display("      RTL %08h, golden %08h", rd, zkey_word);
    end
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    ctrl(32'h8);
    chk_reg(R_CYC, 32'hFFFFFFFF, mon_cyc_max, "CYCLES_MAX khac monitor");
    wr(R_CYC, 32'h0);
    mon_clr = 1'b1; @(posedge clk); #1 mon_clr = 1'b0;
    chk_reg(R_CYC, 32'hFFFFFFFF, 32'h0, "ghi xoa CYCLES_MAX");

    // ================================================================ I  bo mau khi chua co khoa; tat thi van ma hoa not
    phase = 10;
    soft_reset;
    wr(R_I2S, sdiv); wr(R_SRC, 32'd1);
    ctrl_lv = 32'h101; ctrl(32'h0);                    // chua RESEED: loi khong ma hoa duoc
    t = 0; rd = 0;
    while (rd == 0 && t < 100000) begin rdr(R_DROP, rd); t = t + 1; end
    ctrl_lv = 32'h100; ctrl(32'h0);                    // tat ngay sau lan bo mau dau tien
    if (rd != 1) err("phai dung lai ngay sau lan bo mau dau tien");
    chk_reg(R_LVL, 32'hFFFF0000, 32'd64 << 16, "in_fifo phai day (64) khi chua co khoa");
    chk_reg(R_STATUS, 32'h8, 32'h8, "IN_OVF khi chua co khoa");
    for (i = 0; i < 512; i = i + 1) gold[i] = g_nokey[i];
    ngold = 105; cnt = 0;
    load_key(ctr_nokey);                               // ENABLE = 0: luong phai ma hoa not 65 mau da thu
    repeat (12000) @(posedge clk);
    chk_reg(R_LVL, 32'hFFFFFFFF, 32'd65, "tat ENABLE: 65 mau da thu phai duoc ma hoa het (in 0, out 65)");
    drain;
    if (cnt != 65) err("so tu sau khi tat khac 65");
    ctrl_lv = 32'h101; ctrl(32'h0);                    // ban ghi moi, khong nap lai khoa
    t = 0;
    while (cnt < 75 && t < 200000) begin
      @(posedge clk);
      if ((t % 2000) == 1999) drain;
      t = t + 1;
    end
    if (cnt < 75) err("ban ghi moi khong ra tu");
    ctrl_lv = 32'h100; ctrl(32'h0);
    repeat (1200) @(posedge clk);
    drain;

    // ================================================================ ket thuc
    phase = 9;
    repeat (4) @(posedge clk);
    if (bad == 0)
      $display("PASS: audio_crypt_top khop golden qua APB3 (REG %0d buoc; luong RAMP/SINE/MIC; tran %0d mau + GAP; CTR, IRQ, KEY_CLEAR; out_fifo %0d tu) (GAP=%0d)",
               n_reg, n_drop, OUT_DEPTH, gap);
    else
      $display("FAIL: audio_crypt_top %0d loi (GAP=%0d)", bad, gap);
    $finish;
  end

  // chot thoi gian: khong de mo phong chay mai
  initial begin
    #400_000_000;
    $display("FAIL: audio_crypt_top het thoi gian o pha %0d", phase);
    $finish;
  end
endmodule
