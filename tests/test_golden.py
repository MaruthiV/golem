import math
from pathlib import Path

import numpy as np
import pytest

from golden import ops
from mind import config

CKPT = Path(config.CHECKPOINT_DIR) / "golem_latest.safetensors"
NPZ = Path(config.DATA_DIR) / "golem_int8.npz"
VAL = Path(config.DATA_DIR) / "val.bin"


def test_quantize_multiplier_accuracy():
    rng = np.random.default_rng(0)
    for r in rng.uniform(1e-4, 8.0, size=200):
        m, s = ops.quantize_multiplier(float(r))
        approx = m * 2.0 ** -s
        assert abs(approx - r) / r < 1e-6


def test_requant_rounding():
    m, s = ops.quantize_multiplier(0.5)
    acc = np.array([3, -3, 4, -4, 1], dtype=np.int64)
    out = ops.requant(acc, m, s)
    assert out.tolist() == [2, -1, 2, -2, 1]


def test_isqrt_vec_exact():
    rng = np.random.default_rng(1)
    n = rng.integers(0, 1 << 44, size=1000)
    t = ops.isqrt_vec(n)
    for ni, ti in zip(n.tolist(), t.tolist()):
        assert ti == math.isqrt(ni)


@pytest.mark.skipif(not CKPT.exists(), reason="no checkpoint")
def test_float_ref_matches_mlx():
    import mlx.core as mx

    from golden.model import FloatRef
    from mind.model import make_model
    from quant.weights import load_fp32

    tokens = np.random.default_rng(2).integers(0, config.VOCAB_SIZE, size=(2, 64))
    ref_logits = FloatRef(load_fp32(CKPT)).forward(tokens)
    m = make_model()
    m.load_weights(str(CKPT))
    m.eval()
    mlx_logits = np.array(m(mx.array(tokens.astype(np.int32))))
    assert float(np.max(np.abs(ref_logits - mlx_logits))) < 2e-3


@pytest.mark.skipif(not (NPZ.exists() and CKPT.exists() and VAL.exists()), reason="no artifacts")
def test_int8_top1_agreement():
    from golden.model import FloatRef, IntGolem
    from quant.weights import load_fp32

    val = np.memmap(VAL, dtype=np.uint16, mode="r")
    rng = np.random.default_rng(3)
    idx = rng.integers(0, len(val) - config.CTX, size=4)
    tokens = np.stack([val[i:i + config.CTX] for i in idx]).astype(np.int64)
    f = FloatRef(load_fp32(CKPT)).forward(tokens)
    g = IntGolem(dict(np.load(NPZ))).forward(tokens)
    agree = float(np.mean(np.argmax(f, axis=-1) == np.argmax(g, axis=-1)))
    assert agree > 0.85, f"top1 agreement {agree:.3f}"
