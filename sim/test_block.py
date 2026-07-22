import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

DATA = Path(__file__).resolve().parents[1] / "data"

CFG_SELS = ["attn_norm", "mlp_norm", "sm", "att", "r2_in", "r2_out", "r3_in", "r3_out"]
PBASES = {"wq": 0, "wk": 256, "wv": 512, "wo": 768, "up": 1024, "down": 1792}
W_ORDER = ["wq", "wk", "wv", "wo", "up", "down"]


def pack_words(row_i8):
    u = row_i8.astype(np.int8).view(np.uint8).astype(np.uint32).reshape(-1, 4)
    return u[:, 0] | (u[:, 1] << 8) | (u[:, 2] << 16) | (u[:, 3] << 24)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for sig in (dut.start, dut.xr_we, dut.cfg_we, dut.gc_we, dut.p_we, dut.sl_we,
                dut.gl_we, dut.kvd_we, dut.w_valid):
        sig.value = 0
    dut.rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def load_layer(dut, q, li=0):
    p = f"layers.{li}."
    for sel, name in enumerate(CFG_SELS):
        dut.cfg_we.value = 1
        dut.cfg_sel.value = sel
        dut.cfg_mult.value = int(q[p + name + ".m"])
        dut.cfg_shift.value = int(q[p + name + ".s"])
        await RisingEdge(dut.clk)
    dut.cfg_we.value = 0
    for gsel, name in ((0, "attn_norm.w"), (1, "mlp_norm.w")):
        for i, v in enumerate(q[p + name].tolist()):
            dut.gc_we.value = 1
            dut.gc_sel.value = gsel
            dut.gc_addr.value = i
            dut.gc_data.value = int(v) & 0xFF
            await RisingEdge(dut.clk)
    dut.gc_we.value = 0
    for i, v in enumerate(q["exp_lut"].tolist()):
        dut.sl_we.value = 1
        dut.sl_addr.value = i
        dut.sl_data.value = int(v)
        await RisingEdge(dut.clk)
    dut.sl_we.value = 0
    for i, v in enumerate(q[p + "gelu_lut"].tolist()):
        dut.gl_we.value = 1
        dut.gl_addr.value = i
        dut.gl_data.value = int(v) & 0xFF
        await RisingEdge(dut.clk)
    dut.gl_we.value = 0
    for name, base in PBASES.items():
        ms, ss = q[p + name + ".m"], q[p + name + ".s"]
        for i in range(len(ms)):
            dut.p_we.value = 1
            dut.p_addr.value = base + i
            dut.p_mult.value = int(ms[i])
            dut.p_shift.value = int(ss[i])
            await RisingEdge(dut.clk)
    dut.p_we.value = 0


def weight_stream(q, li=0):
    p = f"layers.{li}."
    return np.concatenate([q[p + n + ".w"].reshape(-1, 4) for n in W_ORDER])


async def run_token(dut, t, xrow, wflat):
    for i, v in enumerate(xrow.tolist()):
        dut.xr_we.value = 1
        dut.xr_addr.value = i
        dut.xr_data.value = int(v) & 0xFF
        await RisingEdge(dut.clk)
    dut.xr_we.value = 0
    dut.t.value = t
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    outs = {}

    async def monitor():
        while len(outs) < 256:
            await ReadOnly()
            if int(dut.r3_valid.value):
                raw = int(dut.r3_data.value)
                outs[int(dut.r3_idx.value)] = raw - 256 if raw >= 128 else raw
            await RisingEdge(dut.clk)

    mon = cocotb.start_soon(monitor())
    i = 0
    while i < wflat.shape[0]:
        dut.w_valid.value = 1
        dut.w_data0.value = int(wflat[i, 0]) & 0xFF
        dut.w_data1.value = int(wflat[i, 1]) & 0xFF
        dut.w_data2.value = int(wflat[i, 2]) & 0xFF
        dut.w_data3.value = int(wflat[i, 3]) & 0xFF
        await ReadOnly()
        ready = int(dut.w_ready.value)
        await RisingEdge(dut.clk)
        if ready:
            i += 1
    dut.w_valid.value = 0
    await mon
    while int(dut.busy.value):
        await RisingEdge(dut.clk)
    return np.array([outs[i] for i in range(256)], dtype=np.int64)


def check(name, got, want):
    if not np.array_equal(got, want.astype(np.int64)):
        bad = np.nonzero(got != want)[0][:8]
        raise AssertionError(f"{name}: mismatch at {bad.tolist()} got {got[bad].tolist()} "
                             f"want {want[bad].tolist()}")


@cocotb.test()
async def test_sequential_tokens(dut):
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    await setup(dut)
    await load_layer(dut, q)
    wflat = weight_stream(q)
    for t in range(16):
        got = await run_token(dut, t, vec["x0"][0, t], wflat)
        check(f"t{t}", got, vec["layers.0.r3"][0, t])


@cocotb.test()
async def test_deep_position_with_preloaded_kv(dut):
    q = dict(np.load(DATA / "golem_int8.npz"))
    vec = dict(np.load(DATA / "vectors" / "seq0.npz"))
    await setup(dut)
    await load_layer(dut, q)
    for t in range(100):
        for vsel, name in ((0, "layers.0.k"), (1, "layers.0.v")):
            words = pack_words(vec[name][0, t])
            for wi, wv in enumerate(words.tolist()):
                dut.kvd_we.value = 1
                dut.kvd_v.value = vsel
                dut.kvd_addr.value = t * 64 + wi
                dut.kvd_data.value = int(wv)
                await RisingEdge(dut.clk)
    dut.kvd_we.value = 0
    got = await run_token(dut, 100, vec["x0"][0, 100], weight_stream(q))
    check("t100", got, vec["layers.0.r3"][0, 100])
