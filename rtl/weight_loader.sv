// Boot-time weight loader: receive the packed image over UART (4 bytes/word, little-endian
// = LSB first, matching quant/pack.py), write each word to SDRAM at incrementing address.
// Owns the SDRAM command port until `done`, then the arbiter takes over.
module weight_loader #(parameter [21:0] N_WORDS = 22'd1624264) (
    input  logic       clk,
    input  logic       rst,

    input  logic [7:0] rx_data,
    input  logic       rx_valid,

    output logic        cmd_valid,
    output logic        cmd_wr,
    output logic [21:0] cmd_addr,
    output logic [31:0] cmd_wdata,
    input  logic        cmd_ready,

    output logic        done
);
  logic [1:0]  bidx;
  logic [23:0] acc;      // low 3 bytes accumulated
  logic [21:0] addr;
  logic        have_word;

  assign cmd_wr = 1'b1;
  assign cmd_addr = addr;

  always_ff @(posedge clk) begin
    if (rst) begin bidx <= 2'd0; addr <= 22'd0; have_word <= 1'b0; done <= 1'b0; cmd_valid <= 1'b0; end
    else if (!done) begin
      if (have_word) begin
        // held-valid: only accept once cmd_valid is actually high on the wire, else it
        // races cmd_ready (combinational, high when the controller is idle) and drops the write.
        if (cmd_valid && cmd_ready) begin
          cmd_valid <= 1'b0; have_word <= 1'b0;
          if (addr == N_WORDS - 22'd1) done <= 1'b1; else addr <= addr + 22'd1;
        end else cmd_valid <= 1'b1;
      end else if (rx_valid) begin
        if (bidx == 2'd3) begin
          cmd_wdata <= {rx_data, acc};           // byte3 is MSB; acc holds bytes 0..2
          have_word <= 1'b1; bidx <= 2'd0;
        end else begin
          acc[bidx*8 +: 8] <= rx_data; bidx <= bidx + 2'd1;
        end
      end
    end
  end
endmodule
