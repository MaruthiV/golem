module requant #(
    parameter OUT_W = 8
) (
    input  logic signed [31:0] acc,
    input  logic        [30:0] mult,
    input  logic        [5:0]  shift,
    output logic signed [OUT_W-1:0] q
);
  localparam signed [63:0] LIM = (64'sd1 << (OUT_W - 1)) - 64'sd1;

  logic signed [63:0] prod;
  logic signed [63:0] rounded;

  always_comb begin
    prod = acc * $signed({1'b0, mult});
    rounded = (prod + (64'sd1 <<< (shift - 6'd1))) >>> shift;
    if (rounded > LIM) q = OUT_W'(LIM);
    else if (rounded < -LIM) q = OUT_W'(-LIM);
    else q = rounded[OUT_W-1:0];
  end
endmodule
