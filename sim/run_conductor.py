from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"


def main():
    runner = get_runner("icarus")
    runner.build(
        sources=[RTL / s for s in ["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv",
                                   "softmax_row.sv", "gelu_lut.sv", "block.sv"]],
        hdl_toplevel="block",
        build_dir=ROOT / "sim" / "build_block",
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="block",
        test_module="conductor",
        test_dir=ROOT / "sim",
        build_dir=ROOT / "sim" / "build_block",
    )


if __name__ == "__main__":
    main()
