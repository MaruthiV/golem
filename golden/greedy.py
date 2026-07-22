import argparse
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

from golden.model import IntGolem
from mind import config


def greedy_ids(golem, start_id, max_new):
    tokens = [start_id]
    for _ in range(max_new):
        window = np.array([tokens[-config.CTX:]], dtype=np.int64)
        logits = golem.forward(window)[0, -1]
        nxt = int(np.argmax(logits))
        tokens.append(nxt)
        if nxt == start_id:
            break
    return tokens


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-new", type=int, default=60)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    data = Path(config.DATA_DIR)
    golem = IntGolem(dict(np.load(data / "golem_int8.npz")))
    tokenizer = Tokenizer.from_file(str(data / "tokenizer.json"))
    eot = tokenizer.token_to_id(config.EOT_TOKEN)
    ids = greedy_ids(golem, eot, args.max_new)
    print(tokenizer.decode(ids[1:]))
    if args.out:
        np.save(args.out, np.array(ids, dtype=np.int64))
        print(f"\nsaved {len(ids)} ids -> {args.out}")


if __name__ == "__main__":
    main()
