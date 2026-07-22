module softmax_row (
    input  logic clk,
    input  logic rst,

    input  logic       start,
    input  logic [8:0] cfg_len,
    input  logic [30:0] cfg_mult,
    input  logic [5:0]  cfg_shift,
    output logic       busy,

    input  logic               s_we,
    input  logic [7:0]         s_addr,
    input  logic signed [31:0] s_data,

    input  logic        lut_we,
    input  logic [8:0]  lut_addr,
    input  logic [16:0] lut_data,

    output logic        out_valid,
    output logic [7:0]  out_idx,
    output logic [16:0] out_data
);
  localparam IDLE = 3'd0, MAX = 3'd1, EXP = 3'd2, PDIV = 3'd3, PDIVW = 3'd4;

  logic [2:0] state;
  logic signed [31:0] sbuf [0:255];
  logic [16:0] ebuf [0:255];
  logic [16:0] lut [0:511];
  logic [8:0] len;
  logic [8:0] idx;
  logic signed [31:0] row_max;
  logic [23:0] denom;

  wire signed [32:0] diff = row_max - sbuf[idx[7:0]];
  logic [63:0] scaled;
  logic [8:0] lut_idx;
  always_comb begin
    scaled = (64'(diff) * 64'({33'b0, cfg_mult}) + (64'd1 << (cfg_shift - 6'd1))) >> cfg_shift;
    lut_idx = (scaled > 64'd511) ? 9'd511 : scaled[8:0];
  end

  logic div_start, div_busy, div_done;
  logic [31:0] div_q;
  divu #(.DW(32), .VW(24)) p_div (
      .clk(clk), .rst(rst), .start(div_start),
      .dividend({ebuf[idx[7:0]], 15'b0}),
      .divisor(denom),
      .busy(div_busy), .done(div_done), .quotient(div_q)
  );

  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    out_valid <= 1'b0;
    div_start <= 1'b0;
    if (s_we) sbuf[s_addr] <= s_data;
    if (lut_we) lut[lut_addr] <= lut_data;
    if (rst) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          len <= cfg_len;
          idx <= 9'd0;
          row_max <= 32'sh80000000;
          state <= MAX;
        end
        MAX: begin
          if (sbuf[idx[7:0]] > row_max) row_max <= sbuf[idx[7:0]];
          idx <= idx + 9'd1;
          if (idx == len - 9'd1) begin
            idx <= 9'd0;
            denom <= 24'd0;
            state <= EXP;
          end
        end
        EXP: begin
          ebuf[idx[7:0]] <= lut[lut_idx];
          denom <= denom + {7'd0, lut[lut_idx]};
          idx <= idx + 9'd1;
          if (idx == len - 9'd1) begin
            idx <= 9'd0;
            state <= PDIV;
          end
        end
        PDIV: begin
          div_start <= 1'b1;
          state <= PDIVW;
        end
        PDIVW: if (div_done) begin
          out_valid <= 1'b1;
          out_idx <= idx[7:0];
          out_data <= div_q[16:0];
          idx <= idx + 9'd1;
          if (idx == len - 9'd1) state <= IDLE;
          else state <= PDIV;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
