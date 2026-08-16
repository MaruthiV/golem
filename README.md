# golem

A transformer accelerator for a 6.36M-parameter language model, written from scratch in
SystemVerilog, verified **bit-exact** against an integer golden model at every layer, and built for a
$35 FPGA.

**1,681 lines of synthesizable SystemVerilog.** Open toolchain end to end — yosys, nextpnr, apicula,
cocotb, Icarus. No Vivado, no HLS, no vendor IP. Developed entirely on a MacBook.

## What is true today

| claim | status |
|---|---|
| Trained from scratch on TinyStories (6.36M params, int8) | ✅ |
| Integer-only inference spec + golden model | ✅ |
| RTL bit-exact vs the golden model, per layer and per token | ✅ 12/12 unit + full-token |
| Whole design in simulation through a real SDR SDRAM protocol | ✅ token 437 bit-exact |
| Fits the Tang Nano 20K — placed, routed, bitstream | ✅ 88% LUT4, 65.75 MHz routed |
| **Running on the physical board** | ⛔ **not yet — the board has not been run** |

Everything below the line is measured in simulation or reported by the tools. Nothing here has
executed on silicon, and this README will say so until it has.

## The number the project is actually about

Generation is memory-bound: `tok/s ≈ memory_bandwidth / model_bytes`. golem started out spending
**~12 cycles per weight word** where its datapath consumes one per cycle — worse than the ~70% idle
time the FPGA-accelerator literature reports as typical.

| | cycles/token | schedule efficiency |
|---|---|---|
| baseline | 19,591,114 | 8.2% |
| full-page bursts | 3,344,462 | 49.7% |
| + page-aligned line buffer, ping-pong prefetch | 1,814,512 | 91.7% |
| + correct SDRAM timings | **1,770,097** | **93.8%** |

Schedule efficiency = ideal weight-read cycles ÷ actual cycles, measured in simulation. It is **not**
a percentage of the memory's rated bandwidth — see `docs/claims.md` for both denominators and why
they must never be conflated.

## Layout

```
mind/     tokenizer + training          golden/   integer reference + test vectors
quant/    quantizer + image packer      rtl/      SystemVerilog (1,681 lines synthesizable)
sim/      Verilator/Icarus + cocotb     scripts/  build, upload, measurement
```

## Build

```
source <oss-cad-suite>/environment
python sim/run.py all                                  # bit-exactness, 12/12
TOP=sdram_selftest bash scripts/build_fpga.sh          # memory self-test bitstream
SEED=7 TOP=golem_board_top bash scripts/build_fpga.sh  # golem bitstream
```
