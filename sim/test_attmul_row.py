import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from golden import ops

DATA = Path(__file__).resolve().parents[1] / "data"


def ref_attmul(p, v, m, s):
    acc = (p[None, :].astype(np.int64) @ v.astype(np.int64))[0]
    return ops.sat8(ops.requant(acc, m, s))


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.p_we.value = 0
    dut.v_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run_attmul(dut, p, v, m, s):
    L, J = v.shape
    for i, val in enumerate(p.tolist()):
        dut.p_we.value = 1
        dut.p_addr.value = i
        dut.p_data.value = int(val)
        await RisingEdge(dut.clk)
    dut.p_we.value = 0
    dut.cfg_len.value = L
    dut.cfg_j.value = J
    dut.cfg_mult.value = int(m)
    dut.cfg_shift.value = int(s)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    outs = {}
    mon_done = [False]

    async def monitor():
        while len(outs) < J:
            await ReadOnly()
            if int(dut.out_valid.value):
                raw = int(dut.out_data.value)
                outs[int(dut.out_idx.value)] = raw - 256 if raw >= 128 else raw
            await RisingEdge(dut.clk)
        mon_done[0] = True

    mon = cocotb.start_soon(monitor())
    flat = v.T.reshape(-1)
    i = 0
    while i < flat.shape[0]:
        dut.v_valid.value = 1
        dut.v_data.value = int(flat[i]) & 0xFF
        await ReadOnly()
        ready = int(dut.v_ready.value)
        await RisingEdge(dut.clk)
        if ready:
            i += 1
    dut.v_valid.value = 0
    await mon
    return np.array([outs[j] for j in range(J)], dtype=np.int64)


def check(name, got, want):
    if not np.array_equal(got, want.astype(np.int64)):
        bad = np.nonzero(got != want)[0][:8]
        raise AssertionError(f"{name}: mismatch at {bad.tolist()} got {got[bad].tolist()} "
                             f"want {want[bad].tolist()}")


@cocotb.test()
async def test_random(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    m, s = int(q["layers.0.att.m"]), int(q["layers.0.att.s"])
    rng = np.random.default_rng(40)
    for L in (1, 100, 256):
        p = rng.integers(0, 32769, L).astype(np.int64)
        v = rng.integers(-127, 128, (L, 32)).astype(np.int8)
        got = await run_attmul(dut, p, v, m, s)
        check(f"random L{L}", got, ref_attmul(p, v, m, s))


@cocotb.test()
async def test_real_layer0(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    m, s = int(q["layers.0.att.m"]), int(q["layers.0.att.s"])
    head = 2
    for row in (0, 100, 255):
        p = vec["layers.0.probs"][0, head, row, :row + 1]
        v = vec["layers.0.v"][0, :row + 1, head * 32:(head + 1) * 32]
        got = await run_attmul(dut, p, v, m, s)
        check(f"real row{row}", got, vec["layers.0.att"][0, row, head * 32:(head + 1) * 32])
