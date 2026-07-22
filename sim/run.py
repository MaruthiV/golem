import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"

BLOCKS = {
    "matmul": (["requant.sv", "matmul_row.sv"], "matmul_row", "test_matmul_row"),
    "rmsnorm": (["requant.sv", "divu.sv", "rmsnorm.sv"], "rmsnorm", "test_rmsnorm"),
    "softmax": (["divu.sv", "softmax_row.sv"], "softmax_row", "test_softmax_row"),
    "gelu": (["gelu_lut.sv"], "gelu_lut", "test_gelu_lut"),
    "block": (["requant.sv", "divu.sv", "matmul_row.sv", "rmsnorm.sv", "softmax_row.sv",
               "gelu_lut.sv", "block.sv"], "block", "test_block"),
}


def run_block(name):
    sources, top, module = BLOCKS[name]
    runner = get_runner("icarus")
    runner.build(
        sources=[RTL / s for s in sources],
        hdl_toplevel=top,
        build_dir=ROOT / "sim" / f"build_{name}",
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel=top,
        test_module=module,
        test_dir=ROOT / "sim",
        build_dir=ROOT / "sim" / f"build_{name}",
    )


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = list(BLOCKS) if target == "all" else [target]
    for name in names:
        print(f"\n=== {name} ===")
        run_block(name)


if __name__ == "__main__":
    main()
