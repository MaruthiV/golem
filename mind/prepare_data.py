from pathlib import Path

import numpy as np
from tokenizers import Tokenizer

from mind import config

CHUNK_STORIES = 10_000


def encode_file(tokenizer, eot_id, txt_path, bin_path):
    tokens_written = 0
    story = []
    buffer = []
    with open(txt_path, encoding="utf-8") as f, open(bin_path, "wb") as out:
        def flush_buffer():
            nonlocal tokens_written
            encodings = tokenizer.encode_batch(buffer)
            ids = []
            for enc in encodings:
                ids.extend(enc.ids)
                ids.append(eot_id)
            np.array(ids, dtype=np.uint16).tofile(out)
            tokens_written += len(ids)
            buffer.clear()

        for line in f:
            if line.strip() == config.EOT_TOKEN:
                if story:
                    buffer.append("".join(story).strip())
                    story = []
                if len(buffer) >= CHUNK_STORIES:
                    flush_buffer()
            else:
                story.append(line)
        if story:
            buffer.append("".join(story).strip())
        if buffer:
            flush_buffer()
    print(f"{bin_path}: {tokens_written:,} tokens")


def main():
    data = Path(config.DATA_DIR)
    tokenizer = Tokenizer.from_file(str(data / "tokenizer.json"))
    eot_id = tokenizer.token_to_id(config.EOT_TOKEN)
    encode_file(tokenizer, eot_id, data / "TinyStoriesV2-GPT4-train.txt", data / "train.bin")
    encode_file(tokenizer, eot_id, data / "TinyStoriesV2-GPT4-valid.txt", data / "val.bin")


if __name__ == "__main__":
    main()
