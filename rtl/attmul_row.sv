module attmul_row (
    input  logic clk,
    input  logic rst,

    input  logic       start,
    input  logic [8:0] cfg_len,
    input  logic [5:0] cfg_j,
    input  logic [30:0] cfg_mult,
    input  logic [5:0]  cfg_shift,
    output logic       busy,

    input  logic        p_we,
    input  logic [7:0]  p_addr,
    input  logic [16:0] p_data,

    input  logic              v_valid,
    input  logic signed [7:0] v_data,
    output logic              v_ready,

    output logic              out_valid,
    output logic [5:0]        out_idx,
    output logic signed [7:0] out_data
);
  localparam IDLE = 2'd0, ACC = 2'd1, EMIT = 2'd2;

  logic [1:0] state;
  logic [16:0] pbuf [0:255];
  logic [8:0] len, s;
  logic [5:0] j, j_total;
  logic signed [31:0] acc_r;

  wire signed [25:0] prod = $signed({1'b0, pbuf[s[7:0]]}) * v_data;

  logic signed [7:0] q_out;
  requant rq (.acc(acc_r), .mult(cfg_mult), .shift(cfg_shift), .q(q_out));

  assign v_ready = (state == ACC);
  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    out_valid <= 1'b0;
    if (p_we) pbuf[p_addr] <= p_data;
    if (rst) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          len <= cfg_len;
          j_total <= cfg_j;
          j <= 6'd0;
          s <= 9'd0;
          acc_r <= 32'sd0;
          state <= ACC;
        end
        ACC: if (v_valid) begin
          acc_r <= acc_r + 32'(prod);
          if (s == len - 9'd1) state <= EMIT;
          else s <= s + 9'd1;
        end
        EMIT: begin
          out_valid <= 1'b1;
          out_idx <= j;
          out_data <= q_out;
          acc_r <= 32'sd0;
          s <= 9'd0;
          if (j == j_total - 6'd1) state <= IDLE;
          else begin
            j <= j + 6'd1;
            state <= ACC;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
