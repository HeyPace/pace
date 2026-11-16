#!/usr/bin/env bash
#
# start-tts-server.sh — run the local Kokoro TTS sidecar Pace's
# LocalServerTTSClient talks to (OpenAI-compatible /v1/audio/speech).
#
# Uses mlx-audio (Apple-Silicon-native MLX runtime; Kokoro-82M). First
# synthesis call downloads the model (~350 MB) from Hugging Face; warm
# synthesis of a sentence is ~150 ms on an M-series Mac.
#
# Pace itself needs no restart when this server returns. After installing
# Japanese support, restart a running sidecar so it loads the Japanese extras;
# the installer prints managed-service and foreground restart instructions.
#
# Usage:
#   ./scripts/start-tts-server.sh           # foreground on port 8880
#   PORT=9000 ./scripts/start-tts-server.sh # custom port (update Info.plist too)
#   ./scripts/start-tts-server.sh --install-japanese # download the optional UniDic dictionary once

set -euo pipefail

PORT="${PORT:-8880}"
voice_support_directory="${PACE_VOICE_SUPPORT_DIRECTORY:-${HOME}/Library/Application Support/Pace/voice-support}"
japanese_receipt="${voice_support_directory}/japanese.enabled"

if [[ "$#" != 0 && !( "$#" == 1 && "$1" == "--install-japanese" ) ]]; then
    echo "Usage: $0 [--install-japanese]" >&2
    exit 2
fi

if ! command -v uvx >/dev/null 2>&1; then
    echo "uvx not found — install uv first: https://docs.astral.sh/uv/" >&2
    exit 1
fi

# webrtcvad still imports pkg_resources, removed in setuptools 81.
# Pin the tested environment so a restart cannot silently change the voice.
misaki_requirement="misaki[en]==0.9.4"
if [[ "${1:-}" == "--install-japanese" || -f "$japanese_receipt" ]]; then
    misaki_requirement="misaki[en,ja]==0.9.4"
fi
uvx_arguments=(--python 3.11
    --with "uvicorn==0.54.0"
    --with "fastapi==0.163.0"
    --with "python-multipart==0.0.33"
    --with "webrtcvad==2.0.10"
    --with "setuptools==80.10.2"
    --with "$misaki_requirement"
    --from "mlx-audio==0.6.5")

if [[ "${1:-}" == "--install-japanese" && "$#" == 1 ]]; then
    exec uvx "${uvx_arguments[@]}" python - "$japanese_receipt" <<'PYTHON'
from pathlib import Path
import subprocess
import sys
import uuid
import unidic

dictionary_directory = Path(unidic.DICDIR)
def dictionary_is_ready():
    return all((dictionary_directory / filename).is_file() for filename in ("mecabrc", "sys.dic"))

if not dictionary_is_ready():
    subprocess.run([sys.executable, "-m", "unidic", "download"], check=True)
if not dictionary_is_ready():
    raise SystemExit("Japanese dictionary installation did not complete.")

receipt = Path(sys.argv[1])
receipt.parent.mkdir(parents=True, exist_ok=True)
temporary_receipt = receipt.with_name(f".{receipt.name}.{uuid.uuid4().hex}")
try:
    temporary_receipt.write_text("Japanese UniDic dictionary validated.\n", encoding="utf-8")
    temporary_receipt.replace(receipt)
finally:
    temporary_receipt.unlink(missing_ok=True)
print("Japanese UniDic dictionary is installed.")
print("Restart the running Kokoro sidecar before using Japanese speech.")
print("For Pace's managed sidecar: launchctl kickstart -k gui/$(id -u)/com.pace.tts-sidecar")
print("For a foreground sidecar: stop it and rerun scripts/start-tts-server.sh")
PYTHON
fi

echo "▶ Kokoro TTS sidecar on http://localhost:${PORT}/v1 (Ctrl-C to stop)"
exec uvx "${uvx_arguments[@]}" python -m mlx_audio.server --port "${PORT}"
