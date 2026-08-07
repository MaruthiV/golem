// Full-board integration harness: the real golem_board_top wired to a behavioral SDRAM
// over a true inout dq bus. cocotb drives clk/rst/uart_rx_pin and watches uart_tx_pin.
// N_WORDS is small: the host "loads" only the first few words over UART; the chip model is
// $readmemh-preloaded with the full image, so after the LOAD->RUN handoff golem reads a
// correct image and must generate the bit-exact first token — end to end through the pins.
module board_tb #(
    parameter CLKS_PER_BIT = 8,
    parameter [21:0] N_WORDS = 22'd16,
    parameter [7:0]  MAX_TOKENS = 8'd1
) (
    input  logic       clk27,
    input  logic       rst_n,
    input  logic       uart_rx_pin,
    output logic       uart_tx_pin,
    output logic [5:0] led
);
  wire cs, ras, cas, we, cke, sdclk; wire [1:0] ba; wire [10:0] a; wire [3:0] dqm;
  wire [31:0] dq;

  golem_board_top #(.CLKS_PER_BIT(CLKS_PER_BIT), .N_WORDS(N_WORDS), .MAX_TOKENS(MAX_TOKENS))
    u_top(.clk27(clk27), .rst_n(rst_n), .uart_rx_pin(uart_rx_pin), .uart_tx_pin(uart_tx_pin),
        .led(led), .O_sdram_clk(sdclk), .O_sdram_cke(cke),
        .O_sdram_cs_n(cs), .O_sdram_ras_n(ras), .O_sdram_cas_n(cas), .O_sdram_wen_n(we),
        .O_sdram_dqm(dqm), .O_sdram_addr(a), .O_sdram_ba(ba), .IO_sdram_dq(dq));

  // the chip model takes a 13-bit a; only 11 are wired on the real SiP part
  sdram_chip_io u_chip(.clk(clk27), .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we),
        .ba(ba), .a({2'b0, a}), .dq(dq));
endmodule
