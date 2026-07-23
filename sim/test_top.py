import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"
CLKS = 8


async def rx(dut, out):
    while True:
        await FallingEdge(dut.uart)
        await ClockCycles(dut.clk, CLKS + CLKS // 2)
        b = 0
        for i in range(8):
            b |= int(dut.uart.value) << i
            await ClockCycles(dut.clk, CLKS)
        out.append(b)


@cocotb.test()
async def story(dut):
    ref = np.load(DATA / "greedy_ref.npy")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    got = []
    cocotb.start_soon(rx(dut, got))
    await RisingEdge(dut.done)
    toks = [(got[2 * i] << 8) | got[2 * i + 1] for i in range(len(got) // 2)]
    dut._log.info(f"UART-streamed tokens: {toks}")
    for i, t in enumerate(toks):
        want = int(ref[i + 1])
        assert t == want, f"token {i}: uart={t} golden={want}"
    dut._log.info(f"PASS: golem_top autonomously generated + streamed {toks} over UART, bit-exact")
