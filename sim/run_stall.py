from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"


def main():
    srcs = ["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv", "softmax_row.sv",
            "gelu_lut.sv", "block.sv", "golem.sv", "mem_arbiter.sv", "sdram_ctrl.sv",
            "sdram_chip.sv", "sim_mem.sv", "stall_probe.sv"]
    runner = get_runner("icarus")
    runner.build(sources=[RTL / s for s in srcs], hdl_toplevel="golem_board_probe",
                 build_dir=ROOT / "sim" / "build_stall", build_args=["-g2012", "-I", str(RTL)],
                 timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="golem_board_probe", test_module="test_golem", test_dir=ROOT / "sim",
                build_dir=ROOT / "sim" / "build_stall",
                plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}",
                          f"+STALLOUT={ROOT / 'data' / 'stall_baseline.json'}"])


if __name__ == "__main__":
    main()
