import numpy as np

from golden import spec


def quantize_multiplier(r):
    if r <= 0:
        raise ValueError("multiplier must be positive")
    shift = 0
    while r < 0.5:
        r *= 2.0
        shift += 1
    while r >= 1.0:
        r /= 2.0
        shift -= 1
    m = int(round(r * (1 << 31)))
    if m == (1 << 31):
        m //= 2
        shift -= 1
    return m, 31 + shift


def requant(acc, m, shift):
    acc = acc.astype(np.int64) * np.int64(m)
    if np.ndim(shift) == 0:
        if shift > 0:
            acc = (acc + (np.int64(1) << np.int64(shift - 1))) >> np.int64(shift)
        else:
            acc = acc << np.int64(-shift)
    else:
        shift = shift.astype(np.int64)
        half = np.where(shift > 0, np.int64(1) << np.maximum(shift - 1, 0), 0)
        acc = np.where(shift > 0, (acc + half) >> np.maximum(shift, 0),
                       acc << np.maximum(-shift, 0))
    return acc


def sat8(x):
    return np.clip(x, -127, 127).astype(np.int8)


def matmul_i8(x_i8, w_i8_t):
    # int8 x int8 with int32 accum, computed exactly in float64 blas for speed
    acc = x_i8.astype(np.float64) @ w_i8_t.astype(np.float64)
    return np.rint(acc).astype(np.int64)


def isqrt_vec(n):
    # exact integer sqrt: float sqrt then correct the off-by-ones
    t = np.floor(np.sqrt(n.astype(np.float64))).astype(np.int64)
    t = np.where((t + 1) * (t + 1) <= n, t + 1, t)
    t = np.where(t * t > n, t - 1, t)
    return t


def int_rmsnorm(x_i8, g_i8, m, shift):
    x = x_i8.astype(np.int64)
    d = x.shape[-1]
    n32 = np.sum(x * x, axis=-1, keepdims=True)
    msq = (n32 + d // 2) // d
    t = isqrt_vec(msq << spec.NORM_ISQRT_SHIFT)
    t = np.maximum(t, 1)
    inv = ((1 << (spec.NORM_INV_SHIFT + spec.NORM_ISQRT_SHIFT // 2)) + t // 2) // t
    inv = np.where(msq == 0, 0, inv)
    acc = x * inv * g_i8.astype(np.int64)
    return sat8(requant(acc, m, shift))


def int_softmax(scores_i32, m_sm, shift_sm, exp_lut, causal_from):
    T = scores_i32.shape[-2]
    Tk = scores_i32.shape[-1]
    mask = np.tril(np.ones((T, Tk), dtype=bool), k=causal_from)
    neg = np.int64(-(1 << 40))
    s = np.where(mask, scores_i32.astype(np.int64), neg)
    row_max = s.max(axis=-1, keepdims=True)
    diff = row_max - s
    idx = requant(diff, m_sm, shift_sm)
    idx = np.clip(idx, 0, spec.EXP_LUT_SIZE - 1).astype(np.int64)
    e = np.where(mask, exp_lut[idx], 0).astype(np.int64)
    denom = e.sum(axis=-1, keepdims=True)
    denom = np.maximum(denom, 1)
    # probs stay in q15: int8 probs destroyed the distribution at T=256
    return (e << spec.EXP_LUT_BITS) // denom
