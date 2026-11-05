// =============================================================================
// dht22_uart_top.sv - bai thu dau tien tren PolarFire SoC Discovery Kit, CHI dung FPGA fabric
// (khong MSS, khong RTOS): doc DHT22 moi 2 s va in ket qua ra USB-UART (UART_D cua FT4232H).
//
//   REF_CLK_50MHz (R18) --> dht22_reader <--> DHT_DATA (E12, chan 7 header RPi, open-drain)
//                               |
//                          line_printer --> uart_tx --> UART_TXD (Y21) --> FT4232H --> COM tren PC
//
//   LED1: nhap nhay 1 Hz (thiet ke dang chay)   LED2: dao trang thai moi lan doc OK
//   LED3: sang khi lan doc gan nhat bi loi      LED4: sang trong luc dang giao tiep voi cam bien
//
// Reset: PolarFire khong dam bao gia tri flip-flop luc bat nguon, nen co bo dem POR va moi
// FSM deu tu quay ve IDLE (timeout / nhanh default) ke ca khi POR khong chay.
// =============================================================================
module dht22_uart_top #(
    parameter int CLK_HZ          = 50_000_000,
    parameter int BAUD            = 115_200,
    parameter int READ_PERIOD_MS  = 2000,     // DHT22: toi thieu 2 s
    parameter int FIRST_READ_MS   = 1500,     // cho cam bien on dinh sau khi cap nguon
    parameter int START_LOW_US    = 2000
) (
    input  logic REF_CLK_50MHz,
    inout  wire  DHT_DATA,
    output logic UART_TXD,
    output logic LED1,
    output logic LED2,
    output logic LED3,
    output logic LED4
);
    logic clk;
    assign clk = REF_CLK_50MHz;

    // ---- power-on reset ~1,3 ms
    logic [15:0] por_cnt;
    logic        rst;
    // synthesis translate_off
    initial por_cnt = '0;          // chi cho mo phong; tren chip gia tri dau la bat ky
    // synthesis translate_on
    always @(posedge clk) begin    // 'always' (khong phai always_ff) vi co initial chi-mo-phong o tren
        if (por_cnt != 16'hFFFF) por_cnt <= por_cnt + 1'b1;
        rst <= (por_cnt != 16'hFFFF);
    end

    // ---- nhip 1 ms
    localparam int MS_DIV = CLK_HZ / 1000;
    logic [$clog2(MS_DIV)-1:0] ms_div;
    logic                      tick_ms;
    always_ff @(posedge clk) begin
        tick_ms <= 1'b0;
        if (rst || ms_div >= MS_DIV - 1) begin
            ms_div  <= '0;
            tick_ms <= !rst;
        end else begin
            ms_div <= ms_div + 1'b1;
        end
    end

    // ---- hen gio doc cam bien + LED nhap nhay
    logic [15:0] ms_cnt;
    logic [9:0]  blink_cnt;
    logic        read_start, banner_start, banner_done;
    always_ff @(posedge clk) begin
        read_start   <= 1'b0;
        banner_start <= 1'b0;
        if (rst) begin
            ms_cnt      <= 16'(READ_PERIOD_MS - FIRST_READ_MS);
            blink_cnt   <= '0;
            LED1        <= 1'b0;
            banner_done <= 1'b0;
        end else begin
            if (!banner_done) begin
                banner_start <= 1'b1;            // in dong chao mot lan sau reset
                banner_done  <= 1'b1;
            end
            if (tick_ms) begin
                blink_cnt <= (blink_cnt >= 499) ? '0 : blink_cnt + 1'b1;
                if (blink_cnt >= 499) LED1 <= !LED1;
                if (ms_cnt >= READ_PERIOD_MS - 1) begin
                    ms_cnt     <= '0;
                    read_start <= 1'b1;
                end else begin
                    ms_cnt <= ms_cnt + 1'b1;
                end
            end
        end
    end

    // ---- DHT22 (open-drain: chi keo 0 hoac tha noi -> Libero suy ra BIBUF)
    logic        drive_low, rd_busy, rd_done;
    logic [2:0]  rd_status;
    logic [39:0] rd_raw;
    logic [15:0] rd_rh, rd_t;

    assign DHT_DATA = drive_low ? 1'b0 : 1'bz;

    dht22_reader #(.CLK_HZ(CLK_HZ), .START_LOW_US(START_LOW_US)) u_dht (
        .clk(clk), .rst(rst), .start(read_start), .data_in(DHT_DATA),
        .drive_low(drive_low), .busy(rd_busy), .done(rd_done), .status(rd_status),
        .raw(rd_raw), .rh_x10(rd_rh), .t_raw(rd_t)
    );

    // ---- in ket qua
    logic [15:0] seq;
    logic        pr_busy, pr_start, pr_banner;
    logic        tx_valid, tx_ready;
    logic [7:0]  tx_data;

    always_ff @(posedge clk) begin
        pr_start <= 1'b0;
        if (rst) begin
            seq  <= '0;
            LED2 <= 1'b0;
            LED3 <= 1'b0;
        end else begin
            if (banner_start && !pr_busy) begin
                pr_start  <= 1'b1;
                pr_banner <= 1'b1;
            end else if (rd_done) begin
                seq <= seq + 1'b1;
                LED3 <= (rd_status != 3'd0);
                if (rd_status == 3'd0) LED2 <= !LED2;
                if (!pr_busy) begin              // dong truoc chua in xong (khong xay ra o 2 s) -> bo
                    pr_start  <= 1'b1;
                    pr_banner <= 1'b0;
                end
            end
        end
    end

    line_printer u_pr (
        .clk(clk), .rst(rst), .start(pr_start), .kind_banner(pr_banner), .seq(seq),
        .status(rd_status), .rh_x10(rd_rh), .t_raw(rd_t), .raw(rd_raw),
        .busy(pr_busy), .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data), .ready(tx_ready), .txd(UART_TXD)
    );

    assign LED4 = rd_busy;
endmodule
