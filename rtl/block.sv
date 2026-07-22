module block (
    input  logic clk,
    input  logic rst,

    input  logic       start,
    input  logic [7:0] t,
    input  logic [2:0] layer,
    output logic       busy,

    input  logic              xr_we,
    input  logic [7:0]        xr_addr,
    input  logic signed [7:0] xr_data,

    input  logic        cfg_we,
    input  logic [2:0]  cfg_sel,
    input  logic [30:0] cfg_mult,
    input  logic [5:0]  cfg_shift,

    input  logic              gc_we,
    input  logic              gc_sel,
    input  logic [7:0]        gc_addr,
    input  logic signed [7:0] gc_data,

    input  logic        p_we,
    input  logic [11:0] p_addr,
    input  logic [30:0] p_mult,
    input  logic [5:0]  p_shift,

    input  logic        sl_we,
    input  logic [8:0]  sl_addr,
    input  logic [16:0] sl_data,

    input  logic              gl_we,
    input  logic [7:0]        gl_addr,
    input  logic signed [7:0] gl_data,

    input  logic        kvd_we,
    input  logic        kvd_v,
    input  logic [13:0] kvd_addr,
    input  logic [31:0] kvd_data,

    input  logic              w_valid,
    input  logic signed [7:0] w_data0,
    input  logic signed [7:0] w_data1,
    input  logic signed [7:0] w_data2,
    input  logic signed [7:0] w_data3,
    output logic              w_ready,

    output logic              r3_valid,
    output logic [7:0]        r3_idx,
    output logic signed [7:0] r3_data
);
  localparam S_IDLE = 4'd0, S_NORM_A = 4'd1, S_MM_Q = 4'd2, S_MM_K = 4'd3, S_MM_V = 4'd4,
             S_SC = 4'd5, S_SM = 4'd6, S_AT = 4'd7, S_AEMIT = 4'd8, S_LD_ATT = 4'd9,
             S_MM_O = 4'd10, S_NORM_M = 4'd11, S_MM_UP = 4'd12, S_LD_GEL = 4'd13, S_MM_DN = 4'd14;

  localparam PB_WQ = 12'd0, PB_WK = 12'd256, PB_WV = 12'd512, PB_WO = 12'd768,
             PB_UP = 12'd1024, PB_DN = 12'd1792;

  logic [3:0] state;
  logic [7:0] tok;
  logic [2:0] h;
  logic [8:0] s;
  logic [2:0] c;
  logic [9:0] ld;
  logic [4:0] ej;
  logic phase_mlp;

  logic signed [7:0] xres [0:255];
  logic signed [7:0] g_attn [0:255];
  logic signed [7:0] g_mlp [0:255];
  logic signed [7:0] r2buf [0:255];
  logic signed [7:0] attbuf [0:255];
  logic signed [7:0] gelbuf [0:767];
  logic [16:0] pbuf [0:255];
  logic signed [7:0] qb0 [0:63];
  logic signed [7:0] qb1 [0:63];
  logic signed [7:0] qb2 [0:63];
  logic signed [7:0] qb3 [0:63];
  logic [31:0] k_mem [0:131071];
  logic [31:0] v_mem [0:131071];
  logic signed [31:0] aacc [0:31];

  logic [30:0] r_mult [0:7];
  logic [5:0] r_shift [0:7];

  always_ff @(posedge clk) begin
    if (xr_we) xres[xr_addr] <= xr_data;
    if (gc_we && !gc_sel) g_attn[gc_addr] <= gc_data;
    if (gc_we && gc_sel) g_mlp[gc_addr] <= gc_data;
    if (cfg_we) begin
      r_mult[cfg_sel] <= cfg_mult;
      r_shift[cfg_sel] <= cfg_shift;
    end
    if (kvd_we && !kvd_v) k_mem[{layer, kvd_addr}] <= kvd_data;
    if (kvd_we && kvd_v) v_mem[{layer, kvd_addr}] <= kvd_data;
  end

  // norm engine, x/g served by phase
  logic nm_start, nm_busy, nm_ov;
  logic [7:0] nm_xa, nm_ga, nm_oi;
  logic signed [7:0] nm_xd, nm_gd, nm_od;
  assign nm_xd = phase_mlp ? r2buf[nm_xa] : xres[nm_xa];
  assign nm_gd = phase_mlp ? g_mlp[nm_ga] : g_attn[nm_ga];
  rmsnorm nm (
      .clk(clk), .rst(rst), .start(nm_start), .busy(nm_busy),
      .x_rd_addr(nm_xa), .x_rd_data(nm_xd), .g_rd_addr(nm_ga), .g_rd_data(nm_gd),
      .cfg_mult(phase_mlp ? r_mult[1] : r_mult[0]),
      .cfg_shift(phase_mlp ? r_shift[1] : r_shift[0]),
      .out_valid(nm_ov), .out_idx(nm_oi), .out_data(nm_od)
  );

  // shared matmul engine
  logic mm_start, mm_busy, mm_ov;
  logic [9:0] mm_cfg_k, mm_cfg_j, mm_oi;
  logic [11:0] mm_pbase;
  logic signed [7:0] mm_od;
  logic mm_xwe;
  logic [9:0] mm_xaddr;
  logic signed [7:0] mm_xdata;
  logic mm_wready;
  matmul_row mm (
      .clk(clk), .rst(rst), .start(mm_start),
      .cfg_k(mm_cfg_k), .cfg_j(mm_cfg_j), .cfg_pbase(mm_pbase), .busy(mm_busy),
      .x_we(mm_xwe), .x_addr(mm_xaddr), .x_data(mm_xdata),
      .p_we(p_we), .p_addr(p_addr), .p_mult(p_mult), .p_shift(p_shift),
      .w_valid(w_valid && w_ready), .w_data0(w_data0), .w_data1(w_data1),
      .w_data2(w_data2), .w_data3(w_data3), .w_ready(mm_wready),
      .out_valid(mm_ov), .out_idx(mm_oi), .out_data(mm_od)
  );
  assign w_ready = mm_wready && (state == S_MM_Q || state == S_MM_K || state == S_MM_V ||
                                 state == S_MM_O || state == S_MM_UP || state == S_MM_DN);

  // matmul x port mux: norm stream, att reload, gel reload
  always_comb begin
    mm_xwe = 1'b0;
    mm_xaddr = '0;
    mm_xdata = '0;
    if (state == S_NORM_A || state == S_NORM_M) begin
      mm_xwe = nm_ov;
      mm_xaddr = {2'b0, nm_oi};
      mm_xdata = nm_od;
    end else if (state == S_LD_ATT) begin
      mm_xwe = 1'b1;
      mm_xaddr = ld;
      mm_xdata = attbuf[ld[7:0]];
    end else if (state == S_LD_GEL) begin
      mm_xwe = 1'b1;
      mm_xaddr = ld;
      mm_xdata = gelbuf[ld];
    end
  end

  // softmax engine
  logic sm_start, sm_busy, sm_ov, sm_swe;
  logic [7:0] sm_saddr, sm_oi;
  logic signed [31:0] sm_sdata;
  logic [16:0] sm_od;
  softmax_row sm (
      .clk(clk), .rst(rst), .start(sm_start),
      .cfg_len(s), .cfg_mult(r_mult[2]), .cfg_shift(r_shift[2]), .busy(sm_busy),
      .s_we(sm_swe), .s_addr(sm_saddr), .s_data(sm_sdata),
      .lut_we(sl_we), .lut_addr(sl_addr), .lut_data(sl_data),
      .out_valid(sm_ov), .out_idx(sm_oi), .out_data(sm_od)
  );

  // gelu lut fed straight off the up-matmul output stream
  logic signed [7:0] gel_y;
  gelu_lut gl (
      .clk(clk), .lut_we(gl_we), .lut_addr(gl_addr), .lut_data(gl_data),
      .x(mm_od), .y(gel_y)
  );

  // score engine
  logic signed [31:0] sc_acc;
  logic [31:0] kword, vword;
  assign kword = k_mem[{layer, s[7:0], h, c}];
  assign vword = v_mem[{layer, s[7:0], h, c}];
  logic signed [7:0] kb0, kb1, kb2, kb3;
  assign {kb3, kb2, kb1, kb0} = kword;
  logic signed [17:0] sc_sum;
  assign sc_sum = qb0[{h, c}] * kb0 + qb1[{h, c}] * kb1 + qb2[{h, c}] * kb2 + qb3[{h, c}] * kb3;

  // att engine: 4 lanes into 32 accumulators
  logic signed [7:0] vb0, vb1, vb2, vb3;
  assign {vb3, vb2, vb1, vb0} = vword;
  logic [16:0] p_s;
  assign p_s = pbuf[s[7:0]];
  logic signed [25:0] ap0, ap1, ap2, ap3;
  assign ap0 = $signed({1'b0, p_s}) * vb0;
  assign ap1 = $signed({1'b0, p_s}) * vb1;
  assign ap2 = $signed({1'b0, p_s}) * vb2;
  assign ap3 = $signed({1'b0, p_s}) * vb3;

  logic signed [7:0] at_q;
  requant at_rq (.acc(aacc[ej]), .mult(r_mult[3]), .shift(r_shift[3]), .q(at_q));

  // residual adds on the o / dn output streams
  logic signed [15:0] res_a, res_b;
  logic signed [16:0] res_sum;
  logic signed [7:0] res_q;
  requant #(.OUT_W(16)) rq_ra (
      .acc(32'(phase_mlp ? r2buf[mm_oi[7:0]] : xres[mm_oi[7:0]])),
      .mult(phase_mlp ? r_mult[6] : r_mult[4]),
      .shift(phase_mlp ? r_shift[6] : r_shift[4]), .q(res_a)
  );
  requant #(.OUT_W(16)) rq_rb (
      .acc(32'(mm_od)),
      .mult(phase_mlp ? r_mult[7] : r_mult[5]),
      .shift(phase_mlp ? r_shift[7] : r_shift[5]), .q(res_b)
  );
  assign res_sum = res_a + res_b;
  always_comb begin
    if (res_sum > 17'sd127) res_q = 8'sd127;
    else if (res_sum < -17'sd127) res_q = -8'sd127;
    else res_q = res_sum[7:0];
  end

  // k/v word packers
  logic [23:0] pack;

  assign busy = (state != S_IDLE);

  always_ff @(posedge clk) begin
    nm_start <= 1'b0;
    mm_start <= 1'b0;
    sm_start <= 1'b0;
    sm_swe <= 1'b0;
    r3_valid <= 1'b0;
    if (rst) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: if (start) begin
          tok <= t;
          phase_mlp <= 1'b0;
          nm_start <= 1'b1;
          state <= S_NORM_A;
        end
        S_NORM_A: if (!nm_busy && !nm_start) begin
          mm_cfg_k <= 10'd256; mm_cfg_j <= 10'd256; mm_pbase <= PB_WQ;
          mm_start <= 1'b1;
          state <= S_MM_Q;
        end
        S_MM_Q: begin
          if (mm_ov) begin
            case (mm_oi[1:0])
              2'd0: qb0[mm_oi[9:2]] <= mm_od;
              2'd1: qb1[mm_oi[9:2]] <= mm_od;
              2'd2: qb2[mm_oi[9:2]] <= mm_od;
              2'd3: qb3[mm_oi[9:2]] <= mm_od;
            endcase
          end
          if (!mm_busy && !mm_start) begin
            mm_pbase <= PB_WK; mm_start <= 1'b1;
            state <= S_MM_K;
          end
        end
        S_MM_K: begin
          if (mm_ov) begin
            if (mm_oi[1:0] == 2'd3) k_mem[{layer, tok, mm_oi[7:2]}] <= {mm_od, pack};
            else pack <= {mm_od, pack[23:8]};
          end
          if (!mm_busy && !mm_start) begin
            mm_pbase <= PB_WV; mm_start <= 1'b1;
            state <= S_MM_V;
          end
        end
        S_MM_V: begin
          if (mm_ov) begin
            if (mm_oi[1:0] == 2'd3) v_mem[{layer, tok, mm_oi[7:2]}] <= {mm_od, pack};
            else pack <= {mm_od, pack[23:8]};
          end
          if (!mm_busy && !mm_start) begin
            h <= 3'd0;
            s <= 9'd0;
            c <= 3'd0;
            sc_acc <= 32'sd0;
            state <= S_SC;
          end
        end
        S_SC: begin
          sc_acc <= sc_acc + 32'(sc_sum);
          if (c == 3'd7) begin
            c <= 3'd0;
            sm_swe <= 1'b1;
            sm_saddr <= s[7:0];
            sm_sdata <= sc_acc + 32'(sc_sum);
            sc_acc <= 32'sd0;
            if (s == {1'b0, tok}) begin
              s <= {1'b0, tok} + 9'd1;
              sm_start <= 1'b1;
              state <= S_SM;
            end else s <= s + 9'd1;
          end else c <= c + 3'd1;
        end
        S_SM: begin
          if (sm_ov) pbuf[sm_oi] <= sm_od;
          if (!sm_busy && !sm_start) begin
            s <= 9'd0;
            c <= 3'd0;
            for (int i = 0; i < 32; i++) aacc[i] <= 32'sd0;
            state <= S_AT;
          end
        end
        S_AT: begin
          aacc[{c, 2'd0}] <= aacc[{c, 2'd0}] + 32'(ap0);
          aacc[{c, 2'd1}] <= aacc[{c, 2'd1}] + 32'(ap1);
          aacc[{c, 2'd2}] <= aacc[{c, 2'd2}] + 32'(ap2);
          aacc[{c, 2'd3}] <= aacc[{c, 2'd3}] + 32'(ap3);
          if (c == 3'd7) begin
            c <= 3'd0;
            if (s == {1'b0, tok}) begin
              ej <= 5'd0;
              state <= S_AEMIT;
            end else s <= s + 9'd1;
          end else c <= c + 3'd1;
        end
        S_AEMIT: begin
          attbuf[{h, ej}] <= at_q;
          if (ej == 5'd31) begin
            if (h == 3'd7) begin
              ld <= 10'd0;
              state <= S_LD_ATT;
            end else begin
              h <= h + 3'd1;
              s <= 9'd0;
              c <= 3'd0;
              sc_acc <= 32'sd0;
              state <= S_SC;
            end
          end else ej <= ej + 5'd1;
        end
        S_LD_ATT: begin
          ld <= ld + 10'd1;
          if (ld == 10'd255) begin
            mm_cfg_k <= 10'd256; mm_cfg_j <= 10'd256; mm_pbase <= PB_WO;
            mm_start <= 1'b1;
            state <= S_MM_O;
          end
        end
        S_MM_O: begin
          if (mm_ov) r2buf[mm_oi[7:0]] <= res_q;
          if (!mm_busy && !mm_start) begin
            phase_mlp <= 1'b1;
            nm_start <= 1'b1;
            state <= S_NORM_M;
          end
        end
        S_NORM_M: if (!nm_busy && !nm_start) begin
          mm_cfg_k <= 10'd256; mm_cfg_j <= 10'd768; mm_pbase <= PB_UP;
          mm_start <= 1'b1;
          state <= S_MM_UP;
        end
        S_MM_UP: begin
          if (mm_ov) gelbuf[mm_oi] <= gel_y;
          if (!mm_busy && !mm_start) begin
            ld <= 10'd0;
            state <= S_LD_GEL;
          end
        end
        S_LD_GEL: begin
          ld <= ld + 10'd1;
          if (ld == 10'd767) begin
            mm_cfg_k <= 10'd768; mm_cfg_j <= 10'd256; mm_pbase <= PB_DN;
            mm_start <= 1'b1;
            state <= S_MM_DN;
          end
        end
        S_MM_DN: begin
          if (mm_ov) begin
            r3_valid <= 1'b1;
            r3_idx <= mm_oi[7:0];
            r3_data <= res_q;
          end
          if (!mm_busy && !mm_start) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
