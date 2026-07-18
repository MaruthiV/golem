import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from golden import ops

DATA = Path(__file__).resolve().parents[1] / "data"


def ref_matmul(x, w, m, s):
    acc = ops.matmul_i8(x[None, :], w.T)[0]
    return ops.sat8(ops.requant(acc, m, s))


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.x_we.value = 0
    dut.p_we.value = 0
    dut.w_valid.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def load(dut, x, m, s):
    for i, v in enumerate(x.tolist()):
        dut.x_we.value = 1
        dut.x_addr.value = i
        dut.x_data.value = int(v) & 0xFF
        await RisingEdge(dut.clk)
    dut.x_we.value = 0
    for i, (mi, si) in enumerate(zip(np.atleast_1d(m).tolist(), np.atleast_1d(s).tolist())):
        dut.p_we.value = 1
        dut.p_addr.value = i
        dut.p_mult.value = int(mi)
        dut.p_shift.value = int(si)
        await RisingEdge(dut.clk)
    dut.p_we.value = 0


async def monitor(dut, outs, expect):
    while len(outs) < expect:
        await ReadOnly()
        if int(dut.out_valid.value):
            idx = int(dut.out_idx.value)
            raw = int(dut.out_data.value)
            outs[idx if expect > 1 else 0] = raw - 256 if raw >= 128 else raw
        await RisingEdge(dut.clk)


async def run_matmul(dut, x, w, m, s):
    J, K = w.shape
    await load(dut, x, np.broadcast_to(m, (J,)), np.broadcast_to(s, (J,)))
    dut.cfg_k.value = K
    dut.cfg_j.value = J
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    outs = {}
    mon = cocotb.start_soon(monitor(dut, outs, J))
    flat = w.reshape(J * (K // 4), 4)
    i = 0
    while i < flat.shape[0]:
        dut.w_valid.value = 1
        dut.w_data0.value = int(flat[i, 0]) & 0xFF
        dut.w_data1.value = int(flat[i, 1]) & 0xFF
        dut.w_data2.value = int(flat[i, 2]) & 0xFF
        dut.w_data3.value = int(flat[i, 3]) & 0xFF
        await ReadOnly()
        ready = int(dut.w_ready.value)
        await RisingEdge(dut.clk)
        if ready:
            i += 1
    dut.w_valid.value = 0
    await mon
    return np.array([outs[j] for j in range(J)], dtype=np.int64)


def check(name, got, want):
    if not np.array_equal(got, want.astype(np.int64)):
        bad = np.nonzero(got != want)[0][:8]
        raise AssertionError(f"{name}: mismatch at {bad.tolist()} got {got[bad].tolist()} "
                             f"want {want[bad].tolist()}")


@cocotb.test()
async def test_tiny(dut):
    await setup(dut)
    x = np.array([1, -2, 3, -4, 5, -6, 7, -128 + 1], dtype=np.int8)
    w = np.array([[1, 1, 1, 1, 1, 1, 1, 1],
                  [-127, 127, -127, 127, -127, 127, -127, 127],
                  [0, 0, 0, 0, 0, 0, 0, 9]], dtype=np.int8)
    m, s = ops.quantize_multiplier(0.5)
    got = await run_matmul(dut, x, w, np.full(3, m), np.full(3, s))
    check("tiny", got, ref_matmul(x, w, np.full(3, m), np.full(3, s)))


@cocotb.test()
async def test_random_k256(dut):
    await setup(dut)
    rng = np.random.default_rng(10)
    x = rng.integers(-127, 128, 256).astype(np.int8)
    w = rng.integers(-127, 128, (256, 256)).astype(np.int8)
    ms = [ops.quantize_multiplier(float(r)) for r in rng.uniform(1e-4, 0.9, 256)]
    m = np.array([a for a, _ in ms])
    s = np.array([b for _, b in ms])
    got = await run_matmul(dut, x, w, m, s)
    check("k256", got, ref_matmul(x, w, m, s))


@cocotb.test()
async def test_random_k768(dut):
    await setup(dut)
    rng = np.random.default_rng(11)
    x = rng.integers(-127, 128, 768).astype(np.int8)
    w = rng.integers(-127, 128, (64, 768)).astype(np.int8)
    ms = [ops.quantize_multiplier(float(r)) for r in rng.uniform(1e-4, 0.9, 64)]
    m = np.array([a for a, _ in ms])
    s = np.array([b for _, b in ms])
    got = await run_matmul(dut, x, w, m, s)
    check("k768", got, ref_matmul(x, w, m, s))


@cocotb.test()
async def test_real_layer0_wq(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    for row in (0, 17):
        x = vec["layers.0.an"][0, row]
        got = await run_matmul(dut, x, q["layers.0.wq.w"],
                               q["layers.0.wq.m"], q["layers.0.wq.s"])
        check(f"wq row{row}", got, vec["layers.0.q"][0, row])


@cocotb.test()
async def test_real_layer0_down(dut):
    await setup(dut)
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    x = vec["layers.0.gel"][0, 3]
    got = await run_matmul(dut, x, q["layers.0.down.w"],
                           q["layers.0.down.m"], q["layers.0.down.s"])
    check("down row3", got, vec["layers.0.dn"][0, 3])
