`timescale 1ns / 1ps
// ============================================================
// Icarus testbench for eeg_hil_top: acts as the PC.
// python/sim_check.py writes
//   tb_cmd.hex  : every byte the PC sends, one hex byte per line
//   tb_meta.txt : one line per transaction "<bytes to send> <reply bytes>"
// The TB sends each transaction over UART_RXD, waits for exactly
// <reply bytes> on UART_TXD, and logs every received byte to tb_rx.hex.
// sim_check.py then parses tb_rx.hex with the SAME parser as the live
// board script and checks all outputs against the bit-exact model.
// ============================================================
module tb_eeg_hil;
    parameter DIV  = 8;                  // clocks per UART bit in simulation
    parameter AW   = 12;                 // RAM depth 2^AW
    localparam MAXB = 400000;

    reg clk = 0;
    always #2.5 clk = ~clk;              // 200 MHz

    reg  rxd = 1'b1;                     // PC -> FPGA
    wire txd;                            // FPGA -> PC
    wire [7:0] led;
    reg  rst_btn = 1'b1;

    eeg_hil_top #(.CLK_HZ(200_000_000), .AW(AW), .SIM_BAUD_DIV(DIV)) dut (
        .SYSCLK_P(clk), .SYSCLK_N(~clk), .CPU_RESET(rst_btn), .GPIO_DIP_SW0(1'b0),
        .UART_RXD(rxd), .UART_TXD(txd), .LED(led));

    reg [7:0] cmd [0:MAXB-1];
    integer fm, fo, r, ntx, nrx, pos, i, k, got, total_rx, ntr;

    task send_byte(input [7:0] b);
        integer j;
        begin
            rxd = 1'b0; repeat (DIV) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rxd = b[j]; repeat (DIV) @(posedge clk); end
            rxd = 1'b1; repeat (DIV) @(posedge clk);
        end
    endtask

    // UART monitor on txd: sample each bit at its centre
    reg [7:0] rb;
    integer   nrecv = 0;
    initial begin : mon
        integer j;
        forever begin
            @(negedge txd);
            repeat (DIV / 2) @(posedge clk);
            if (txd == 1'b0) begin
                for (j = 0; j < 8; j = j + 1) begin repeat (DIV) @(posedge clk); rb[j] = txd; end
                repeat (DIV) @(posedge clk);
                if (txd !== 1'b1) $display("TB: framing error on txd");
                $fwrite(fo, "%02x\n", rb);
                nrecv = nrecv + 1;
            end
        end
    end

    initial begin
        for (i = 0; i < MAXB; i = i + 1) cmd[i] = 8'h00;
        $readmemh("tb_cmd.hex", cmd);
        fo = $fopen("tb_rx.hex", "w");
        fm = $fopen("tb_meta.txt", "r");
        if (fm == 0) begin $display("TB: cannot open tb_meta.txt"); $finish; end
        repeat (20) @(posedge clk);
        rst_btn = 1'b0;
        repeat (20) @(posedge clk);
        pos = 0; total_rx = 0; ntr = 0;
        while (!$feof(fm)) begin
            r = $fscanf(fm, "%d %d\n", ntx, nrx);
            if (r == 2) begin
                for (k = 0; k < ntx; k = k + 1) begin send_byte(cmd[pos]); pos = pos + 1; end
                total_rx = total_rx + nrx;
                got = 0;
                while (nrecv < total_rx && got < 40 * DIV * 10 * (nrx + 10) + 2000000) begin
                    @(posedge clk); got = got + 1;
                end
                if (nrecv < total_rx) begin
                    $display("TB: TIMEOUT in transaction %0d (have %0d of %0d reply bytes)", ntr, nrecv, total_rx);
                    $fclose(fo); $finish;
                end
                ntr = ntr + 1;
            end
        end
        repeat (40 * DIV) @(posedge clk);
        $display("TB: %0d transactions, %0d bytes sent, %0d bytes received, LED=%b", ntr, pos, nrecv, led);
        $fclose(fo);
        $finish;
    end
endmodule
