`timescale 1ns / 1ps
// ============================================================
// VC709 hardware harness for the folded 8-tap MRPM FIR.
//
//   200 MHz SYSCLK -> (optional MMCM) -> clk
//   Two NCO tones (sine ROM) -> x_smp, one sample every SAMPLE_DIV clocks
//   x_smp -> fir8_fold / fir8_fold_pipelined (unchanged thesis RTL) -> y_out
//   ILA probes x/y/valids/indices; CSV export is diffed against the
//   bit-exact Python model in vc709/python/demo_model.py.
//
// Tone A: fixed, fs/64.       Tone B: GPIO_DIP_SW * fs/512  (sweep knob)
// x_smp = (sinA>>>1) + (sinB>>>1), always fits in 8-bit signed.
//
// Determinism: after CPU_RESET, sample n has phase n*inc (mod 2^16) and
// sample_idx == n, so the model needs no clock-level alignment.
// SAMPLE_DIV must be >= 6 (pipelined FIR latency is 4 clocks).
// ============================================================
module demo_top #(
    parameter USE_PIPE   = 1,        // 1: fir8_fold_pipelined, 0: fir8_fold
    parameter USE_MMCM   = 0,        // 1: clk = 200 MHz * 5 / MMCM_DIV
    parameter MMCM_DIV   = 10,       // 10 -> 100 MHz, 5 -> 200 MHz
    parameter SAMPLE_DIV = 8,        // fs = clk / SAMPLE_DIV
    parameter [15:0] INC_A = 16'd1024 // tone A phase increment (fs/64)
)(
    input  wire       SYSCLK_P,
    input  wire       SYSCLK_N,
    input  wire       CPU_RESET,     // active-high push button
    input  wire [7:0] GPIO_DIP_SW,
    output wire [7:0] LED
);
    // ---------------- clocking ----------------
    wire clk;
    wire locked;
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
            .CLKFBOUT_MULT_F (5.0),        // VCO = 1000 MHz
            .CLKOUT0_DIVIDE_F(MMCM_DIV),
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

    // ---------------- async input sync ----------------
    reg [1:0] rst_sync = 2'b00;
    reg [7:0] dip_s0 = 8'd0, dip = 8'd0;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], CPU_RESET};
        dip_s0   <= GPIO_DIP_SW;
        dip      <= dip_s0;
    end
    wire rst = rst_sync[1] | ~locked;

    // ---------------- sample tick ----------------
    reg [15:0] divcnt = 16'd0;
    reg        tick   = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            divcnt <= 16'd0; tick <= 1'b0;
        end else if (divcnt == SAMPLE_DIV - 1) begin
            divcnt <= 16'd0; tick <= 1'b1;
        end else begin
            divcnt <= divcnt + 16'd1; tick <= 1'b0;
        end
    end

    // ---------------- two-tone NCO ----------------
    reg  [15:0] ph_a = 16'd0, ph_b = 16'd0;
    wire [15:0] inc_b = {dip, 7'b0};
    always @(posedge clk) begin
        if (rst) begin
            ph_a <= 16'd0; ph_b <= 16'd0;
        end else if (tick) begin
            ph_a <= ph_a + INC_A;
            ph_b <= ph_b + inc_b;
        end
    end

    wire signed [7:0] sin_a, sin_b;
    sine_rom u_rom_a (.clk(clk), .addr(ph_a[15:8]), .q(sin_a));
    sine_rom u_rom_b (.clk(clk), .addr(ph_b[15:8]), .q(sin_b));

    reg signed [7:0]  x_smp      = 8'd0;
    reg               in_valid_s = 1'b0;
    reg        [15:0] sample_idx = 16'd0;
    always @(posedge clk) begin
        if (rst) begin
            x_smp <= 8'd0; in_valid_s <= 1'b0; sample_idx <= 16'd0;
        end else begin
            in_valid_s <= tick;
            if (tick)       x_smp      <= (sin_a >>> 1) + (sin_b >>> 1);
            if (in_valid_s) sample_idx <= sample_idx + 16'd1;
        end
    end

    // ---------------- DUT ----------------
    wire signed [19:0] y_out;
    wire               out_valid;
    generate if (USE_PIPE) begin : g_pipe
        fir8_fold_pipelined u_fir (.clk(clk), .rst(rst), .in_valid(in_valid_s),
            .x_in(x_smp), .out_valid(out_valid), .y_out(y_out));
    end else begin : g_fold
        fir8_fold u_fir (.clk(clk), .rst(rst), .in_valid(in_valid_s),
            .x_in(x_smp), .out_valid(out_valid), .y_out(y_out));
    end endgenerate

    // Index of the sample that y_out belongs to while out_valid is high.
    // fir8_fold emits y[n-1] on the clock after x[n] enters; pipelined emits y[n].
    wire [15:0] y_idx = sample_idx - (USE_PIPE ? 16'd1 : 16'd2);

    // ---------------- debug ----------------
`ifdef USE_ILA
    ila_0 u_ila (
        .clk(clk),
        .probe0(x_smp), .probe1(in_valid_s), .probe2(y_out), .probe3(out_valid),
        .probe4(sample_idx), .probe5(y_idx), .probe6(dip));
`endif

    // ---------------- LEDs ----------------
    reg [26:0] hb = 27'd0;
    always @(posedge clk) hb <= hb + 27'd1;
    assign LED[0]   = hb[26];
    assign LED[1]   = rst;
    assign LED[2]   = USE_PIPE;
    assign LED[3]   = locked;
    assign LED[7:4] = dip[3:0];
endmodule
