// Gowin rPLL wrapper. CLKOUT = 27 MHz * (FBDIV+1) / (IDIV+1), and the VCO runs at CLKOUT * ODIV,
// which must land in 400-1200 MHz. CLKOUTP is the same clock shifted by PSDA/16 of a period —
// that is the SDRAM's own clock pin. Only silicon can say where the data window actually sits,
// so PSDA is a parameter and the board self-test sweeps it (T70 / gate G7).
// Divider values verified against nand2mario/sdram-tang-nano-20k's generated wrapper for this
// exact part (DEVICE GW2A-18C, FCLKIN 27, PSDA_SEL as the SDRAM phase knob).
module pll #(
    parameter int IDIV  = 8,        // 27 * 22 / 9 = 66 MHz
    parameter int FBDIV = 21,
    parameter int ODIV  = 8,        // VCO = 66 * 8 = 528 MHz
    parameter int PHASE = 10        // CLKOUTP shift, in 16ths of a period (0..15)
) (
    input  logic clkin,
    output logic clkout,
    output logic clkoutp,
    output logic lock
);
  wire gnd = 1'b0;
  // rPLL wants PSDA_SEL as a 4-character string; a Verilog string literal is just its bytes,
  // so build it from PHASE. Keeps the phase an integer the build script can sweep (T70/G7).
  function automatic [31:0] bits4(input int v);
    bits4 = {8'h30 + 8'((v >> 3) & 1), 8'h30 + 8'((v >> 2) & 1),
             8'h30 + 8'((v >> 1) & 1), 8'h30 + 8'(v & 1)};
  endfunction
  localparam [31:0] PSDA_S = bits4(PHASE);
  rPLL #(
      .FCLKIN("27"), .IDIV_SEL(IDIV), .FBDIV_SEL(FBDIV), .ODIV_SEL(ODIV),
      .PSDA_SEL(PSDA_S), .DUTYDA_SEL("1000"), .DYN_DA_EN("false"),
      .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
      .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"),
      .CLKOUTD_BYPASS("false"), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
      .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
      .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"), .DYN_SDIV_SEL(2),
      .DEVICE("GW2A-18C")
  ) u (
      .CLKIN(clkin), .CLKFB(gnd), .RESET(gnd), .RESET_P(gnd),
      .CLKOUT(clkout), .CLKOUTP(clkoutp), .LOCK(lock), .CLKOUTD(), .CLKOUTD3(),
      .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
  );
endmodule
