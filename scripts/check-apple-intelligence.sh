#!/usr/bin/env bash
#
# check-apple-intelligence.sh — print the current readiness state of
# Apple Intelligence (the macOS 26 on-device LLM Pace's fast path
# depends on).
#
# Compiles + runs a tiny Swift program that queries
# `SystemLanguageModel.default.availability` from the
# FoundationModels framework, then prints one of:
#
#   ✅ Ready                    — Pace's FM fast path will work
#   ⚠️  Not enabled              — flip the toggle in System Settings
#   ⏳ Model still downloading  — wait
#   ❌ Device not eligible      — pre-M1 / <8GB RAM
#
# Usage:
#   ./scripts/check-apple-intelligence.sh

set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

CHECKER_SOURCE_FILE="$(mktemp -t pace-ai-check.XXXXXX).swift"
cat > "$CHECKER_SOURCE_FILE" <<'SWIFT_EOF'
import FoundationModels

let modelAvailability = SystemLanguageModel.default.availability

switch modelAvailability {
case .available:
    print("✅ Apple Intelligence is READY")
    print("   Pace's Foundation Models fast path is active.")
case .unavailable(.deviceNotEligible):
    print("❌ This Mac is NOT eligible for Apple Intelligence")
    print("   Apple Intelligence requires M1 (or newer) + 8GB+ RAM.")
    print("   Pace will fall back to LocalPlannerClient (LM Studio).")
case .unavailable(.appleIntelligenceNotEnabled):
    print("⚠️  Apple Intelligence is NOT enabled")
    print("   To enable:")
    print("     1. Apple menu → System Settings")
    print("     2. Sidebar → Apple Intelligence & Siri")
    print("     3. Turn 'Apple Intelligence' on")
    print("     4. Wait for the ~3GB model download to finish")
case .unavailable(.modelNotReady):
    print("⏳ Apple Intelligence is enabled but model is STILL DOWNLOADING")
    print("   The on-device model is ~3GB. Wait a few minutes, then re-run this script.")
@unknown default:
    // Future SDK might add new Availability cases; print enough to
    // debug rather than silently miss the state.
    print("❓ Apple Intelligence availability: \(modelAvailability) (unknown case)")
}
SWIFT_EOF

# Compile + run as a one-shot. swift's `-target` accepts the SDK
# version we set as the deployment floor in the Xcode project.
xcrun swift -target arm64-apple-macos26.0 "$CHECKER_SOURCE_FILE"
EXIT_CODE=$?
rm -f "$CHECKER_SOURCE_FILE"
exit $EXIT_CODE
