import argparse
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

from golden.model import IntGolem
from mind import config


def generate(golem, tokenizer, rng, prompt="", max_new=300, temperature=0.8, top_k=40):
    eot_id = tokenizer.token_to_id(config.EOT_TOKEN)
    ids = tokenizer.encode(prompt).ids if prompt else [eot_id]
    scale = golem.logit_scale()
    tokens = list(ids)
    for _ in range(max_new):
        window = np.array([tokens[-config.CTX:]], dtype=np.int64)
        logits_i32 = golem.forward(window)[0, -1]
        if temperature == 0:
            next_id = int(np.argmax(logits_i32))
        else:
            logits = logits_i32.astype(np.float64) * scale / temperature
            if top_k:
                kth = np.sort(logits)[-top_k]
                logits = np.where(logits < kth, -np.inf, logits)
            p = np.exp(logits - logits.max())
            p /= p.sum()
            next_id = int(rng.choice(len(p), p=p))
        if next_id == eot_id:
            break
        tokens.append(next_id)
    return tokenizer.decode(tokens[len(ids):])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", default="")
    parser.add_argument("--n", type=int, default=1)
    parser.add_argument("--max-new", type=int, default=300)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--top-k", type=int, default=40)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    data = Path(config.DATA_DIR)
    golem = IntGolem(dict(np.load(data / "golem_int8.npz")))
    tokenizer = Tokenizer.from_file(str(data / "tokenizer.json"))
    rng = np.random.default_rng(args.seed)
    for i in range(args.n):
        story = generate(golem, tokenizer, rng, args.prompt, args.max_new,
                         args.temperature, args.top_k)
        print(f"--- story {i + 1} ---")
        print((args.prompt + story).strip())
        print()


if __name__ == "__main__":
    main()
