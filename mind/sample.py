import argparse
from pathlib import Path

import mlx.core as mx
from tokenizers import Tokenizer

from mind import config
from mind.model import make_model

NEG_INF = float("-inf")


def generate(model, tokenizer, prompt="", max_new=300, temperature=0.8, top_k=40):
    eot_id = tokenizer.token_to_id(config.EOT_TOKEN)
    ids = tokenizer.encode(prompt).ids if prompt else [eot_id]
    tokens = mx.array([ids])
    for _ in range(max_new):
        logits = model(tokens[:, -config.CTX:])[0, -1]
        if temperature == 0:
            next_id = mx.argmax(logits).item()
        else:
            logits = logits / temperature
            if top_k:
                kth_largest = mx.sort(logits)[-top_k]
                logits = mx.where(logits < kth_largest, NEG_INF, logits)
            next_id = mx.random.categorical(logits).item()
        if next_id == eot_id:
            break
        tokens = mx.concatenate([tokens, mx.array([[next_id]])], axis=1)
    return tokenizer.decode(tokens[0].tolist()[len(ids):])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default=f"{config.CHECKPOINT_DIR}/golem_latest.safetensors")
    parser.add_argument("--prompt", default="")
    parser.add_argument("--n", type=int, default=1)
    parser.add_argument("--max-new", type=int, default=300)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--top-k", type=int, default=40)
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    if args.seed is not None:
        mx.random.seed(args.seed)
    model = make_model()
    model.load_weights(args.checkpoint)
    model.eval()
    tokenizer = Tokenizer.from_file(str(Path(config.DATA_DIR) / "tokenizer.json"))
    for i in range(args.n):
        story = generate(model, tokenizer, args.prompt, args.max_new,
                         args.temperature, args.top_k)
        print(f"--- story {i + 1} ---")
        print((args.prompt + story).strip())
        print()


if __name__ == "__main__":
    main()
