module golem (
    input  logic clk,
    input  logic rst,

    input  logic        start,
    input  logic [11:0] token,
    input  logic [7:0]  pos,
    output logic        busy,

    output logic [21:0] mrd_addr,
    output logic        mrd_req,
    input  logic        mrd_valid,
    input  logic [31:0] mrd_data,

    output logic        kv_we,
    output logic        kv_wsel,
    output logic [16:0] kv_waddr,
    output logic [31:0] kv_wdata,
    output logic [16:0] kv_raddr,
    output logic        kv_rsel,
    output logic        kv_rreq,
    input  logic        kv_rvalid,
    input  logic [31:0] kv_rdata,

    output logic        tok_valid,
    output logic [11:0] tok_out
);
  `include "golem_mem.svh"
  localparam V=4096, WSTART = 16 + 4096 + 64 + 64 + 64;

  typedef enum logic [4:0] {
    S_IDLE, S_HDR, S_LUT, S_ETOK, S_EPOS, S_ECMB, S_LX, S_SCAL, S_PARM,
    S_GATN, S_GMLP, S_GELU, S_START, S_WT, S_CAP, S_NEXT,
    S_ON_G, S_ON_RUN, S_LG, S_DONE
  } st_t;
  st_t st;

  logic [30:0] emt_m, emp_m, on_m;
  logic [5:0]  emt_s, emp_s, on_s;
  logic [2:0]  li;
  logic [17:0] lc;
  logic [11:0] cnt;
  logic [1:0]  sub;
  logic [30:0] mtmp;
  logic [5:0]  stmp;
  logic [8:0]  ei;
  logic [11:0] jarg;
  logic signed [31:0] jmax, hacc;

  logic signed [7:0] xbuf [0:255];
  logic signed [7:0] tbuf [0:255];
  logic signed [7:0] pbuf [0:255];
  logic signed [7:0] gbuf [0:255];
  logic signed [7:0] ob0[0:63], ob1[0:63], ob2[0:63], ob3[0:63];

  wire [31:0] md = mrd_data;
  wire signed [7:0] mb0=md[7:0], mb1=md[15:8], mb2=md[23:16], mb3=md[31:24];
  logic signed [7:0] mbsub;
  always_comb unique case (sub)
    2'd0: mbsub=mb0; 2'd1: mbsub=mb1; 2'd2: mbsub=mb2; default: mbsub=mb3;
  endcase

  // embedding requant (int16 out), fed from tok/pos buffers
  logic signed [15:0] etq, epq; logic signed [16:0] esum; logic signed [7:0] e8;
  requant #(.OUT_W(16)) e_tok(.acc(32'(tbuf[ei[7:0]])), .mult(emt_m), .shift(emt_s), .q(etq));
  requant #(.OUT_W(16)) e_pos(.acc(32'(pbuf[ei[7:0]])), .mult(emp_m), .shift(emp_s), .q(epq));
  always_comb begin
    esum = etq + epq;
    if (esum > 17'sd127) e8 = 8'sd127;
    else if (esum < -17'sd127) e8 = -8'sd127;
    else e8 = esum[7:0];
  end

  logic blk_start, blk_busy, r3_v; logic [7:0] r3_i; logic signed [7:0] r3_d;
  logic xr_we; logic [7:0] xr_a; logic signed [7:0] xr_d;
  logic cfg_we; logic [2:0] cfg_sel;
  logic gc_we, gc_sel; logic [7:0] gc_a; logic signed [7:0] gc_d;
  logic p_we; logic [11:0] p_a;
  logic sl_we; logic [8:0] sl_a; logic [16:0] sl_d;
  logic gl_we; logic [7:0] gl_a; logic signed [7:0] gl_d;
  logic w_rdy;
  block u_block(
    .clk(clk), .rst(rst), .start(blk_start), .t(pos), .layer(li), .busy(blk_busy),
    .xr_we(xr_we), .xr_addr(xr_a), .xr_data(xr_d),
    .cfg_we(cfg_we), .cfg_sel(cfg_sel), .cfg_mult(mtmp), .cfg_shift(stmp),
    .gc_we(gc_we), .gc_sel(gc_sel), .gc_addr(gc_a), .gc_data(gc_d),
    .p_we(p_we), .p_addr(p_a), .p_mult(mtmp), .p_shift(stmp),
    .sl_we(sl_we), .sl_addr(sl_a), .sl_data(sl_d),
    .gl_we(gl_we), .gl_addr(gl_a), .gl_data(gl_d),
    .kv_we(kv_we), .kv_wsel(kv_wsel), .kv_waddr(kv_waddr), .kv_wdata(kv_wdata),
    .kv_raddr(kv_raddr), .kv_rsel(kv_rsel), .kv_rreq(kv_rreq), .kv_rvalid(kv_rvalid),
    .kv_rdata(kv_rdata),
    .w_valid((st==S_WT) && mrd_valid), .w_data0(mb0), .w_data1(mb1), .w_data2(mb2), .w_data3(mb3), .w_ready(w_rdy),
    .r3_valid(r3_v), .r3_idx(r3_i), .r3_data(r3_d));

  logic nrm_start, nrm_busy, nrm_v; logic [7:0] nrm_xa, nrm_ga, nrm_i; logic signed [7:0] nrm_o;
  rmsnorm u_norm(.clk(clk), .rst(rst), .start(nrm_start), .busy(nrm_busy),
    .x_rd_addr(nrm_xa), .x_rd_data(xbuf[nrm_xa]), .g_rd_addr(nrm_ga), .g_rd_data(gbuf[nrm_ga]),
    .cfg_mult(on_m), .cfg_shift(on_s), .out_valid(nrm_v), .out_idx(nrm_i), .out_data(nrm_o));

  wire signed [17:0] hs = ob0[cnt[5:0]]*mb0 + ob1[cnt[5:0]]*mb1 + ob2[cnt[5:0]]*mb2 + ob3[cnt[5:0]]*mb3;
  wire signed [31:0] hnext = hacc + 32'(hs);
  wire [21:0] lbase = 22'(MEM_LAYERS + li*MEM_LAYER_STRIDE);

  assign busy = (st != S_IDLE);
  // states that read the weight/config SDRAM. real SDRAM has latency, so the FSM
  // must wait for mrd_valid before consuming — `stall` freezes it until data arrives.
  assign mrd_req = (st==S_HDR || st==S_LUT || st==S_ETOK || st==S_EPOS || st==S_SCAL ||
                    st==S_PARM || st==S_GATN || st==S_GMLP || st==S_GELU || st==S_WT ||
                    st==S_ON_G || st==S_LG);
  wire stall = mrd_req && !mrd_valid;

  always_comb begin
    unique case (st)
      S_HDR:  mrd_addr = 22'(cnt);
      S_LUT:  mrd_addr = 22'(MEM_EXP_LUT + cnt);
      S_ETOK: mrd_addr = 22'(MEM_TOK_EMB + token*64 + cnt);
      S_EPOS: mrd_addr = 22'(MEM_POS_EMB + pos*64 + cnt);
      S_SCAL: mrd_addr = lbase + 22'(cnt);
      S_PARM: mrd_addr = lbase + 22'(16 + cnt);
      S_GATN: mrd_addr = lbase + 22'(16+4096) + 22'(cnt);
      S_GMLP: mrd_addr = lbase + 22'(16+4096+64) + 22'(cnt);
      S_GELU: mrd_addr = lbase + 22'(16+4096+128) + 22'(cnt);
      S_WT:   mrd_addr = lbase + 22'(WSTART) + 22'(lc);
      S_ON_G: mrd_addr = 22'(MEM_OUT_NORM_GAIN + cnt);
      S_LG:   mrd_addr = 22'(MEM_TOK_EMB + jarg*64 + cnt);
      default: mrd_addr = 22'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    blk_start<=0; nrm_start<=0; tok_valid<=0;
    xr_we<=0; cfg_we<=0; gc_we<=0; p_we<=0; sl_we<=0; gl_we<=0;
    // r3 streams out DURING weight streaming (matmul emits early rows before late
    // weights arrive), so capture it in any state the block is running.
    if (r3_v) xbuf[r3_i]<=r3_d;
    if (rst) st<=S_IDLE;
    else if (stall) begin end  // waiting on SDRAM: hold the FSM, re-request same addr
    else case (st)
      S_IDLE: if (start) begin cnt<=0; st<=S_HDR; end
      S_HDR: begin
        case (cnt)
          0: emt_m<=md[30:0]; 1: emt_s<=md[5:0]; 2: emp_m<=md[30:0];
          3: emp_s<=md[5:0]; 4: on_m<=md[30:0]; 5: on_s<=md[5:0];
        endcase
        if (cnt==5) begin cnt<=0; st<=S_LUT; end else cnt<=cnt+1;
      end
      S_LUT: begin
        sl_we<=1; sl_a<=cnt[8:0]; sl_d<=md[16:0];
        if (cnt==511) begin cnt<=0; st<=S_ETOK; end else cnt<=cnt+1;
      end
      S_ETOK: begin
        tbuf[{cnt[5:0],2'd0}]<=mb0; tbuf[{cnt[5:0],2'd1}]<=mb1;
        tbuf[{cnt[5:0],2'd2}]<=mb2; tbuf[{cnt[5:0],2'd3}]<=mb3;
        if (cnt==63) begin cnt<=0; st<=S_EPOS; end else cnt<=cnt+1;
      end
      S_EPOS: begin
        pbuf[{cnt[5:0],2'd0}]<=mb0; pbuf[{cnt[5:0],2'd1}]<=mb1;
        pbuf[{cnt[5:0],2'd2}]<=mb2; pbuf[{cnt[5:0],2'd3}]<=mb3;
        if (cnt==63) begin ei<=0; st<=S_ECMB; end else cnt<=cnt+1;
      end
      S_ECMB: begin
        xbuf[ei[7:0]]<=e8;
        if (ei==255) begin li<=0; cnt<=0; st<=S_LX; end else ei<=ei+1;
      end
      S_LX: begin
        xr_we<=1; xr_a<=cnt[7:0]; xr_d<=xbuf[cnt[7:0]];
        if (cnt==255) begin cnt<=0; st<=S_SCAL; end else cnt<=cnt+1;
      end
      S_SCAL: begin
        if (~cnt[0]) mtmp<=md[30:0]; else begin stmp<=md[5:0]; cfg_we<=1; cfg_sel<=cnt[3:1]; end
        if (cnt==15) begin cnt<=0; st<=S_PARM; end else cnt<=cnt+1;
      end
      S_PARM: begin
        if (~cnt[0]) mtmp<=md[30:0]; else begin stmp<=md[5:0]; p_we<=1; p_a<=cnt[11:1]; end
        if (cnt==4095) begin cnt<=0; sub<=0; st<=S_GATN; end else cnt<=cnt+1;
      end
      S_GATN: begin
        gc_we<=1; gc_sel<=0; gc_a<={cnt[5:0],sub}; gc_d<=mbsub;
        if (sub==3) begin sub<=0; if (cnt==63) begin cnt<=0; st<=S_GMLP; end else cnt<=cnt+1; end
        else sub<=sub+1;
      end
      S_GMLP: begin
        gc_we<=1; gc_sel<=1; gc_a<={cnt[5:0],sub}; gc_d<=mbsub;
        if (sub==3) begin sub<=0; if (cnt==63) begin cnt<=0; st<=S_GELU; end else cnt<=cnt+1; end
        else sub<=sub+1;
      end
      S_GELU: begin
        gl_we<=1; gl_a<={cnt[5:0],sub}; gl_d<=mbsub;
        if (sub==3) begin sub<=0; if (cnt==63) begin lc<=0; st<=S_START; end else cnt<=cnt+1; end
        else sub<=sub+1;
      end
      S_START: begin blk_start<=1; st<=S_WT; end
      S_WT: if (w_rdy) begin
        if (lc==18'(163839)) st<=S_CAP; else lc<=lc+1;
      end
      S_CAP: if (!blk_busy && !blk_start) st<=S_NEXT;
      S_NEXT: if (li==7) begin cnt<=0; st<=S_ON_G; end
              else begin li<=li+1; cnt<=0; st<=S_LX; end
      S_ON_G: begin
        gbuf[{cnt[5:0],2'd0}]<=mb0; gbuf[{cnt[5:0],2'd1}]<=mb1;
        gbuf[{cnt[5:0],2'd2}]<=mb2; gbuf[{cnt[5:0],2'd3}]<=mb3;
        if (cnt==63) begin st<=S_ON_RUN; nrm_start<=1; end else cnt<=cnt+1;
      end
      S_ON_RUN: begin
        if (nrm_v) case (nrm_i[1:0])
          0: ob0[nrm_i[7:2]]<=nrm_o; 1: ob1[nrm_i[7:2]]<=nrm_o;
          2: ob2[nrm_i[7:2]]<=nrm_o; 3: ob3[nrm_i[7:2]]<=nrm_o;
        endcase
        if (!nrm_busy && !nrm_start) begin jarg<=0; jmax<=32'sh80000000; cnt<=0; hacc<=0; st<=S_LG; end
      end
      S_LG: begin
        hacc<=hnext;
        if (cnt==63) begin
          if (hnext > jmax) begin jmax<=hnext; tok_out<=jarg; end
          if (jarg==V-1) st<=S_DONE;
          else begin jarg<=jarg+1; cnt<=0; hacc<=0; end
        end else cnt<=cnt+1;
      end
      S_DONE: begin tok_valid<=1; st<=S_IDLE; end
      default: st<=S_IDLE;
    endcase
  end
endmodule
