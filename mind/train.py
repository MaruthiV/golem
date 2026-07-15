import argparse
import json
import time
from functools import partial
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np
from mlx.utils import tree_flatten
from tokenizers import Tokenizer

from mind import config
from mind.model import make_model
from mind.sample import generate


def get_batch(data, rng):
    idx = rng.integers(0, len(data) - config.CTX - 1, size=config.BATCH_SIZE)
    x = np.stack([data[i:i + config.CTX] for i in idx]).astype(np.int32)
    y = np.stack([data[i + 1:i + config.CTX + 1] for i in idx]).astype(np.int32)
    return mx.array(x), mx.array(y)


def loss_fn(model, x, y):
    logits = model(x)
    return nn.losses.cross_entropy(
        logits.reshape(-1, logits.shape[-1]), y.reshape(-1), reduction="mean")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    mx.random.seed(1337)
    rng = np.random.default_rng(1337)
    data_dir = Path(config.DATA_DIR)
    ckpt_dir = Path(config.CHECKPOINT_DIR)
    ckpt_dir.mkdir(exist_ok=True)
    train_data = np.memmap(data_dir / "train.bin", dtype=np.uint16, mode="r")
    val_data = np.memmap(data_dir / "val.bin", dtype=np.uint16, mode="r")
    tokenizer = Tokenizer.from_file(str(data_dir / "tokenizer.json"))

    model = make_model()
    n_params = sum(p.size for _, p in tree_flatten(model.parameters()))
    print(f"params: {n_params / 1e6:.2f}M ({n_params / 1e6:.2f}MB int8)")

    start_step = 0
    latest = ckpt_dir / "golem_latest.safetensors"
    meta_path = ckpt_dir / "meta.json"
    if args.resume and latest.exists():
        model.load_weights(str(latest))
        start_step = json.loads(meta_path.read_text())["step"]
        print(f"resumed from step {start_step}")

    schedule = optim.join_schedules(
        [optim.linear_schedule(0.0, config.LR, config.WARMUP_STEPS),
         optim.cosine_decay(config.LR, config.MAX_STEPS - config.WARMUP_STEPS, config.MIN_LR)],
        [config.WARMUP_STEPS])
    optimizer = optim.AdamW(learning_rate=schedule, weight_decay=config.WEIGHT_DECAY)
    loss_and_grad = nn.value_and_grad(model, loss_fn)

    state = [model.state, optimizer.state]

    @partial(mx.compile, inputs=state, outputs=state)
    def train_step(x, y):
        loss, grads = loss_and_grad(model, x, y)
        grads, _ = optim.clip_grad_norm(grads, config.GRAD_CLIP)
        optimizer.update(model, grads)
        return loss

    def val_loss():
        losses = []
        for _ in range(config.VAL_BATCHES):
            x, y = get_batch(val_data, rng)
            losses.append(loss_fn(model, x, y).item())
        return sum(losses) / len(losses)

    stories_log = ckpt_dir / "stories.log"
    t0 = time.time()
    tokens_seen = 0
    for step in range(start_step + 1, config.MAX_STEPS + 1):
        x, y = get_batch(train_data, rng)
        loss = train_step(x, y)
        mx.eval(state)
        tokens_seen += config.BATCH_SIZE * config.CTX

        if step % 50 == 0:
            tok_s = tokens_seen / (time.time() - t0)
            print(f"step {step} loss {loss.item():.4f} {tok_s:,.0f} tok/s")

        if step % config.VAL_EVERY == 0:
            vl = val_loss()
            print(f"step {step} val_loss {vl:.4f}")

        if step % config.SAMPLE_EVERY == 0:
            story = generate(model, tokenizer, "Once upon a time", max_new=200)
            with open(stories_log, "a") as f:
                f.write(f"\n=== step {step} ===\nOnce upon a time{story}\n")
            print(f"sampled story at step {step} -> {stories_log}")

        if step % config.CHECKPOINT_EVERY == 0 or step == config.MAX_STEPS:
            model.save_weights(str(latest))
            model.save_weights(str(ckpt_dir / f"golem_{step:06d}.safetensors"))
            meta_path.write_text(json.dumps({"step": step, "params": n_params}))

    final_vl = val_loss()
    print(f"done. final val_loss {final_vl:.4f}")
    meta_path.write_text(json.dumps({"step": config.MAX_STEPS, "params": n_params,
                                     "final_val_loss": final_vl}))


if __name__ == "__main__":
    main()
