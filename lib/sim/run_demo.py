"""Run the reference example both ways and print the comparison.

    python lib/sim/run_demo.py            # burst path through wstream
    DEMO_MODE=bypass python lib/sim/run_demo.py
"""
import os
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"


def main():
    bypass = 1 if os.environ.get("DEMO_MODE") == "bypass" else 0
    srcs = [LIB / "rtl" / "sdram_ctrl.sv", LIB / "rtl" / "wstream.sv",
            ROOT / "rtl" / "sdram_chip.sv", ROOT / "rtl" / "sdram_chip_io.sv",
            LIB / "example" / "wstream_demo.sv"]
    runner = get_runner("icarus")
    runner.build(sources=srcs, hdl_toplevel="wstream_demo",
                 build_dir=ROOT / "sim" / f"build_demo{bypass}",
                 build_args=["-g2012"], parameters={"BYPASS": bypass},
                 timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="wstream_demo", test_module="test_demo",
                test_dir=LIB / "sim", build_dir=ROOT / "sim" / f"build_demo{bypass}")


if __name__ == "__main__":
    main()
