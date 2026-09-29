`timescale 1ns / 1ps
// ============================================================
// UART transmitter, 8N1, LSB first.
// Handshake: the byte is accepted on a clock edge where start=1 and
// ready=1; ready drops on the next cycle and returns high only after
// the stop bit has been sent.
// ============================================================
module uart_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] div,
    input  wire        start,
    input  wire [7:0]  data,
    output wire        ready,
    output reg         txd = 1'b1
);
    reg        busy = 1'b0;
    reg [15:0] cnt  = 16'd0;
    reg [3:0]  bi   = 4'd0;
    reg [9:0]  sh   = 10'h3FF;     // {stop, data[7:0], start}
    assign ready = ~busy;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; txd <= 1'b1; cnt <= 16'd0; bi <= 4'd0;
        end else if (!busy) begin
            txd <= 1'b1;
            if (start) begin
                sh   <= {1'b1, data, 1'b0};
                busy <= 1'b1; cnt <= 16'd0; bi <= 4'd0;
            end
        end else if (cnt == 16'd0) begin
            if (bi == 4'd10) busy <= 1'b0;      // stop bit finished
            else begin
                txd <= sh[0];
                sh  <= {1'b1, sh[9:1]};
                bi  <= bi + 4'd1;
                cnt <= div - 16'd1;
            end
        end else cnt <= cnt - 16'd1;
    end
endmodule
