import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"


def run(which):
    runner = get_runner("icarus")
    if which == "uart":
        runner.build(sources=[RTL / "uart_tx.sv"], hdl_toplevel="uart_tx",
                     build_dir=ROOT / "sim" / "build_uart", build_args=["-g2012"],
                     parameters={"CLKS_PER_BIT": 8}, timescale=("1ns", "1ps"))
        runner.test(hdl_toplevel="uart_tx", test_module="test_uart",
                    test_dir=ROOT / "sim", build_dir=ROOT / "sim" / "build_uart")
    else:
        srcs = ["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv", "softmax_row.sv",
                "gelu_lut.sv", "block.sv", "golem.sv", "sdram_model.sv", "mem_arbiter.sv",
                "uart_tx.sv", "golem_top.sv"]
        runner.build(sources=[RTL / s for s in srcs], hdl_toplevel="golem_top",
                     build_dir=ROOT / "sim" / "build_top", build_args=["-g2012", "-I", str(RTL)],
                     parameters={"CLKS_PER_BIT": 8, "MAX_TOKENS": 2}, timescale=("1ns", "1ps"))
        runner.test(hdl_toplevel="golem_top", test_module="test_top", test_dir=ROOT / "sim",
                    build_dir=ROOT / "sim" / "build_top",
                    plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}"])


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "top")
