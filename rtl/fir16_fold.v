// ============================================================
// 16-tap signed linear-phase FIR, SYMMETRIC-FOLDED (TASK 4)
// h = [0,0,-1,-4,-3,7,25,39, 39,25,7,-3,-4,-1,0,0], scale 2^7.
// Symmetric -> pre-add pairs, only 8 multipliers (half of naive 16).
// Pre-add (d[i]+d[15-i]) is 9-bit signed; multiplier 9x8.
// Output: full precision, 20-bit signed (worst-case |acc| < 2^19).
//
// Same structure and latency model as fir8_fold.v (L=1): one output
// register on the d->y_out path. Adder-tree adder is swappable via the
// same `FIR_ADDER macro used by fir8_fold.v.
// ============================================================
`ifndef FIR_ADDER
`define FIR_ADDER han_carlson_adder
`endif
module fir16_fold #(
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
    localparam signed [CW-1:0] H1 = 8'sd0;
    localparam signed [CW-1:0] H2 = -8'sd1;
    localparam signed [CW-1:0] H3 = -8'sd4;
    localparam signed [CW-1:0] H4 = -8'sd3;
    localparam signed [CW-1:0] H5 = 8'sd7;
    localparam signed [CW-1:0] H6 = 8'sd25;
    localparam signed [CW-1:0] H7 = 8'sd39;

    reg signed [IW-1:0] d [0:15];
    integer j;

    // symmetric pre-adds: 9-bit signed
    wire signed [IW:0] pa0 = d[0] + d[15];   // * H0
    wire signed [IW:0] pa1 = d[1] + d[14];   // * H1
    wire signed [IW:0] pa2 = d[2] + d[13];   // * H2
    wire signed [IW:0] pa3 = d[3] + d[12];   // * H3
    wire signed [IW:0] pa4 = d[4] + d[11];   // * H4
    wire signed [IW:0] pa5 = d[5] + d[10];   // * H5
    wire signed [IW:0] pa6 = d[6] + d[9];    // * H6
    wire signed [IW:0] pa7 = d[7] + d[8];    // * H7

    // 8 multipliers (9x8 signed)
    wire signed [16:0] m0,m1,m2,m3,m4,m5,m6,m7;   // 9+8=17 bits
    mrpm_radix4_wide #(.AW(9),.BW(8)) M0(.a(pa0),.b(H0),.p(m0));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M1(.a(pa1),.b(H1),.p(m1));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M2(.a(pa2),.b(H2),.p(m2));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M3(.a(pa3),.b(H3),.p(m3));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M4(.a(pa4),.b(H4),.p(m4));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M5(.a(pa5),.b(H5),.p(m5));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M6(.a(pa6),.b(H6),.p(m6));
    mrpm_radix4_wide #(.AW(9),.BW(8)) M7(.a(pa7),.b(H7),.p(m7));

    // sign-extend products to OW
    wire signed [OW-1:0] p0 = {{(OW-17){m0[16]}}, m0};
    wire signed [OW-1:0] p1 = {{(OW-17){m1[16]}}, m1};
    wire signed [OW-1:0] p2 = {{(OW-17){m2[16]}}, m2};
    wire signed [OW-1:0] p3 = {{(OW-17){m3[16]}}, m3};
    wire signed [OW-1:0] p4 = {{(OW-17){m4[16]}}, m4};
    wire signed [OW-1:0] p5 = {{(OW-17){m5[16]}}, m5};
    wire signed [OW-1:0] p6 = {{(OW-17){m6[16]}}, m6};
    wire signed [OW-1:0] p7 = {{(OW-17){m7[16]}}, m7};

    // 3-level balanced adder tree (8 -> 4 -> 2 -> 1)
    wire signed [OW-1:0] t0,t1,t2,t3;   // level 1
    wire signed [OW-1:0] u0,u1;         // level 2
    wire signed [OW-1:0] v0;            // level 3
    `FIR_ADDER #(.WIDTH(OW)) L0(.a(p0),.b(p1),.cin(1'b0),.sum(t0),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L1(.a(p2),.b(p3),.cin(1'b0),.sum(t1),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L2(.a(p4),.b(p5),.cin(1'b0),.sum(t2),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L3(.a(p6),.b(p7),.cin(1'b0),.sum(t3),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L4(.a(t0),.b(t1),.cin(1'b0),.sum(u0),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L5(.a(t2),.b(t3),.cin(1'b0),.sum(u1),.cout());
    `FIR_ADDER #(.WIDTH(OW)) L6(.a(u0),.b(u1),.cin(1'b0),.sum(v0),.cout());

    always @(posedge clk) begin
        if (rst) begin
            for (j=0;j<16;j=j+1) d[j] <= 0;
            out_valid <= 0; y_out <= 0;
        end else begin
            if (in_valid) begin
                for (j=15;j>0;j=j-1) d[j] <= d[j-1];
                d[0] <= x_in;
            end
            y_out <= v0;
            out_valid <= in_valid;
        end
    end
endmodule
