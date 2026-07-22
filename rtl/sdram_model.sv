// Single-port SDRAM behavioral model: what the real controller presents to the fabric.
// One command at a time; posted writes; reads return LAT cycles later.
// (The actual GW2AR SDRAM controller — init/refresh/activate/CAS pin timing — plugs
//  into this same command port during board bring-up; its correctness is a board test.)
module sdram_model #(parameter LAT = 4) (
    input  logic        clk,
    input  logic        cmd_valid,
    input  logic        cmd_wr,
    input  logic [21:0] cmd_addr,
    input  logic [31:0] cmd_wdata,
    output logic        cmd_ready,
    output logic        rd_valid,
    output logic [31:0] rd_data
);
  logic [31:0] m [0:(1<<21)-1];
  string hf;
  initial begin
    if (!$value$plusargs("HEX=%s", hf)) hf = "data/golem_mem.hex";
    $readmemh(hf, m);
  end
  logic busy; logic [2:0] cnt; logic [21:0] ra;
  assign cmd_ready = !busy;
  always_ff @(posedge clk) begin
    rd_valid <= 1'b0;
    if (!busy) begin
      if (cmd_valid && cmd_wr) m[cmd_addr] <= cmd_wdata;
      else if (cmd_valid && !cmd_wr) begin ra <= cmd_addr; cnt <= LAT[2:0]; busy <= 1'b1; end
    end else if (cnt > 3'd1) cnt <= cnt - 3'd1;
    else begin rd_valid <= 1'b1; rd_data <= m[ra]; busy <= 1'b0; end
  end
endmodule
