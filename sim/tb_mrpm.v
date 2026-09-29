`timescale 1ns/1ps
module tb_mrpm;
    reg signed [7:0] a, b;
    wire signed [15:0] p;
    integer ia, ib, errors;
    mrpm_radix4 #(.W(8)) dut (.a(a), .b(b), .p(p));
    initial begin
        errors = 0;
        for (ia = -128; ia < 128; ia = ia + 1) begin
            for (ib = -128; ib < 128; ib = ib + 1) begin
                a = ia[7:0]; b = ib[7:0];
                #1;
                if (p !== (ia*ib)) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH a=%0d b=%0d got=%0d exp=%0d", ia, ib, p, ia*ib);
                end
            end
        end
        $display("EXHAUSTIVE signed 8x8: %0d mismatches (0=perfect)", errors);
        $finish;
    end
endmodule
