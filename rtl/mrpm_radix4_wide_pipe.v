// ============================================================
// Pipelined signed radix-4 (modified Booth) MRPM, parameterized.
// Identical function to mrpm_radix4_wide.v but with ONE pipeline
// register stage inserted between Booth partial-product generation
// and the final Han-Carlson accumulation tree (TASK 1 requirement).
//
// Latency: 1 clock (pp register). Product p is combinational from
// the registered partial products, so a downstream stage can also
// register p ("after multipliers" boundary in fir8_fold_pipelined).
//
// NOTE: like mrpm_radix4_wide.v the accumulator hardcodes 4 partial
// products (valid for BW=8 -> BWE/2=4). Same assumption, same result.
// ============================================================
module mrpm_radix4_wide_pipe #(
    parameter AW = 9,
    parameter BW = 8
)(
    input  wire                     clk,
    input  wire signed [AW-1:0]     a,   // multiplicand (pre-added samples)
    input  wire signed [BW-1:0]     b,   // multiplier (coefficient)
    output wire signed [AW+BW-1:0]  p
);
    localparam PW = AW+BW;

    wire signed [PW-1:0] a_ext = {{BW{a[AW-1]}}, a};
    // multiplier b, radix-4 Booth needs BW even; pad if odd
    localparam BWE = (BW % 2 == 0) ? BW : BW+1;
    wire signed [BWE-1:0] b_ext = {{(BWE-BW){b[BW-1]}}, b};
    wire [BWE:0] bm = {b_ext, 1'b0};

    wire signed [PW-1:0] pp [0:BWE/2-1];
    genvar k;
    generate
      for (k = 0; k < BWE/2; k = k + 1) begin : booth
        wire b_2kp1 = bm[2*k+2];
        wire b_2k   = bm[2*k+1];
        wire b_2km1 = bm[2*k];
        wire neg = b_2kp1;
        wire two = (b_2kp1 & ~b_2k & ~b_2km1) | (~b_2kp1 & b_2k & b_2km1);
        wire one = b_2k ^ b_2km1;
        wire signed [PW-1:0] a1 = one ? a_ext : {PW{1'b0}};
        wire signed [PW-1:0] a2 = two ? (a_ext <<< 1) : {PW{1'b0}};
        wire signed [PW-1:0] mag = a1 | a2;
        wire signed [PW-1:0] sval = neg ? (~mag + 1'b1) : mag;
        assign pp[k] = sval <<< (2*k);
      end
    endgenerate

    // ---- PIPELINE REGISTER: Booth-PP generation -> accumulation ----
    reg signed [PW-1:0] pp_r [0:BWE/2-1];
    integer kk;
    always @(posedge clk) begin
        for (kk = 0; kk < BWE/2; kk = kk + 1)
            pp_r[kk] <= pp[kk];
    end

    // sum all partial products with a Han-Carlson adder tree (BW=8 -> 4 pps)
    wire signed [PW-1:0] s0, s1;
    han_carlson_adder #(.WIDTH(PW)) A0(.a(pp_r[0]),.b(pp_r[1]),.cin(1'b0),.sum(s0),.cout());
    han_carlson_adder #(.WIDTH(PW)) A1(.a(pp_r[2]),.b(pp_r[3]),.cin(1'b0),.sum(s1),.cout());
    han_carlson_adder #(.WIDTH(PW)) A2(.a(s0),.b(s1),.cin(1'b0),.sum(p),.cout());
endmodule
