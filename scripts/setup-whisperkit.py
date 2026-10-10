#!/usr/bin/env python3
"""Provision Pace's small, local WhisperKit model outside protected Documents."""
import concurrent.futures
import json
import pathlib
import urllib.request

REPOSITORY = "argmaxinc/whisperkit-coreml"
REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
MODEL = "openai_whisper-base.en"
TOKENIZER_REVISION = "911407f4214e0e1d82085af863093ec0b66f9cd6"
DESTINATION = pathlib.Path.home() / "Library/Application Support/Pace/Models/WhisperKit" / MODEL


def download(url, destination, expected_size=None):
    if destination.exists() and (expected_size is None or destination.stat().st_size == expected_size):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    if expected_size is not None and temporary.stat().st_size != expected_size:
        raise RuntimeError(f"Incomplete model file: {destination.name}")
    temporary.replace(destination)


def main():
    url = f"https://huggingface.co/api/models/{REPOSITORY}/tree/{REVISION}/{MODEL}?recursive=true"
    with urllib.request.urlopen(url, timeout=30) as response:
        entries = json.load(response)
    files = [entry for entry in entries if entry["type"] == "file"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(download,
            f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{entry['path']}",
            DESTINATION / entry["path"].removeprefix(MODEL + "/"), entry["size"])
            for entry in files]
        for future in futures:
            future.result()
    # Bundle tokenizer inputs locally; recognition never needs a network fetch.
    for name in ("tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "special_tokens_map.json"):
        download(f"https://huggingface.co/openai/whisper-base.en/resolve/{TOKENIZER_REVISION}/{name}", DESTINATION / name)
    print(f"WhisperKit base.en ready: {DESTINATION}")


if __name__ == "__main__":
    main()
