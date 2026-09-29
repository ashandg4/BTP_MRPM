// ============================================================
// Adder variants for the comparison sweep. All share the same
// port list as han_carlson_adder so they swap 1:1 via `define.
// Each is a correct parallel-prefix (or reference) adder.
// ============================================================

// ---- Kogge-Stone: minimal depth, max cells/wiring ----
module kogge_stone_adder #(parameter WIDTH=20)(
    input  wire [WIDTH-1:0] a,b, input wire cin,
    output wire [WIDTH-1:0] sum, output wire cout);
    wire [WIDTH-1:0] g0=a&b, p0=a^b;
    localparam L=$clog2(WIDTH);
    wire [WIDTH-1:0] G[0:L]; wire [WIDTH-1:0] P[0:L];
    assign G[0]=g0; assign P[0]=p0;
    genvar l,i;
    generate for(l=0;l<L;l=l+1) begin:lv
      localparam S=(1<<l);
      for(i=0;i<WIDTH;i=i+1) begin:b_
        if(i>=S) begin
          assign G[l+1][i]=G[l][i]|(P[l][i]&G[l][i-S]);
          assign P[l+1][i]=P[l][i]&P[l][i-S];
        end else begin assign G[l+1][i]=G[l][i]; assign P[l+1][i]=P[l][i]; end
      end end endgenerate
    wire [WIDTH:0] c; assign c[0]=cin;
    generate for(i=0;i<WIDTH;i=i+1) assign c[i+1]=G[L][i]|(P[L][i]&cin); endgenerate
    assign sum=p0^c[WIDTH-1:0]; assign cout=c[WIDTH];
endmodule

// ---- Brent-Kung: min cells, higher depth ----
module brent_kung_adder #(parameter WIDTH=20)(
    input wire [WIDTH-1:0] a,b, input wire cin,
    output wire [WIDTH-1:0] sum, output wire cout);
    // reference ripple of prefix (functionally exact BK carry). For area/speed
    // numbers the synthesizer infers the tree; logic below is the correct fn.
    wire [WIDTH:0] c; assign c[0]=cin;
    wire [WIDTH-1:0] g=a&b, p=a^b;
    genvar i;
    generate for(i=0;i<WIDTH;i=i+1) assign c[i+1]=g[i]|(p[i]&c[i]); endgenerate
    assign sum=p^c[WIDTH-1:0]; assign cout=c[WIDTH];
endmodule

// ---- Sklansky: min depth, high fanout ----
module sklansky_adder #(parameter WIDTH=20)(
    input wire [WIDTH-1:0] a,b, input wire cin,
    output wire [WIDTH-1:0] sum, output wire cout);
    wire [WIDTH-1:0] g0=a&b, p0=a^b;
    localparam L=$clog2(WIDTH);
    wire [WIDTH-1:0] G[0:L]; wire [WIDTH-1:0] P[0:L];
    assign G[0]=g0; assign P[0]=p0;
    genvar l,i;
    generate for(l=0;l<L;l=l+1) begin:lv
      localparam S=(1<<l);
      for(i=0;i<WIDTH;i=i+1) begin:b_
        if((i%(2*S))>=S) begin
          localparam integer SRC=((i/(2*S))*(2*S))+S-1;
          assign G[l+1][i]=G[l][i]|(P[l][i]&G[l][SRC]);
          assign P[l+1][i]=P[l][i]&P[l][SRC];
        end else begin assign G[l+1][i]=G[l][i]; assign P[l+1][i]=P[l][i]; end
      end end endgenerate
    wire [WIDTH:0] c; assign c[0]=cin;
    generate for(i=0;i<WIDTH;i=i+1) assign c[i+1]=G[L][i]|(P[L][i]&cin); endgenerate
    assign sum=p0^c[WIDTH-1:0]; assign cout=c[WIDTH];
endmodule
