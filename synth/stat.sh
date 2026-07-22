#!/bin/bash
# quick synthesizability + complexity check per datapath module (generic gates, no PDK)
set -e
cd "$(dirname "$0")/.."
mods=(requant divu matmul_row rmsnorm softmax_row gelu_lut)
srcs="rtl/requant.sv rtl/divu.sv rtl/matmul_row.sv rtl/rmsnorm.sv rtl/softmax_row.sv rtl/gelu_lut.sv"
for m in "${mods[@]}"; do
  echo "=== $m ==="
  yosys -q -p "read_verilog -sv $srcs; synth -top $m -flatten; abc -g AND,OR,XOR,MUX; stat" 2>&1 \
    | grep -E "Number of cells|Number of wires|\\\$_|Estimated" | head -20 || true
done
echo "=== block (full, with memories) ==="
yosys -q -p "read_verilog -sv $srcs rtl/block.sv; synth -top block; stat" 2>&1 \
  | grep -E "Number of cells|Number of memories|Number of memory bits|Number of wires" | head
