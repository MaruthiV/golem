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
