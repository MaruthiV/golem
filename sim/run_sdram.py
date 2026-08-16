from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
LIB = ROOT / "lib" / "rtl"


def main():
    runner = get_runner("icarus")
    runner.build(sources=[RTL / "sdram_chip.sv", RTL / LIB / "sdram_ctrl.sv", RTL / "sim_mem.sv",
                          RTL / "requant.sv", RTL / "divu.sv", RTL / "matmul_row.sv",
                          RTL / "rmsnorm.sv", RTL / "softmax_row.sv", RTL / "gelu_lut.sv",
                          RTL / "block.sv", RTL / "golem.sv", RTL / LIB / "mem_arbiter.sv"],
                 hdl_toplevel="sdram_sys", build_dir=ROOT / "sim" / "build_sdram",
                 build_args=["-g2012", "-I", str(RTL)], timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="sdram_sys", test_module="test_sdram", test_dir=ROOT / "sim",
                build_dir=ROOT / "sim" / "build_sdram",
                plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}"])


if __name__ == "__main__":
    main()
