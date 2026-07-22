import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

DATA = Path(__file__).resolve().parents[1] / "data"


@cocotb.test()
async def test_sweep_and_real(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    lut = q["layers.0.gelu_lut"]
    dut.lut_we.value = 0
    await RisingEdge(dut.clk)
    for i in range(256):
        dut.lut_we.value = 1
        dut.lut_addr.value = i
        dut.lut_data.value = int(lut[i]) & 0xFF
        await RisingEdge(dut.clk)
    dut.lut_we.value = 0

    for x in range(-127, 128):
        dut.x.value = x & 0xFF
        await Timer(1, unit="ns")
        raw = int(dut.y.value)
        got = raw - 256 if raw >= 128 else raw
        want = int(lut[x + 127])
        assert got == want, f"x={x} got {got} want {want}"

    up = vec["layers.0.up"][0, 7]
    gel = vec["layers.0.gel"][0, 7]
    for k in range(0, 768, 97):
        dut.x.value = int(up[k]) & 0xFF
        await Timer(1, unit="ns")
        raw = int(dut.y.value)
        got = raw - 256 if raw >= 128 else raw
        assert got == int(gel[k]), f"real k={k}"
