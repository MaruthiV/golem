module rmsnorm (
    input  logic clk,
    input  logic rst,

    input  logic start,
    output logic busy,

    output logic [7:0]        x_rd_addr,
    input  logic signed [7:0] x_rd_data,
    output logic [7:0]        g_rd_addr,
    input  logic signed [7:0] g_rd_data,

    input  logic [30:0] cfg_mult,
    input  logic [5:0]  cfg_shift,

    output logic              out_valid,
    output logic [7:0]        out_idx,
    output logic signed [7:0] out_data
);
  localparam IDLE = 3'd0, SQ = 3'd1, LATCH = 3'd2, SQRT = 3'd3, DIV = 3'd4, DIVW = 3'd5, OUT = 3'd6;

  logic [2:0] state;
  logic [7:0] idx;
  logic [31:0] n32;
  logic [13:0] msq;
  logic [25:0] rad;
  logic [12:0] root;
  logic [17:0] rem;
  logic [3:0] sq_count;
  logic [20:0] inv;

  wire [17:0] rem_next = {rem[15:0], rad[25:24]};
  wire [14:0] trial = {root, 2'b01};
  wire ge = rem_next >= {3'b0, trial};

  logic div_start, div_busy, div_done;
  logic [26:0] div_q;
  wire [26:0] div_dividend = (27'd1 << 26) + {14'd0, root[12:1]};
  divu #(.DW(27), .VW(13)) inv_div (
      .clk(clk), .rst(rst), .start(div_start),
      .dividend(div_dividend), .divisor(root),
      .busy(div_busy), .done(div_done), .quotient(div_q)
  );

  logic signed [28:0] xinv;
  logic signed [36:0] full;
  logic signed [31:0] acc_sat;
  assign x_rd_addr = idx;
  assign g_rd_addr = idx;
  assign xinv = x_rd_data * $signed({1'b0, inv});
  assign full = xinv * g_rd_data;
  always_comb begin
    if (full > 37'sd2147483646) acc_sat = 32'sd2147483646;
    else if (full < -37'sd2147483646) acc_sat = -32'sd2147483646;
    else acc_sat = full[31:0];
  end

  logic signed [7:0] q_out;
  requant rq (.acc(acc_sat), .mult(cfg_mult), .shift(cfg_shift), .q(q_out));

  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    out_valid <= 1'b0;
    div_start <= 1'b0;
    if (rst) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          idx <= 8'd0;
          n32 <= 32'd0;
          state <= SQ;
        end
        SQ: begin
          n32 <= n32 + 32'(x_rd_data * x_rd_data);
          idx <= idx + 8'd1;
          if (idx == 8'd255) state <= LATCH;
        end
        LATCH: begin
          msq <= 14'((n32 + 32'd128) >> 8);
          rad <= 26'(((n32 + 32'd128) >> 8) << 12);
          root <= '0;
          rem <= '0;
          sq_count <= 4'd13;
          state <= SQRT;
        end
        SQRT: begin
          rem <= ge ? rem_next - {3'b0, trial} : rem_next;
          rad <= rad << 2;
          root <= {root[11:0], ge};
          sq_count <= sq_count - 4'd1;
          if (sq_count == 4'd1) state <= DIV;
        end
        DIV: begin
          if (msq == 0) begin
            inv <= 21'd0;
            idx <= 8'd0;
            state <= OUT;
          end else begin
            div_start <= 1'b1;
            state <= DIVW;
          end
        end
        DIVW: if (div_done) begin
          inv <= div_q[20:0];
          idx <= 8'd0;
          state <= OUT;
        end
        OUT: begin
          out_valid <= 1'b1;
          out_idx <= idx;
          out_data <= q_out;
          idx <= idx + 8'd1;
          if (idx == 8'd255) state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
