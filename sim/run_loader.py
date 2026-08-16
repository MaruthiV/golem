import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
LIB = ROOT / "lib" / "rtl"


def run(which):
    runner = get_runner("icarus")
    if which == "uart_rx":
        runner.build(sources=[RTL / "uart_rx.sv"], hdl_toplevel="uart_rx",
                     build_dir=ROOT / "sim" / "build_uart_rx", build_args=["-g2012"],
                     parameters={"CLKS_PER_BIT": 8}, timescale=("1ns", "1ps"))
        runner.test(hdl_toplevel="uart_rx", test_module="test_uart_rx",
                    test_dir=ROOT / "sim", build_dir=ROOT / "sim" / "build_uart_rx")
    else:
        srcs = ["sdram_chip.sv", LIB / "sdram_ctrl.sv", "weight_loader.sv", "sim_mem.sv",
                "requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv", "softmax_row.sv",
                "gelu_lut.sv", "block.sv", "golem.sv", LIB / "mem_arbiter.sv"]
        runner.build(sources=[s if isinstance(s, Path) else RTL / s for s in srcs], hdl_toplevel="loader_sys",
                     build_dir=ROOT / "sim" / "build_loader",
                     build_args=["-g2012", "-I", str(RTL)], timescale=("1ns", "1ps"))
        runner.test(hdl_toplevel="loader_sys", test_module="test_loader", test_dir=ROOT / "sim",
                    build_dir=ROOT / "sim" / "build_loader",
                    plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}"])


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "loader")
