// Behavioral SDR SDRAM model for simulation (the chip on the Tang Nano). Standard SDR
// command protocol: ACTIVE opens a row, READ/WRITE (with A10 auto-precharge) access a
// column, data returns CAS cycles after READ. Single-outstanding access (the controller
// uses auto-precharge, one transaction at a time) so a counter models CAS latency.
// Modeled 32-bit wide; a 16-bit board chip is the same protocol with a burst-of-2 data
// phase — adapt only the data stage in sdram_ctrl.
module sdram_chip #(parameter CAS = 2) (
    input  logic        clk,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic [1:0]  ba,
    input  logic [12:0] a,
    input  logic [31:0] dq_i,
    output logic [31:0] dq_o
);
  localparam AW = 21;                 // 2M words = 64Mbit at 32-bit
  logic [31:0] mem [0:(1<<AW)-1];
  logic [10:0] act_row [0:3];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, mem);
  end

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  localparam CMD_ACT=4'b0011, CMD_RD=4'b0101, CMD_WR=4'b0100,
             CMD_PRE=4'b0010, CMD_REF=4'b0001, CMD_LMR=4'b0000;
  wire [AW-1:0] addr = {ba, act_row[ba], a[7:0]};

  logic [31:0] latched;
  logic [2:0]  rdcnt;
  always_ff @(posedge clk) begin
    if (cmd == CMD_ACT) act_row[ba] <= a[10:0];
    else if (cmd == CMD_WR) mem[addr] <= dq_i;
    if (cmd == CMD_RD) begin latched <= mem[addr]; rdcnt <= CAS[2:0]; end
    else if (rdcnt != 0) rdcnt <= rdcnt - 3'd1;
    if (rdcnt == 3'd1) dq_o <= latched;   // data on dq_o CAS cycles after READ
  end
endmodule
