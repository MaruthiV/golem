// Behavioral SDR SDRAM with a real bidirectional (inout) data bus — for the full
// golem_board_top integration sim, which drives its SDRAM pins including tristate dq.
// Same command decode as sdram_chip; the only difference is dq is inout: the chip reads
// it during WRITE and drives it (for a few cycles) during the read-data window.
module sdram_chip_io #(parameter CAS = 2) (
    input  logic        clk,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic [1:0]  ba,
    input  logic [12:0] a,
    inout  wire  [31:0] dq
);
  localparam AW = 21;
  logic [31:0] mem [0:(1<<AW)-1];
  logic [10:0] act_row [0:3];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, mem);
  end

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  localparam CMD_ACT=4'b0011, CMD_RD=4'b0101, CMD_WR=4'b0100;
  wire [AW-1:0] addr = {ba, act_row[ba], a[7:0]};

  logic [31:0] latched, dqreg;
  logic [2:0]  rdcnt, oecnt;
  initial begin rdcnt = 0; oecnt = 0; end   // power up hi-Z (real chip); else X-drive corrupts writes
  always_ff @(posedge clk) begin
    if (cmd == CMD_ACT) act_row[ba] <= a[10:0];
    else if (cmd == CMD_WR) mem[addr] <= dq;
    if (cmd == CMD_RD) begin latched <= mem[addr]; rdcnt <= CAS[2:0]; end
    else if (rdcnt != 0) rdcnt <= rdcnt - 3'd1;
    if (rdcnt == 3'd1) begin dqreg <= latched; oecnt <= 3'd3; end
    else if (oecnt != 0) oecnt <= oecnt - 3'd1;
  end
  assign dq = (oecnt != 0) ? dqreg : 32'bz;   // drive only in the read-data window
endmodule
