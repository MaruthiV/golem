module selftest_tb #(parameter int CLK_MHZ = 27, parameter int CLKS_PER_BIT = 8) (
    input  logic clk27,
    input  logic rst_n,
    output logic uart_tx_pin,
    output logic [5:0] led
);
  wire [31:0] dq;
  wire cs, ras, cas, we, cke; wire [1:0] ba; wire [10:0] a;
  sdram_selftest #(.CLK_MHZ(CLK_MHZ), .CLKS_PER_BIT(CLKS_PER_BIT)) u_dut(.clk27(clk27), .rst_n(rst_n), .uart_rx_pin(1'b1),
      .uart_tx_pin(uart_tx_pin), .led(led),
      .O_sdram_clk(), .O_sdram_cke(cke), .O_sdram_cs_n(cs), .O_sdram_ras_n(ras),
      .O_sdram_cas_n(cas), .O_sdram_wen_n(we), .O_sdram_dqm(), .O_sdram_addr(a),
      .O_sdram_ba(ba), .IO_sdram_dq(dq));
  sdram_chip_io u_chip(.clk(clk27), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
      .ba(ba), .a({2'b0, a}), .dq(dq));
endmodule
