from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
LIB = ROOT / "lib" / "rtl"


def main():
    srcs = ["uart_tx.sv", LIB / "sdram_ctrl.sv", "sdram_chip.sv", "sdram_chip_io.sv",
            "sdram_selftest.sv", "selftest_tb.sv"]
    runner = get_runner("icarus")
    runner.build(sources=[s if isinstance(s, Path) else RTL / s for s in srcs], hdl_toplevel="selftest_tb",
                 build_dir=ROOT / "sim" / "build_selftest",
                 build_args=["-g2012", "-I", str(RTL)], timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="selftest_tb", test_module="test_selftest",
                test_dir=ROOT / "sim", build_dir=ROOT / "sim" / "build_selftest")


if __name__ == "__main__":
    main()
