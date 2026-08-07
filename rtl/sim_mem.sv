// behavioral SDRAM stand-in for simulation: loads the packed image, async read.
// on the real FPGA this is replaced by the SDRAM controller (M8b/M9).
module sim_mem (
    input  logic [21:0] addr,
    output logic [31:0] data
);
  logic [31:0] m [0:(1<<21)-1];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, m);
  end
  assign data = m[addr];
endmodule

// latency-accurate SDRAM read model: data becomes valid LAT cycles after a stable
// (req, addr). Represents CAS/activate latency — the real thing golem must tolerate.
module sdram_rd #(parameter LAT = 4) (
    input  logic        clk,
    input  logic        req,
    input  logic [21:0] addr,
    output logic        valid,
    output logic [31:0] data
);
  logic [31:0] m [0:(1<<21)-1];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, m);
  end
  logic [21:0] la; logic [2:0] cnt;
  always_ff @(posedge clk) begin
    if (!req) begin cnt <= LAT[2:0]; la <= 22'h3FFFFF; end
    else if (addr != la) begin la <= addr; cnt <= LAT[2:0]; end
    else if (cnt != 0) cnt <= cnt - 3'd1;
  end
  assign valid = req && (addr == la) && (cnt == 0);
  assign data = m[addr];
endmodule

// behavioral KV memory (the SDRAM KV region in sim): posted (sync) write, LAT-cycle read.
module kv_mem #(parameter LAT = 4) (
    input  logic        clk,
    input  logic        we,
    input  logic        wsel,
    input  logic [16:0] waddr,
    input  logic [31:0] wdata,
    input  logic        rreq,
    input  logic [16:0] raddr,
    input  logic        rsel,
    output logic        rvalid,
    output logic [31:0] rdata
);
  logic [31:0] kmem [0:(1<<17)-1];
  logic [31:0] vmem [0:(1<<17)-1];
  always_ff @(posedge clk) if (we) begin
    if (wsel) kmem[waddr] <= wdata; else vmem[waddr] <= wdata;
  end
  logic [17:0] la; logic [2:0] cnt;
  wire [17:0] cur = {rsel, raddr};
  always_ff @(posedge clk) begin
    if (!rreq) begin cnt <= LAT[2:0]; la <= 18'h3FFFF; end
    else if (cur != la) begin la <= cur; cnt <= LAT[2:0]; end
    else if (cnt != 0) cnt <= cnt - 3'd1;
  end
  assign rvalid = rreq && (cur == la) && (cnt == 0);
  assign rdata = rsel ? kmem[raddr] : vmem[raddr];
endmodule

module golem_sim (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [11:0] token,
    input  logic [7:0]  pos,
    output logic        busy,
    output logic        tok_valid,
    output logic [11:0] tok_out
);
  logic [21:0] a; logic [31:0] d; logic rq, rv;
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;
  golem u_golem(.clk(clk), .rst(rst), .start(start), .token(token), .pos(pos), .busy(busy),
                .mrd_addr(a), .mrd_req(rq), .mrd_valid(rv), .mrd_data(d),
                .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
                .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
                .tok_valid(tok_valid), .tok_out(tok_out));
  sdram_rd u_mem(.clk(clk), .req(rq), .addr(a), .valid(rv), .data(d));
  kv_mem u_kv(.clk(clk), .we(kw), .wsel(kws), .waddr(kwa), .wdata(kwd),
              .rreq(krq), .raddr(kra), .rsel(krs), .rvalid(krv), .rdata(krd));
endmodule

