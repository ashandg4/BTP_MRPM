// ============================================================
// 8-tap signed linear-phase FIR, SYMMETRIC-FOLDED
// h = [0,3,20,42,42,20,3,0], symmetric -> pre-add pairs,
// only 4 multipliers (half of the naive 8).
// Pre-add: (d[i]+d[7-i]) is 9-bit signed; multiplier 9x8.
// Output: full precision, 20-bit signed.
// ============================================================
// TASK 2 adder sweep: the FIR-tree adder is selected at compile time.
// Default is han_carlson_adder so existing builds are byte-for-byte unchanged.
// Swap for the sweep with e.g. -D FIR_ADDER=kogge_stone_adder (all four
// variants in adder_variants.v share the han_carlson_adder port list).
`ifndef FIR_ADDER
`define FIR_ADDER han_carlson_adder
`endif
module fir8_fold #(
    parameter IW = 8,
    parameter CW = 8,
    parameter OW = 20
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire signed [IW-1:0] x_in,
    output reg                  out_valid,
    output reg  signed [OW-1:0] y_out
);
    localparam signed [CW-1:0] H0 = 8'sd0;
    localparam signed [CW-1:0] H1 = 8'sd3;
    localparam signed [CW-1:0] H2 = 8'sd20;
    localparam signed [CW-1:0] H3 = 8'sd42;

    reg signed [IW-1:0] d [0:7];
    integer j;

    // symmetric pre-adds: 9-bit signed
    wire signed [IW:0] pa0 = d[0] + d[7];   // * H0
    wire signed [IW:0] pa1 = d[1] + d[6];   // * H1
    wire signed [IW:0] pa2 = d[2] + d[5];   // * H2
    wire signed [IW:0] pa3 = d[3] + d[4];   // * H3

    // only 4 multipliers (9x8 signed)
    wire signed [16:0] m0,m1,m2,m3;   // 9+8=17 bits
    mrpm_radix4_wide #(.AW(9),.BW(8)) M0(.a(pa0),.b(H0),.p(m0));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M1(.a(pa1),.b(H1),.p(m1));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M2(.a(pa2),.b(H2),.p(m2));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M3(.a(pa3),.b(H3),.p(m3));

    wire signed [OW-1:0] p0 = {{(OW-17){m0[16]}}, m0};
    wire signed [OW-1:0] p1 = {{(OW-17){m1[16]}}, m1};
    wire signed [OW-1:0] p2 = {{(OW-17){m2[16]}}, m2};
    wire signed [OW-1:0] p3 = {{(OW-17){m3[16]}}, m3};

    wire signed [OW-1:0] t0,t1,t2;
    `FIR_ADDER #(.WIDTH(OW)) T0(.a(p0),.b(p1),.cin(1'b0),.sum(t0),.cout());
    `FIR_ADDER #(.WIDTH(OW)) T1(.a(p2),.b(p3),.cin(1'b0),.sum(t1),.cout());
    `FIR_ADDER #(.WIDTH(OW)) T2(.a(t0),.b(t1),.cin(1'b0),.sum(t2),.cout());

    always @(posedge clk) begin
        if (rst) begin
            for (j=0;j<8;j=j+1) d[j] <= 0;
            out_valid <= 0; y_out <= 0;
        end else begin
            if (in_valid) begin
                for (j=7;j>0;j=j-1) d[j] <= d[j-1];
                d[0] <= x_in;
            end
            y_out <= t2;
            out_valid <= in_valid;
        end
    end
endmodule
