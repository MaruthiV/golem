// T30 cycle attribution. Counts in native sim because cocotb per-cycle sampling over
// ~19.6M cycles/token would take hours. Dumps JSON when tok_valid pulses.
module stall_probe (
    input logic        clk,
    input logic        rst,
    input logic        dump,
    input logic        busy,
    input logic [4:0]  g_st,
    input logic        g_req,
    input logic        g_valid,
    input logic        kv_rreq,
    input logic        kv_rvalid,
    input logic        kv_we,
    input logic [3:0]  c_st,
    input logic [2:0]  a_st,
    input logic        o_valid,
    input logic        i_ready,
    input logic        i_rvalid
);
  localparam NG = 20, NC = 12, NA = 5;
  localparam C_IDLE = 4'd4, C_REF = 4'd11;

  reg [63:0] cyc_total, cyc_stall, cyc_kvstall, cyc_cmdwait, cyc_busidle, cyc_useful;
  reg [63:0] n_ref, n_mrd, n_kvr, n_kvw, n_tok;
  reg [63:0] g_cyc   [0:NG-1];
  reg [63:0] g_stl   [0:NG-1];
  reg [63:0] c_cyc   [0:NC-1];
  reg [63:0] a_cyc   [0:NA-1];
  reg [3:0]  c_st_q;
  reg [8*256:1] outp;
  reg [31:0] snap_every, snap_ctr;
  integer i, fd;

  wire g_stall  = g_req && !g_valid;
  wire kv_stall = kv_rreq && !kv_rvalid;
  // periodic snapshots too: a $finish racing the final dump would otherwise lose everything
  wire do_dump = dump || (busy && snap_ctr == 0);

  initial begin
    cyc_total = 0; cyc_stall = 0; cyc_kvstall = 0; cyc_cmdwait = 0;
    cyc_busidle = 0; cyc_useful = 0;
    n_ref = 0; n_mrd = 0; n_kvr = 0; n_kvw = 0; n_tok = 0;
    c_st_q = C_IDLE;
    for (i = 0; i < NG; i = i + 1) begin g_cyc[i] = 0; g_stl[i] = 0; end
    for (i = 0; i < NC; i = i + 1) c_cyc[i] = 0;
    for (i = 0; i < NA; i = i + 1) a_cyc[i] = 0;
    if (!$value$plusargs("STALLOUT=%s", outp)) outp = "data/stall_baseline.json";
    if (!$value$plusargs("SNAPEVERY=%d", snap_every)) snap_every = 32'd4000000;
    snap_ctr = snap_every;
  end

  always @(posedge clk) if (!rst) begin
    if (busy) begin
      snap_ctr <= (snap_ctr == 0) ? snap_every : snap_ctr - 1;
      cyc_total <= cyc_total + 1;
      g_cyc[g_st] <= g_cyc[g_st] + 1;
      c_cyc[c_st] <= c_cyc[c_st] + 1;
      a_cyc[a_st] <= a_cyc[a_st] + 1;
      if (g_stall) begin
        cyc_stall <= cyc_stall + 1;
        g_stl[g_st] <= g_stl[g_st] + 1;
      end
      // a cycle nobody is blocked on memory for: the datapath actually moved
      if (!g_stall && !kv_stall) cyc_useful <= cyc_useful + 1;
      if (kv_stall) cyc_kvstall <= cyc_kvstall + 1;
      // arbiter holding a command the controller won't accept (busy or refreshing)
      if (o_valid && !i_ready) cyc_cmdwait <= cyc_cmdwait + 1;
      // memory free and nobody asking: bandwidth thrown away
      if (c_st == C_IDLE && !o_valid) cyc_busidle <= cyc_busidle + 1;
      if (c_st == C_REF && c_st_q != C_REF) n_ref <= n_ref + 1;
      if (g_valid)   n_mrd <= n_mrd + 1;
      if (kv_rvalid) n_kvr <= n_kvr + 1;
      if (kv_we)     n_kvw <= n_kvw + 1;
    end
    c_st_q <= c_st;
  end

  always @(posedge clk) if (!rst && do_dump) begin
    if (dump) n_tok = n_tok + 1;
    fd = $fopen(outp, "w");
    $fwrite(fd, "{\n");
    $fwrite(fd, "  \"final\": %0d,\n", dump);
    $fwrite(fd, "  \"tokens\": %0d,\n", n_tok);
    $fwrite(fd, "  \"cyc_total\": %0d,\n", cyc_total);
    $fwrite(fd, "  \"cyc_useful\": %0d,\n", cyc_useful);
    $fwrite(fd, "  \"cyc_mrd_stall\": %0d,\n", cyc_stall);
    $fwrite(fd, "  \"cyc_kv_stall\": %0d,\n", cyc_kvstall);
    $fwrite(fd, "  \"cyc_cmd_wait\": %0d,\n", cyc_cmdwait);
    $fwrite(fd, "  \"cyc_bus_idle\": %0d,\n", cyc_busidle);
    $fwrite(fd, "  \"n_refresh\": %0d,\n", n_ref);
    $fwrite(fd, "  \"n_mrd_reads\": %0d,\n", n_mrd);
    $fwrite(fd, "  \"n_kv_reads\": %0d,\n", n_kvr);
    $fwrite(fd, "  \"n_kv_writes\": %0d,\n", n_kvw);
    $fwrite(fd, "  \"golem_state_cycles\": [");
    for (i = 0; i < NG; i = i + 1) $fwrite(fd, "%0d%s", g_cyc[i], (i == NG-1) ? "" : ", ");
    $fwrite(fd, "],\n");
    $fwrite(fd, "  \"golem_state_stall\": [");
    for (i = 0; i < NG; i = i + 1) $fwrite(fd, "%0d%s", g_stl[i], (i == NG-1) ? "" : ", ");
    $fwrite(fd, "],\n");
    $fwrite(fd, "  \"ctrl_state_cycles\": [");
    for (i = 0; i < NC; i = i + 1) $fwrite(fd, "%0d%s", c_cyc[i], (i == NC-1) ? "" : ", ");
    $fwrite(fd, "],\n");
    $fwrite(fd, "  \"arb_state_cycles\": [");
    for (i = 0; i < NA; i = i + 1) $fwrite(fd, "%0d%s", a_cyc[i], (i == NA-1) ? "" : ", ");
    $fwrite(fd, "]\n}\n");
    $fclose(fd);
    $display("[probe] token %0d: %0d cycles, %0d mrd stall, %0d reads -> %s",
             n_tok, cyc_total, cyc_stall, n_mrd, outp);
  end
endmodule

// golem_board + the probe. Same ports as golem_board so test_golem.py runs unchanged.
module golem_board_probe (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [11:0] token,
    input  logic [7:0]  pos,
    output logic        busy,
    output logic        tok_valid,
    output logic [11:0] tok_out
);
  golem_board u_dut(.clk(clk), .rst(rst), .start(start), .token(token), .pos(pos),
                    .busy(busy), .tok_valid(tok_valid), .tok_out(tok_out));

  stall_probe u_probe(
    .clk(clk), .rst(rst), .dump(tok_valid), .busy(busy),
    .g_st(u_dut.u_golem.st), .g_req(u_dut.mrd_req), .g_valid(u_dut.mrd_valid),
    .kv_rreq(u_dut.krq), .kv_rvalid(u_dut.krv), .kv_we(u_dut.kw),
    .c_st(u_dut.u_ctrl.st), .a_st(u_dut.u_arb.st),
    .o_valid(u_dut.o_valid), .i_ready(u_dut.c_ready), .i_rvalid(u_dut.c_rvalid));
endmodule
