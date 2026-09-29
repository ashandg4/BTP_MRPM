// ============================================================
// 8-tap signed linear-phase FIR, SYMMETRIC-FOLDED + PIPELINED
// Functionally identical to fir8_fold.v (same 0-mismatch output),
// but pipelined to raise Fmax (TASK 1).
//
// Pipeline register boundaries (x_in -> y_out):
//   (0) delay line d[]                         [exists in fir8_fold]
//   (R1) inside multiplier: Booth-PP -> accum  [mrpm_radix4_wide_pipe]
//   (R2) after multipliers (products)          [new]
//   (R3) after first adder-tree level (t0,t1)  [new]
//   (R4) output y_out                          [exists in fir8_fold]
//
// Registers on the d->y_out path: R1,R2,R3,R4 = 4 -> latency L=4
// (fir8_fold had only R4 -> L=1). The self-check testbench compares
// yq[i+L] against golden ya[i].
// ============================================================
module fir8_fold_pipelined #(
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

    // symmetric pre-adds: 9-bit signed (combinational from delay line)
    wire signed [IW:0] pa0 = d[0] + d[7];   // * H0
    wire signed [IW:0] pa1 = d[1] + d[6];   // * H1
    wire signed [IW:0] pa2 = d[2] + d[5];   // * H2
    wire signed [IW:0] pa3 = d[3] + d[4];   // * H3

    // 4 pipelined multipliers (9x8 signed). Each carries R1 internally.
    wire signed [16:0] m0,m1,m2,m3;   // 9+8=17 bits
    mrpm_radix4_wide_pipe #(.AW(9),.BW(8)) M0(.clk(clk),.a(pa0),.b(H0),.p(m0));
    mrpm_radix4_wide_pipe #(.AW(9),.BW(8)) M1(.clk(clk),.a(pa1),.b(H1),.p(m1));
    mrpm_radix4_wide_pipe #(.AW(9),.BW(8)) M2(.clk(clk),.a(pa2),.b(H2),.p(m2));
    mrpm_radix4_wide_pipe #(.AW(9),.BW(8)) M3(.clk(clk),.a(pa3),.b(H3),.p(m3));

    // sign-extend products to OW (combinational from mult outputs)
    wire signed [OW-1:0] p0 = {{(OW-17){m0[16]}}, m0};
    wire signed [OW-1:0] p1 = {{(OW-17){m1[16]}}, m1};
    wire signed [OW-1:0] p2 = {{(OW-17){m2[16]}}, m2};
    wire signed [OW-1:0] p3 = {{(OW-17){m3[16]}}, m3};

    // ---- R2: register products (after multipliers) ----
    reg signed [OW-1:0] p0_r, p1_r, p2_r, p3_r;

    // first adder-tree level (combinational from registered products)
    wire signed [OW-1:0] t0, t1;
    han_carlson_adder #(.WIDTH(OW)) T0(.a(p0_r),.b(p1_r),.cin(1'b0),.sum(t0),.cout());
    han_carlson_adder #(.WIDTH(OW)) T1(.a(p2_r),.b(p3_r),.cin(1'b0),.sum(t1),.cout());

    // ---- R3: register first adder-tree level ----
    reg signed [OW-1:0] t0_r, t1_r;

    // second adder-tree level (combinational)
    wire signed [OW-1:0] t2;
    han_carlson_adder #(.WIDTH(OW)) T2(.a(t0_r),.b(t1_r),.cin(1'b0),.sum(t2),.cout());

    // valid pipeline: in_valid delayed by the 4 datapath register stages
    reg [3:0] vpipe;

    always @(posedge clk) begin
        if (rst) begin
            for (j=0;j<8;j=j+1) d[j] <= 0;
            p0_r <= 0; p1_r <= 0; p2_r <= 0; p3_r <= 0;
            t0_r <= 0; t1_r <= 0;
            vpipe <= 4'b0;
            out_valid <= 0; y_out <= 0;
        end else begin
            // stage 0: delay line
            if (in_valid) begin
                for (j=7;j>0;j=j-1) d[j] <= d[j-1];
                d[0] <= x_in;
            end
            // R2: latch products
            p0_r <= p0; p1_r <= p1; p2_r <= p2; p3_r <= p3;
            // R3: latch first adder level
            t0_r <= t0; t1_r <= t1;
            // R4: output
            y_out <= t2;
            // valid shift (matches the 4-stage datapath latency)
            vpipe <= {vpipe[2:0], in_valid};
            out_valid <= vpipe[3];
        end
    end
endmodule
