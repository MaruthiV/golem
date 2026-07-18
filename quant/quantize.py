import json
from pathlib import Path

import numpy as np

from golden import spec
from golden.model import gelu
from golden.ops import quantize_multiplier
from mind import config
from quant.weights import load_fp32


def quant_per_tensor(w):
    s = max(float(np.max(np.abs(w))), 1e-8) / 127.0
    return np.clip(np.round(w / s), -127, 127).astype(np.int8), s


def quant_per_channel(w):
    s = np.maximum(np.max(np.abs(w), axis=1), 1e-8) / 127.0
    q = np.clip(np.round(w / s[:, None]), -127, 127).astype(np.int8)
    return q, s


def pack_multiplier(r):
    m, s = quantize_multiplier(r)
    return np.int64(m), np.int64(s)


def pack_multipliers(rs):
    ms, ss = zip(*(quantize_multiplier(float(r)) for r in rs))
    return np.array(ms, dtype=np.int64), np.array(ss, dtype=np.int64)


def main():
    data = Path(config.DATA_DIR)
    w = load_fp32(Path(config.CHECKPOINT_DIR) / "golem_latest.safetensors")
    act = json.loads((data / "act_scales.json").read_text())
    hd = config.DIM // config.N_HEADS
    norm_q = 1 << spec.NORM_INV_SHIFT
    out = {}

    tok_q, s_tok = quant_per_tensor(w["tok_emb"])
    pos_q, s_pos = quant_per_tensor(w["pos_emb"])
    out["tok_emb.w"], out["pos_emb.w"] = tok_q, pos_q
    out["emb_tok.m"], out["emb_tok.s"] = pack_multiplier(s_tok / act["x0"])
    out["emb_pos.m"], out["emb_pos.s"] = pack_multiplier(s_pos / act["x0"])

    def linear(dst, wname, s_in, s_out):
        q, s_w = quant_per_channel(w[wname])
        out[dst + ".w"] = q
        out[dst + ".m"], out[dst + ".s"] = pack_multipliers(s_in * s_w / s_out)

    def norm(dst, wname, s_out):
        g_q, s_g = quant_per_tensor(w[wname])
        out[dst + ".w"] = g_q
        out[dst + ".m"], out[dst + ".s"] = pack_multiplier(s_g / (norm_q * s_out))

    s_res = act["x0"]
    for i in range(config.N_LAYERS):
        p = f"layers.{i}."
        norm(p + "attn_norm", p + "attn_norm", act[p + "an"])
        linear(p + "wq", p + "wq", act[p + "an"], act[p + "q"])
        linear(p + "wk", p + "wk", act[p + "an"], act[p + "k"])
        linear(p + "wv", p + "wv", act[p + "an"], act[p + "v"])
        r_sm = (act[p + "q"] * act[p + "k"] / np.sqrt(hd)) / spec.SM_SCALE
        out[p + "sm.m"], out[p + "sm.s"] = pack_multiplier(r_sm)
        out[p + "att.m"], out[p + "att.s"] = pack_multiplier(
            act[p + "v"] / ((1 << spec.PROB_Q) * act[p + "att"]))
        linear(p + "wo", p + "wo", act[p + "att"], act[p + "o"])
        out[p + "r2_in.m"], out[p + "r2_in.s"] = pack_multiplier(s_res / act[p + "r2"])
        out[p + "r2_out.m"], out[p + "r2_out.s"] = pack_multiplier(act[p + "o"] / act[p + "r2"])
        norm(p + "mlp_norm", p + "mlp_norm", act[p + "mn"])
        linear(p + "up", p + "up", act[p + "mn"], act[p + "up"])
        codes = np.arange(-127, 128, dtype=np.float64) * act[p + "up"]
        lut = np.clip(np.round(gelu(codes) / act[p + "gel"]), -127, 127).astype(np.int8)
        out[p + "gelu_lut"] = np.concatenate([lut, np.zeros(1, dtype=np.int8)])
        linear(p + "down", p + "down", act[p + "gel"], act[p + "dn"])
        out[p + "r3_in.m"], out[p + "r3_in.s"] = pack_multiplier(act[p + "r2"] / act[p + "r3"])
        out[p + "r3_out.m"], out[p + "r3_out.s"] = pack_multiplier(act[p + "dn"] / act[p + "r3"])
        s_res = act[p + "r3"]

    norm("out_norm", "out_norm", act["on"])
    idx = np.arange(spec.EXP_LUT_SIZE, dtype=np.float64)
    out["exp_lut"] = np.round(np.exp(-idx * spec.SM_SCALE) * (1 << spec.EXP_LUT_BITS)).astype(np.int64)
    out["logit_scale"] = np.float64(act["on"] * s_tok)

    path = data / "golem_int8.npz"
    np.savez(path, **out)
    weight_bytes = sum(v.nbytes for k, v in out.items() if k.endswith(".w"))
    print(f"saved {path}: {weight_bytes / 1e6:.2f}MB of int8 weights")


if __name__ == "__main__":
    main()
