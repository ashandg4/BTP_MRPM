`timescale 1ns / 1ps
// Stimulus for the activity-annotated (SAIF) power estimate: streams the
// quantised EEG record into ONE post-route FIR netlist at 200 MHz, one
// sample per clock - the same stream the board sees in hil_run.py (gap 0).
// Compiled by vc709/eeg/tcl/power_saif.tcl with
//   -d DUT=<fir module> -d NSAMP=<n>   (stimulus file: stim.hex in the run dir)
module tb_power;
    reg clk = 1'b0;
    always #2.5 clk = ~clk;                  // 200 MHz
    reg              rst = 1'b1, v = 1'b0;
    reg  signed [7:0] x  = 8'sd0;
    wire              ov;
    wire signed [19:0] y;
    reg  [7:0] mem [0:`NSAMP-1];
    integer i;

    `DUT dut (.clk(clk), .rst(rst), .in_valid(v), .x_in(x), .out_valid(ov), .y_out(y));

    initial begin
        $readmemh("stim.hex", mem);   // copied next to the snapshot by power_saif.tcl
        repeat (20) @(posedge clk);
        rst <= 1'b0;
        repeat (20) @(posedge clk);          // SAIF logging starts at 200 ns (see power_saif.tcl)
        for (i = 0; i < `NSAMP; i = i + 1) begin
            @(posedge clk); v <= 1'b1; x <= mem[i];
        end
        @(posedge clk); v <= 1'b0;
        repeat (10) @(posedge clk);
        $finish;
    end
endmodule
