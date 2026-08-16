import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def run(dut, limit=4_000_000):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            return
    raise AssertionError("demo never finished")


@cocotb.test()
async def stream(dut):
    await run(dut)
    cycles, reads = int(dut.cycles.value), int(dut.reads.value)
    bad = int(dut.mismatches.value)
    eff = reads / cycles
    mode = os.environ.get("DEMO_MODE", "burst")
    dut._log.info(f"{mode}: {reads} words in {cycles} cycles -> "
                  f"{cycles/reads:.2f} cycles/word, {eff*100:.1f}% schedule efficiency")
    assert bad == 0, f"{bad} words came back wrong"
    if mode == "burst":
        assert eff > 0.85, f"burst path only reached {eff*100:.1f}%"
    else:
        assert eff < 0.30, f"bypass path reached {eff*100:.1f}%, expected it to be bad"
