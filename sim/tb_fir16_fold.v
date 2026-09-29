`timescale 1ns/1ps
// Self-check for the 16-tap symmetric-folded FIR. Same latency model as
// tb_fold.v (L=1): output for input i appears at yq[i+1].
module tb_fir16_fold;
    reg clk=0, rst=1, in_valid=0;
    reg signed [7:0] x;
    wire ov; wire signed [19:0] y;
    integer r, errors, i, fd, nsamp;
    reg [7:0] xa[0:255]; reg [19:0] ya[0:255];
    reg signed [19:0] yq[0:255];
    fir16_fold dut(.clk(clk),.rst(rst),.in_valid(in_valid),.x_in(x),.out_valid(ov),.y_out(y));
    always #5 clk=~clk;
    initial begin
        errors=0; nsamp=0;
        fd=$fopen("fir16_vectors.txt","r");
        if (fd==0) begin $display("ERROR: cannot open fir16_vectors.txt"); $finish; end
        while(!$feof(fd)) begin r=$fscanf(fd,"%h %h\n",xa[nsamp],ya[nsamp]); if(r==2) nsamp=nsamp+1; end
        $fclose(fd);
        @(negedge clk); rst=0;
        for(i=0;i<nsamp;i=i+1) begin @(negedge clk); x=xa[i]; in_valid=1; @(posedge clk); #1; yq[i]=y; end
        in_valid=0;
        for(i=0;i+1<nsamp;i=i+1)
            if(yq[i+1]!==$signed(ya[i])) begin errors=errors+1;
                if(errors<6) $display("FIR16 MISMATCH #%0d got=%0d exp=%0d",i,yq[i+1],$signed(ya[i])); end
        $display("16-TAP FOLDED FIR self-check: %0d mismatches over %0d samples (0=perfect)",errors,nsamp-1);
        $finish;
    end
endmodule
