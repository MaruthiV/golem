// golem_board_top — the actual FPGA top for the Tang Nano 20K. Boot flow:
//   LOAD: host streams the weight image over UART -> weight_loader writes it into SDRAM.
//   RUN:  control FSM drives golem; tokens stream out UART; host maps ids->text.
// NOTE: SDRAM modeled/wired 32-bit (matches the verified sim). Confirm the real chip's
// data width/timing from the datasheet during bring-up and adapt the data phase if 16-bit.
module golem_board_top #(
    parameter CLKS_PER_BIT = 234,          // 27MHz / 115200
    parameter [11:0] START_TOK = 12'd0,
    parameter [7:0]  MAX_TOKENS = 8'd120,
    parameter [21:0] N_WORDS = 22'd1624264
) (
    input  logic        clk27,
    input  logic        rst_n,
    input  logic        uart_rx_pin,
    output logic        uart_tx_pin,
    output logic [5:0]  led,

    // The GW2AR-18's SDRAM is inside the package (SiP). nextpnr-himbaechel wires it up via
    // these EXACT dedicated port names — there are no IO_LOC constraints for SDRAM, which is
    // why nand2mario's working .cst has none. Naming them anything else (we had sdram_cs_n
    // etc.) makes nextpnr treat them as ordinary user I/O and fail with "Unconstrained IO".
    // addr is 11 bits here (2048 rows), not the controller's generic 13.
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output logic [3:0]  O_sdram_dqm,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    inout  wire  [31:0] IO_sdram_dq
);
  wire clk = clk27;
  logic [1:0] rsync;
  always_ff @(posedge clk) rsync <= {rsync[0], ~rst_n};
  wire rst = rsync[1];

  // ---- UART rx -> weight loader ----
  logic [7:0] rx_data; logic rx_valid;
  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx(.clk(clk), .rst(rst), .rx(uart_rx_pin),
                .data(rx_data), .valid(rx_valid));
  logic ld_valid, ld_wr; logic [21:0] ld_addr; logic [31:0] ld_wdata; logic ld_ready, load_done;
  weight_loader #(.N_WORDS(N_WORDS)) u_ld(.clk(clk), .rst(rst),
                .rx_data(rx_data), .rx_valid(rx_valid),
                .cmd_valid(ld_valid), .cmd_wr(ld_wr), .cmd_addr(ld_addr), .cmd_wdata(ld_wdata),
                .cmd_ready(ld_ready), .done(load_done));
  wire loading = !load_done;

  // ---- golem + arbiter (RUN) ----
  wire fsm_rst = rst | loading;   // hold generation until weights are loaded
  logic g_start, g_busy, g_tvalid; logic [11:0] g_token, g_tout; logic [7:0] g_pos;
  logic mrd_req, mrd_valid; logic [21:0] mrd_addr; logic [31:0] mrd_data;
  logic ws_req, ws_valid, ws_last; logic [21:0] ws_addr; logic [8:0] ws_len; logic [31:0] ws_data;
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;
  logic arb_valid, arb_wr; logic [21:0] arb_addr; logic [31:0] arb_wdata; logic arb_ready;
  logic [8:0] arb_len;
  logic c_valid, c_wr; logic [21:0] c_addr; logic [31:0] c_wdata, c_rdata;
  logic [8:0] c_len; logic c_ready, c_rvalid, c_rlast;

  golem u_golem(.clk(clk), .rst(fsm_rst), .start(g_start), .token(g_token), .pos(g_pos),
                .busy(g_busy), .mrd_addr(mrd_addr), .mrd_req(mrd_req), .mrd_valid(mrd_valid),
                .mrd_data(mrd_data), .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
                .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
                .tok_valid(g_tvalid), .tok_out(g_tout));
  wstream #(.LB(7)) u_ws(.clk(clk), .rst(fsm_rst),
                .mrd_req(mrd_req), .mrd_addr(mrd_addr), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .m_req(ws_req), .m_addr(ws_addr), .m_len(ws_len),
                .m_valid(ws_valid), .m_last(ws_last), .m_data(ws_data));
  mem_arbiter u_arb(.clk(clk), .rst(fsm_rst),
                .mrd_req(ws_req), .mrd_addr(ws_addr), .mrd_len(ws_len),
                .mrd_valid(ws_valid), .mrd_last(ws_last), .mrd_data(ws_data),
                .kv_rreq(krq), .kv_raddr(kra), .kv_rsel(krs), .kv_rvalid(krv), .kv_rdata(krd),
                .kv_we(kw), .kv_waddr(kwa), .kv_wsel(kws), .kv_wdata(kwd),
                .o_valid(arb_valid), .o_wr(arb_wr), .o_addr(arb_addr), .o_len(arb_len),
                .o_wdata(arb_wdata),
                .i_ready(arb_ready), .i_rvalid(c_rvalid), .i_rlast(c_rlast), .i_rdata(c_rdata));

  // ---- SDRAM command port mux: loader owns it while loading, arbiter while running ----
  assign c_valid = loading ? ld_valid : arb_valid;
  assign c_wr    = loading ? ld_wr    : arb_wr;
  assign c_addr  = loading ? ld_addr  : arb_addr;
  assign c_len   = loading ? 9'd1     : arb_len;
  assign c_wdata = loading ? ld_wdata : arb_wdata;
  assign ld_ready  = loading ? c_ready : 1'b0;
  assign arb_ready = loading ? 1'b0    : c_ready;

  logic [31:0] dq_o, dq_i; logic dq_oe; logic [12:0] a_full;
  sdram_ctrl u_ctrl(.clk(clk), .rst(rst), .cmd_valid(c_valid), .cmd_wr(c_wr),
                .cmd_addr(c_addr), .cmd_len(c_len), .rd_last(c_rlast),
                .cmd_wdata(c_wdata), .cmd_ready(c_ready),
                .rd_valid(c_rvalid), .rd_data(c_rdata),
                .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n), .cas_n(O_sdram_cas_n),
                .we_n(O_sdram_wen_n), .cke(O_sdram_cke), .ba(O_sdram_ba), .a(a_full),
                .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i));
  assign O_sdram_addr = a_full[10:0];       // 2048 rows; A10 is also the auto-precharge bit
  assign O_sdram_dqm  = 4'b0000;            // never mask: every access is a full 32-bit word
  assign O_sdram_clk  = clk;                // TODO(bring-up): may need a PLL phase shift
  assign IO_sdram_dq = dq_oe ? dq_o : 32'bz;   // tristate the bidirectional data bus
  assign dq_i = IO_sdram_dq;

  // ---- UART tx ----
  logic u_send, u_busy; logic [7:0] u_data;
  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx(.clk(clk), .rst(rst), .send(u_send), .data(u_data),
                .tx(uart_tx_pin), .busy(u_busy));

  // ---- control FSM (autonomous generation, started once weights are loaded) ----
  localparam C_INIT=0, C_START=1, C_STARTW=2, C_WAIT=3, C_HI=4, C_HIA=5, C_HID=6,
             C_LO=7, C_LOA=8, C_LOD=9, C_NEXT=10, C_DONE=11;
  logic [3:0] cst; logic [11:0] cur; logic [7:0] pos; logic story_done;
  always_ff @(posedge clk) begin
    g_start <= 1'b0; u_send <= 1'b0;
    if (fsm_rst) begin cst <= C_INIT; story_done <= 1'b0; end
    else case (cst)
      C_INIT:   begin cur <= START_TOK; pos <= 8'd0; cst <= C_START; end
      C_START:  begin g_token <= cur; g_pos <= pos; g_start <= 1'b1; cst <= C_STARTW; end
      C_STARTW: cst <= C_WAIT;
      C_WAIT:   if (g_tvalid) begin cur <= g_tout; cst <= C_HI; end
      C_HI:     if (!u_busy) begin u_send <= 1'b1; u_data <= {4'd0, cur[11:8]}; cst <= C_HIA; end
      C_HIA:    if (u_busy) cst <= C_HID;
      C_HID:    if (!u_busy) cst <= C_LO;
      C_LO:     if (!u_busy) begin u_send <= 1'b1; u_data <= cur[7:0]; cst <= C_LOA; end
      C_LOA:    if (u_busy) cst <= C_LOD;
      C_LOD:    if (!u_busy) cst <= C_NEXT;
      C_NEXT:   begin pos <= pos + 8'd1;
                if (pos == MAX_TOKENS - 8'd1 || cur == START_TOK) cst <= C_DONE; else cst <= C_START; end
      C_DONE:   story_done <= 1'b1;
      default:  cst <= C_INIT;
    endcase
  end

  assign led = {story_done, ~load_done, load_done, g_busy, 2'b0};
endmodule
