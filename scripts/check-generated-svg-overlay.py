#!/usr/bin/env python3
"""Check the real generated-SVG window's transparency and visible content.

Run on a logged-in macOS 26 desktop with Screen Recording access for the runner:
    python3 scripts/check-generated-svg-overlay.py --output /absolute/private/new-directory

Compiles only the standalone helper and current SVG validator/renderer with swiftc.
The helper shows its own nonactivating, click-through panel. Only that explicit
window ID is captured. No input or app activation is performed. Evidence includes
the PNG, pixel inspection, source hashes, compiler/probe logs, and final result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
import time
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SOURCES = [
    REPOSITORY / "scripts/GeneratedSVGOverlayProbe.swift",
    REPOSITORY / "leanring-buddy/PaceGeneratedSVG.swift",
    REPOSITORY / "leanring-buddy/PaceGeneratedSVGRenderer.swift",
]


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def source_hashes() -> dict[str, str]:
    return {
        str(path.relative_to(REPOSITORY)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [*SOURCES, Path(__file__).resolve()]
    }


def remaining(deadline: float) -> float:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError("Owned overlay probe exceeded its ten-second runtime budget")
    return seconds


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New private evidence directory outside the repository")
    arguments = parser.parse_args()
    output = arguments.output.expanduser().resolve()
    if not arguments.output.expanduser().is_absolute() or output == REPOSITORY or REPOSITORY in output.parents:
        parser.error("--output must be an absolute private directory outside the repository")
    if platform.system() != "Darwin":
        parser.error("This rendered regression requires a logged-in macOS desktop")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = output / "generated-svg-overlay-probe"
    ready_path = output / "ready.json"
    stop_marker = output / "stop"
    capture_path = output / "overlay.png"
    result: dict = {"passed": False, "output": str(output)}
    process: subprocess.Popen | None = None
    probe_log = None
    hashes = source_hashes()
    write_json(output / "source-sha256.json", hashes)
    try:
        architecture = platform.machine()
        if architecture not in {"arm64", "x86_64"}:
            raise RuntimeError(f"Unsupported macOS architecture: {architecture}")
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", f"{architecture}-apple-macos26.0",
                   "-module-cache-path", str(output / "module-cache"), *map(str, SOURCES), "-o", str(binary)]
        write_json(output / "compile-command.json", {"arguments": command, "timeoutSeconds": 60})
        with (output / "compile.log").open("w", encoding="utf-8") as compile_log:
            subprocess.run(command, cwd=REPOSITORY, stdout=compile_log, stderr=subprocess.STDOUT, check=True, timeout=60)
        probe_log = (output / "probe.log").open("w", encoding="utf-8")
        process = subprocess.Popen([str(binary), "--ready-json", str(ready_path), "--stop-marker", str(stop_marker)],
                                   cwd=output, stdout=probe_log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 10
        while not ready_path.exists():
            remaining(deadline)
            if process.poll() is not None:
                raise RuntimeError(f"Owned overlay helper exited before readiness ({process.returncode})")
            time.sleep(min(0.1, remaining(deadline)))
        ready = json.loads(ready_path.read_text(encoding="utf-8"))
        if ready.get("status") != "ready" or ready.get("pid") != process.pid:
            raise RuntimeError(f"Owned overlay helper did not become ready: {ready}")
        window_id = ready.get("windowID")
        if type(window_id) is not int or window_id <= 0:
            raise RuntimeError("Owned helper supplied an invalid window ID")
        result["windowID"] = window_id
        result["pid"] = process.pid
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), str(capture_path)],
                       cwd=output, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=remaining(deadline))
        inspection = subprocess.run([str(binary), "--inspect-image", str(capture_path)], cwd=output,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=remaining(deadline))
        (output / "inspection-stderr.log").write_text(inspection.stderr, encoding="utf-8")
        pixels = json.loads(inspection.stdout)
        write_json(output / "pixels.json", pixels)
        result["pixels"] = pixels
        if inspection.returncode != 0 or pixels.get("passed") is not True:
            raise RuntimeError("Overlay pixels failed four transparent corners or visible blue drawing assertion")
        if source_hashes() != hashes:
            raise RuntimeError("SVG renderer sources changed while the regression was running")
        result["passed"] = True
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
    finally:
        if process is not None:
            stop_marker.touch()
            try:
                process.wait(timeout=4)
                result["teardown"] = "stop-marker"
                if process.returncode != 0:
                    result["passed"] = False
                    result["error"] = f"Owned helper exited abnormally ({process.returncode})"
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=0.75)
                    result["teardown"] = "terminated-owned-helper"
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=0.25)
                    result["teardown"] = "killed-owned-helper"
                result["passed"] = False
                result["error"] = "Owned helper failed its five-second graceful teardown budget"
        if probe_log is not None:
            probe_log.close()
        write_json(output / "result.json", result)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
