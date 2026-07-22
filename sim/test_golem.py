import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"


@cocotb.test()
async def generate(dut):
    ref = np.load(DATA / "greedy_ref.npy")
    n = int(os.environ.get("GOLEM_TOKENS", "1"))
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    token = int(ref[0])
    for pos in range(n):
        dut.token.value = token
        dut.pos.value = pos
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0
        while True:
            await RisingEdge(dut.clk)
            if int(dut.tok_valid.value):
                break
        got = int(dut.tok_out.value)
        want = int(ref[pos + 1])
        dut._log.info(f"pos {pos}: golem={got} golden={want} {'ok' if got == want else 'MISMATCH'}")
        assert got == want, f"pos {pos}: golem {got} != golden {want}"
        token = got
    dut._log.info(f"PASS: golem.sv top-level generated {n} tokens bit-exact vs golden greedy")
