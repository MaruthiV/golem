// Multiplex golem's three memory accessors onto the ONE SDRAM command port:
//   - weight/config reads (mrd)   - KV cache reads   - KV cache writes
// Priority: pending write > KV read > weight read (so attention makes progress).
// Reads are single-outstanding; writes are posted via a 1-deep latch (KV writes are
// sparse — ~1 per 260 cycles — so they always drain before the next).
module mem_arbiter (
    input  logic        clk,
    input  logic        rst,

    input  logic        mrd_req,
    input  logic [21:0] mrd_addr,
    output logic        mrd_valid,
    output logic [31:0] mrd_data,

    input  logic        kv_rreq,
    input  logic [16:0] kv_raddr,
    input  logic        kv_rsel,
    output logic        kv_rvalid,
    output logic [31:0] kv_rdata,

    input  logic        kv_we,
    input  logic [16:0] kv_waddr,
    input  logic        kv_wsel,
    input  logic [31:0] kv_wdata,

    output logic        o_valid,
    output logic        o_wr,
    output logic [21:0] o_addr,
    output logic [31:0] o_wdata,
    input  logic        i_ready,
    input  logic        i_rvalid,
    input  logic [31:0] i_rdata
);
  `include "golem_mem.svh"
  // K region at KV_BASE, V region 131072 words later
  function automatic [21:0] kvaddr(input logic sel, input logic [16:0] a);
    kvaddr = 22'(MEM_KV_BASE) + (sel ? 22'd0 : 22'd131072) + {5'd0, a};
  endfunction

  logic wpend; logic [21:0] waddr_l; logic [31:0] wdata_l;
  logic [2:0] st;  // 0 pick, 1 issue-write, 2 issue-read, 3 wait-data, 4 cooldown
  logic tag;       // 0 = mrd, 1 = kv

  // held-valid handshake: o_valid stays asserted until (o_valid && i_ready) — the command
  // is never lost to a refresh, since i_ready (cmd_ready) truly means "accepted this cycle".
  always_ff @(posedge clk) begin
    o_valid <= 1'b0; mrd_valid <= 1'b0; kv_rvalid <= 1'b0;
    if (rst) begin st <= 3'd0; wpend <= 1'b0; end
    else begin
      case (st)
        3'd0: begin  // pick a request
          if (wpend) begin
            o_valid <= 1'b1; o_wr <= 1'b1; o_addr <= waddr_l; o_wdata <= wdata_l;
            wpend <= 1'b0; st <= 3'd1;
          end else if (kv_rreq) begin
            o_valid <= 1'b1; o_wr <= 1'b0; o_addr <= kvaddr(kv_rsel, kv_raddr);
            tag <= 1'b1; st <= 3'd2;
          end else if (mrd_req) begin
            o_valid <= 1'b1; o_wr <= 1'b0; o_addr <= mrd_addr;
            tag <= 1'b0; st <= 3'd2;
          end
        end
        3'd1: begin o_valid <= 1'b1; if (i_ready) begin o_valid <= 1'b0; st <= 3'd0; end end
        3'd2: begin o_valid <= 1'b1; if (i_ready) begin o_valid <= 1'b0; st <= 3'd3; end end
        3'd3: if (i_rvalid) begin
          if (tag) begin kv_rdata <= i_rdata; kv_rvalid <= 1'b1; end
          else begin mrd_data <= i_rdata; mrd_valid <= 1'b1; end
          st <= 3'd4;  // cooldown: let the consumer advance its address before re-issuing
        end
        3'd4: st <= 3'd0;
      endcase
      if (kv_we) begin wpend <= 1'b1; waddr_l <= kvaddr(kv_wsel, kv_waddr); wdata_l <= kv_wdata; end
    end
  end
endmodule
