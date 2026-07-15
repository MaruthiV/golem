from pathlib import Path

from huggingface_hub import hf_hub_download

from mind import config

FILES = ["TinyStoriesV2-GPT4-train.txt", "TinyStoriesV2-GPT4-valid.txt"]


def main():
    Path(config.DATA_DIR).mkdir(exist_ok=True)
    for name in FILES:
        path = hf_hub_download(repo_id="roneneldan/TinyStories", filename=name,
                               repo_type="dataset", local_dir=config.DATA_DIR)
        print(f"downloaded {path}")


if __name__ == "__main__":
    main()
