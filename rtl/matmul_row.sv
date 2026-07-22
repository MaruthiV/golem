module matmul_row (
    input  logic clk,
    input  logic rst,

    input  logic       start,
    input  logic [9:0] cfg_k,
    input  logic [9:0] cfg_j,
    input  logic [11:0] cfg_pbase,
    output logic       busy,

    input  logic              x_we,
    input  logic [9:0]        x_addr,
    input  logic signed [7:0] x_data,

    input  logic        p_we,
    input  logic [11:0] p_addr,
    input  logic [30:0] p_mult,
    input  logic [5:0]  p_shift,

    input  logic              w_valid,
    input  logic signed [7:0] w_data0,
    input  logic signed [7:0] w_data1,
    input  logic signed [7:0] w_data2,
    input  logic signed [7:0] w_data3,
    output logic              w_ready,

    output logic              out_valid,
    output logic [9:0]        out_idx,
    output logic signed [7:0] out_data
);
  localparam IDLE = 2'd0, ACC = 2'd1, EMIT = 2'd2;

  logic [1:0] state;
  logic [7:0] kw, k_words;
  logic [9:0] j, j_total;
  logic [11:0] pbase;
  logic signed [31:0] acc_r;

  // x buffer banked by k%4 so one weight word meets four x bytes per cycle
  logic signed [7:0] xb0 [0:191];
  logic signed [7:0] xb1 [0:191];
  logic signed [7:0] xb2 [0:191];
  logic signed [7:0] xb3 [0:191];
  logic [36:0] params [0:4095];

  always_ff @(posedge clk) begin
    if (x_we) begin
      case (x_addr[1:0])
        2'd0: xb0[x_addr[9:2]] <= x_data;
        2'd1: xb1[x_addr[9:2]] <= x_data;
        2'd2: xb2[x_addr[9:2]] <= x_data;
        2'd3: xb3[x_addr[9:2]] <= x_data;
      endcase
    end
    if (p_we) params[p_addr] <= {p_mult, p_shift};
  end

  logic signed [16:0] s01, s23;
  logic signed [17:0] sum4;
  assign s01 = xb0[kw] * w_data0 + xb1[kw] * w_data1;
  assign s23 = xb2[kw] * w_data2 + xb3[kw] * w_data3;
  assign sum4 = s01 + s23;

  logic [36:0] p_cur;
  assign p_cur = params[pbase + {2'b0, j}];

  logic signed [7:0] q_out;
  requant rq (
      .acc  (acc_r),
      .mult (p_cur[36:6]),
      .shift(p_cur[5:0]),
      .q    (q_out)
  );

  assign w_ready = (state == ACC);
  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      out_valid <= 1'b0;
    end else begin
      out_valid <= 1'b0;
      case (state)
        IDLE: begin
          if (start) begin
            k_words <= cfg_k[9:2] - 8'd1;
            j_total <= cfg_j;
            pbase <= cfg_pbase;
            j <= 10'd0;
            kw <= 8'd0;
            acc_r <= 32'sd0;
            state <= ACC;
          end
        end
        ACC: begin
          if (w_valid) begin
            acc_r <= acc_r + 32'(sum4);
            if (kw == k_words) state <= EMIT;
            else kw <= kw + 8'd1;
          end
        end
        EMIT: begin
          out_valid <= 1'b1;
          out_idx <= j;
          out_data <= q_out;
          acc_r <= 32'sd0;
          kw <= 8'd0;
          if (j == j_total - 10'd1) state <= IDLE;
          else begin
            j <= j + 10'd1;
            state <= ACC;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
