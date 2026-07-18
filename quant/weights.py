import numpy as np

from mind import config


def load_fp32(checkpoint_path):
    import mlx.core as mx

    raw = {k: np.array(v, dtype=np.float32) for k, v in mx.load(str(checkpoint_path)).items()}
    w = {
        "tok_emb": raw["tok_emb.weight"],
        "pos_emb": raw["pos_emb.weight"],
        "out_norm": raw["out_norm.weight"],
    }
    for i in range(config.N_LAYERS):
        src = f"blocks.{i}."
        dst = f"layers.{i}."
        w[dst + "attn_norm"] = raw[src + "attn_norm.weight"]
        w[dst + "mlp_norm"] = raw[src + "mlp_norm.weight"]
        for name in ("wq", "wk", "wv", "wo"):
            w[dst + name] = raw[f"{src}attn.{name}.weight"]
        w[dst + "up"] = raw[src + "mlp.up.weight"]
        w[dst + "down"] = raw[src + "mlp.down.weight"]
    return w
