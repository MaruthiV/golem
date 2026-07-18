module requant (
    input  logic signed [31:0] acc,
    input  logic        [30:0] mult,
    input  logic        [5:0]  shift,
    output logic signed [7:0]  q
);
  logic signed [63:0] prod;
  logic signed [63:0] rounded;

  always_comb begin
    prod = acc * $signed({1'b0, mult});
    rounded = (prod + (64'sd1 <<< (shift - 6'd1))) >>> shift;
    if (rounded > 64'sd127) q = 8'sd127;
    else if (rounded < -64'sd127) q = -8'sd127;
    else q = rounded[7:0];
  end
endmodule
