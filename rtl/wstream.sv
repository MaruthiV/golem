// Read-ahead line buffer on golem's weight/config read path. T30 measured that S_WT (81%) and
// S_LG (16%) of a token are strictly sequential address streams, so one burst fills a whole line
// and the next LINE-1 reads are free. The read is asynchronous, so a hit costs ZERO cycles --
// golem's FSM was written against 0-latency memory and this restores that on every hit.
// LINE is one SDRAM page (256 words), and requests are page-aligned, so a burst never crosses a
// row (a sequential SDRAM burst wraps inside its page, which would silently read the wrong row).
// Only golem's mrd path goes through here. KV lives at MEM_KV_BASE and above, weights/configs
// strictly below, so KV writes can never alias this line and no invalidation is needed.
module wstream #(parameter LB = 8) (
    input  logic clk,
    input  logic rst,

    // golem side: combinational on a hit
    input  logic        mrd_req,
    input  logic [21:0] mrd_addr,
    output logic        mrd_valid,
    output logic [31:0] mrd_data,

    // memory side: one aligned burst per line
    output logic        m_req,
    output logic [21:0] m_addr,
    output logic [8:0]  m_len,
    input  logic        m_valid,
    input  logic        m_last,
    input  logic [31:0] m_data
);
  localparam LINE = 1 << LB;

  logic [31:0]     line [0:LINE-1];
  logic [21-LB:0]  tag, fill_tag;
  logic            tag_valid, filling;
  logic [LB-1:0]   fill_idx;

  wire [21-LB:0] req_tag = mrd_addr[21:LB];
  wire hit = tag_valid && (req_tag == tag);

  assign mrd_valid = mrd_req && hit;
  assign mrd_data  = line[mrd_addr[LB-1:0]];

  // hold the request for the whole fill; the arbiter is busy until the burst ends, so it
  // cannot double-issue, and dropping m_req on m_last stops it re-issuing after cooldown
  assign m_req  = filling;
  assign m_addr = {fill_tag, {LB{1'b0}}};
  assign m_len  = 9'(LINE);

  always_ff @(posedge clk) begin
    if (rst) begin
      filling <= 1'b0; tag_valid <= 1'b0;
    end else if (!filling) begin
      if (mrd_req && !hit) begin
        filling <= 1'b1; fill_tag <= req_tag; fill_idx <= '0;
        tag_valid <= 1'b0;            // no hits while the line is in flight
      end
    end else if (m_valid) begin
      line[fill_idx] <= m_data;
      fill_idx <= fill_idx + 1'b1;
      if (m_last) begin filling <= 1'b0; tag <= fill_tag; tag_valid <= 1'b1; end
    end
  end
endmodule
