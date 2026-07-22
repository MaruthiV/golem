module gelu_lut (
    input  logic clk,

    input  logic              lut_we,
    input  logic [7:0]        lut_addr,
    input  logic signed [7:0] lut_data,

    input  logic signed [7:0] x,
    output logic signed [7:0] y
);
  logic signed [7:0] lut [0:255];

  always_ff @(posedge clk) begin
    if (lut_we) lut[lut_addr] <= lut_data;
  end

  wire [7:0] idx = 8'(x + 8'sd127);
  assign y = lut[idx];
endmodule
