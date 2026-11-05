// =============================================================================
// line_printer.sv - in mot dong ASCII qua uart_tx.
//
//   kind = BANNER : "PBL5 DHT22 bring-up (FPGA only) 115200 8N1 DATA=E12\r\n"
//   kind = READING, status OK  : "#00012 RH=65.2% T=-3.5C raw=028C80236F OK\r\n"
//   kind = READING, loi        : "#00013 ERR=CHECKSUM raw=028C011DB7\r\n"
//
// Cach lam: bo dem pc chay qua "chuong trinh" in (ham step()); moi pc cho ra mot ky tu,
// hoac bo qua (vd. so 0 o dau), hoac ket thuc. pc chi tang khi uart_tx nhan ky tu.
// =============================================================================
module line_printer (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        kind_banner,      // 1 = BANNER, 0 = READING
    input  logic [15:0] seq,
    input  logic [2:0]  status,
    input  logic [15:0] rh_x10,
    input  logic [15:0] t_raw,
    input  logic [39:0] raw,
    output logic        busy,
    output logic        tx_valid,
    output logic [7:0]  tx_data,
    input  logic        tx_ready
);
    localparam logic [2:0] ST_OK = 3'd0, ST_NO_RESPONSE = 3'd1, ST_TIMEOUT = 3'd2,
                           ST_CHECKSUM = 3'd3, ST_RANGE = 3'd4;

    localparam int          BANNER_LEN = 51;
    localparam logic [8*BANNER_LEN-1:0] BANNER = "PBL5 DHT22 bring-up (FPGA only) 115200 8N1 DATA=E12";
    localparam logic [7:0]  CR = 8'h0D, LF = 8'h0A;

    // ---- doi nhi phan -> BCD (double dabble), dung cho so <= 65535
    function automatic logic [19:0] bin2bcd(input logic [15:0] b);
        logic [35:0] s;
        s = {20'd0, b};
        for (int i = 0; i < 16; i++) begin
            for (int d = 0; d < 5; d++)
                if (s[16 + 4 * d +: 4] > 4'd4) s[16 + 4 * d +: 4] = s[16 + 4 * d +: 4] + 4'd3;
            s = s << 1;
        end
        return s[35:16];
    endfunction

    function automatic logic [7:0] dig(input logic [3:0] d);
        return 8'h30 + {4'h0, d};
    endfunction

    function automatic logic [7:0] hex(input logic [3:0] h);
        return (h < 4'd10) ? 8'h30 + {4'h0, h} : 8'h37 + {4'h0, h};   // 'A' = 0x41
    endfunction

    function automatic logic [8*11-1:0] err_name(input logic [2:0] s);   // dem bang ' ' (khong in)
        case (s)
            ST_NO_RESPONSE: return "NO_RESPONSE";
            ST_TIMEOUT:     return "TIMEOUT    ";
            ST_CHECKSUM:    return "CHECKSUM   ";
            ST_RANGE:       return "RANGE      ";
            default:        return "UNKNOWN    ";
        endcase
    endfunction

    // ---- gia tri da chot luc start
    logic        is_banner, ok, t_neg;
    logic [19:0] seq_bcd, rh_bcd, t_bcd;
    logic [39:0] raw_l;
    logic [2:0]  st_l;

    // ---- mot buoc cua chuong trinh in: {ket_thuc, in_ra, ky_tu}
    typedef struct packed { logic fin; logic emit; logic [7:0] ch; } step_t;

    function automatic step_t chr(input logic [7:0] c);   return '{1'b0, 1'b1, c};   endfunction
    function automatic step_t skip();                     return '{1'b0, 1'b0, 8'h00}; endfunction
    function automatic step_t opt(input logic e, input logic [7:0] c); return '{1'b0, e, c}; endfunction

    // in so x10 dang "65.2" / "100.0" / "5.0": digits d3 d2 d1 '.' d0, bo so 0 o dau
    function automatic step_t num(input logic [19:0] b, input int k);
        case (k)
            0: return opt(b[15:12] != 0, dig(b[15:12]));
            1: return opt(b[15:12] != 0 || b[11:8] != 0, dig(b[11:8]));
            2: return chr(dig(b[7:4]));
            3: return chr(8'h2E);                                  // '.'
            default: return chr(dig(b[3:0]));
        endcase
    endfunction

    function automatic step_t hexraw(input int k);                // k = 0..9, nibble cao truoc
        return chr(hex(raw_l[39 - 4 * k -: 4]));
    endfunction

    function automatic step_t step(input logic [6:0] pc);
        logic [8*11-1:0] name;
        if (is_banner) begin
            if (pc < BANNER_LEN)       return chr(BANNER[8 * (BANNER_LEN - 1 - pc) +: 8]);
            if (pc == BANNER_LEN)      return chr(CR);
            if (pc == BANNER_LEN + 1)  return chr(LF);
            return '{1'b1, 1'b0, 8'h00};
        end
        if (pc == 0)  return chr("#");
        if (pc <= 5)  return chr(dig(seq_bcd[4 * (5 - pc) +: 4]));     // 5 chu so
        if (pc == 6)  return chr(" ");
        if (ok) begin
            case (pc)
                7: return chr("R");  8: return chr("H");  9: return chr("=");
                10, 11, 12, 13, 14: return num(rh_bcd, pc - 10);
                15: return chr("%"); 16: return chr(" "); 17: return chr("T"); 18: return chr("=");
                19: return opt(t_neg, "-");
                20, 21, 22, 23, 24: return num(t_bcd, pc - 20);
                25: return chr("C");
                26: return chr(" "); 27: return chr("r"); 28: return chr("a"); 29: return chr("w");
                30: return chr("=");
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40: return hexraw(pc - 31);
                41: return chr(" "); 42: return chr("O"); 43: return chr("K");
                44: return chr(CR);  45: return chr(LF);
                default: return '{1'b1, 1'b0, 8'h00};
            endcase
        end
        name = err_name(st_l);
        case (pc)
            7: return chr("E"); 8: return chr("R"); 9: return chr("R"); 10: return chr("=");
            11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21: begin
                logic [7:0] c;
                c = name[8 * (10 - (pc - 11)) +: 8];
                return opt(c != " ", c);
            end
            22: return chr(" "); 23: return chr("r"); 24: return chr("a"); 25: return chr("w");
            26: return chr("=");
            27, 28, 29, 30, 31, 32, 33, 34, 35, 36: return hexraw(pc - 27);
            37: return chr(CR); 38: return chr(LF);
            default: return '{1'b1, 1'b0, 8'h00};
        endcase
    endfunction

    // ---- dieu khien
    logic [6:0] pc;
    step_t      cur;
    always_comb cur = step(pc);   // always_comb: tinh lai ca khi bien doc trong step() doi (khong chi pc)
    assign tx_valid = busy && !cur.fin && cur.emit;
    assign tx_data  = cur.ch;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            pc   <= '0;
        end else if (!busy) begin
            if (start) begin
                busy      <= 1'b1;
                pc        <= '0;
                is_banner <= kind_banner;
                ok        <= (status == ST_OK);
                st_l      <= status;
                seq_bcd   <= bin2bcd(seq);
                rh_bcd    <= bin2bcd(rh_x10);
                t_bcd     <= bin2bcd({1'b0, t_raw[14:0]});
                t_neg     <= t_raw[15];
                raw_l     <= raw;
            end
        end else if (cur.fin || pc == 7'h7F) begin
            busy <= 1'b0;
        end else if (!cur.emit || tx_ready) begin   // bo qua, hoac uart_tx da nhan ky tu
            pc <= pc + 1'b1;
        end
    end
endmodule
