module divu #(
    parameter DW = 31,
    parameter VW = 24
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [DW-1:0] dividend,
    input  logic [VW-1:0] divisor,
    output logic busy,
    output logic done,
    output logic [DW-1:0] quotient
);
  logic [DW-1:0] q_r, num;
  logic [VW:0] rem;
  logic [6:0] count;

  wire [VW:0] rem_next = {rem[VW-1:0], num[DW-1]};
  wire ge = rem_next >= {1'b0, divisor};

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
    end else if (start && !busy) begin
      busy <= 1'b1;
      num <= dividend;
      q_r <= '0;
      rem <= '0;
      count <= 7'(DW);
    end else if (busy) begin
      rem <= ge ? rem_next - {1'b0, divisor} : rem_next;
      num <= num << 1;
      q_r <= {q_r[DW-2:0], ge};
      count <= count - 7'd1;
      if (count == 7'd1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  assign quotient = q_r;
endmodule
