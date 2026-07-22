import numpy as np
from scipy.special import erf

from golden import ops, spec
from mind import config

EPS = 1e-5


def gelu(x):
    return x * 0.5 * (1.0 + erf(x / np.sqrt(2.0)))


def rmsnorm(x, g):
    return x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + EPS) * g


def softmax(x):
    e = np.exp(x - x.max(axis=-1, keepdims=True))
    return e / e.sum(axis=-1, keepdims=True)


def split_heads(x, n_heads):
    T, D = x.shape[-2:]
    return x.reshape(*x.shape[:-1], n_heads, D // n_heads).swapaxes(-3, -2)


class FloatRef:
    def __init__(self, weights):
        self.w = weights
        self.hooks = None

    def record(self, name, x):
        if self.hooks is not None:
            peak = float(np.max(np.abs(x))) if x.size else 0.0
            self.hooks[name] = max(self.hooks.get(name, 0.0), peak)

    def forward(self, tokens):
        w = self.w
        x = w["tok_emb"][tokens] + w["pos_emb"][np.arange(tokens.shape[-1])]
        self.record("x0", x)
        for i in range(config.N_LAYERS):
            p = f"layers.{i}."
            an = rmsnorm(x, w[p + "attn_norm"])
            self.record(p + "an", an)
            q, k, v = an @ w[p + "wq"].T, an @ w[p + "wk"].T, an @ w[p + "wv"].T
            self.record(p + "q", q), self.record(p + "k", k), self.record(p + "v", v)
            qh, kh, vh = (split_heads(t, config.N_HEADS) for t in (q, k, v))
            T = tokens.shape[-1]
            scores = qh @ kh.swapaxes(-1, -2) / np.sqrt(config.DIM // config.N_HEADS)
            scores = np.where(np.tril(np.ones((T, T), dtype=bool)), scores, -1e30)
            att = softmax(scores) @ vh
            att = att.swapaxes(-3, -2).reshape(*x.shape)
            self.record(p + "att", att)
            o = att @ w[p + "wo"].T
            self.record(p + "o", o)
            x = x + o
            self.record(p + "r2", x)
            mn = rmsnorm(x, w[p + "mlp_norm"])
            self.record(p + "mn", mn)
            up = mn @ w[p + "up"].T
            self.record(p + "up", up)
            gel = gelu(up)
            self.record(p + "gel", gel)
            dn = gel @ w[p + "down"].T
            self.record(p + "dn", dn)
            x = x + dn
            self.record(p + "r3", x)
        on = rmsnorm(x, w["out_norm"])
        self.record("on", on)
        return on @ w["tok_emb"].T


class IntGolem:
    def __init__(self, q):
        self.q = q
        self.capture = None

    def cap(self, name, arr):
        if self.capture is not None:
            self.capture[name] = np.array(arr)

    def linear(self, x_i8, name):
        q = self.q
        acc = ops.matmul_i8(x_i8, q[name + ".w"].T)
        return ops.sat8(ops.requant(acc, q[name + ".m"], q[name + ".s"]))

    def forward(self, tokens):
        q = self.q
        tok = q["tok_emb.w"][tokens].astype(np.int64)
        pos = q["pos_emb.w"][np.arange(tokens.shape[-1])].astype(np.int64)
        a = ops.sat16(ops.requant(tok, int(q["emb_tok.m"]), int(q["emb_tok.s"])))
        b = ops.sat16(ops.requant(pos, int(q["emb_pos.m"]), int(q["emb_pos.s"])))
        x = ops.sat8(a + b)
        self.cap("x0", x)
        for i in range(config.N_LAYERS):
            p = f"layers.{i}."
            an = ops.int_rmsnorm(x, q[p + "attn_norm.w"], int(q[p + "attn_norm.m"]),
                                 int(q[p + "attn_norm.s"]))
            self.cap(p + "an", an)
            qq = self.linear(an, p + "wq")
            kk = self.linear(an, p + "wk")
            vv = self.linear(an, p + "wv")
            self.cap(p + "q", qq), self.cap(p + "k", kk), self.cap(p + "v", vv)
            qh, kh, vh = (split_heads(t, config.N_HEADS) for t in (qq, kk, vv))
            scores = ops.matmul_i8(qh, kh.swapaxes(-1, -2))
            self.cap(p + "scores", scores)
            probs = ops.int_softmax(scores, int(q[p + "sm.m"]), int(q[p + "sm.s"]),
                                    q["exp_lut"], 0)
            self.cap(p + "probs", probs)
            acc = ops.matmul_i8(probs, vh)
            att = ops.sat8(ops.requant(acc, int(q[p + "att.m"]), int(q[p + "att.s"])))
            att = att.swapaxes(-3, -2).reshape(*x.shape)
            self.cap(p + "att", att)
            o = self.linear(att, p + "wo")
            self.cap(p + "o", o)
            ra = ops.sat16(ops.requant(x.astype(np.int64), int(q[p + "r2_in.m"]), int(q[p + "r2_in.s"])))
            rb = ops.sat16(ops.requant(o.astype(np.int64), int(q[p + "r2_out.m"]), int(q[p + "r2_out.s"])))
            x = ops.sat8(ra + rb)
            self.cap(p + "r2", x)
            mn = ops.int_rmsnorm(x, q[p + "mlp_norm.w"], int(q[p + "mlp_norm.m"]),
                                 int(q[p + "mlp_norm.s"]))
            self.cap(p + "mn", mn)
            up = self.linear(mn, p + "up")
            self.cap(p + "up", up)
            gel = q[p + "gelu_lut"][up.astype(np.int64) + 127]
            self.cap(p + "gel", gel)
            dn = self.linear(gel, p + "down")
            self.cap(p + "dn", dn)
            ra = ops.sat16(ops.requant(x.astype(np.int64), int(q[p + "r3_in.m"]), int(q[p + "r3_in.s"])))
            rb = ops.sat16(ops.requant(dn.astype(np.int64), int(q[p + "r3_out.m"]), int(q[p + "r3_out.s"])))
            x = ops.sat8(ra + rb)
            self.cap(p + "r3", x)
        on = ops.int_rmsnorm(x, q["out_norm.w"], int(q["out_norm.m"]), int(q["out_norm.s"]))
        logits = ops.matmul_i8(on, q["tok_emb.w"].T)
        return logits

    def logit_scale(self):
        return float(self.q["logit_scale"])
