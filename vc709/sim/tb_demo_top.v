`timescale 1ns/1ps
// Self-check for the VC709 harness (compile with -DSIM_NO_PRIMS for Icarus).
// Golden file: vc709/sim/demo_golden.txt from gen_sine_rom.py --dip <DIP>.
// Checks every (sample_idx, x_smp) at in_valid_s and every (y_idx, y_out) at
// out_valid against the golden lines, exactly like check_ila_csv.py does on
// the real ILA export.
module tb_demo_top;
    parameter USE_PIPE = 1;
    parameter DIP      = 32;
    parameter NSAMP    = 2048;

    reg clk_p = 0;
    reg rst   = 1;
    wire [7:0] led;
    wire [7:0] dip_w = DIP;

    demo_top #(.USE_PIPE(USE_PIPE)) dut (
        .SYSCLK_P(clk_p), .SYSCLK_N(~clk_p), .CPU_RESET(rst),
        .GPIO_DIP_SW(dip_w), .LED(led));

    always #2.5 clk_p = ~clk_p;   // 200 MHz

    reg [7:0]  gx [0:NSAMP-1];
    reg [19:0] gy [0:NSAMP-1];
    integer fd, r, n, gi, dummy, xerr, yerr, xcnt, ycnt;

    initial begin
        fd = $fopen("demo_golden.txt", "r");
        if (fd == 0) begin $display("ERROR: cannot open demo_golden.txt"); $finish; end
        n = 0;
        while (!$feof(fd) && n < NSAMP) begin
            r = $fscanf(fd, "%d %h %h\n", dummy, gx[n], gy[n]);
            if (r == 3) n = n + 1;
        end
        $fclose(fd);
        if (n != NSAMP) $display("WARNING: golden has %0d lines, expected %0d", n, NSAMP);

        xerr = 0; yerr = 0; xcnt = 0; ycnt = 0;
        repeat (20) @(negedge clk_p);
        rst = 0;
        wait (ycnt == NSAMP);
        $display("DEMO_TOP (USE_PIPE=%0d) self-check: x %0d mismatches / %0d, y %0d mismatches / %0d (0 = bit-exact)",
                 USE_PIPE, xerr, xcnt, yerr, ycnt);
        $finish;
    end

    always @(posedge clk_p) begin
        #1;
        if (dut.in_valid_s && dut.sample_idx < NSAMP) begin
            xcnt = xcnt + 1;
            if (dut.x_smp !== $signed(gx[dut.sample_idx])) begin
                xerr = xerr + 1;
                if (xerr < 6) $display("X MISMATCH idx=%0d got=%0d exp=%0d",
                                       dut.sample_idx, dut.x_smp, $signed(gx[dut.sample_idx]));
            end
        end
        if (dut.out_valid && dut.y_idx < NSAMP) begin
            ycnt = ycnt + 1;
            if (dut.y_out !== $signed(gy[dut.y_idx])) begin
                yerr = yerr + 1;
                if (yerr < 6) $display("Y MISMATCH idx=%0d got=%0d exp=%0d",
                                       dut.y_idx, dut.y_out, $signed(gy[dut.y_idx]));
            end
        end
    end
endmodule
