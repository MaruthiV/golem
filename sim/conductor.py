import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from golden import ops
from mind import config

DATA = Path(__file__).resolve().parents[1] / "data"
CFG_SELS = ["attn_norm", "mlp_norm", "sm", "att", "r2_in", "r2_out", "r3_in", "r3_out"]
PBASES = {"wq": 0, "wk": 256, "wv": 512, "wo": 768, "up": 1024, "down": 1792}
W_ORDER = ["wq", "wk", "wv", "wo", "up", "down"]

Q = dict(np.load(DATA / "golem_int8.npz"))
WFLAT = {li: np.concatenate([Q[f"layers.{li}.{n}.w"].reshape(-1, 4) for n in W_ORDER])
         for li in range(config.N_LAYERS)}


def embed(token, pos):
    tok = Q["tok_emb.w"][token].astype(np.int64)
    pe = Q["pos_emb.w"][pos].astype(np.int64)
    a = ops.sat16(ops.requant(tok, int(Q["emb_tok.m"]), int(Q["emb_tok.s"])))
    b = ops.sat16(ops.requant(pe, int(Q["emb_pos.m"]), int(Q["emb_pos.s"])))
    return ops.sat8(a + b)


def head(x):
    on = ops.int_rmsnorm(x[None, :], Q["out_norm.w"], int(Q["out_norm.m"]),
                         int(Q["out_norm.s"]))[0]
    logits = ops.matmul_i8(on[None, :], Q["tok_emb.w"].T)[0]
    return int(np.argmax(logits))


async def wr(dut, we, addr, data, values, mask=0xFF):
    for i, v in enumerate(values):
        we.value = 1
        addr.value = i
        data.value = int(v) & mask
        await RisingEdge(dut.clk)
    we.value = 0


async def boot(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for s in (dut.start, dut.xr_we, dut.cfg_we, dut.gc_we, dut.p_we, dut.sl_we,
              dut.gl_we, dut.kvd_we, dut.w_valid):
        s.value = 0
    dut.rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    await wr(dut, dut.sl_we, dut.sl_addr, dut.sl_data, Q["exp_lut"].tolist(), mask=0x1FFFF)


async def load_layer_cfg(dut, li):
    p = f"layers.{li}."
    for sel, name in enumerate(CFG_SELS):
        dut.cfg_we.value = 1
        dut.cfg_sel.value = sel
        dut.cfg_mult.value = int(Q[p + name + ".m"])
        dut.cfg_shift.value = int(Q[p + name + ".s"])
        await RisingEdge(dut.clk)
    dut.cfg_we.value = 0
    for gsel, name in ((0, "attn_norm.w"), (1, "mlp_norm.w")):
        for i, v in enumerate(Q[p + name].tolist()):
            dut.gc_we.value = 1
            dut.gc_sel.value = gsel
            dut.gc_addr.value = i
            dut.gc_data.value = int(v) & 0xFF
            await RisingEdge(dut.clk)
    dut.gc_we.value = 0
    await wr(dut, dut.gl_we, dut.gl_addr, dut.gl_data, Q[p + "gelu_lut"].tolist())
    for name, base in PBASES.items():
        ms, ss = Q[p + name + ".m"], Q[p + name + ".s"]
        for i in range(len(ms)):
            dut.p_we.value = 1
            dut.p_addr.value = base + i
            dut.p_mult.value = int(ms[i])
            dut.p_shift.value = int(ss[i])
            await RisingEdge(dut.clk)
    dut.p_we.value = 0


async def run_layer(dut, x, pos, li):
    await wr(dut, dut.xr_we, dut.xr_addr, dut.xr_data, x.tolist())
    dut.t.value = pos
    dut.layer.value = li
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
    w = WFLAT[li]
    i = 0
    while i < w.shape[0]:
        dut.w_valid.value = 1
        dut.w_data0.value = int(w[i, 0]) & 0xFF
        dut.w_data1.value = int(w[i, 1]) & 0xFF
        dut.w_data2.value = int(w[i, 2]) & 0xFF
        dut.w_data3.value = int(w[i, 3]) & 0xFF
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


@cocotb.test()
async def generate(dut):
    ref = np.load(DATA / "greedy_ref.npy")
    n_tokens = int(os.environ.get("GOLEM_TOKENS", "4"))
    await boot(dut)
    token = int(ref[0])
    produced = [token]
    for pos in range(n_tokens):
        x = embed(token, pos)
        for li in range(config.N_LAYERS):
            await load_layer_cfg(dut, li)
            x = await run_layer(dut, x, pos, li)
        nxt = head(x)
        produced.append(nxt)
        want = int(ref[pos + 1])
        status = "ok" if nxt == want else "MISMATCH"
        dut._log.info(f"pos {pos}: rtl={nxt} golden={want} {status}")
        assert nxt == want, f"pos {pos}: rtl {nxt} != golden {want}"
        token = nxt
    np.save(DATA / "rtl_story_ids.npy", np.array(produced, dtype=np.int64))
    dut._log.info(f"PASS: {n_tokens} tokens bit-exact vs golden greedy")
