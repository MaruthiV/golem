// 8N1 UART receiver. Samples at the middle of each bit; emits data + a 1-cycle valid.
module uart_rx #(parameter CLKS_PER_BIT = 234) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid
);
  localparam IDLE=2'd0, START=2'd1, DATA=2'd2, STOP=2'd3;
  logic [1:0]  st;
  logic [15:0] cnt;
  logic [2:0]  idx;
  logic [7:0]  sh;
  logic        r0, r1;   // 2-FF synchronizer

  always_ff @(posedge clk) begin
    r0 <= rx; r1 <= r0;
    valid <= 1'b0;
    if (rst) begin st <= IDLE; end
    else case (st)
      IDLE:  if (!r1) begin cnt <= (CLKS_PER_BIT/2); st <= START; end
      START: if (cnt == 0) begin
               if (!r1) begin cnt <= CLKS_PER_BIT - 1; idx <= 0; st <= DATA; end
               else st <= IDLE;   // false start
             end else cnt <= cnt - 16'd1;
      DATA:  if (cnt == 0) begin
               sh[idx] <= r1; cnt <= CLKS_PER_BIT - 1;
               if (idx == 3'd7) st <= STOP; else idx <= idx + 3'd1;
             end else cnt <= cnt - 16'd1;
      STOP:  if (cnt == 0) begin data <= sh; valid <= 1'b1; st <= IDLE; end
             else cnt <= cnt - 16'd1;
    endcase
  end
endmodule
