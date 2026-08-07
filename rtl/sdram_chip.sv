// Behavioral SDR SDRAM model for simulation (the chip on the Tang Nano). Standard SDR
// command protocol: ACTIVE opens a row, READ/WRITE access a column, data returns CAS cycles
// after READ. Burst reads stream sequential columns one word/cycle until the programmed
// burst length runs out, or PRECHARGE / BURST-TERMINATE stops them.
// 32-bit wide and 256 columns/page, per Gowin DS226-2.7E (GW2AR-18 QN88): 32 bits, 166 MHz,
// 4 banks x 512K x 32, 2048 rows x 256 columns, CAS 2 or 3, burst 1/2/4/8/full-page.
module sdram_chip #(parameter CAS = 2) (
    input  logic        clk,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic [1:0]  ba,
    input  logic [12:0] a,
    input  logic [31:0] dq_i,
    output logic [31:0] dq_o,
    output logic        dq_oe      // for the inout wrapper; leave open for the split-bus users
);
  localparam AW = 21;                 // 2M words = 64Mbit at 32-bit
  localparam PAGE = 256;
  logic [31:0] mem [0:(1<<AW)-1];
  logic [10:0] act_row [0:3];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, mem);
  end

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  localparam CMD_ACT=4'b0011, CMD_RD=4'b0101, CMD_WR=4'b0100,
             CMD_PRE=4'b0010, CMD_REF=4'b0001, CMD_LMR=4'b0000, CMD_BST=4'b0110;
  wire [AW-1:0] addr = {ba, act_row[ba], a[7:0]};

  // burst length from the mode register (A2:A0), per the SDR spec
  logic [8:0] blen;
  initial blen = 9'd1;
  function automatic [8:0] decode_bl(input logic [2:0] m);
    case (m)
      3'b000: decode_bl = 9'd1;
      3'b001: decode_bl = 9'd2;
      3'b010: decode_bl = 9'd4;
      3'b011: decode_bl = 9'd8;
      3'b111: decode_bl = 9'(PAGE);
      default: decode_bl = 9'd1;
    endcase
  endfunction

  // in-flight burst
  logic [1:0] rb_bank;
  logic [7:0] rb_col;
  logic [8:0] rb_left;
  wire  [AW-1:0] rb_addr = {rb_bank, act_row[rb_bank], rb_col};

  // CAS delay line: a word fetched this cycle lands on dq_o CAS cycles later
  logic [31:0] dl [0:3];
  logic [3:0]  dv;
  logic [2:0]  oecnt;
  integer k;
  initial begin rb_left = 0; dv = 0; oecnt = 0; end   // power up hi-Z, like a real chip
  assign dq_oe = (oecnt != 0);

  always_ff @(posedge clk) begin
    for (k = 0; k < 3; k = k + 1) begin dl[k] <= dl[k+1]; dv[k] <= dv[k+1]; end
    dv[3] <= 1'b0;

    if (cmd == CMD_LMR) blen <= decode_bl(a[2:0]);
    if (cmd == CMD_ACT) act_row[ba] <= a[10:0];
    else if (cmd == CMD_WR) mem[addr] <= dq_i;

    if (cmd == CMD_RD) begin
      // first word of the burst comes from the addressed column
      dl[CAS-1] <= mem[addr]; dv[CAS-1] <= 1'b1;
      rb_bank <= ba; rb_col <= a[7:0] + 8'd1; rb_left <= blen - 9'd1;
    end else if (cmd == CMD_BST || cmd == CMD_PRE) begin
      rb_left <= 0;                       // stop fetching; in-flight words still drain
    end else if (rb_left != 0) begin
      dl[CAS-1] <= mem[rb_addr]; dv[CAS-1] <= 1'b1;
      rb_col <= rb_col + 8'd1;            // sequential burst wraps inside the page
      rb_left <= rb_left - 9'd1;
    end

    // drive dq for as long as burst data keeps arriving, plus a short tail; a WRITE
    // releases it immediately so the controller's drive can never collide with ours
    if (dv[0]) begin dq_o <= dl[0]; oecnt <= 3'd2; end
    else if (cmd == CMD_WR) oecnt <= 3'd0;
    else if (oecnt != 0) oecnt <= oecnt - 3'd1;
  end
endmodule
