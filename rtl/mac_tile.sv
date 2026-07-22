module mac_tile (
    input  logic clk,
    input  logic rst,

    input  logic       clr,
    input  logic       en,
    input  logic signed [7:0] x0, x1, x2, x3,
    input  logic signed [7:0] w0, w1, w2, w3,

    input  logic        emit,
    input  logic [30:0] mult,
    input  logic [5:0]  shift,
    output logic signed [31:0] acc,
    output logic signed [7:0]  q
);
  logic signed [16:0] s01, s23;
  logic signed [17:0] sum4;
  assign s01 = x0 * w0 + x1 * w1;
  assign s23 = x2 * w2 + x3 * w3;
  assign sum4 = s01 + s23;

  always_ff @(posedge clk) begin
    if (rst || clr) acc <= 32'sd0;
    else if (en) acc <= acc + 32'(sum4);
  end

  requant rq (.acc(acc), .mult(mult), .shift(shift), .q(q));
endmodule
