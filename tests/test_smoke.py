import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np

from mind.model import Golem

TINY = dict(vocab_size=64, dim=32, n_layers=2, n_heads=2, ff_dim=96, ctx=16)


def test_forward_shape():
    model = Golem(**TINY)
    tokens = mx.array(np.random.randint(0, 64, size=(3, 16)))
    logits = model(tokens)
    assert logits.shape == (3, 16, 64)
    assert mx.isfinite(logits).all().item()


def test_train_step_changes_params():
    mx.random.seed(0)
    model = Golem(**TINY)
    optimizer = optim.AdamW(learning_rate=1e-3)
    x = mx.array(np.random.randint(0, 64, size=(4, 16)))
    y = mx.array(np.random.randint(0, 64, size=(4, 16)))

    def loss_fn(model, x, y):
        logits = model(x)
        return nn.losses.cross_entropy(
            logits.reshape(-1, 64), y.reshape(-1), reduction="mean")

    before = model.blocks[0].attn.wq.weight.tolist()
    loss_and_grad = nn.value_and_grad(model, loss_fn)
    loss, grads = loss_and_grad(model, x, y)
    grads, _ = optim.clip_grad_norm(grads, 1.0)
    optimizer.update(model, grads)
    mx.eval(model.parameters())
    assert mx.isfinite(loss).item()
    assert model.blocks[0].attn.wq.weight.tolist() != before


def test_greedy_generate_runs():
    model = Golem(**TINY)
    tokens = mx.array([[1, 2, 3]])
    for _ in range(5):
        logits = model(tokens[:, -16:])[0, -1]
        next_id = mx.argmax(logits).item()
        tokens = mx.concatenate([tokens, mx.array([[next_id]])], axis=1)
    assert tokens.shape == (1, 8)
