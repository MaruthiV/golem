// Synthesizable board top: the whole chip EXCEPT the SDRAM controller, whose command
// port is exposed. On the board, connect (o_*/i_*) to the open Tang Nano SDRAM
// controller, whose SDRAM pins become the real top-level ports. This variant is what
// gets synthesized/placed-and-routed for the fabric fit + timing (Fmax); the behavioral
// sdram_model used in sim is not synthesizable.
module golem_fpga #(
    parameter CLKS_PER_BIT = 234,
    parameter [11:0] START_TOK = 12'd0,
    parameter [7:0]  MAX_TOKENS = 8'd64
) (
    input  logic clk,
    input  logic rst_n,
    output logic uart,
    output logic done,

    // SDRAM controller command port (wire to the open GW2AR SDRAM controller on board)
    output logic        o_valid,
    output logic        o_wr,
    output logic [21:0] o_addr,
    output logic [31:0] o_wdata,
    input  logic        i_ready,
    input  logic        i_rvalid,
    input  logic [31:0] i_rdata
);
  logic [1:0] rsync;
  always_ff @(posedge clk) rsync <= {rsync[0], ~rst_n};
  wire rst = rsync[1];

  logic g_start, g_busy, g_tvalid; logic [11:0] g_token, g_tout; logic [7:0] g_pos;
  logic mrd_req, mrd_valid; logic [21:0] mrd_addr; logic [31:0] mrd_data;
  logic kw, kws, krs, krq, krv; logic [16:0] kwa, kra; logic [31:0] kwd, krd;

  golem u_golem(.clk(clk), .rst(rst), .start(g_start), .token(g_token), .pos(g_pos), .busy(g_busy),
                .mrd_addr(mrd_addr), .mrd_req(mrd_req), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_we(kw), .kv_wsel(kws), .kv_waddr(kwa), .kv_wdata(kwd),
                .kv_raddr(kra), .kv_rsel(krs), .kv_rreq(krq), .kv_rvalid(krv), .kv_rdata(krd),
                .tok_valid(g_tvalid), .tok_out(g_tout));
  mem_arbiter u_arb(.clk(clk), .rst(rst),
                .mrd_req(mrd_req), .mrd_addr(mrd_addr), .mrd_valid(mrd_valid), .mrd_data(mrd_data),
                .kv_rreq(krq), .kv_raddr(kra), .kv_rsel(krs), .kv_rvalid(krv), .kv_rdata(krd),
                .kv_we(kw), .kv_waddr(kwa), .kv_wsel(kws), .kv_wdata(kwd),
                .o_valid(o_valid), .o_wr(o_wr), .o_addr(o_addr), .o_wdata(o_wdata),
                .i_ready(i_ready), .i_rvalid(i_rvalid), .i_rdata(i_rdata));

  logic u_send, u_busy; logic [7:0] u_data;
  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart(.clk(clk), .rst(rst), .send(u_send), .data(u_data),
                .tx(uart), .busy(u_busy));

  localparam C_INIT=0, C_START=1, C_STARTW=2, C_WAIT=3, C_HI=4, C_HIA=5, C_HID=6,
             C_LO=7, C_LOA=8, C_LOD=9, C_NEXT=10, C_DONE=11;
  logic [3:0] cst; logic [11:0] cur; logic [7:0] pos;
  always_ff @(posedge clk) begin
    g_start <= 1'b0; u_send <= 1'b0;
    if (rst) begin cst <= C_INIT; done <= 1'b0; end
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
      C_DONE:   done <= 1'b1;
      default:  cst <= C_INIT;
    endcase
  end
endmodule
