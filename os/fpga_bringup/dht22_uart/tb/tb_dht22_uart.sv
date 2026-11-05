// =============================================================================
// tb_dht22_uart.sv - mo phong dht22_uart_top voi mo hinh DHT22 + bo thu UART.
//   Kich ban: OK, sai checksum, khong phan hoi, nhiet do am / RH = 100,0 %, RH = 5,0 % / T = 0,0.
//   Moi dong UART nhan duoc duoc so voi dong mong doi; cuoi cung in "TB PASS" hoac "TB FAIL".
// =============================================================================
`timescale 1ns / 1ps

module tb_dht22_uart;
    localparam int CLK_HZ = 50_000_000;
    localparam int BAUD   = 115_200;
    localparam real BIT_NS = 1.0e9 / BAUD;

    logic clk = 0;
    always #10 clk = ~clk;                         // 50 MHz

    tri1  dht_line;                                // dien tro keo len
    logic model_low = 0;
    assign dht_line = model_low ? 1'b0 : 1'bz;

    logic txd;
    logic led1, led2, led3, led4;

    dht22_uart_top #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .READ_PERIOD_MS(14), .FIRST_READ_MS(12)
    ) dut (
        .REF_CLK_50MHz(clk), .DHT_DATA(dht_line), .UART_TXD(txd),
        .LED1(led1), .LED2(led2), .LED3(led3), .LED4(led4)
    );

    // ------------------------------------------------------------ kich ban cam bien
    typedef struct { logic respond; logic [15:0] rh, t; logic bad_sum; } scen_t;
    scen_t sc [5] = '{
        '{1, 16'h028C, 16'h011D, 0},               // 65,2 %  28,5 C
        '{1, 16'h028C, 16'h011D, 1},               // checksum sai
        '{0, 16'h0000, 16'h0000, 0},               // khong phan hoi
        '{1, 16'h03E8, 16'h8023, 0},               // 100,0 % -3,5 C
        '{1, 16'h0032, 16'h0000, 0}                // 5,0 %   0,0 C
    };

    function automatic logic [39:0] frame(scen_t s);
        logic [7:0] sum;
        sum = s.rh[15:8] + s.rh[7:0] + s.t[15:8] + s.t[7:0];
        return {s.rh, s.t, s.bad_sum ? sum ^ 8'h01 : sum};
    endfunction

    function automatic string x10(logic [15:0] v);      // 652 -> "65.2"
        return $sformatf("%0d.%0d", v / 10, v % 10);
    endfunction

    function automatic string pad5(int n);               // Questa khong dem 0 voi %05d
        string s = $sformatf("%0d", n);
        while (s.len() < 5) s = {"0", s};
        return s;
    endfunction

    function automatic string hex40(logic [39:0] v);     // %h luon chu thuong -> doi sang hoa
        string s = $sformatf("%h", v);
        return s.toupper();
    endfunction

    string expected [$];
    initial begin
        expected.push_back("PBL5 DHT22 bring-up (FPGA only) 115200 8N1 DATA=E12");
        foreach (sc[i]) begin
            automatic string pre = {"#", pad5(i + 1), " "};
            if (!sc[i].respond)
                expected.push_back({pre, "ERR=NO_RESPONSE raw="});         // raw: so sanh tien to
            else if (sc[i].bad_sum)
                expected.push_back({pre, {"ERR=CHECKSUM raw=", hex40(frame(sc[i]))}});
            else
                expected.push_back({pre, "RH=", x10(sc[i].rh), "% T=", sc[i].t[15] ? "-" : "",
                                    x10({1'b0, sc[i].t[14:0]}), "C raw=",
                                    hex40(frame(sc[i])), " OK"});
        end
    end

    // Mo hinh DHT22: cho host keo thap >= 500 us roi nha, tra loi theo kich ban.
    initial begin : sensor
        time t0;
        logic [39:0] f;
        foreach (sc[i]) begin
            @(negedge dht_line);
            t0 = $time;
            @(posedge dht_line);
            if ($time - t0 < 500_000) $error("xung start qua ngan: %0t", $time - t0);
            if (!sc[i].respond) continue;
            f = frame(sc[i]);
            #30us;  model_low = 1; #80us; model_low = 0; #80us;
            for (int b = 39; b >= 0; b--) begin
                model_low = 1; #50us; model_low = 0;
                if (f[b]) #70us; else #27us;
            end
            model_low = 1; #50us; model_low = 0;
        end
    end

    // ------------------------------------------------------------ bo thu UART
    int    errors = 0, nlines = 0;
    string line = "";
    initial begin : uart_rx
        logic [7:0] c;
        forever begin
            @(negedge txd);
            #(BIT_NS * 1.5);
            for (int b = 0; b < 8; b++) begin
                c[b] = txd;
                #(BIT_NS);
            end
            if (txd !== 1'b1) begin $error("loi khung stop"); errors++; end
            if (c == 8'h0A) begin
                automatic string exp = expected.size() ? expected.pop_front() : "<khong mong doi>";
                automatic logic ok = exp.substr(exp.len() - 4, exp.len() - 1) == "raw="
                           ? line.substr(0, exp.len() - 1) == exp : line == exp;
                $display("[%5.1f ms] UART: %s %s", $realtime / 1ms, line, ok ? "" : "  <-- SAI");
                if (!ok) begin $display("            mong doi: %s", exp); errors++; end
                nlines++;
                line = "";
            end else if (c != 8'h0D) begin
                line = {line, string'(c)};
            end
        end
    end

    initial begin
        #80ms;
        if (nlines != 6) begin $display("chi nhan %0d/6 dong", nlines); errors++; end
        if (errors == 0) $display("TB PASS (%0d dong khop)", nlines);
        else             $display("TB FAIL (%0d loi)", errors);
        $finish;
    end
endmodule
