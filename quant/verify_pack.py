import numpy as np

from mind import config
from quant.pack import PARAM_ORDER, SCALARS, W_ORDER, build


def unpack_i8(words, n):
    b = np.array(words[:n // 4], dtype=np.uint32)
    out = np.empty(n, dtype=np.int8)
    for k in range(4):
        out[k::4] = ((b >> (8 * k)) & 0xFF).astype(np.uint8).view(np.int8)
    return out


def main():
    from pathlib import Path

    q = dict(np.load(Path(config.DATA_DIR) / "golem_int8.npz"))
    w = build(q)
    W = w.words
    off = w.off
    bad = 0

    def check(name, got, want):
        nonlocal bad
        if not np.array_equal(np.asarray(got), np.asarray(want)):
            print(f"  MISMATCH {name}")
            bad += 1

    check("emb_tok.m", W[0], int(q["emb_tok.m"]))
    check("emb_tok.s", W[1], int(q["emb_tok.s"]))
    check("out_norm.m", W[4], int(q["out_norm.m"]))
    check("exp_lut", W[off["EXP_LUT"]:off["EXP_LUT"] + 512], q["exp_lut"])
    check("out_norm.w", unpack_i8(W[off["OUT_NORM_GAIN"]:], 256), q["out_norm.w"])
    check("pos_emb", unpack_i8(W[off["POS_EMB"]:], config.CTX * config.DIM),
          q["pos_emb.w"].reshape(-1))
    check("tok_emb", unpack_i8(W[off["TOK_EMB"]:], config.VOCAB_SIZE * config.DIM),
          q["tok_emb.w"].reshape(-1))

    stride = off["LAYER_STRIDE"]
    for li in (0, 3, 7):
        base = off["LAYERS"] + li * stride
        p = f"layers.{li}."
        c = base
        for name in SCALARS:
            check(f"L{li}.{name}.m", W[c], int(q[p + name + ".m"])); c += 2
        for name in PARAM_ORDER:
            n = len(q[p + name + ".m"])
            for i in range(n):
                if W[c] != int(q[p + name + ".m"][i]):
                    check(f"L{li}.{name}.m[{i}]", W[c], int(q[p + name + ".m"][i]))
                c += 2
        c += 64 + 64 + 64  # gains + gelu
        wq = unpack_i8(W[c:], q[p + "wq.w"].size)
        check(f"L{li}.wq.w", wq, q[p + "wq.w"].reshape(-1))
        c += q[p + "wq.w"].size // 4
        for name in W_ORDER[1:]:
            sz = q[p + name + ".w"].size
            c += sz // 4
        assert c - base == stride, f"L{li} stride {c-base} != {stride}"

    print("PASS: SDRAM image round-trips losslessly" if bad == 0 else f"FAIL: {bad} mismatches")
    assert bad == 0


if __name__ == "__main__":
    main()
