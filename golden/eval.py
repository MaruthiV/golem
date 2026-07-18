import argparse
from pathlib import Path

import numpy as np

from golden.model import FloatRef, IntGolem
from mind import config
from quant.weights import load_fp32

FP32_REF_LOSS = 1.3903
G1_MAX_DELTA = 0.05


def cross_entropy(logits, targets):
    logits = logits - logits.max(axis=-1, keepdims=True)
    logsumexp = np.log(np.sum(np.exp(logits), axis=-1))
    picked = np.take_along_axis(logits, targets[..., None], axis=-1)[..., 0]
    return float(np.mean(logsumexp - picked))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--batches", type=int, default=16)
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()

    data = Path(config.DATA_DIR)
    val = np.memmap(data / "val.bin", dtype=np.uint16, mode="r")
    ref = FloatRef(load_fp32(Path(config.CHECKPOINT_DIR) / "golem_latest.safetensors"))
    golem = IntGolem(dict(np.load(data / "golem_int8.npz")))
    scale = golem.logit_scale()

    rng = np.random.default_rng(9999)
    f_losses, i_losses = [], []
    for b in range(args.batches):
        idx = rng.integers(0, len(val) - config.CTX - 1, size=args.batch_size)
        x = np.stack([val[i:i + config.CTX] for i in idx]).astype(np.int64)
        y = np.stack([val[i + 1:i + config.CTX + 1] for i in idx]).astype(np.int64)
        f_losses.append(cross_entropy(ref.forward(x), y))
        i_losses.append(cross_entropy(golem.forward(x).astype(np.float64) * scale, y))
        print(f"batch {b + 1}/{args.batches} fp32 {f_losses[-1]:.4f} int8 {i_losses[-1]:.4f}")

    f, i = float(np.mean(f_losses)), float(np.mean(i_losses))
    delta = (i - f) / f
    print(f"\nfp32 loss {f:.4f} (train-time ref {FP32_REF_LOSS})")
    print(f"int8 loss {i:.4f}")
    print(f"delta {delta * 100:+.2f}% (G1 bar: <{G1_MAX_DELTA * 100:.0f}%)")
    print("G1 loss check:", "PASS" if delta < G1_MAX_DELTA else "FAIL")


if __name__ == "__main__":
    main()
