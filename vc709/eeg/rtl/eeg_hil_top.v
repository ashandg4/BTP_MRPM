`timescale 1ns / 1ps
// ============================================================
// VC709 hardware-in-the-loop (HIL) test of the thesis FIR filters
// on real EEG data (synth.mat, 140,007 samples).
//
//   PC --USB-UART--> x RAM (int8, up to 2^AW samples)
//   'R' : x RAM streams at full clock rate (or with a gap) through
//         three thesis FIRs in parallel, fed the SAME samples:
//            DUT0  fir8_symmetric       (A: direct form, 8 MRPM)
//            DUT1  fir8_fold            (B: folded, 4 MRPM)
//            DUT2  fir8_fold_pipelined  (C: folded + 4-stage pipeline)
//         every output is written to a per-DUT y RAM, and on-chip
//         counters record output count, first-output latency, last-
//         output cycle and a 32-bit sum of outputs.
//   PC <--USB-UART-- y RAMs, counters
//
// The thesis RTL in ../../../rtl is instantiated UNCHANGED.
// Everything runs in ONE clock domain (clk). The PC checks every
// hardware output against the bit-exact Python model.
//
// Protocol (all multi-byte fields big-endian):
//   'P'            -> "HIL1" CLK_HZ[4] AW[1] NDUT[1]                (10 B)
//   'L' N[3] x*N   -> 'K' N[3] SUM[4]   SUM = sum of the N bytes as unsigned
//   'R' GAP[1]     -> 'D' FLAGS[1] then per DUT d=0..2:
//                       CNT[4] LAT[2] LAST[4] YSUM[4]               (44 B)
//                     GAP = idle clocks between samples (0 = one sample
//                     per clock). FLAGS bit0 = timeout.
//                     LAT  = clocks from the first in_valid to the first
//                            out_valid of that DUT.
//                     LAST = clocks from the first in_valid to the last
//                            out_valid (so total clocks = LAST + 1).
//                     YSUM = sum of the 20-bit signed outputs, mod 2^32.
//   'Y' d[1]       -> 'Y' then CNT_d words, 3 bytes each (20-bit sign-extended)
//   'X'            -> 'X' then N bytes (read-back of x RAM)
//   other          -> '?' byte
//
// DIP SW0: 0 = 115200 baud, 1 = 921600 baud (read continuously).
// LEDs: 0 heartbeat | 1 UART rx | 2 UART tx | 3 run busy |
//       4 last run OK | 5 921600 baud | 6 clock locked | 7 error
// ============================================================
module eeg_hil_top #(
    parameter CLK_HZ       = 200_000_000,
    parameter USE_MMCM     = 0,     // 1: clk = 200 MHz * MMCM_M / MMCM_O
    parameter MMCM_M       = 6,     // VCO = 200*M MHz, must be 600..1440
    parameter MMCM_O       = 4,
    parameter AW           = 18,    // RAM depth 2^AW (262,144 >= 140,007)
    parameter SIM_BAUD_DIV = 0      // simulation only: fixed clocks/bit
)(
    input  wire       SYSCLK_P,
    input  wire       SYSCLK_N,
    input  wire       CPU_RESET,     // active-high push button
    input  wire       GPIO_DIP_SW0,
    input  wire       UART_RXD,      // FPGA input  (from CP2103 TXD)
    output wire       UART_TXD,      // FPGA output (to CP2103 RXD)
    output wire [7:0] LED
);
    localparam NDUT     = 3;
    localparam OW       = 20;
    localparam [15:0] DIV_SLOW = (CLK_HZ + 57600)  / 115200;
    localparam [15:0] DIV_FAST = (CLK_HZ + 460800) / 921600;
    localparam [15:0] DIV_SIM  = SIM_BAUD_DIV;

    // ---------------- clocking ----------------
    wire clk, locked;
`ifdef SIM_NO_PRIMS
    assign clk    = SYSCLK_P;
    assign locked = 1'b1;
