// SDRAM self-test: the bring-up design that runs BEFORE golem, and the thing gate G7 sweeps.
// Writes an address-dependent pattern across all 4 banks and 4 rows, bursts it back, compares.
// Result goes to the LEDs and repeats over UART as ASCII: "P e0000 c066 p06\r\n" — readable in
// any serial monitor, so a phase sweep is just: rebuild with PHASE=n, flash, look at the letter.
// Bursts (not single words) because that is how golem actually reads, so this exercises the same
// CAS/streaming path that matters.
module sdram_selftest #(
    parameter int CLK_MHZ = 27,
    parameter int USE_PLL = 0,
    parameter int PLL_IDIV = 8, parameter int PLL_FBDIV = 21, parameter int PLL_ODIV = 8,
    parameter int PLL_PHASE = 10,
    parameter int CLKS_PER_BIT = 0        // 0 = derive from CLK_MHZ at 115200 baud
) (
    input  logic        clk27,
    input  logic        rst_n,
    input  logic        uart_rx_pin,
    output logic        uart_tx_pin,
    output logic [5:0]  led,
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output logic [3:0]  O_sdram_dqm,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    inout  wire  [31:0] IO_sdram_dq
);
  localparam int CPB = (CLKS_PER_BIT > 0) ? CLKS_PER_BIT : (CLK_MHZ * 1000000) / 115200;
  localparam [9:0] LAST = 10'd1023;          // 4 rows x 256 cols per bank

  wire clk, sdram_clk;
  generate if (USE_PLL) begin : g_pll
    pll #(.IDIV(PLL_IDIV), .FBDIV(PLL_FBDIV), .ODIV(PLL_ODIV), .PHASE(PLL_PHASE))
      u_pll(.clkin(clk27), .clkout(clk), .clkoutp(sdram_clk), .lock());
  end else begin : g_nopll
    assign clk = clk27;
    assign sdram_clk = clk27;
  end endgenerate

  logic [1:0] rsync;
  always_ff @(posedge clk) rsync <= {rsync[0], ~rst_n};
  wire rst = rsync[1];

  logic        c_valid, c_wr, c_ready, c_rvalid, c_rlast, init_done;
  logic [21:0] c_addr;
  logic [8:0]  c_len;
  logic [31:0] c_wdata, c_rdata;
  logic [31:0] dq_o, dq_i; logic dq_oe; logic [12:0] a_full;

  sdram_ctrl #(.CLK_MHZ(CLK_MHZ)) u_ctrl(.clk(clk), .rst(rst),
      .cmd_valid(c_valid), .cmd_wr(c_wr), .cmd_addr(c_addr), .cmd_len(c_len),
      .cmd_wdata(c_wdata), .cmd_ready(c_ready), .init_done(init_done),
      .rd_valid(c_rvalid), .rd_last(c_rlast), .rd_data(c_rdata),
      .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n), .cas_n(O_sdram_cas_n),
      .we_n(O_sdram_wen_n), .cke(O_sdram_cke), .ba(O_sdram_ba), .a(a_full),
      .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i));
  assign O_sdram_addr = a_full[10:0];
  assign O_sdram_dqm  = 4'b0000;
  assign O_sdram_clk  = sdram_clk;
  assign IO_sdram_dq  = dq_oe ? dq_o : 32'bz;
  assign dq_i = IO_sdram_dq;

  logic [1:0] bank; logic [9:0] idx, ridx;
  wire [21:0] waddr = {1'b0, bank, 9'b0, idx};
  wire [21:0] raddr = {1'b0, bank, 9'b0, ridx};
  function automatic [31:0] pat(input [21:0] a);
    pat = {a[9:0], a[21:0]} ^ 32'hA5A5_5A5A;
  endfunction

  localparam S_WAIT=0, S_WR=1, S_RD=2, S_RDW=3, S_DONE=4;
  logic [2:0] st;
  logic [15:0] errs;
  logic [21:0] first_bad;

  assign c_wdata = pat(waddr);
  assign c_addr  = (st == S_WR) ? waddr : raddr;
  assign c_wr    = (st == S_WR);
  assign c_len   = (st == S_WR) ? 9'd1 : 9'd256;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_WAIT; bank <= 2'd0; idx <= 10'd0; ridx <= 10'd0;
      errs <= 16'd0; first_bad <= 22'd0; c_valid <= 1'b0;
    end else case (st)
      S_WAIT: if (init_done) begin st <= S_WR; c_valid <= 1'b1; end
      S_WR: if (c_valid && c_ready) begin
              if (idx == LAST) begin
                idx <= 10'd0;
                if (bank == 2'd3) begin bank <= 2'd0; st <= S_RD; end
                else bank <= bank + 2'd1;
              end else idx <= idx + 10'd1;
            end else c_valid <= 1'b1;
      S_RD: if (c_valid && c_ready) begin c_valid <= 1'b0; st <= S_RDW; end
            else c_valid <= 1'b1;
      S_RDW: if (c_rvalid) begin
               if (c_rdata != pat(raddr)) begin
                 if (errs == 16'd0) first_bad <= raddr;
                 if (errs != 16'hFFFF) errs <= errs + 16'd1;
               end
               if (c_rlast) begin
                 if (ridx[9:8] == 2'd3) begin
                   ridx <= 10'd0;
                   if (bank == 2'd3) st <= S_DONE;
                   else begin bank <= bank + 2'd1; st <= S_RD; end
                 end else begin ridx <= ridx + 10'd1; st <= S_RD; end
               end else ridx <= ridx + 10'd1;
             end
      S_DONE: c_valid <= 1'b0;
      default: st <= S_WAIT;
    endcase
  end

  // ---- report: 16 ASCII bytes, repeated ----
  logic u_send, u_busy; logic [7:0] u_data;
  uart_tx #(.CLKS_PER_BIT(CPB)) u_tx(.clk(clk), .rst(rst), .send(u_send), .data(u_data),
                .tx(uart_tx_pin), .busy(u_busy));
  function automatic [7:0] hex(input [3:0] v);
    hex = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h57 + {4'd0, v});
  endfunction
  logic [3:0] bi; logic [15:0] gap;
  function automatic [7:0] rpt(input [3:0] i);
    case (i)
      4'd0: rpt = (errs == 16'd0) ? 8'h50 : 8'h46;   // P / F
      4'd1: rpt = 8'h20;
      4'd2: rpt = 8'h65;                             // e
      4'd3: rpt = hex(errs[15:12]);
      4'd4: rpt = hex(errs[11:8]);
      4'd5: rpt = hex(errs[7:4]);
      4'd6: rpt = hex(errs[3:0]);
      4'd7: rpt = 8'h20;
      4'd8: rpt = 8'h63;                             // c = clock
      4'd9: rpt = hex(4'((CLK_MHZ / 100) % 10));
      4'd10: rpt = hex(4'((CLK_MHZ / 10) % 10));
      4'd11: rpt = hex(4'(CLK_MHZ % 10));
      4'd12: rpt = 8'h20;
      4'd13: rpt = 8'h70;                            // p = phase
      4'd14: rpt = hex(4'(PLL_PHASE));
      default: rpt = 8'h0A;
    endcase
  endfunction
  always_ff @(posedge clk) begin
    u_send <= 1'b0;
    if (rst) begin bi <= 4'd0; gap <= 16'd0; end
    else if (st == S_DONE) begin
      if (gap != 16'd0) gap <= gap - 16'd1;
      else if (!u_busy && !u_send) begin
        u_send <= 1'b1; u_data <= rpt(bi);
        if (bi == 4'd15) begin bi <= 4'd0; gap <= 16'hFFFF; end else bi <= bi + 4'd1;
      end
    end
  end

  assign led = {2'b0, (st == S_DONE) && (errs != 0), (st == S_DONE) && (errs == 0),
                st != S_WAIT, init_done};
endmodule
