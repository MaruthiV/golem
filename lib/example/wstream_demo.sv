// Reference example for the wstream memory subsystem, with no model attached.
// A synthetic consumer walks a sequential address range one word per cycle, exactly the way a
// decode loop reads weights, and the demo counts what it costs. Two knobs make the point:
//   BYPASS=0  full-page bursts through wstream's ping-pong line buffer
//   BYPASS=1  the same consumer talking straight to the controller, one access per word
// The efficiency counters are the deliverable: reads/cycles is the number to compare.
module wstream_demo #(
    parameter int LB      = 7,          // line = 2^LB words, must be <= one SDRAM page
    parameter int NWORDS  = 4096,       // synthetic "weights" to stream
    parameter int BYPASS  = 0,
    parameter int CLK_MHZ = 27
) (
    input  logic clk,
    input  logic rst,
    output logic done,
    output logic [31:0] cycles,
    output logic [31:0] reads,
    output logic [31:0] mismatches
);
  logic        c_valid, c_wr, c_ready, c_rvalid, c_rlast, init_done;
  logic [21:0] c_addr;
  logic [8:0]  c_len;
  logic [31:0] c_wdata, c_rdata;
  logic [31:0] dq_o, dq_i; logic dq_oe; logic [12:0] a_full;
  wire cs, ras, cas, we, cke; wire [1:0] ba;
  wire  [31:0] dq = dq_oe ? dq_o : 32'bz;
  assign dq_i = dq;

  sdram_ctrl #(.CLK_MHZ(CLK_MHZ), .INIT_NS(2400)) u_ctrl(.clk(clk), .rst(rst),
      .cmd_valid(c_valid), .cmd_wr(c_wr), .cmd_addr(c_addr), .cmd_len(c_len),
      .cmd_wdata(c_wdata), .cmd_ready(c_ready), .init_done(init_done),
      .rd_valid(c_rvalid), .rd_last(c_rlast), .rd_data(c_rdata),
      .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .cke(cke), .ba(ba), .a(a_full),
      .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i));
  sdram_chip_io u_chip(.clk(clk), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
      .ba(ba), .a(a_full), .dq(dq));

  // the consumer: one sequential word per cycle, stalling only when the data is not there
  logic [21:0] rd_addr;
  logic        rd_req;
  logic        mrd_valid; logic [31:0] mrd_data;
  logic [21:0] ws_addr; logic [8:0] ws_len; logic ws_req, ws_valid, ws_last;
  logic [31:0] ws_data;

  function automatic [31:0] expect_at(input [21:0] a);
    expect_at = {a[9:0], a[21:0]} ^ 32'hA5A5_5A5A;
  endfunction

  // phase 0 fills the memory with the pattern so the example needs no data file; only phase 1
  // is measured, since the efficiency claim is about the read stream.
  logic phase;
  logic [21:0] wr_addr;
  logic wr_valid;
  wire  ws_rst = rst | ~phase;

  generate if (BYPASS == 0) begin : g_stream
    wstream #(.LB(LB)) u_ws(.clk(clk), .rst(ws_rst),
        .mrd_req(rd_req), .mrd_addr(rd_addr), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
        .m_req(ws_req), .m_addr(ws_addr), .m_len(ws_len),
        .m_valid(ws_valid), .m_last(ws_last), .m_data(ws_data));
    assign c_valid = phase ? ws_req : wr_valid;
    assign c_wr    = ~phase;
    assign c_addr  = phase ? ws_addr : wr_addr;
    assign c_len   = phase ? ws_len : 9'd1;
    assign c_wdata = expect_at(wr_addr);
    assign ws_valid = c_rvalid; assign ws_last = c_rlast; assign ws_data = c_rdata;
  end else begin : g_direct
    // no line buffer: every word is its own command, which is the pattern to beat
    logic pending;
    assign c_valid = phase ? (rd_req && !pending) : wr_valid;
    assign c_wr    = ~phase;
    assign c_addr  = phase ? rd_addr : wr_addr;
    assign c_len   = 9'd1;
    assign c_wdata = expect_at(wr_addr);
    assign mrd_valid = c_rvalid; assign mrd_data = c_rdata;
    // writes never answer with rd_valid, so the outstanding-read latch only applies once the
    // read phase has started
    always_ff @(posedge clk) begin
      if (rst || !phase) pending <= 1'b0;
      else if (c_valid && c_ready) pending <= 1'b1;
      else if (c_rvalid) pending <= 1'b0;
    end
    assign ws_req = 1'b0; assign ws_addr = 22'd0; assign ws_len = 9'd0;
  end endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_addr <= 22'd0; rd_req <= 1'b0; done <= 1'b0; phase <= 1'b0;
      wr_addr <= 22'd0; wr_valid <= 1'b0;
      cycles <= 32'd0; reads <= 32'd0; mismatches <= 32'd0;
    end else if (!phase) begin
      if (init_done) wr_valid <= 1'b1;
      if (wr_valid && c_ready) begin
        if (wr_addr == 22'(NWORDS - 1)) begin phase <= 1'b1; wr_valid <= 1'b0; end
        else wr_addr <= wr_addr + 22'd1;
      end
    end else if (!done) begin
      rd_req <= 1'b1;
      if (rd_req) cycles <= cycles + 32'd1;
      if (mrd_valid) begin
        reads <= reads + 32'd1;
        if (mrd_data !== expect_at(rd_addr)) mismatches <= mismatches + 32'd1;
        if (rd_addr == 22'(NWORDS - 1)) begin done <= 1'b1; rd_req <= 1'b0; end
        else rd_addr <= rd_addr + 22'd1;
      end
    end
  end
endmodule
