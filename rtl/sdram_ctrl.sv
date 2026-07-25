// SDR SDRAM controller: golem's command port (o_*/i_*) on one side, SDRAM pins on the
// other. Auto-precharge per access (one open row at a time -> no bank tracking), periodic
// auto-refresh. Timing params are small for sim; on the board set them from the chip
// datasheet (CAS, tRCD, tRP, tRFC, refresh interval) and tune via the SDRAM self-test.
module sdram_ctrl #(
    parameter INIT_WAIT = 64,
    parameter REFRESH_INT = 700,   // cycles between refreshes (board: tREFI * fclk)
    parameter tRCD = 2, parameter CAS = 2, parameter tRP = 2, parameter tRFC = 5
) (
    input  logic clk,
    input  logic rst,

    input  logic        cmd_valid,
    input  logic        cmd_wr,
    input  logic [21:0]  cmd_addr,
    input  logic [31:0]  cmd_wdata,
    output logic        cmd_ready,
    output logic        rd_valid,
    output logic [31:0] rd_data,

    output logic        cs_n, ras_n, cas_n, we_n,
    output logic        cke,
    output logic [1:0]  ba,
    output logic [12:0] a,
    output logic [31:0] dq_o,
    output logic        dq_oe,
    input  logic [31:0] dq_i
);
  localparam [3:0] C_NOP=4'b0111, C_ACT=4'b0011, C_RD=4'b0101, C_WR=4'b0100,
                   C_PRE=4'b0010, C_REF=4'b0001, C_LMR=4'b0000;
  localparam S_INIT=0, S_PRE=1, S_REF0=2, S_LMR=3, S_IDLE=4, S_ACT=5, S_RCD=6,
             S_RD=7, S_CAS=8, S_WR=9, S_RP=10, S_REF=11;

  logic [3:0]  st;
  logic [3:0]  cmd;
  logic [15:0] tcnt;
  logic [15:0] refctr;
  logic [3:0]  initref;
  logic        pend_wr; logic [21:0] pend_addr; logic [31:0] pend_wdata;

  wire [1:0]  b_bank = cmd_addr[20:19];
  wire [10:0] b_row  = cmd_addr[18:8];
  wire [7:0]  b_col  = cmd_addr[7:0];
  wire refresh_due = (refctr >= REFRESH_INT);

  assign {cs_n, ras_n, cas_n, we_n} = cmd;
  assign cke = 1'b1;

  always_ff @(posedge clk) begin
    cmd <= C_NOP; rd_valid <= 1'b0; cmd_ready <= 1'b0; dq_oe <= 1'b0;
    refctr <= refctr + 16'd1;
    if (rst) begin st <= S_INIT; tcnt <= INIT_WAIT; refctr <= 0; end
    else case (st)
      S_INIT: if (tcnt == 0) begin cmd <= C_PRE; a <= 13'h400; st <= S_PRE; tcnt <= tRP; end
              else tcnt <= tcnt - 16'd1;
      S_PRE:  if (tcnt == 0) begin cmd <= C_REF; st <= S_REF0; tcnt <= tRFC; initref <= 4'd7; end
              else tcnt <= tcnt - 16'd1;
      S_REF0: if (tcnt == 0) begin
                if (initref == 0) begin cmd <= C_LMR; a <= 13'h022; ba <= 2'd0; st <= S_LMR; tcnt <= 4; end
                else begin cmd <= C_REF; initref <= initref - 4'd1; tcnt <= tRFC; end
              end else tcnt <= tcnt - 16'd1;
      S_LMR:  if (tcnt == 0) begin st <= S_IDLE; refctr <= 0; end else tcnt <= tcnt - 16'd1;
      S_IDLE: begin
        if (refresh_due) begin cmd <= C_REF; refctr <= 0; st <= S_REF; tcnt <= tRFC; end
        else begin
          cmd_ready <= 1'b1;
          if (cmd_valid) begin
            cmd_ready <= 1'b0;
            pend_wr <= cmd_wr; pend_addr <= cmd_addr; pend_wdata <= cmd_wdata;
            cmd <= C_ACT; ba <= b_bank; a <= {2'b0, b_row}; st <= S_ACT; tcnt <= tRCD;
          end
        end
      end
      S_ACT: if (tcnt == 0) begin
               ba <= pend_addr[20:19];
               a <= {2'b0, 1'b1, 2'b0, pend_addr[7:0]};   // A10=1 auto-precharge, col in a[7:0]
               if (pend_wr) begin cmd <= C_WR; dq_o <= pend_wdata; dq_oe <= 1'b1; st <= S_WR; tcnt <= tRP; end
               else begin cmd <= C_RD; st <= S_CAS; tcnt <= CAS + 2; end   // +2: registered cmd + registered dq_o
             end else tcnt <= tcnt - 16'd1;
      S_CAS: if (tcnt == 0) begin rd_data <= dq_i; rd_valid <= 1'b1; st <= S_RP; tcnt <= tRP; end
             else tcnt <= tcnt - 16'd1;
      S_WR:  if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      S_RP:  if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      S_REF: if (tcnt == 0) st <= S_IDLE; else tcnt <= tcnt - 16'd1;
      default: st <= S_IDLE;
    endcase
  end
endmodule
