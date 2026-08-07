// Read-ahead line buffer on golem's weight/config read path. T30 measured that S_WT (81%) and
// S_LG (16%) of a token are strictly sequential address streams, so one burst fills a whole line
// and the next LINE-1 reads are free. The read is asynchronous, so a hit costs ZERO cycles --
// golem's FSM was written against 0-latency memory and this restores that on every hit.
//
// Two lines, ping-pong: while golem consumes one, the next is already being fetched, so the fill
// and the compute overlap instead of serializing (T34b measured the SDRAM idle 48.7% of the time
// with a single line). Steady-state cost becomes max(fill, consume) rather than fill + consume.
//
// Lines are page-aligned and LINE <= one SDRAM page, so a burst never crosses a row (a sequential
// SDRAM burst wraps inside its page, which would silently read the wrong row).
// Only golem's mrd path goes through here. KV lives at MEM_KV_BASE and above, weights/configs
// strictly below, so KV writes can never alias these lines and no invalidation is needed.
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
  localparam TW = 22 - LB;                  // tag width

  logic [31:0]    line [0:2*LINE-1];        // {sel, idx}
  logic [TW-1:0]  tag  [0:1];
  logic [1:0]     tv;
  logic           filling, fill_sel;
  logic [TW-1:0]  fill_tag;
  logic [LB-1:0]  fill_idx;

  wire [TW-1:0]  req_tag = mrd_addr[21:LB];
  wire [LB-1:0]  req_idx = mrd_addr[LB-1:0];
  wire hit0 = tv[0] && (tag[0] == req_tag);
  wire hit1 = tv[1] && (tag[1] == req_tag);
  wire hit  = hit0 || hit1;
  wire sel  = hit0 ? 1'b0 : 1'b1;

  assign mrd_valid = mrd_req && hit;
  assign mrd_data  = line[{sel, req_idx}];

  // the line after the one being served — what the prefetch goes after
  wire [TW-1:0] next_tag = req_tag + 1'b1;
  wire have_next = (tv[0] && tag[0] == next_tag) || (tv[1] && tag[1] == next_tag);

  // fill the line we are NOT serving from, so a fill never clobbers the line in use
  wire victim = hit0 ? 1'b1 : 1'b0;
  wire start_demand = mrd_req && !hit;          // blocking: golem is stalled on this
  wire start_pre    = mrd_req && hit && !have_next;   // overlapped: golem keeps consuming

  assign m_req  = filling;
  assign m_addr = {fill_tag, {LB{1'b0}}};
  assign m_len  = 9'(LINE);

  always_ff @(posedge clk) begin
    if (rst) begin
      filling <= 1'b0; tv <= 2'b00;
    end else if (!filling) begin
      if (start_demand || start_pre) begin
        filling  <= 1'b1;
        fill_sel <= victim;
        fill_tag <= start_demand ? req_tag : next_tag;
        fill_idx <= '0;
        tv[victim] <= 1'b0;                 // no hits on a line that is mid-flight
      end
    end else if (m_valid) begin
      line[{fill_sel, fill_idx}] <= m_data;
      fill_idx <= fill_idx + 1'b1;
      if (m_last) begin
        filling <= 1'b0;
        tag[fill_sel] <= fill_tag;
        tv[fill_sel]  <= 1'b1;
      end
    end
  end
endmodule
