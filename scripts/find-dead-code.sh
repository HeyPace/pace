#!/usr/bin/env bash
#
# find-dead-code.sh — run periphery against Pace and print unused
# Swift declarations. Reads config from .periphery.yml at repo root.
#
# Prerequisites:
#   brew install periphery
#   bash scripts/test-pace.sh   # populates /tmp/pace-test-derived-data
#
# Usage:
#   bash scripts/find-dead-code.sh           # full scan, prints to stdout
#   bash scripts/find-dead-code.sh > out.txt # capture for diff over time

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v periphery >/dev/null 2>&1; then
    echo "❌ periphery is not installed. Install with: brew install periphery" >&2
    exit 1
fi

cd "$PROJECT_DIR"

# DEVELOPER_DIR is required by periphery's xcrun calls. Pin to the
# main Xcode app explicitly so this works even if xcode-select
# happens to point elsewhere.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        # Fall back to a versioned Xcode (e.g. Xcode-27.0.0-Beta.3.app),
        # mirroring scripts/test-pace.sh. Exclude Xcodes.app (the version
        # manager — it has no Contents/Developer).
        beta_xcode="$(/usr/bin/find /Applications -maxdepth 1 -name 'Xcode*.app' ! -name 'Xcodes.app' -type d 2>/dev/null | /usr/bin/sort | /usr/bin/tail -1)"
        if [ -n "$beta_xcode" ] && [ -d "$beta_xcode/Contents/Developer" ]; then
            export DEVELOPER_DIR="$beta_xcode/Contents/Developer"
        fi
    fi
fi

if [ ! -d /tmp/pace-test-derived-data/Index.noindex/DataStore ]; then
    echo "⚠️  Index store at /tmp/pace-test-derived-data/Index.noindex/DataStore"
    echo "    does not exist. Run 'bash scripts/test-pace.sh' first so periphery"
    echo "    has an index to read." >&2
    exit 1
fi

periphery scan
