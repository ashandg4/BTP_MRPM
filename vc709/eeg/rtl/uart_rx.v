`timescale 1ns / 1ps
// ============================================================
// UART receiver, 8N1, LSB first.
// div = clock cycles per bit (runtime input, so the baud rate can be
// switched from a DIP switch without rebuilding).
// The start bit is re-checked at its centre to reject glitches; every
// data bit is sampled at its centre. A bad stop bit drops the byte.
// ============================================================
module uart_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] div,
    input  wire        rxd,        // asynchronous pin
    output reg         valid,      // 1-cycle pulse
    output reg  [7:0]  data
);
    // 2-FF synchroniser (line idles high)
    reg r0 = 1'b1, r1 = 1'b1;
    always @(posedge clk) begin r0 <= rxd; r1 <= r0; end

    localparam IDLE = 2'd0, START = 2'd1, BITS = 2'd2, STOP = 2'd3;
    reg [1:0]  st  = IDLE;
    reg [15:0] cnt = 16'd0;
    reg [2:0]  bi  = 3'd0;
    reg [7:0]  sh  = 8'd0;

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            st <= IDLE; cnt <= 16'd0; bi <= 3'd0;
        end else case (st)
            IDLE: if (!r1) begin st <= START; cnt <= {1'b0, div[15:1]}; end
            START: if (cnt == 16'd0) begin
                       if (!r1) begin st <= BITS; cnt <= div - 16'd1; bi <= 3'd0; end
                       else st <= IDLE;                  // glitch
                   end else cnt <= cnt - 16'd1;
            BITS: if (cnt == 16'd0) begin
                      sh  <= {r1, sh[7:1]};
                      cnt <= div - 16'd1;
                      if (bi == 3'd7) st <= STOP;
                      bi  <= bi + 3'd1;
                  end else cnt <= cnt - 16'd1;
            STOP: if (cnt == 16'd0) begin
                      if (r1) begin valid <= 1'b1; data <= sh; end
                      st <= IDLE;
                  end else cnt <= cnt - 16'd1;
        endcase
    end
endmodule
