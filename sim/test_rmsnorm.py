import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from golden import ops

DATA = Path(__file__).resolve().parents[1] / "data"


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.x_we.value = 0
    dut.g_we.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def write_port(dut, we, addr, data, values):
    for i, v in enumerate(values.tolist()):
        we.value = 1
        addr.value = i
        data.value = int(v) & 0xFF
        await RisingEdge(dut.clk)
    we.value = 0


async def run_norm(dut, x, g, m, s):
    await write_port(dut, dut.x_we, dut.x_addr, dut.x_data, x)
    await write_port(dut, dut.g_we, dut.g_addr, dut.g_data, g)
    dut.cfg_mult.value = int(m)
    dut.cfg_shift.value = int(s)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    outs = {}
    while len(outs) < 256:
        await ReadOnly()
        if int(dut.out_valid.value):
            raw = int(dut.out_data.value)
            outs[int(dut.out_idx.value)] = raw - 256 if raw >= 128 else raw
        await RisingEdge(dut.clk)
    return np.array([outs[i] for i in range(256)], dtype=np.int64)


def check(name, got, want):
    if not np.array_equal(got, want.astype(np.int64)):
        bad = np.nonzero(got != want)[0][:8]
        raise AssertionError(f"{name}: mismatch at {bad.tolist()} got {got[bad].tolist()} "
                             f"want {want[bad].tolist()}")


@cocotb.test()
async def test_random_rows(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    g = q["layers.0.attn_norm.w"]
    m, s = int(q["layers.0.attn_norm.m"]), int(q["layers.0.attn_norm.s"])
    rng = np.random.default_rng(20)
    cases = [rng.integers(-127, 128, 256).astype(np.int8),
             np.zeros(256, dtype=np.int8),
             np.array([127] + [0] * 255, dtype=np.int8),
             np.array([1] + [0] * 255, dtype=np.int8),
             rng.integers(-3, 4, 256).astype(np.int8)]
    for i, x in enumerate(cases):
        got = await run_norm(dut, x, g, m, s)
        want = ops.int_rmsnorm(x[None, :], g, m, s)[0]
        check(f"random{i}", got, want)


@cocotb.test()
async def test_real_layer0(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    g = q["layers.0.attn_norm.w"]
    m, s = int(q["layers.0.attn_norm.m"]), int(q["layers.0.attn_norm.s"])
    for row in (0, 100, 255):
        x = vec["x0"][0, row]
        got = await run_norm(dut, x, g, m, s)
        check(f"real row{row}", got, vec["layers.0.an"][0, row])
