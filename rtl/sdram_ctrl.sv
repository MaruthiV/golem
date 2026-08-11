// SDR SDRAM controller: golem's command port on one side, SDRAM pins on the other.
// Reads are BURSTS: one ACTIVE opens a row, then cmd_len sequential words stream out one per
// cycle, then an explicit PRECHARGE. This amortizes tRCD/CAS/tRP over the whole burst instead
// of paying them per word (T30 measured 11.0 cycles/word of that overhead). Writes keep
// per-access auto-precharge — they are sparse (KV only) and not worth the complexity.
// Mode register is programmed full-page + sequential, so any cmd_len up to the page works.
// Timings are given in NANOSECONDS and converted to cycles from CLK_MHZ, so the controller is
// correct at any clock instead of only at the one it was tuned for. Values are the SDR numbers
// nand2mario's Tang Nano 20K controller uses on this exact SiP part (tRCD/tRP 15 ns, tRC 60 ns,
// CAS 2) — Gowin DS226-2.7E gives access time and CAS but not the full timing table. Treat them
// as conservative-until-confirmed and tighten against the SDRAM self-test at bring-up.
// Refresh: the part needs 4,096 refreshes per 64 ms = one per 15.625 us. Refresh is only taken
// in S_IDLE, so the interval is shortened by a worst-case burst (MAXLEN) to leave room.
module sdram_ctrl #(
    parameter int CLK_MHZ  = 27,
    parameter int tRCD_NS  = 15,
    parameter int tRP_NS   = 15,
    parameter int tRC_NS   = 60,      // also used for tRFC
    parameter int tREFI_NS = 15625,
    parameter int INIT_NS  = 200000,  // power-up NOP wait before the first command
    parameter int CAS      = 2,
    parameter int PAGE     = 256,
    parameter int MAXLEN   = 256      // longest burst a requester may ask for
) (
    input  logic clk,
    input  logic rst,

    input  logic        cmd_valid,
    input  logic        cmd_wr,
    input  logic [21:0] cmd_addr,
    input  logic [8:0]  cmd_len,     // sequential words to read (1..PAGE); ignored for writes
    input  logic [31:0] cmd_wdata,
    output logic        cmd_ready,
    output logic        init_done,   // low until the power-up sequence has finished
    output logic        rd_valid,
    output logic        rd_last,     // high with the final word of a burst
    output logic [31:0] rd_data,

    output logic        cs_n, ras_n, cas_n, we_n,
    output logic        cke,
    output logic [1:0]  ba,
    output logic [12:0] a,
    output logic [31:0] dq_o,
    output logic        dq_oe,
    input  logic [31:0] dq_i
);
  function automatic int ns2cyc(input int ns);
    ns2cyc = (ns * CLK_MHZ + 999) / 1000;
  endfunction
  // tcnt is a countdown that fires at 0, so a stored value of N enforces N+1 cycles
  localparam int C_RCD = ns2cyc(tRCD_NS), C_RP = ns2cyc(tRP_NS), C_RFC = ns2cyc(tRC_NS);
  localparam int C_REFI = ns2cyc(tREFI_NS);
  localparam [15:0] tRCD = 16'(C_RCD > 0 ? C_RCD - 1 : 0);
  localparam [15:0] tRP  = 16'(C_RP  > 0 ? C_RP  - 1 : 0);
  localparam [15:0] tRFC = 16'(C_RFC > 0 ? C_RFC - 1 : 0);
  localparam [15:0] INIT_WAIT = 16'(ns2cyc(INIT_NS));
  localparam [15:0] REFRESH_INT = 16'(C_REFI > MAXLEN + 8 ? C_REFI - MAXLEN - 8 : 8);

  localparam [3:0] C_NOP=4'b0111, C_ACT=4'b0011, C_RD=4'b0101, C_WR=4'b0100,
                   C_PRE=4'b0010, C_REF=4'b0001, C_LMR=4'b0000;
  localparam S_INIT=0, S_PRE=1, S_REF0=2, S_LMR=3, S_IDLE=4, S_ACT=5, S_STREAM=6,
             S_PCH=7, S_CAS=8, S_WR=9, S_RP=10, S_REF=11;

  logic [3:0]  st;
  logic [3:0]  cmd;
  logic [15:0] tcnt;
  logic [15:0] refctr;
  logic [3:0]  initref;
  logic        pend_wr; logic [21:0] pend_addr; logic [31:0] pend_wdata;
  logic [8:0]  pend_len, left;

  wire [1:0]  b_bank = cmd_addr[20:19];
  wire [10:0] b_row  = cmd_addr[18:8];
  wire [7:0]  b_col  = cmd_addr[7:0];
  wire refresh_due = (refctr >= REFRESH_INT);
  // a sequential burst wraps inside the page, so never let one cross a row boundary
  wire [8:0] page_left = 9'(PAGE) - {1'b0, b_col};
  wire [8:0] eff_len = (cmd_len == 0) ? 9'd1
                     : (cmd_len > page_left) ? page_left : cmd_len;

  assign {cs_n, ras_n, cas_n, we_n} = cmd;
  assign cke = 1'b1;
  // combinational: accurately reflects "I will accept a command THIS cycle" (no refresh race)
  assign cmd_ready = (st == S_IDLE) && !refresh_due;
  // the 200 us power-up is real: anything upstream that streams data in must wait for this,
  // or it spends the whole init window talking to a controller that cannot accept a word.
  assign init_done = (st != S_INIT) && (st != S_PRE) && (st != S_REF0) && (st != S_LMR);

  always_ff @(posedge clk) begin
    cmd <= C_NOP; rd_valid <= 1'b0; rd_last <= 1'b0; dq_oe <= 1'b0;
    refctr <= refctr + 16'd1;
    if (rst) begin st <= S_INIT; tcnt <= INIT_WAIT; refctr <= 0; end
    else case (st)
      S_INIT: if (tcnt == 0) begin cmd <= C_PRE; a <= 13'h400; st <= S_PRE; tcnt <= tRP; end
              else tcnt <= tcnt - 16'd1;
      S_PRE:  if (tcnt == 0) begin cmd <= C_REF; st <= S_REF0; tcnt <= tRFC; initref <= 4'd7; end
              else tcnt <= tcnt - 16'd1;
      S_REF0: if (tcnt == 0) begin
                // mode register: full-page burst, sequential, CAS latency
                if (initref == 0) begin
                  cmd <= C_LMR; a <= {6'b0, 3'(CAS), 1'b0, 3'b111}; ba <= 2'd0;
                  st <= S_LMR; tcnt <= 4;
                end
                else begin cmd <= C_REF; initref <= initref - 4'd1; tcnt <= tRFC; end
              end else tcnt <= tcnt - 16'd1;
      S_LMR:  if (tcnt == 0) begin st <= S_IDLE; refctr <= 0; end else tcnt <= tcnt - 16'd1;
      S_IDLE: begin
        if (refresh_due) begin cmd <= C_REF; refctr <= 0; st <= S_REF; tcnt <= tRFC; end
        else if (cmd_valid) begin
          pend_wr <= cmd_wr; pend_addr <= cmd_addr; pend_wdata <= cmd_wdata;
          pend_len <= eff_len;
          // synthesis translate_off
          if (!cmd_wr && cmd_len > page_left && cmd_len != 0)
            $display("[sdram_ctrl] burst clamped %0d->%0d at col %0d (requester should page-align)",
                     cmd_len, page_left, b_col);
          // synthesis translate_on
          cmd <= C_ACT; ba <= b_bank; a <= {2'b0, b_row}; st <= S_ACT; tcnt <= tRCD;
        end
      end
      S_ACT: if (tcnt == 0) begin
               ba <= pend_addr[20:19];
               if (pend_wr) begin
                 a <= {2'b0, 1'b1, 2'b0, pend_addr[7:0]};   // A10=1 auto-precharge for writes
                 cmd <= C_WR; dq_o <= pend_wdata; dq_oe <= 1'b1; st <= S_WR; tcnt <= tRP;
               end else begin
                 // A10=0: no auto-precharge. The mode register is full-page, and auto-precharge
                 // is not usable with a full-page burst — S_PCH closes the row explicitly instead.
                 a <= {2'b0, 1'b0, 2'b0, pend_addr[7:0]};
                 // +1: cmd is registered, so the chip sees C_RD one cycle late, and its dq_o is
                 // registered too. The first word is on dq_i exactly CAS+1 edges after this one;
                 // it does NOT hold, because a burst advances dq_o every cycle.
                 cmd <= C_RD; st <= S_CAS; tcnt <= CAS + 1;
               end
             end else tcnt <= tcnt - 16'd1;
      // first word of the burst
      S_CAS: if (tcnt == 0) begin
               rd_data <= dq_i; rd_valid <= 1'b1;
               if (pend_len <= 9'd1) begin rd_last <= 1'b1; st <= S_PCH; end
               else begin left <= pend_len - 9'd1; st <= S_STREAM; end
             end else tcnt <= tcnt - 16'd1;
      // remaining words: one per cycle, no further commands
      S_STREAM: begin
        rd_data <= dq_i; rd_valid <= 1'b1;
        if (left == 9'd1) begin rd_last <= 1'b1; st <= S_PCH; end
        else left <= left - 9'd1;
      end
      // PRECHARGE also terminates the burst, so no separate BURST-TERMINATE needed
      S_PCH: begin cmd <= C_PRE; a <= 13'h400; st <= S_RP; tcnt <= tRP; end
      S_WR:  if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      S_RP:  if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      S_REF: if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      default: st <= S_IDLE;
    endcase
  end
endmodule
