#!/bin/bash
# golem FPGA build flow for the Tang Nano 20K (Gowin GW2AR-18).
# Needs the OSS CAD Suite on PATH (yosys + nextpnr-himbaechel + apicula + openFPGALoader):
#   https://github.com/YosysHQ/oss-cad-suite-build/releases  (darwin-arm64)
#   then: source <oss-cad-suite>/environment
#
# TOP = golem_board_top: the full board design — golem + arbiter + SDRAM controller +
# UART rx/tx + weight loader, using the dedicated SiP SDRAM port names (see docs/board.md).
# This is the ONLY viable P&R target. TOP=golem_fpga synthesizes but can NEVER place: it
# exposes the whole command port as ~100 I/O (o_addr + o_wdata + i_rdata + o_len + handshakes)
# on an 88-pin package. It is kept only as a synthesis-only resource probe.
set -e
cd "$(dirname "$0")/.."

TOP=${TOP:-golem_board_top}
DEVICE="GW2AR-LV18QN88C8/I7"
FAMILY="GW2A-18C"

if [ "$TOP" = "sdram_selftest" ]; then
  # bring-up design: no golem at all, just the memory path. Builds in ~1 min and is what the
  # clock/phase sweep flashes (T70 / gate G7).
  RTL="rtl/uart_tx.sv rtl/sdram_ctrl.sv rtl/pll.sv rtl/sdram_selftest.sv"
else
  RTL="rtl/requant.sv rtl/divu.sv rtl/matmul_row.sv rtl/rmsnorm.sv rtl/softmax_row.sv \
       rtl/gelu_lut.sv rtl/block.sv rtl/golem.sv rtl/mem_arbiter.sv rtl/wstream.sv rtl/uart_tx.sv"
  if [ "$TOP" = "golem_board_top" ]; then
    RTL="$RTL rtl/uart_rx.sv rtl/weight_loader.sv rtl/sdram_ctrl.sv rtl/pll.sv rtl/golem_board_top.sv"
  else
    RTL="$RTL rtl/golem_fpga.sv"
  fi
fi

# CLK_MHZ/USE_PLL pick the internal clock (T68). FREQ constrains nextpnr so timing is VERIFIED
# at that clock rather than merely reported against himbaechel's 12 MHz default.
CLK_MHZ=${CLK_MHZ:-27}
USE_PLL=${USE_PLL:-0}
FREQ=${FREQ:-$CLK_MHZ}
# PLL dividers: CLK_MHZ = 27*(FBDIV+1)/(IDIV+1), and VCO = CLK_MHZ*ODIV must be 400..1200 MHz.
# PHASE shifts the SDRAM's own clock in 16ths of a period — the knob the board self-test sweeps.
PHASE=${PHASE:-10}
case "$CLK_MHZ" in
  27)  IDIV=0; FBDIV=0;  ODIV=32 ;;   # VCO 864
  54)  IDIV=0; FBDIV=1;  ODIV=16 ;;   # VCO 864
  60)  IDIV=8; FBDIV=19; ODIV=8  ;;   # VCO 480
  66)  IDIV=8; FBDIV=21; ODIV=8  ;;   # VCO 528
  81)  IDIV=0; FBDIV=2;  ODIV=8  ;;   # VCO 648
  108) IDIV=0; FBDIV=3;  ODIV=8  ;;   # VCO 864
  *) if [ "$USE_PLL" = "1" ]; then echo "no PLL dividers for CLK_MHZ=$CLK_MHZ" >&2; exit 1; fi ;;
esac

CHP=""
if [ "$TOP" = "golem_board_top" ] || [ "$TOP" = "sdram_selftest" ]; then
  # -chparam on hierarchy, NOT the chparam command: chparam derives a copy and leaves the
  # original as top, so the parameters silently do not apply.
  CHP="-chparam CLK_MHZ $CLK_MHZ -chparam USE_PLL $USE_PLL -chparam PLL_IDIV $IDIV"
  CHP="$CHP -chparam PLL_FBDIV $FBDIV -chparam PLL_ODIV $ODIV -chparam PLL_PHASE $PHASE"
fi

mkdir -p fpga/out
yosys -p "read_verilog -sv $RTL; hierarchy -top $TOP $CHP; synth_gowin -top $TOP -json fpga/out/$TOP.json"
nextpnr-himbaechel --json fpga/out/$TOP.json --write fpga/out/${TOP}_pnr.json \
  --device "$DEVICE" --vopt family=$FAMILY --vopt cst=fpga/tangnano20k.cst --freq $FREQ --seed ${SEED:-1}
# one bitstream per top, no shared alias: TOP=sdram_selftest and TOP=golem_board_top are flashed
# in the same session during bring-up, and a shared name means flashing whichever built last.
gowin_pack -d $FAMILY -o fpga/out/${TOP}.fs fpga/out/${TOP}_pnr.json

echo "bitstream: fpga/out/${TOP}.fs"
echo "flash (volatile SRAM): openFPGALoader -b tangnano20k fpga/out/${TOP}.fs"
echo "flash (persistent):    openFPGALoader -b tangnano20k -f fpga/out/${TOP}.fs"
if [ "$TOP" = "sdram_selftest" ]; then
  echo "then: python scripts/read_selftest.py /dev/tty.usbserial-XXXX"
else
  echo "then: python scripts/upload_weights.py /dev/tty.usbserial-XXXX"
fi
