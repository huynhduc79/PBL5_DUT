// =============================================================================
// dht22_reader.sv - doc mot khung 40 bit tu DHT22 (AM2302) hoan toan bang phan cung.
//
// Giao thuc (xem os/common/dht22.h, giong het ban C tren RTOS):
//   FPGA keo DATA thap START_LOW_US roi nha -> cam bien: thap ~80 us, cao ~80 us
//   40 bit: thap ~50 us, roi cao 26-28 us (bit 0) hoac ~70 us (bit 1)
//   RH[16] | T[16] (bit 15 = dau) | checksum[8] = tong 4 byte dau (mod 256)
//
// Chan DATA la open-drain: drive_low = 1 keo xuong 0, = 0 thi tha noi (dien tro keo len).
// Moi trang thai cho deu co timeout, nen FSM tu thoat ra IDLE ke ca khi khong co reset.
// =============================================================================
module dht22_reader #(
    parameter int CLK_HZ       = 50_000_000,
    parameter int START_LOW_US = 2000,     // >= 1 ms
    parameter int BIT1_MIN_US  = 48        // xung cao > 48 us -> bit 1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,             // xung 1 chu ky: bat dau mot lan doc
    input  logic        data_in,           // muc chan DATA (chua dong bo)
    output logic        drive_low,
    output logic        busy,
    output logic        done,              // xung 1 chu ky khi co ket qua
    output logic [2:0]  status,            // ST_*
    output logic [39:0] raw,               // 5 byte nhan duoc, byte dau o bit 39..32
    output logic [15:0] rh_x10,
    output logic [15:0] t_raw
);
    localparam logic [2:0] ST_OK = 3'd0, ST_NO_RESPONSE = 3'd1, ST_TIMEOUT = 3'd2,
                           ST_CHECKSUM = 3'd3, ST_RANGE = 3'd4;
    localparam int US_DIV = CLK_HZ / 1_000_000;

    // ---- dong bo + loc nhieu: chi doi muc khi 4 mau lien tiep giong nhau
    logic [2:0] sync;
    logic [3:0] hist;
    logic       level;
    always_ff @(posedge clk) begin
        sync <= {sync[1:0], data_in};
        hist <= {hist[2:0], sync[2]};
        if (hist == 4'b1111)      level <= 1'b1;
        else if (hist == 4'b0000) level <= 1'b0;
    end

    // ---- nhip 1 us
    logic [$clog2(US_DIV)-1:0] div;
    logic                      tick_us;
    always_ff @(posedge clk) begin
        tick_us <= 1'b0;
        if (rst || div >= US_DIV - 1) begin
            div     <= '0;
            tick_us <= !rst;
        end else begin
            div <= div + 1'b1;
        end
    end

    typedef enum logic [3:0] {
        S_IDLE, S_START_LOW, S_WAIT_RESP_LOW, S_RESP_LOW, S_RESP_HIGH,
        S_BIT_LOW, S_BIT_HIGH, S_CHECK
    } state_t;
    state_t      st;
    logic [11:0] us;        // so us trong trang thai hien tai (bao hoa)
    logic [5:0]  nbit;
    logic [39:0] shreg;

    function automatic logic [11:0] sat_inc(input logic [11:0] v);
        return (v == 12'hFFF) ? v : v + 1'b1;
    endfunction

    always_ff @(posedge clk) begin : fsm
        logic       fin;
        logic [2:0] fin_st;
        fin    = 1'b0;
        fin_st = ST_OK;
        done  <= 1'b0;
        if (tick_us) us <= sat_inc(us);

        if (rst) begin
            st        <= S_IDLE;
            drive_low <= 1'b0;
            us        <= '0;
        end else begin
            case (st)
                S_IDLE: begin
                    drive_low <= 1'b0;
                    if (start) begin
                        st        <= S_START_LOW;
                        drive_low <= 1'b1;
                        us        <= '0;
                    end
                end
                S_START_LOW: if (us >= START_LOW_US[11:0]) begin
                    drive_low <= 1'b0;                     // nha chan, cho cam bien tra loi
                    st        <= S_WAIT_RESP_LOW;
                    us        <= '0;
                end
                S_WAIT_RESP_LOW: begin                    // cam bien keo thap sau 20-40 us
                    if (!level && us >= 5)  begin st <= S_RESP_LOW;  us <= '0; end
                    else if (us > 200)      begin fin = 1'b1; fin_st = ST_NO_RESPONSE; end
                end
                S_RESP_LOW: begin                         // thap ~80 us
                    if (level)              begin st <= S_RESP_HIGH; us <= '0; end
                    else if (us > 120)      begin fin = 1'b1; fin_st = ST_NO_RESPONSE; end
                end
                S_RESP_HIGH: begin                        // cao ~80 us
                    if (!level)             begin st <= S_BIT_LOW; us <= '0; nbit <= '0; end
                    else if (us > 120)      begin fin = 1'b1; fin_st = ST_NO_RESPONSE; end
                end
                S_BIT_LOW: begin                          // thap ~50 us truoc moi bit
                    if (level)              begin st <= S_BIT_HIGH; us <= '0; end
                    else if (us > 100)      begin fin = 1'b1; fin_st = ST_TIMEOUT; end
                end
                S_BIT_HIGH: begin                         // do rong xung cao = gia tri bit
                    if (!level) begin
                        shreg <= {shreg[38:0], (us > BIT1_MIN_US[11:0])};
                        us    <= '0;
                        if (nbit == 6'd39) st <= S_CHECK;
                        else begin nbit <= nbit + 1'b1; st <= S_BIT_LOW; end
                    end else if (us > 120) begin fin = 1'b1; fin_st = ST_TIMEOUT; end
                end
                S_CHECK: begin
                    raw    <= shreg;
                    rh_x10 <= shreg[39:24];
                    t_raw  <= shreg[23:8];
                    if (shreg[39:32] + shreg[31:24] + shreg[23:16] + shreg[15:8] != shreg[7:0])
                        begin fin = 1'b1; fin_st = ST_CHECKSUM; end
                    else if (shreg[39:24] > 16'd1000 ||                       // 0..100,0 %RH
                             (shreg[23] ? shreg[22:8] > 15'd400 : shreg[22:8] > 15'd800))
                        begin fin = 1'b1; fin_st = ST_RANGE; end                                     // -40..80 do C
                    else
                        begin fin = 1'b1; fin_st = ST_OK; end
                end
                default: st <= S_IDLE;
            endcase
            if (fin) begin                                // ket thuc mot lan doc
                status    <= fin_st;
                done      <= 1'b1;
                drive_low <= 1'b0;
                st        <= S_IDLE;
                if (fin_st == ST_NO_RESPONSE || fin_st == ST_TIMEOUT) raw <= shreg;   // de debug
            end
        end
    end

    assign busy = (st != S_IDLE);
endmodule
