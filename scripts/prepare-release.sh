#!/usr/bin/env bash

# Build and verify a Release Pace.app without version bumps, Sparkle signing,
# notarization, GitHub writes, appcast edits, commits, pushes, or deployment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="leanring-buddy"
SIGNING_IDENTITY="${PACE_DEVELOPER_ID:--}"
PREPARE_ROOT="${PACE_PREPARE_OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/pace-release-prep.XXXXXX")}"
DERIVED_DATA="$PREPARE_ROOT/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Pace.app"
OUTPUT_APP="$PREPARE_ROOT/Pace.app"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in \
        "/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer" \
        "/Applications/Xcode-27.0.0-Beta.app/Contents/Developer" \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode.app/Contents/Developer"; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

[[ -n "${DEVELOPER_DIR:-}" ]] || { echo "full Xcode installation not found" >&2; exit 1; }
[[ ! -e "$OUTPUT_APP" ]] || { echo "output already exists: $OUTPUT_APP" >&2; exit 1; }
mkdir -p "$PREPARE_ROOT"

echo "▶ Building isolated Release app"
xcodebuild \
    -project "$PROJECT_DIR/leanring-buddy.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build

[[ -d "$BUILT_APP" ]] || { echo "missing built app: $BUILT_APP" >&2; exit 1; }
ditto "$BUILT_APP" "$OUTPUT_APP"

mkdir -p "$OUTPUT_APP/Contents/Resources/scripts"
cp "$SCRIPT_DIR/start-tts-server.sh" "$OUTPUT_APP/Contents/Resources/scripts/start-tts-server.sh"
chmod +x "$OUTPUT_APP/Contents/Resources/scripts/start-tts-server.sh"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null || {
    echo "Developer ID identity is not installed: $SIGNING_IDENTITY" >&2
    exit 1
}
fi

# Sparkle arrives with its upstream Team ID. Re-sign embedded frameworks before
# the outer app so dyld sees one signing identity throughout the bundle.
while IFS= read -r framework_path; do
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        codesign --force --deep --sign - "$framework_path"
    else
        codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$framework_path"
    fi
done < <(find "$OUTPUT_APP/Contents/Frameworks" -maxdepth 2 -name "*.framework" -type d 2>/dev/null)

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$OUTPUT_APP"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_APP"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
echo "source: $(git -C "$PROJECT_DIR" rev-parse --short HEAD) (dirty=$(if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then echo true; else echo false; fi))"
echo "$OUTPUT_APP"
