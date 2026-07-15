import mlx.core as mx
import mlx.nn as nn


class Attention(nn.Module):
    def __init__(self, dim, n_heads):
        super().__init__()
        self.n_heads = n_heads
        self.scale = (dim // n_heads) ** -0.5
        self.wq = nn.Linear(dim, dim, bias=False)
        self.wk = nn.Linear(dim, dim, bias=False)
        self.wv = nn.Linear(dim, dim, bias=False)
        self.wo = nn.Linear(dim, dim, bias=False)

    def __call__(self, x, mask):
        B, T, D = x.shape
        q = self.wq(x).reshape(B, T, self.n_heads, -1).transpose(0, 2, 1, 3)
        k = self.wk(x).reshape(B, T, self.n_heads, -1).transpose(0, 2, 1, 3)
        v = self.wv(x).reshape(B, T, self.n_heads, -1).transpose(0, 2, 1, 3)
        out = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.scale, mask=mask)
        return self.wo(out.transpose(0, 2, 1, 3).reshape(B, T, D))


class MLP(nn.Module):
    def __init__(self, dim, ff_dim):
        super().__init__()
        self.up = nn.Linear(dim, ff_dim, bias=False)
        self.down = nn.Linear(ff_dim, dim, bias=False)

    def __call__(self, x):
        return self.down(nn.gelu(self.up(x)))


class Block(nn.Module):
    def __init__(self, dim, n_heads, ff_dim):
        super().__init__()
        self.attn_norm = nn.RMSNorm(dim)
        self.attn = Attention(dim, n_heads)
        self.mlp_norm = nn.RMSNorm(dim)
        self.mlp = MLP(dim, ff_dim)

    def __call__(self, x, mask):
        x = x + self.attn(self.attn_norm(x), mask)
        return x + self.mlp(self.mlp_norm(x))


class Golem(nn.Module):
    def __init__(self, vocab_size, dim, n_layers, n_heads, ff_dim, ctx):
        super().__init__()
        self.ctx = ctx
        self.tok_emb = nn.Embedding(vocab_size, dim)
        self.pos_emb = nn.Embedding(ctx, dim)
        self.blocks = [Block(dim, n_heads, ff_dim) for _ in range(n_layers)]
        self.out_norm = nn.RMSNorm(dim)

    def __call__(self, tokens):
        T = tokens.shape[1]
        x = self.tok_emb(tokens) + self.pos_emb(mx.arange(T))
        mask = nn.MultiHeadAttention.create_additive_causal_mask(T).astype(x.dtype)
        for block in self.blocks:
            x = block(x, mask)
        # tied embeddings: output projection reuses tok_emb
        return self.tok_emb.as_linear(self.out_norm(x))


def make_model():
    from mind import config

    return Golem(config.VOCAB_SIZE, config.DIM, config.N_LAYERS, config.N_HEADS,
                 config.FF_DIM, config.CTX)
