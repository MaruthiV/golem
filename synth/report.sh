#!/bin/bash
cd "$(dirname "$0")/.."
SRC="rtl/requant.sv rtl/divu.sv rtl/matmul_row.sv rtl/rmsnorm.sv rtl/softmax_row.sv rtl/gelu_lut.sv"
OUT=synth/report.txt
: > "$OUT"
for m in requant gelu_lut divu matmul_row softmax_row rmsnorm; do
  yosys -p "read_verilog -sv $SRC; synth -top $m -flatten; stat" > synth/raw_$m.txt 2>&1
  cells=$(grep -E "Number of cells:" synth/raw_$m.txt | tail -1 | grep -oE "[0-9]+")
  mem=$(grep -E "Number of memory bits:" synth/raw_$m.txt | tail -1 | grep -oE "[0-9]+")
  ok=$(grep -icE "\\\$error|syntax error|ERROR:" synth/raw_$m.txt)
  echo "$m  cells=${cells:-NA}  mem_bits=${mem:-0}  errors=$ok" >> "$OUT"
done
echo "--- full block (with on-die buffers) ---" >> "$OUT"
yosys -p "read_verilog -sv $SRC rtl/block.sv; synth -top block" > synth/raw_block.txt 2>&1
bc=$(grep -E "Number of cells:" synth/raw_block.txt | tail -1 | grep -oE "[0-9]+")
bm=$(grep -E "Number of memory bits:" synth/raw_block.txt | tail -1 | grep -oE "[0-9]+")
be=$(grep -icE "syntax error|ERROR:" synth/raw_block.txt)
echo "block  cells=${bc:-NA}  mem_bits=${bm:-0}  errors=$be" >> "$OUT"
echo "DONE" >> "$OUT"
