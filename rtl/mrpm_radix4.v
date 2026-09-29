// ============================================================
// Signed 8-bit radix-4 (modified Booth) MRPM
// - 4 unrolled radix-4 stages (2 multiplier bits / stage)
// - every partial-product accumulation uses Han-Carlson adder
// - combinational (single-cycle) core; pipeline wrapper separate
// Product: signed 16-bit  (8x8)
// ============================================================
module mrpm_radix4 #(
    parameter W = 8
)(
    input  wire signed [W-1:0]   a,   // multiplicand
    input  wire signed [W-1:0]   b,   // multiplier
    output wire signed [2*W-1:0] p
);
    localparam PW = 2*W; // 16

    // sign-extend multiplicand to product width
    wire signed [PW-1:0] a_ext = {{W{a[W-1]}}, a};

    // multiplier bits with implicit b[-1]=0
    wire [W:0] bm = {b, 1'b0};   // bm[0] is the phantom -1 bit

    // ---- generate the 4 Booth partial products ----
    // digit_k from (b[2k+1], b[2k], b[2k-1]) -> value in {-2,-1,0,1,2}
    // pp_k = a_ext * digit_k, shifted left by 2k
    wire signed [PW-1:0] pp [0:W/2-1];

    genvar k;
    generate
      for (k = 0; k < W/2; k = k + 1) begin : booth
        wire b_2kp1 = bm[2*k+2];
        wire b_2k   = bm[2*k+1];
        wire b_2km1 = bm[2*k];
        // Booth recode
        wire neg    =  b_2kp1;
        wire two    =  (b_2kp1 & ~b_2k & ~b_2km1) | (~b_2kp1 & b_2k & b_2km1);
        wire one    =  b_2k ^ b_2km1;
        // base value: one*A + two*2A  (then negate if neg)
        wire signed [PW-1:0] a1 = one ? a_ext : {PW{1'b0}};
        wire signed [PW-1:0] a2 = two ? (a_ext <<< 1) : {PW{1'b0}};
        wire signed [PW-1:0] mag = a1 | a2; // one and two are mutually exclusive
        wire signed [PW-1:0] signed_val = neg ? (~mag + 1'b1) : mag;
        assign pp[k] = signed_val <<< (2*k);
      end
    endgenerate

    // ---- accumulate the 4 partial products with Han-Carlson adders ----
    wire signed [PW-1:0] s01, s23, total;
    wire c0, c1, c2;
    han_carlson_adder #(.WIDTH(PW)) A0 (.a(pp[0]), .b(pp[1]), .cin(1'b0), .sum(s01), .cout(c0));
    han_carlson_adder #(.WIDTH(PW)) A1 (.a(pp[2]), .b(pp[3]), .cin(1'b0), .sum(s23), .cout(c1));
    han_carlson_adder #(.WIDTH(PW)) A2 (.a(s01),   .b(s23),   .cin(1'b0), .sum(total), .cout(c2));

    assign p = total;
endmodule
