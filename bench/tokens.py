"""o200k_base token counts. The encoding file is cached in .venv/tiktoken-cache."""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("TIKTOKEN_CACHE_DIR", os.path.join(HERE, ".venv", "tiktoken-cache"))

import tiktoken  # noqa: E402

_ENC = tiktoken.get_encoding("o200k_base")


def count(text):
    return len(_ENC.encode(text or "", disallowed_special=()))