// weight_loader + SDRAM (ctrl+chip) + a test read port — for the loader unit test.
module loader_sys #(parameter [21:0] N_WORDS = 22'd20) (
    input  logic        clk,
    input  logic        rst,
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,
    output logic        load_done,
    input  logic        t_valid,
    input  logic [21:0] t_addr,
    output logic        t_ready,
    output logic        t_rvalid,
    output logic [31:0] t_rdata
);
  logic ld_valid, ld_wr; logic [21:0] ld_addr; logic [31:0] ld_wdata; logic ld_ready;
  weight_loader #(.N_WORDS(N_WORDS)) u_ld(.clk(clk), .rst(rst), .rx_data(rx_data),
    .rx_valid(rx_valid), .cmd_valid(ld_valid), .cmd_wr(ld_wr), .cmd_addr(ld_addr),
    .cmd_wdata(ld_wdata), .cmd_ready(ld_ready), .done(load_done));
  wire loading = !load_done;
  logic c_valid, c_wr; logic [21:0] c_addr; logic [31:0] c_wdata, c_rdata; logic c_ready, c_rvalid;
  assign c_valid = loading ? ld_valid : t_valid;
  assign c_wr    = loading ? ld_wr    : 1'b0;
  assign c_addr  = loading ? ld_addr  : t_addr;
  assign c_wdata = ld_wdata;
  assign ld_ready = loading ? c_ready : 1'b0;
  assign t_ready  = loading ? 1'b0 : c_ready;
  assign t_rvalid = c_rvalid; assign t_rdata = c_rdata;
  logic cs, ras, cas, we, cke; logic [1:0] ba; logic [12:0] a; logic [31:0] dqo, dqi; logic dqoe;
  sdram_ctrl u_ctrl(.clk(clk), .rst(rst), .cmd_valid(c_valid), .cmd_wr(c_wr), .cmd_addr(c_addr),
    .cmd_len(9'd1), .rd_last(),
    .cmd_wdata(c_wdata), .cmd_ready(c_ready), .rd_valid(c_rvalid), .rd_data(c_rdata),
    .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .cke(cke), .ba(ba), .a(a),
    .dq_o(dqo), .dq_oe(dqoe), .dq_i(dqi));
  sdram_chip u_chip(.clk(clk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
    .ba(ba), .a(a), .dq_i(dqo), .dq_o(dqi));
endmodule

// SDRAM controller + behavioral chip, exposing golem's command port — for the ctrl unit test.
module sdram_sys (
    input  logic        clk,
    input  logic        rst,
    input  logic        cmd_valid,
    input  logic        cmd_wr,
    input  logic [21:0] cmd_addr,
    input  logic [8:0]  cmd_len,
    input  logic [31:0] cmd_wdata,
    output logic        cmd_ready,
    output logic        rd_valid,
    output logic        rd_last,
    output logic [31:0] rd_data
);
  logic cs, ras, cas, we, cke; logic [1:0] ba; logic [12:0] a;
  logic [31:0] dqo, dqi; logic dqoe;
  sdram_ctrl u_ctrl(.clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_wr(cmd_wr),
    .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wdata(cmd_wdata), .cmd_ready(cmd_ready),
    .rd_valid(rd_valid), .rd_last(rd_last), .rd_data(rd_data),
    .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .cke(cke), .ba(ba), .a(a),
    .dq_o(dqo), .dq_oe(dqoe), .dq_i(dqi));
  sdram_chip u_chip(.clk(clk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
    .ba(ba), .a(a), .dq_i(dqo), .dq_o(dqi));
endmodule

// golem + arbiter + real SDRAM controller + chip model — the full board memory path in sim.
module golem_board (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [11:0] token,
    input  logic [7:0]  pos,
    output logic        busy,
    output logic        tok_valid,
    output logic [11:0] tok_out
);
  logic mrd_req, mrd_valid; logic [21:0] mrd_addr; logic [31:0] mrd_data;
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;
  logic o_valid, o_wr, c_ready, c_rvalid; logic [21:0] o_addr; logic [31:0] o_wdata, c_rdata;
  logic cs, ras, cas, we, cke; logic [1:0] ba; logic [12:0] a; logic [31:0] dqo, dqi; logic dqoe;

  golem u_golem(.clk(clk), .rst(rst), .start(start), .token(token), .pos(pos), .busy(busy),
                .mrd_addr(mrd_addr), .mrd_req(mrd_req), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
                .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
                .tok_valid(tok_valid), .tok_out(tok_out));
  mem_arbiter u_arb(.clk(clk), .rst(rst),
                .mrd_req(mrd_req), .mrd_addr(mrd_addr), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_rreq(krq), .kv_raddr(kra), .kv_rsel(krs), .kv_rvalid(krv), .kv_rdata(krd),
                .kv_we(kw), .kv_waddr(kwa), .kv_wsel(kws), .kv_wdata(kwd),
                .o_valid(o_valid), .o_wr(o_wr), .o_addr(o_addr), .o_wdata(o_wdata),
                .i_ready(c_ready), .i_rvalid(c_rvalid), .i_rdata(c_rdata));
  sdram_ctrl u_ctrl(.clk(clk), .rst(rst), .cmd_valid(o_valid), .cmd_wr(o_wr),
                .cmd_addr(o_addr), .cmd_len(9'd1), .rd_last(),
                .cmd_wdata(o_wdata), .cmd_ready(c_ready),
                .rd_valid(c_rvalid), .rd_data(c_rdata),
                .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .cke(cke), .ba(ba), .a(a),
                .dq_o(dqo), .dq_oe(dqoe), .dq_i(dqi));
  sdram_chip u_chip(.clk(clk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
                .ba(ba), .a(a), .dq_i(dqo), .dq_o(dqi));
endmodule

// golem + arbiter + ONE unified SDRAM — the real board memory architecture, in sim.
module golem_soc (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [11:0] token,
    input  logic [7:0]  pos,
    output logic        busy,
    output logic        tok_valid,
    output logic [11:0] tok_out
);
  logic mrd_req, mrd_valid; logic [21:0] mrd_addr; logic [31:0] mrd_data;
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;
  logic o_valid, o_wr, sd_ready, sd_rvalid; logic [21:0] o_addr; logic [31:0] o_wdata, sd_rdata;

  golem u_golem(.clk(clk), .rst(rst), .start(start), .token(token), .pos(pos), .busy(busy),
                .mrd_addr(mrd_addr), .mrd_req(mrd_req), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
                .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
                .tok_valid(tok_valid), .tok_out(tok_out));
  mem_arbiter u_arb(.clk(clk), .rst(rst),
                .mrd_req(mrd_req), .mrd_addr(mrd_addr), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_rreq(krq), .kv_raddr(kra), .kv_rsel(krs), .kv_rvalid(krv), .kv_rdata(krd),
                .kv_we(kw), .kv_waddr(kwa), .kv_wsel(kws), .kv_wdata(kwd),
                .o_valid(o_valid), .o_wr(o_wr), .o_addr(o_addr), .o_wdata(o_wdata),
                .i_ready(sd_ready), .i_rvalid(sd_rvalid), .i_rdata(sd_rdata));
  sdram_model u_sd(.clk(clk), .cmd_valid(o_valid), .cmd_wr(o_wr), .cmd_addr(o_addr),
                .cmd_wdata(o_wdata), .cmd_ready(sd_ready), .rd_valid(sd_rvalid), .rd_data(sd_rdata));
endmodule

// block + KV memory, for the block-level test (block now has external KV ports)
module block_sim (
    input  logic clk, input logic rst,
    input  logic start, input logic [7:0] t, input logic [2:0] layer, output logic busy,
    input  logic xr_we, input logic [7:0] xr_addr, input logic signed [7:0] xr_data,
    input  logic cfg_we, input logic [2:0] cfg_sel, input logic [30:0] cfg_mult, input logic [5:0] cfg_shift,
    input  logic gc_we, input logic gc_sel, input logic [7:0] gc_addr, input logic signed [7:0] gc_data,
    input  logic p_we, input logic [11:0] p_addr, input logic [30:0] p_mult, input logic [5:0] p_shift,
    input  logic sl_we, input logic [8:0] sl_addr, input logic [16:0] sl_data,
    input  logic gl_we, input logic [7:0] gl_addr, input logic signed [7:0] gl_data,
    input  logic w_valid, input logic signed [7:0] w_data0, w_data1, w_data2, w_data3, output logic w_ready,
    output logic r3_valid, output logic [7:0] r3_idx, output logic signed [7:0] r3_data
);
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;
  block u_block(.clk(clk), .rst(rst), .start(start), .t(t), .layer(layer), .busy(busy),
    .xr_we(xr_we), .xr_addr(xr_addr), .xr_data(xr_data),
    .cfg_we(cfg_we), .cfg_sel(cfg_sel), .cfg_mult(cfg_mult), .cfg_shift(cfg_shift),
    .gc_we(gc_we), .gc_sel(gc_sel), .gc_addr(gc_addr), .gc_data(gc_data),
    .p_we(p_we), .p_addr(p_addr), .p_mult(p_mult), .p_shift(p_shift),
    .sl_we(sl_we), .sl_addr(sl_addr), .sl_data(sl_data),
    .gl_we(gl_we), .gl_addr(gl_addr), .gl_data(gl_data),
    .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
    .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
    .w_valid(w_valid), .w_data0(w_data0), .w_data1(w_data1), .w_data2(w_data2), .w_data3(w_data3),
    .w_ready(w_ready), .r3_valid(r3_valid), .r3_idx(r3_idx), .r3_data(r3_data));
  kv_mem u_kv(.clk(clk), .we(kw), .wsel(kws), .waddr(kwa), .wdata(kwd),
              .rreq(krq), .raddr(kra), .rsel(krs), .rvalid(krv), .rdata(krd));
endmodule

// same command port, but the inout-bus chip model — isolates sdram_chip_io tristate timing.
module sdram_sys_io (
    input  logic        clk,
    input  logic        rst,
    input  logic        cmd_valid,
    input  logic        cmd_wr,
    input  logic [21:0] cmd_addr,
    input  logic [31:0] cmd_wdata,
    output logic        cmd_ready,
    output logic        rd_valid,
    output logic [31:0] rd_data
);
  logic cs, ras, cas, we, cke; logic [1:0] ba; logic [12:0] a;
  logic [31:0] dqo, dqi; logic dqoe;
  wire [31:0] dq = dqoe ? dqo : 32'bz;
  assign dqi = dq;
  sdram_ctrl u_ctrl(.clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_wr(cmd_wr),
    .cmd_addr(cmd_addr), .cmd_len(9'd1), .rd_last(),
    .cmd_wdata(cmd_wdata), .cmd_ready(cmd_ready),
    .rd_valid(rd_valid), .rd_data(rd_data),
    .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .cke(cke), .ba(ba), .a(a),
    .dq_o(dqo), .dq_oe(dqoe), .dq_i(dqi));
  sdram_chip_io u_chip(.clk(clk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
    .ba(ba), .a(a), .dq(dq));
endmodule
