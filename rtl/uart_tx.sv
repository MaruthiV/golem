// 8N1 UART transmitter. CLKS_PER_BIT = clk_freq / baud (27e6/115200 = 234 on the board).
module uart_tx #(parameter CLKS_PER_BIT = 234) (
    input  logic       clk,
    input  logic       rst,
    input  logic       send,
    input  logic [7:0] data,
    output logic       tx,
    output logic       busy
);
  localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
  logic [1:0]  st;
  logic [15:0] clkcnt;
  logic [2:0]  bitidx;
  logic [7:0]  shift;
  wire last = (clkcnt == CLKS_PER_BIT - 1);

  always_ff @(posedge clk) begin
    if (rst) begin st <= IDLE; tx <= 1'b1; busy <= 1'b0; end
    else case (st)
      IDLE: begin
        tx <= 1'b1; busy <= 1'b0;
        if (send) begin shift <= data; busy <= 1'b1; clkcnt <= 0; st <= START; end
      end
      START: begin
        tx <= 1'b0;
        if (last) begin clkcnt <= 0; bitidx <= 0; st <= DATA; end else clkcnt <= clkcnt + 1;
      end
      DATA: begin
        tx <= shift[bitidx];
        if (last) begin
          clkcnt <= 0;
          if (bitidx == 3'd7) st <= STOP; else bitidx <= bitidx + 1;
        end else clkcnt <= clkcnt + 1;
      end
      STOP: begin
        tx <= 1'b1;
        if (last) begin busy <= 1'b0; st <= IDLE; end else clkcnt <= clkcnt + 1;
      end
    endcase
  end
endmodule
