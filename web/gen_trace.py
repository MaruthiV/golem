import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
import numpy as np
from cocotb.triggers import Edge, RisingEdge

from mind import config
from sim.conductor import Q, WFLAT, boot, embed, load_layer_cfg

ROOT = Path(__file__).resolve().parents[1]
STATE_NAMES = ["idle", "norm", "matmul_Q", "matmul_K", "matmul_V", "scores", "softmax",
               "attention", "attention", "load", "matmul_O", "norm", "matmul_up",
               "load", "matmul_down"]
ENGINE = {"idle": "", "norm": "rmsnorm", "matmul_Q": "matmul", "matmul_K": "matmul",
          "matmul_V": "matmul", "scores": "attn", "softmax": "softmax", "attention": "attn",
          "load": "buffer", "matmul_O": "matmul", "matmul_up": "matmul",
          "matmul_down": "matmul"}


async def capture_layer_schedule(dut):
    events = []

    async def mon():
        last = None
        while True:
            await Edge(dut.state)
            await RisingEdge(dut.clk)
            v = int(dut.state.value)
            t = cocotb.utils.get_sim_time("ns")
            if v != last:
                events.append((t, STATE_NAMES[v]))
                last = v

    m = cocotb.start_soon(mon())
    ref = np.load(ROOT / "data" / "greedy_ref.npy")
    x = embed(int(ref[0]), 0)
    await load_layer_cfg(dut, 0)
    await wr_x(dut, x)
    dut.t.value = 0
    dut.layer.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    w = WFLAT[0]
    i = 0
    while i < w.shape[0] or int(dut.busy.value):
        if i < w.shape[0]:
            dut.w_valid.value = 1
            dut.w_data0.value = int(w[i, 0]) & 0xFF
            dut.w_data1.value = int(w[i, 1]) & 0xFF
            dut.w_data2.value = int(w[i, 2]) & 0xFF
            dut.w_data3.value = int(w[i, 3]) & 0xFF
        from cocotb.triggers import ReadOnly
        await ReadOnly()
        ready = int(dut.w_ready.value)
        await RisingEdge(dut.clk)
        if ready and i < w.shape[0]:
            i += 1
    m.kill()
    return events


async def wr_x(dut, x):
    for i, v in enumerate(x.tolist()):
        dut.xr_we.value = 1
        dut.xr_addr.value = i
        dut.xr_data.value = int(v) & 0xFF
        await RisingEdge(dut.clk)
    dut.xr_we.value = 0


@cocotb.test()
async def trace(dut):
    await boot(dut)
    events = await capture_layer_schedule(dut)
    t0 = events[0][0]
    phases = []
    for (t, name), (t2, _) in zip(events, events[1:] + [(events[-1][0], None)]):
        phases.append({"engine": ENGINE.get(name, ""), "op": name,
                       "start": round(t - t0), "dur": round(t2 - t)})
    layer_cycles = round((events[-1][0] - t0) / 10)

    tok = __import__("tokenizers").Tokenizer.from_file(str(ROOT / "data" / "tokenizer.json"))
    ref = np.load(ROOT / "data" / "greedy_ref.npy")
    words = [tok.decode([int(i)]) for i in ref[1:]]

    vec = dict(np.load(ROOT / "data" / "vectors" / "seq0.npz"))
    att = vec["layers.0.probs"][0, 0, :32, :32]
    att = (att / max(att.max(), 1) * 255).astype(int).tolist()

    out = {
        "phases": phases,
        "layer_cycles": layer_cycles,
        "n_layers": config.N_LAYERS,
        "cycles_per_token": layer_cycles * config.N_LAYERS,
        "params_m": 6.36,
        "words": words,
        "attention": att,
        "dim": config.DIM,
        "heads": config.N_HEADS,
        "vocab": config.VOCAB_SIZE,
    }
    (ROOT / "web" / "trace.json").write_text(json.dumps(out))
    dut._log.info(f"trace: {len(phases)} phases, {layer_cycles} cycles/layer, "
                  f"{layer_cycles * config.N_LAYERS} cycles/token")
