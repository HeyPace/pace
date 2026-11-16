#!/usr/bin/env bash
#
# start-tts-server.sh — run the local Kokoro TTS sidecar Pace's
# LocalServerTTSClient talks to (OpenAI-compatible /v1/audio/speech).
#
# Uses mlx-audio (Apple-Silicon-native MLX runtime; Kokoro-82M). First
# synthesis call downloads the model (~350 MB) from Hugging Face; warm
# synthesis of a sentence is ~150 ms on an M-series Mac.
#
# Pace needs no restart: when this server is down it speaks with the
# Apple voice, and the next turn after the server comes up uses Kokoro.
#
# Usage:
#   ./scripts/start-tts-server.sh           # foreground on port 8880
#   PORT=9000 ./scripts/start-tts-server.sh # custom port (update Info.plist too)
#   ./scripts/start-tts-server.sh --install-japanese # download the optional UniDic dictionary once

set -euo pipefail

PORT="${PORT:-8880}"

if ! command -v uvx >/dev/null 2>&1; then
    echo "uvx not found — install uv first: https://docs.astral.sh/uv/" >&2
    exit 1
fi

# webrtcvad still imports pkg_resources, removed in setuptools 81.
# Pin the tested environment so a restart cannot silently change the voice.
uvx_arguments=(--python 3.11
    --with "uvicorn==0.54.0"
    --with "fastapi==0.163.0"
    --with "python-multipart==0.0.33"
    --with "webrtcvad==2.0.10"
    --with "setuptools==80.10.2"
    --with "misaki[en,ja]==0.9.4"
    --from "mlx-audio==0.6.5")

if [[ "${1:-}" == "--install-japanese" && "$#" == 1 ]]; then
    exec uvx "${uvx_arguments[@]}" python - <<'PYTHON'
from pathlib import Path
import subprocess
import sys
import unidic

dictionary_directory = Path(unidic.DICDIR)
if not (dictionary_directory / "mecabrc").is_file():
    subprocess.run([sys.executable, "-m", "unidic", "download"], check=True)
if not (dictionary_directory / "mecabrc").is_file():
    raise SystemExit("Japanese dictionary installation did not complete.")
print("Japanese UniDic dictionary is ready.")
PYTHON
fi

if [[ "$#" != 0 ]]; then
    echo "Usage: $0 [--install-japanese]" >&2
    exit 2
fi

echo "▶ Kokoro TTS sidecar on http://localhost:${PORT}/v1 (Ctrl-C to stop)"
exec uvx "${uvx_arguments[@]}" python -m mlx_audio.server --port "${PORT}"
