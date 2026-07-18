import json
from pathlib import Path

import numpy as np

from golden import spec
from golden.model import FloatRef
from mind import config
from quant.weights import load_fp32


def main():
    data = Path(config.DATA_DIR)
    val = np.memmap(data / "val.bin", dtype=np.uint16, mode="r")
    ref = FloatRef(load_fp32(Path(config.CHECKPOINT_DIR) / "golem_latest.safetensors"))
    ref.hooks = {}
    rng = np.random.default_rng(4242)
    for _ in range(spec.CALIB_BATCHES):
        idx = rng.integers(0, len(val) - config.CTX, size=spec.CALIB_BATCH_SIZE)
        tokens = np.stack([val[i:i + config.CTX] for i in idx]).astype(np.int64)
        ref.forward(tokens)
    scales = {k: max(v, 1e-8) / 127.0 for k, v in ref.hooks.items()}
    out = data / "act_scales.json"
    out.write_text(json.dumps(scales, indent=1))
    print(f"saved {out} ({len(scales)} activation scales)")


if __name__ == "__main__":
    main()
