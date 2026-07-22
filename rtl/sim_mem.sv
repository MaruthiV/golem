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
  logic [21:0] a; logic [31:0] d;
  golem u_golem(.clk(clk), .rst(rst), .start(start), .token(token), .pos(pos), .busy(busy),
                .mrd_addr(a), .mrd_data(d), .tok_valid(tok_valid), .tok_out(tok_out));
  sim_mem u_mem(.addr(a), .data(d));
endmodule
