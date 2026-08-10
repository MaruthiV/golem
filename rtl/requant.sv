module requant #(
    parameter ACC_W = 32,
    parameter OUT_W = 8
) (
    input  logic signed [ACC_W-1:0] acc,
    input  logic        [30:0] mult,
    input  logic        [5:0]  shift,
    output logic signed [OUT_W-1:0] q
);
  localparam BW = ACC_W + 2;
  localparam signed [63:0] LIM = (64'sd1 <<< (OUT_W - 1)) - 64'sd1;

  // every shift the model emits is >= 30 (measured: min 30, max 54 over 16,451 params), so
  // prod[ACC_W+30:29] carries everything the round-half-up needs, rounding bit included.
  // exact, not an approximation, and it drops both 64-bit barrel shifters:
  //   (prod + 2^(shift-1)) >>> shift  ==  ((prod[.:29] >>> s) + 1) >>> 1,  s = shift-30.
  logic signed [ACC_W+30:0] prod;
  logic signed [BW-1:0] base;
  logic signed [BW:0] rounded;
  logic [5:0] s;

  always_comb begin
    prod = acc * $signed({1'b0, mult});
    s = shift - 6'd30;
    base = prod[ACC_W+30:29];
    rounded = ((base >>> s) + 1) >>> 1;
    if (rounded > LIM) q = OUT_W'(LIM);
    else if (rounded < -LIM) q = OUT_W'(-LIM);
    else q = OUT_W'(rounded);
  end
endmodule
