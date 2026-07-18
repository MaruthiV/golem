import json
from pathlib import Path

import numpy as np

from golden import ops, spec
from golden.model import FloatRef, IntGolem, split_heads
from mind import config
from quant.weights import load_fp32


def main():
    data = Path(config.DATA_DIR)
    val = np.memmap(data / "val.bin", dtype=np.uint16, mode="r")
    act = json.loads((data / "act_scales.json").read_text())
    ref = FloatRef(load_fp32(Path(config.CHECKPOINT_DIR) / "golem_latest.safetensors"))
    golem = IntGolem(dict(np.load(data / "golem_int8.npz")))

    rng = np.random.default_rng(7)
    idx = rng.integers(0, len(val) - config.CTX, size=8)
    tokens = np.stack([val[i:i + config.CTX] for i in idx]).astype(np.int64)

    ref.hooks = {}
    ref.forward(tokens)
    float_acts = dict(ref.captured) if hasattr(ref, "captured") else None

    # rerun float with captures
    captures = {}
    orig_record = ref.record

    def record_cap(name, x):
        captures[name] = np.array(x)
        orig_record(name, x)

    ref.record = record_cap
    ref.hooks = {}
    f_logits = ref.forward(tokens)

    # walk the int model manually, mirroring IntGolem.forward, comparing at each point
    q = golem.q
    rows = []

    def compare(name, int_arr, int_scale):
        f = captures[name]
        i = int_arr.astype(np.float64) * int_scale
        rel = np.sqrt(np.mean((f - i) ** 2)) / (np.sqrt(np.mean(f ** 2)) + 1e-12)
        clip = float(np.mean(np.abs(int_arr) >= 127))
        rows.append((name, rel, clip))

    tok = q["tok_emb.w"][tokens].astype(np.int64)
    pos = q["pos_emb.w"][np.arange(tokens.shape[-1])].astype(np.int64)
    a = ops.requant(tok, int(q["emb_tok.m"]), int(q["emb_tok.s"]))
    b = ops.requant(pos, int(q["emb_pos.m"]), int(q["emb_pos.s"]))
    x = ops.sat8(a + b)
    compare("x0", x, act["x0"])
    for li in range(config.N_LAYERS):
        p = f"layers.{li}."
        an = ops.int_rmsnorm(x, q[p + "attn_norm.w"], int(q[p + "attn_norm.m"]),
                             int(q[p + "attn_norm.s"]))
        compare(p + "an", an, act[p + "an"])
        qq = golem.linear(an, p + "wq")
        kk = golem.linear(an, p + "wk")
        vv = golem.linear(an, p + "wv")
        compare(p + "q", qq, act[p + "q"])
        qh, kh, vh = (split_heads(t, config.N_HEADS) for t in (qq, kk, vv))
        scores = ops.matmul_i8(qh, kh.swapaxes(-1, -2))
        probs = ops.int_softmax(scores, int(q[p + "sm.m"]), int(q[p + "sm.s"]),
                                q["exp_lut"], 0)
        acc = ops.matmul_i8(probs, vh)
        att = ops.sat8(ops.requant(acc, int(q[p + "att.m"]), int(q[p + "att.s"])))
        att = att.swapaxes(-3, -2).reshape(*x.shape)
        compare(p + "att", att, act[p + "att"])
        o = golem.linear(att, p + "wo")
        compare(p + "o", o, act[p + "o"])
        ra = ops.requant(x.astype(np.int64), int(q[p + "r2_in.m"]), int(q[p + "r2_in.s"]))
        rb = ops.requant(o.astype(np.int64), int(q[p + "r2_out.m"]), int(q[p + "r2_out.s"]))
        x = ops.sat8(ra + rb)
        compare(p + "r2", x, act[p + "r2"])
        mn = ops.int_rmsnorm(x, q[p + "mlp_norm.w"], int(q[p + "mlp_norm.m"]),
                             int(q[p + "mlp_norm.s"]))
        up = golem.linear(mn, p + "up")
        compare(p + "up", up, act[p + "up"])
        gel = q[p + "gelu_lut"][up.astype(np.int64) + 127]
        dn = golem.linear(gel, p + "down")
        compare(p + "dn", dn, act[p + "dn"])
        ra = ops.requant(x.astype(np.int64), int(q[p + "r3_in.m"]), int(q[p + "r3_in.s"]))
        rb = ops.requant(dn.astype(np.int64), int(q[p + "r3_out.m"]), int(q[p + "r3_out.s"]))
        x = ops.sat8(ra + rb)
        compare(p + "r3", x, act[p + "r3"])

    print(f"{'point':<22}{'rel_rms_err':>12}{'clip%':>8}")
    for name, rel, clip in rows:
        flag = "  <-- " + ("CLIP" if clip > 0.01 else "ERR") if (rel > 0.15 or clip > 0.01) else ""
        print(f"{name:<22}{rel:>12.4f}{clip * 100:>7.2f}%{flag}")

    g_logits = golem.forward(tokens).astype(np.float64) * golem.logit_scale()
    agree = float(np.mean(np.argmax(f_logits, -1) == np.argmax(g_logits, -1)))
    print(f"\ntop1 agreement {agree:.3f}")


if __name__ == "__main__":
    main()
