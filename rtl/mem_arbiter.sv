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
  logic [1:0] st;  // 0 = idle/issue, 1 = waiting for read data, 2 = cooldown
  logic tag;       // 0 = mrd, 1 = kv

  always_ff @(posedge clk) begin
    o_valid <= 1'b0; mrd_valid <= 1'b0; kv_rvalid <= 1'b0;
    if (rst) begin st <= 2'd0; wpend <= 1'b0; end
    else begin
      case (st)
        2'd0: if (i_ready) begin
          if (wpend) begin
            o_valid <= 1'b1; o_wr <= 1'b1; o_addr <= waddr_l; o_wdata <= wdata_l;
            wpend <= 1'b0;
          end else if (kv_rreq) begin
            o_valid <= 1'b1; o_wr <= 1'b0; o_addr <= kvaddr(kv_rsel, kv_raddr);
            tag <= 1'b1; st <= 2'd1;
          end else if (mrd_req) begin
            o_valid <= 1'b1; o_wr <= 1'b0; o_addr <= mrd_addr;
            tag <= 1'b0; st <= 2'd1;
          end
        end
        2'd1: if (i_rvalid) begin
          if (tag) begin kv_rdata <= i_rdata; kv_rvalid <= 1'b1; end
          else begin mrd_data <= i_rdata; mrd_valid <= 1'b1; end
          st <= 2'd2;  // cooldown: let the consumer advance its address before re-issuing
        end
        2'd2: st <= 2'd0;
      endcase
      // latch a KV write last so it is never dropped by a same-cycle drain
      if (kv_we) begin wpend <= 1'b1; waddr_l <= kvaddr(kv_wsel, kv_waddr); wdata_l <= kv_wdata; end
    end
  end
endmodule
