from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
LIB = ROOT / "lib" / "rtl"


def main():
    srcs = ["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv", "softmax_row.sv",
            "gelu_lut.sv", "block.sv", "golem.sv", LIB / "mem_arbiter.sv", "uart_tx.sv", "uart_rx.sv",
            "weight_loader.sv", LIB / "sdram_ctrl.sv", LIB / "wstream.sv", "sdram_chip.sv", "sdram_chip_io.sv", "golem_board_top.sv",
            "board_tb.sv"]
    runner = get_runner("icarus")
    runner.build(sources=[s if isinstance(s, Path) else RTL / s for s in srcs], hdl_toplevel="board_tb",
                 build_dir=ROOT / "sim" / "build_board_top",
                 build_args=["-g2012", "-I", str(RTL)],
                 parameters={"CLKS_PER_BIT": 8}, timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="board_tb", test_module="test_board_top", test_dir=ROOT / "sim",
                build_dir=ROOT / "sim" / "build_board_top",
                plusargs=[f"+HEX={ROOT / 'data' / 'golem_mem.hex'}"])


if __name__ == "__main__":
    main()
