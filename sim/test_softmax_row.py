import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from golden import ops, spec

DATA = Path(__file__).resolve().parents[1] / "data"


def ref_softmax_row(scores, m, s, lut):
    d = (np.max(scores) - scores).astype(np.int64)
    idx = np.clip(ops.requant(d, m, s), 0, spec.EXP_LUT_SIZE - 1)
    e = lut[idx]
    denom = max(int(e.sum()), 1)
    return (e << spec.EXP_LUT_BITS) // denom


async def setup(dut, lut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.s_we.value = 0
    dut.lut_we.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    for i, v in enumerate(lut.tolist()):
        dut.lut_we.value = 1
        dut.lut_addr.value = i
        dut.lut_data.value = int(v)
        await RisingEdge(dut.clk)
    dut.lut_we.value = 0


async def run_row(dut, scores, m, s):
    L = len(scores)
    for i, v in enumerate(scores.tolist()):
        dut.s_we.value = 1
        dut.s_addr.value = i
        dut.s_data.value = int(v) & 0xFFFFFFFF
        await RisingEdge(dut.clk)
    dut.s_we.value = 0
    dut.cfg_len.value = L
    dut.cfg_mult.value = int(m)
    dut.cfg_shift.value = int(s)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    outs = {}
    while len(outs) < L:
        await ReadOnly()
        if int(dut.out_valid.value):
            outs[int(dut.out_idx.value)] = int(dut.out_data.value)
        await RisingEdge(dut.clk)
    return np.array([outs[i] for i in range(L)], dtype=np.int64)


def check(name, got, want):
    if not np.array_equal(got, want.astype(np.int64)):
        bad = np.nonzero(got != want)[0][:8]
        raise AssertionError(f"{name}: mismatch at {bad.tolist()} got {got[bad].tolist()} "
                             f"want {want[bad].tolist()}")


@cocotb.test()
async def test_random_rows(dut):
    q = dict(np.load(DATA / "golem_int8.npz"))
    lut = q["exp_lut"]
    m, s = int(q["layers.0.sm.m"]), int(q["layers.0.sm.s"])
    await setup(dut, lut)
    rng = np.random.default_rng(30)
    for L in (1, 7, 100):
        scores = rng.integers(-(1 << 19), 1 << 19, L).astype(np.int64)
        got = await run_row(dut, scores, m, s)
        check(f"random L{L}", got, ref_softmax_row(scores, m, s, lut))


@cocotb.test()
async def test_real_layer0(dut):
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    lut = q["exp_lut"]
    m, s = int(q["layers.0.sm.m"]), int(q["layers.0.sm.s"])
    await setup(dut, lut)
    for row in (0, 100, 255):
        scores = vec["layers.0.scores"][0, 2, row, :row + 1]
        got = await run_row(dut, scores, m, s)
        check(f"real row{row}", got, vec["layers.0.probs"][0, 2, row, :row + 1])
