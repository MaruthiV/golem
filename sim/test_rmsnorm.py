import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, ReadWrite, RisingEdge

from golden import ops

DATA = Path(__file__).resolve().parents[1] / "data"

HOLD = {"x": np.zeros(256, dtype=np.int64), "g": np.zeros(256, dtype=np.int64)}


async def serve_mem(dut):
    while True:
        await RisingEdge(dut.clk)
        await ReadWrite()
        xa, ga = dut.x_rd_addr.value, dut.g_rd_addr.value
        if xa.is_resolvable:
            dut.x_rd_data.value = int(HOLD["x"][int(xa)]) & 0xFF
        if ga.is_resolvable:
            dut.g_rd_data.value = int(HOLD["g"][int(ga)]) & 0xFF


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.x_rd_data.value = 0
    dut.g_rd_data.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    cocotb.start_soon(serve_mem(dut))
    await RisingEdge(dut.clk)


async def run_norm(dut, x, g, m, s):
    HOLD["x"][:] = x
    HOLD["g"][:] = g
    dut.cfg_mult.value = int(m)
    dut.cfg_shift.value = int(s)
    await RisingEdge(dut.clk)
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
