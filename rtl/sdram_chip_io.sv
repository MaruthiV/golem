// sdram_chip with a real bidirectional (inout) data bus — for the full golem_board_top
// integration sim, which drives its SDRAM pins including tristate dq.
// This is a THIN WRAPPER on purpose: it used to be a second hand-written copy of the chip
// model, and the two drifted the moment sdram_chip learned burst reads (the copy still did
// single-word reads with a 3-cycle drive window, so the controller sampled hi-Z and got X).
// Wrapping means there is exactly one model of the chip's behaviour.
module sdram_chip_io #(parameter CAS = 2) (
    input  logic        clk,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic [1:0]  ba,
    input  logic [12:0] a,
    inout  wire  [31:0] dq
);
  logic [31:0] dq_o;
  logic        dq_oe;
  sdram_chip #(.CAS(CAS)) u_chip(
    .clk(clk), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dq_i(dq), .dq_o(dq_o), .dq_oe(dq_oe));
  assign dq = dq_oe ? dq_o : 32'bz;
endmodule
