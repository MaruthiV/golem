from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"


def main():
    runner = get_runner("icarus")
    runner.build(
        sources=[RTL / s for s in ["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv",
                                   "softmax_row.sv", "gelu_lut.sv", "block.sv",
                                   "golem.sv", "sim_mem.sv"]],
        hdl_toplevel="golem_sim",
        build_dir=ROOT / "sim" / "build_golem",
        build_args=["-g2012", "-I", str(RTL)],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="golem_sim",
        test_module="test_golem",
        test_dir=ROOT / "sim",
        build_dir=ROOT / "sim" / "build_golem",
        plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}"],
    )


if __name__ == "__main__":
    main()
