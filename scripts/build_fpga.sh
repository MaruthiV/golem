#!/bin/bash
# golem FPGA build flow for the Tang Nano 20K (Gowin GW2AR-18).
# Needs the OSS CAD Suite on PATH (yosys + nextpnr-himbaechel + apicula + openFPGALoader):
#   https://github.com/YosysHQ/oss-cad-suite-build/releases  (darwin-arm64)
#   then: source <oss-cad-suite>/environment
#
# TOP = golem_board_top: the full board design — golem + arbiter + SDRAM controller +
# UART rx/tx + weight loader, with physical SDRAM pins (see docs/board.md).
# To just check fabric fit + Fmax of the core logic first, set TOP=golem_fpga (its SDRAM
# command port floats as I/O; drops the controller / loader / uart_rx).
set -e
cd "$(dirname "$0")/.."

TOP=${TOP:-golem_board_top}
DEVICE="GW2AR-LV18QN88C8/I7"
FAMILY="GW2A-18C"

RTL="rtl/requant.sv rtl/divu.sv rtl/matmul_row.sv rtl/rmsnorm.sv rtl/softmax_row.sv \
     rtl/gelu_lut.sv rtl/block.sv rtl/golem.sv rtl/mem_arbiter.sv rtl/wstream.sv rtl/uart_tx.sv"
if [ "$TOP" = "golem_board_top" ]; then
  RTL="$RTL rtl/uart_rx.sv rtl/weight_loader.sv rtl/sdram_ctrl.sv rtl/golem_board_top.sv"
else
  RTL="$RTL rtl/golem_fpga.sv"
fi

mkdir -p fpga/out
yosys -p "read_verilog -sv $RTL; synth_gowin -top $TOP -json fpga/out/$TOP.json"
nextpnr-himbaechel --json fpga/out/$TOP.json --write fpga/out/${TOP}_pnr.json \
  --device "$DEVICE" --vopt family=$FAMILY --vopt cst=fpga/tangnano20k.cst
gowin_pack -d $FAMILY -o fpga/out/golem.fs fpga/out/${TOP}_pnr.json

echo "bitstream: fpga/out/golem.fs"
echo "flash (volatile SRAM): openFPGALoader -b tangnano20k fpga/out/golem.fs"
echo "flash (persistent):    openFPGALoader -b tangnano20k -f fpga/out/golem.fs"
echo "then: python scripts/read_story.py /dev/tty.usbserial-XXXX"
