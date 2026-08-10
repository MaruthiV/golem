// All three arrays here (sbuf 256x32, ebuf 256x17, lut 512x17 = ~21 Kbit) used ASYNC reads,
// which infer distributed LUTRAM plus a read mux per bit — a 256:1 mux is ~85 LUT4 per bit, and
// the 512-deep lut is worse. T45 P&R showed that class of mux tree is what blows the LUT4 budget.
// Registering every read maps them to BSRAM instead. The scan phases each gain a cycle per
// element (MAX 2/elem, EXP 3/elem, +1 before each divide) — a few % of a token, and the divides
// already dominate this engine — in exchange for the fabric it frees.
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
  localparam IDLE = 4'd0, MAXA = 4'd1, MAXB = 4'd2, EXPA = 4'd3, EXPB = 4'd4, EXPC = 4'd5,
             PDIVR = 4'd6, PDIV = 4'd7, PDIVW = 4'd8;

  logic [3:0] state;
  logic signed [31:0] sbuf [0:255];
  logic [16:0] ebuf [0:255];
  logic [16:0] lut [0:511];
  logic [8:0] len;
  logic [8:0] idx;
  logic signed [31:0] row_max;
  logic [23:0] denom;

  // registered reads -> BSRAM
  logic signed [31:0] s_q;
  logic [16:0] lut_q, e_q;
  // eb_we is registered, so it lands a cycle after EXPC — by then idx has advanced, so the
  // write address has to be latched alongside the data
  logic        eb_we;
  logic [7:0]  eb_waddr;
  logic [16:0] eb_wdata;

  wire signed [32:0] diff = row_max - s_q;
  logic [63:0] scaled;
  logic [8:0] lut_idx;
  always_comb begin
    scaled = (64'(diff) * 64'({33'b0, cfg_mult}) + (64'd1 << (cfg_shift - 6'd1))) >> cfg_shift;
    lut_idx = (scaled > 64'd511) ? 9'd511 : scaled[8:0];
  end

  always_ff @(posedge clk) begin
    if (s_we) sbuf[s_addr] <= s_data;
    s_q <= sbuf[idx[7:0]];
  end
  always_ff @(posedge clk) begin
    if (lut_we) lut[lut_addr] <= lut_data;
    lut_q <= lut[lut_idx];
  end
  always_ff @(posedge clk) begin
    if (eb_we) ebuf[eb_waddr] <= eb_wdata;
    e_q <= ebuf[idx[7:0]];
  end

  logic div_start, div_busy, div_done;
  logic [31:0] div_q;
  divu #(.DW(32), .VW(24)) p_div (
      .clk(clk), .rst(rst), .start(div_start),
      .dividend({e_q, 15'b0}),
      .divisor(denom),
      .busy(div_busy), .done(div_done), .quotient(div_q)
  );

  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    out_valid <= 1'b0;
    div_start <= 1'b0;
    eb_we <= 1'b0;
    if (rst) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          len <= cfg_len;
          idx <= 9'd0;
          row_max <= 32'sh80000000;
          state <= MAXA;
        end
        // MAXA presents sbuf[idx]; s_q holds it in MAXB
        MAXA: state <= MAXB;
        MAXB: begin
          if (s_q > row_max) row_max <= s_q;
          idx <= idx + 9'd1;
          if (idx == len - 9'd1) begin
            idx <= 9'd0;
            denom <= 24'd0;
            state <= EXPA;
          end else state <= MAXA;
        end
        // EXPA presents sbuf[idx]; EXPB has s_q and presents lut[lut_idx]; EXPC has lut_q
        EXPA: state <= EXPB;
        EXPB: state <= EXPC;
        EXPC: begin
          eb_we <= 1'b1; eb_waddr <= idx[7:0]; eb_wdata <= lut_q;
          denom <= denom + {7'd0, lut_q};
          idx <= idx + 9'd1;
          if (idx == len - 9'd1) begin
            idx <= 9'd0;
            state <= PDIVR;
          end else state <= EXPA;
        end
        // PDIVR presents ebuf[idx]; e_q feeds the divider in PDIV
        PDIVR: state <= PDIV;
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
          else state <= PDIVR;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
