from pathlib import Path

import numpy as np

from golden.model import IntGolem
from mind import config


def main():
    data = Path(config.DATA_DIR)
    out_dir = data / "vectors"
    out_dir.mkdir(exist_ok=True)
    val = np.memmap(data / "val.bin", dtype=np.uint16, mode="r")
    tokens = np.array(val[1000:1000 + config.CTX]).astype(np.int64)[None, :]

    golem = IntGolem(dict(np.load(data / "golem_int8.npz")))
    golem.capture = {}
    logits = golem.forward(tokens)
    golem.capture["tokens"] = tokens
    golem.capture["logits"] = logits
    np.savez_compressed(out_dir / "seq0.npz", **golem.capture)
    print(f"saved {out_dir / 'seq0.npz'}: {len(golem.capture)} tensors")

    q = dict(np.load(data / "golem_int8.npz"))
    shifts = [int(np.min(q[k])) for k in q if k.endswith(".s")]
    print(f"min shift across all requant params: {min(shifts)} (RTL assumes >= 1)")


if __name__ == "__main__":
    main()
