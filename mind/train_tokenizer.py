from pathlib import Path

from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers

from mind import config


def main():
    tokenizer = Tokenizer(models.BPE())
    tokenizer.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tokenizer.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(
        vocab_size=config.VOCAB_SIZE,
        special_tokens=[config.EOT_TOKEN],
        initial_alphabet=pre_tokenizers.ByteLevel.alphabet(),
    )
    train_file = str(Path(config.DATA_DIR) / "TinyStoriesV2-GPT4-train.txt")
    tokenizer.train([train_file], trainer)
    out = str(Path(config.DATA_DIR) / "tokenizer.json")
    tokenizer.save(out)
    print(f"saved {out}, vocab size {tokenizer.get_vocab_size()}")


if __name__ == "__main__":
    main()
