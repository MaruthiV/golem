#!/bin/bash
# Gate G7: find the real maximum SDRAM clock and the PLL phase that works, on silicon.
# For each (clock, phase) it builds sdram_selftest, flashes it, and reads the ASCII report.
# "P" = 4096 words over 4 banks written and burst-read back with zero mismatches.
# No simulation can answer this — the data window's position is a physical property of the SiP.
#   bash scripts/sdram_sweep.sh /dev/tty.usbserial-XXXX
set -u
cd "$(dirname "$0")/.."
PORT=${1:-/dev/tty.usbserial-1}
CLOCKS=${CLOCKS:-"27 54 66 81 108"}
PHASES=${PHASES:-"0 2 4 6 8 10 12 14"}

printf 'clk  ' ; for p in $PHASES; do printf '%4s' "p$p"; done; printf '\n'
for c in $CLOCKS; do
  printf '%-5s' "$c"
  for p in $PHASES; do
    U=1; [ "$c" = "27" ] && U=0
    if ! CLK_MHZ=$c USE_PLL=$U PHASE=$p TOP=sdram_selftest bash scripts/build_fpga.sh >/dev/null 2>&1; then
      printf '%4s' "b!"; continue
    fi
    if ! openFPGALoader -b tangnano20k fpga/out/sdram_selftest.fs >/dev/null 2>&1; then
      printf '%4s' "f!"; continue
    fi
    R=$(python3 scripts/read_selftest.py "$PORT" 4 2>/dev/null)
    case "$R" in
      P*) printf '%4s' "P" ;;
      F*) printf '%4s' "F" ;;
      *)  printf '%4s' "-" ;;
    esac
  done
  printf '\n'
done
echo "P = zero mismatches. Pick the highest clock with a wide band of P, and its middle phase."
