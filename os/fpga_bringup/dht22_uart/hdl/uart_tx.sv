// =============================================================================
// uart_tx.sv - UART 8N1, chi truyen. ready = 1 khi nhan duoc byte moi (valid & ready).
// =============================================================================
module uart_tx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       valid,
    input  logic [7:0] data,
    output logic       ready,
    output logic       txd
);
    localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;     // 50 MHz / 115200 -> 434 (sai so 0,01 %)

    logic [$clog2(DIV)-1:0] cnt;
    logic [3:0]             nbit;      // 0 = dang ranh
    logic [9:0]             shreg;     // {stop, data[7:0], start}, LSB ra truoc

    assign ready = (nbit == 0);

    always_ff @(posedge clk) begin
        if (rst) begin
            nbit <= '0;
            txd  <= 1'b1;
            cnt  <= '0;
        end else if (nbit == 0) begin
            txd <= 1'b1;
            if (valid) begin
                shreg <= {1'b1, data, 1'b0};
                nbit  <= 4'd11;                 // 10 bit + 1 lan cho het bit stop
                cnt   <= '0;
            end
        end else if (cnt == 0) begin
            if (nbit == 4'd1 || nbit > 4'd11) begin
                nbit <= '0;                     // het bit stop (hoac nbit hong khi khong co reset)
            end else begin
                txd   <= shreg[0];
                shreg <= {1'b1, shreg[9:1]};
                cnt   <= DIV - 1;
                nbit  <= nbit - 1'b1;
            end
        end else begin
            cnt <= cnt - 1'b1;
        end
    end
endmodule
