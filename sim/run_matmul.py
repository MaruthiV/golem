from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]


def main():
    runner = get_runner("icarus")
    runner.build(
        sources=[ROOT / "rtl" / "requant.sv", ROOT / "rtl" / "matmul_row.sv"],
        hdl_toplevel="matmul_row",
        build_dir=ROOT / "sim" / "build_matmul",
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="matmul_row",
        test_module="test_matmul_row",
        test_dir=ROOT / "sim",
        build_dir=ROOT / "sim" / "build_matmul",
    )


if __name__ == "__main__":
    main()