`else
    wire clk_ibuf;
    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) u_ibuf (
        .I(SYSCLK_P), .IB(SYSCLK_N), .O(clk_ibuf));
    generate if (USE_MMCM) begin : g_mmcm
        wire clk_fb, clk_mmcm;
        MMCME2_BASE #(
            .CLKIN1_PERIOD   (5.000),
            .CLKFBOUT_MULT_F (MMCM_M),
            .CLKOUT0_DIVIDE_F(MMCM_O),
            .DIVCLK_DIVIDE   (1)
        ) u_mmcm (
            .CLKIN1(clk_ibuf), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
            .CLKOUT0(clk_mmcm), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
            .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
            .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
            .CLKFBOUTB());
        BUFG u_bufg (.I(clk_mmcm), .O(clk));
    end else begin : g_nommcm
        BUFG u_bufg (.I(clk_ibuf), .O(clk));
        assign locked = 1'b1;
    end endgenerate
`endif

    // ---------------- reset / switch sync ----------------
    reg [1:0] rst_s = 2'b11;
    reg [1:0] sw_s  = 2'b00;
    always @(posedge clk) begin
        rst_s <= {rst_s[0], CPU_RESET | ~locked};
        sw_s  <= {sw_s[0], GPIO_DIP_SW0};
    end
    wire rst  = rst_s[1];
    wire fast = sw_s[1];
    wire [15:0] div = (DIV_SIM != 16'd0) ? DIV_SIM : (fast ? DIV_FAST : DIV_SLOW);

    // ---------------- UART ----------------
    wire       rx_v;
    wire [7:0] rx_d;
    reg        tx_start = 1'b0;
    reg  [7:0] tx_data  = 8'd0;
    wire       tx_ready;
    uart_rx u_rx (.clk(clk), .rst(rst), .div(div), .rxd(UART_RXD),
                  .valid(rx_v), .data(rx_d));
    uart_tx u_tx (.clk(clk), .rst(rst), .div(div), .start(tx_start),
                  .data(tx_data), .ready(tx_ready), .txd(UART_TXD));
    // a byte may be issued when the transmitter is idle and no issue is in flight
    wire tx_can = tx_ready & ~tx_start;

    // ---------------- memories ----------------
    localparam DEPTH = 1 << AW;
    (* ram_style = "block" *) reg [7:0]    xram  [0:DEPTH-1];
    (* ram_style = "block" *) reg [OW-1:0] yram0 [0:DEPTH-1];
    (* ram_style = "block" *) reg [OW-1:0] yram1 [0:DEPTH-1];
    (* ram_style = "block" *) reg [OW-1:0] yram2 [0:DEPTH-1];

    reg          x_we = 1'b0;
    reg [AW-1:0] x_wa = 0;
    reg [7:0]    x_wd = 8'd0;
    reg [AW-1:0] x_ra = 0;
    reg [7:0]    x_q1 = 8'd0, x_q2 = 8'd0;   // 2-cycle read (BRAM + output reg)
    always @(posedge clk) begin
        if (x_we) xram[x_wa] <= x_wd;
        x_q1 <= xram[x_ra];
        x_q2 <= x_q1;
    end

    // y write side (one port per DUT) and a shared read address for dumps
    reg          y_we0 = 1'b0, y_we1 = 1'b0, y_we2 = 1'b0;
    reg [AW-1:0] y_wa0 = 0, y_wa1 = 0, y_wa2 = 0;
    reg [OW-1:0] y_wd0 = 0, y_wd1 = 0, y_wd2 = 0;
    reg [AW-1:0] y_ra = 0;
    reg [OW-1:0] y_q10 = 0, y_q11 = 0, y_q12 = 0;
    reg [OW-1:0] y_q20 = 0, y_q21 = 0, y_q22 = 0;
    always @(posedge clk) begin
        if (y_we0) yram0[y_wa0] <= y_wd0;
        y_q10 <= yram0[y_ra]; y_q20 <= y_q10;
    end
    always @(posedge clk) begin
        if (y_we1) yram1[y_wa1] <= y_wd1;
        y_q11 <= yram1[y_ra]; y_q21 <= y_q11;
    end
    always @(posedge clk) begin
        if (y_we2) yram2[y_wa2] <= y_wd2;
        y_q12 <= yram2[y_ra]; y_q22 <= y_q12;
    end

    // ---------------- devices under test (unchanged thesis RTL) ----------------
    reg                  dut_rst = 1'b1;
    reg                  in_v    = 1'b0;     // = issue valid delayed by 2 (RAM latency)
    wire signed [7:0]    in_x    = x_q2;
    wire                 ov0, ov1, ov2;
    wire signed [OW-1:0] yo0, yo1, yo2;
    // keep_hierarchy: no logic may be shared or merged across the three DUTs
    // (they see the same input), so per-DUT utilisation in the report is exact.
    (* keep_hierarchy = "yes" *)
    fir8_symmetric      u_dut0 (.clk(clk), .rst(dut_rst), .in_valid(in_v), .x_in(in_x),
                                .out_valid(ov0), .y_out(yo0));
    (* keep_hierarchy = "yes" *)
    fir8_fold           u_dut1 (.clk(clk), .rst(dut_rst), .in_valid(in_v), .x_in(in_x),
                                .out_valid(ov1), .y_out(yo1));
    (* keep_hierarchy = "yes" *)
    fir8_fold_pipelined u_dut2 (.clk(clk), .rst(dut_rst), .in_valid(in_v), .x_in(in_x),
                                .out_valid(ov2), .y_out(yo2));

    // ---------------- run bookkeeping ----------------
    reg        run_act = 1'b0;     // counters armed
    reg        started = 1'b0;
    reg [31:0] t       = 32'd0;    // clocks since the first in_valid
    reg [31:0] cnt0 = 0, cnt1 = 0, cnt2 = 0;
    reg [15:0] lat0 = 0, lat1 = 0, lat2 = 0;
    reg [31:0] last0 = 0, last1 = 0, last2 = 0;
    reg [31:0] ys0 = 0, ys1 = 0, ys2 = 0;
    reg        got0 = 0, got1 = 0, got2 = 0;

    // registered DUT outputs -> RAM write (keeps DUT->BRAM paths short)
    reg          c_v0 = 0, c_v1 = 0, c_v2 = 0;
    reg [OW-1:0] c_y0 = 0, c_y1 = 0, c_y2 = 0;

    always @(posedge clk) begin
        c_v0 <= ov0 & run_act; c_y0 <= yo0;
        c_v1 <= ov1 & run_act; c_y1 <= yo1;
        c_v2 <= ov2 & run_act; c_y2 <= yo2;
        y_we0 <= c_v0; y_wd0 <= c_y0;
        y_we1 <= c_v1; y_wd1 <= c_y1;
        y_we2 <= c_v2; y_wd2 <= c_y2;
        if (y_we0) y_wa0 <= y_wa0 + 1'b1;
        if (y_we1) y_wa1 <= y_wa1 + 1'b1;
        if (y_we2) y_wa2 <= y_wa2 + 1'b1;
        if (c_v0) ys0 <= ys0 + {{(32-OW){c_y0[OW-1]}}, c_y0};
        if (c_v1) ys1 <= ys1 + {{(32-OW){c_y1[OW-1]}}, c_y1};
        if (c_v2) ys2 <= ys2 + {{(32-OW){c_y2[OW-1]}}, c_y2};

        if (run_act) begin
            if (started)   t <= t + 32'd1;
            else if (in_v) begin started <= 1'b1; t <= 32'd1; end
            if (ov0) begin cnt0 <= cnt0 + 1; last0 <= t; if (!got0) begin got0 <= 1; lat0 <= t[15:0]; end end
            if (ov1) begin cnt1 <= cnt1 + 1; last1 <= t; if (!got1) begin got1 <= 1; lat1 <= t[15:0]; end end
            if (ov2) begin cnt2 <= cnt2 + 1; last2 <= t; if (!got2) begin got2 <= 1; lat2 <= t[15:0]; end end
        end

        if (clr) begin
            started <= 0; t <= 0;
            cnt0 <= 0; cnt1 <= 0; cnt2 <= 0;
            lat0 <= 0; lat1 <= 0; lat2 <= 0;
            last0 <= 0; last1 <= 0; last2 <= 0;
            ys0 <= 0; ys1 <= 0; ys2 <= 0;
            got0 <= 0; got1 <= 0; got2 <= 0;
            y_wa0 <= 0; y_wa1 <= 0; y_wa2 <= 0;
        end
    end

    // ---------------- command FSM ----------------
    localparam S_IDLE  = 5'd0,  S_LEN   = 5'd1,  S_LOAD  = 5'd2,  S_GAP   = 5'd3,
               S_RRST  = 5'd4,  S_RUN   = 5'd5,  S_DRAIN = 5'd6,  S_SEL   = 5'd7,
               S_DRD   = 5'd8,  S_DWAIT = 5'd9,  S_DTX   = 5'd10, S_REPLY = 5'd11,
               S_XRD   = 5'd12, S_XWAIT = 5'd13, S_XTX   = 5'd14, S_HDR   = 5'd15;

    reg [4:0]    st = S_IDLE;
    reg          clr = 1'b0;
    reg [23:0]   n = 24'd0;            // number of samples in x RAM
    reg [1:0]    lb = 2'd0;            // length-byte counter
    reg [23:0]   li = 24'd0;           // load / dump index
    reg [31:0]   xsum = 32'd0;
    reg [7:0]    gap = 8'd0, gcnt = 8'd0;
    reg [AW:0]   ra = 0;               // run issue index
    reg          iss = 1'b0, iss1 = 1'b0;
    reg [7:0]    wcnt = 8'd0;
    reg [1:0]    dsel = 2'd0;
    reg [1:0]    bsel = 2'd0;
    reg [23:0]   dword = 24'd0;
    reg [7:0]    dbyte = 8'd0;
    reg          timeout = 1'b0, run_ok = 1'b0, err = 1'b0;
    reg [4:0]    after_hdr = S_IDLE;
    reg [31:0]   tlimit = 32'd0;

    // Replies are NOT copied into a buffer: every source (counters, sums, n)
    // is frozen while a reply is sent, so the byte is selected straight from
    // it by (rkind, ridx). This keeps the reply path to one 8-bit mux.
    localparam K_PING = 2'd0, K_LOAD = 2'd1, K_RUN = 2'd2, K_BAD = 2'd3;
    reg [1:0]    rkind = K_PING;
    reg [7:0]    badb  = 8'd0;
    reg          rflag = 1'b0;
    reg [5:0]    rlen = 6'd0, ridx = 6'd0;
    localparam [31:0] CLK32 = CLK_HZ;
    localparam [7:0]  AW8 = AW, NDUT8 = NDUT;
    wire [79:0]  v_ping = {"HIL1", CLK32, AW8, NDUT8};
    wire [63:0]  v_load = {"K", n, xsum};
    wire [343:0] v_run  = {7'd0, rflag,
                           cnt0, lat0, last0, ys0,
                           cnt1, lat1, last1, ys1,
                           cnt2, lat2, last2, ys2};
    reg  [7:0]   rbyte;
    always @(*) begin
        case (rkind)
        K_PING:  rbyte = v_ping[8*(9  - ridx) +: 8];
        K_LOAD:  rbyte = v_load[8*(7  - ridx) +: 8];
        K_RUN:   rbyte = v_run [8*(42 - ridx) +: 8];
        default: rbyte = (ridx == 6'd0) ? "?" : badb;
        endcase
    end

    wire [23:0] cnt_sel = (dsel == 2'd0) ? cnt0[23:0] : (dsel == 2'd1) ? cnt1[23:0] : cnt2[23:0];
    wire [OW-1:0] yq_sel = (dsel == 2'd0) ? y_q20 : (dsel == 2'd1) ? y_q21 : y_q22;
    wire all_out = (cnt0[23:0] == n) & (cnt1[23:0] == n) & (cnt2[23:0] == n);


    always @(posedge clk) begin
        tx_start <= 1'b0;
        x_we     <= 1'b0;
        clr      <= 1'b0;
        // issue pipeline: x_ra registered with iss, data valid 2 clocks later
        iss1 <= iss;
        in_v <= iss1;
        iss  <= 1'b0;

        if (rst) begin
            st <= S_IDLE; run_act <= 1'b0; dut_rst <= 1'b1;
            iss <= 1'b0; iss1 <= 1'b0; in_v <= 1'b0; err <= 1'b0;
        end else case (st)
        // ---------------------------------------------------------
        S_IDLE: if (rx_v) begin
            case (rx_d)
            "P": begin
                rkind <= K_PING; rlen <= 6'd10; ridx <= 6'd0; st <= S_REPLY;
            end
            "L": begin lb <= 2'd0; n <= 24'd0; st <= S_LEN; end
            "R": st <= S_GAP;
            "Y": st <= S_SEL;
            "X": begin dbyte <= "X"; after_hdr <= S_XRD; li <= 24'd0; st <= S_HDR; end
            default: begin rkind <= K_BAD; badb <= rx_d; rlen <= 6'd2; ridx <= 6'd0;
                           err <= 1'b1; st <= S_REPLY; end
            endcase
        end
        // ---------------- load ----------------
        S_LEN: if (rx_v) begin
            n  <= {n[15:0], rx_d};
            lb <= lb + 2'd1;
            if (lb == 2'd2) begin
                li <= 24'd0; xsum <= 32'd0;
                if ({n[15:0], rx_d} == 24'd0 || {n[15:0], rx_d} > DEPTH) begin
                    n <= 24'd0; st <= S_LOAD;    // replies K with N=0
                end else st <= S_LOAD;
            end
        end
        S_LOAD: if (li == n) begin
            rkind <= K_LOAD; rlen <= 6'd8; ridx <= 6'd0; st <= S_REPLY;
        end else if (rx_v) begin
            x_we <= 1'b1; x_wa <= li[AW-1:0]; x_wd <= rx_d;
            xsum <= xsum + {24'd0, rx_d};
            li   <= li + 24'd1;
        end
        // ---------------- run ----------------
        S_GAP: if (rx_v) begin
            gap <= rx_d; dut_rst <= 1'b1; run_act <= 1'b0; clr <= 1'b1;
            wcnt <= 8'd0; timeout <= 1'b0;
            tlimit <= {n, 8'd0} + 32'd1024;   // >= n*(gap+1) for any gap; shift, no multiplier
            st <= S_RRST;
        end
        S_RRST: begin                       // hold the DUTs in reset for 8 clocks
            wcnt <= wcnt + 8'd1;
            if (wcnt == 8'd7) begin
                dut_rst <= 1'b0; run_act <= 1'b1; ra <= 0; gcnt <= 8'd0;
                st <= S_RUN;
            end
        end
        S_RUN: begin
            if (ra == n) begin wcnt <= 8'd0; st <= S_DRAIN; end
            else if (gcnt == 8'd0) begin
                x_ra <= ra[AW-1:0]; iss <= 1'b1; ra <= ra + 1'b1; gcnt <= gap;
            end else gcnt <= gcnt - 8'd1;
            if (started && t > tlimit) begin timeout <= 1'b1; wcnt <= 8'd0; st <= S_DRAIN; end
        end
        S_DRAIN: begin
            // wait until every DUT has produced n outputs, then 4 more clocks so the
            // registered capture path (c_* -> y_we/ys) has retired the last sample
            if ((all_out && !iss && !iss1 && !in_v) || (started && t > tlimit) || n == 24'd0) begin
                run_act <= 1'b0;
                wcnt <= wcnt + 8'd1;
                if (wcnt == 8'd4) begin
                    if (!all_out) timeout <= 1'b1;
                    st <= S_HDR; after_hdr <= S_REPLY; dbyte <= "D";
                end
            end
        end
        // ---------------- y dump ----------------
        S_SEL: if (rx_v) begin
            dsel <= (rx_d > 8'd2) ? 2'd2 : rx_d[1:0];
            li <= 24'd0; dbyte <= "Y"; after_hdr <= S_DRD; st <= S_HDR;
        end
        S_DRD: if (li == cnt_sel) st <= S_IDLE;
               else begin y_ra <= li[AW-1:0]; wcnt <= 8'd0; st <= S_DWAIT; end
        S_DWAIT: begin                      // 2-clock read latency (+1 margin)
            wcnt <= wcnt + 8'd1;
            if (wcnt == 8'd2) begin
                dword <= {{(24-OW){yq_sel[OW-1]}}, yq_sel};
                bsel <= 2'd0; st <= S_DTX;
            end
        end
        S_DTX: if (tx_can) begin
            tx_start <= 1'b1;
            tx_data  <= (bsel == 2'd0) ? dword[23:16] : (bsel == 2'd1) ? dword[15:8] : dword[7:0];
            bsel <= bsel + 2'd1;
            if (bsel == 2'd2) begin li <= li + 24'd1; st <= S_DRD; end
        end
        // ---------------- x read-back ----------------
        S_XRD: if (li == n) st <= S_IDLE;
               else begin x_ra <= li[AW-1:0]; wcnt <= 8'd0; st <= S_XWAIT; end
        S_XWAIT: begin
            wcnt <= wcnt + 8'd1;
            if (wcnt == 8'd2) st <= S_XTX;
        end
        S_XTX: if (tx_can) begin
            tx_start <= 1'b1; tx_data <= x_q2; li <= li + 24'd1; st <= S_XRD;
        end
        // ---------------- header byte, then continue ----------------
        S_HDR: if (tx_can) begin
            tx_start <= 1'b1; tx_data <= dbyte;
            if (after_hdr == S_REPLY) begin
                // build the 'R' report now that all counters are final
                // counters are final (run_act=0) and stay frozen until the next 'R'
                rflag <= timeout | ~all_out;
                rkind <= K_RUN; rlen <= 6'd43; ridx <= 6'd0;
                run_ok <= all_out & ~timeout;
            end
            st <= after_hdr;
        end
        // ---------------- generic reply sender ----------------
        S_REPLY: if (tx_can) begin
            tx_start <= 1'b1; tx_data <= rbyte;
            ridx <= ridx + 6'd1;
            if (ridx == rlen - 6'd1) st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end

    // ---------------- LEDs ----------------
    reg [26:0] hb = 27'd0;
    reg [22:0] rx_led = 0, tx_led = 0;
    always @(posedge clk) begin
        hb <= hb + 27'd1;
        rx_led <= rx_v  ? {23{1'b1}} : (rx_led != 0 ? rx_led - 1'b1 : 23'd0);
        tx_led <= tx_start ? {23{1'b1}} : (tx_led != 0 ? tx_led - 1'b1 : 23'd0);
    end
    assign LED[0] = hb[26];
    assign LED[1] = |rx_led;
    assign LED[2] = |tx_led;
    assign LED[3] = run_act;
    assign LED[4] = run_ok;
    assign LED[5] = fast;
    assign LED[6] = locked;
    assign LED[7] = err | timeout;
endmodule
