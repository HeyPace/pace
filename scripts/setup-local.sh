#!/usr/bin/env bash
#
# setup-local.sh — Provisions LM Studio + the local models pace needs.
#
# Idempotent: safe to re-run. Skips work that's already done. The only
# thing this script CAN'T do is build the app (per AGENTS.md you must
# Cmd+R in Xcode, not run xcodebuild from a terminal).
#
# WhisperKit is OPTIONAL — the default voice provider is Apple Speech
# (on-device, zero setup). Only add the WhisperKit SPM package if you
# specifically want to swap STT backends via VoiceTranscriptionProvider=
# whisperkit in Info.plist.
#
# Usage:
#   ./scripts/setup-local.sh          # full provision
#   ./scripts/setup-local.sh status   # just print state of the world
#
set -euo pipefail

LM_STUDIO_BIN="$HOME/.lmstudio/bin/lms"
LM_STUDIO_API_BASE="http://localhost:1234/v1"

# Models we want present + loaded. These names are what `lms` resolves
# against — append `@variant` if you need a specific quantization.
# Qwen 3.5 4B is the default single-model local stack. It supports both chat
# and vision, fits comfortably on the primary development Mac, and avoids the
# model-swap stalls caused by loading separate 12B planner and 8B VLM models.
PLANNER_MODEL_NAME="qwen/qwen3.5-4b"
PLANNER_CONTEXT_LENGTH=8192
VLM_MODEL_NAME="$PLANNER_MODEL_NAME"

print_step() {
    printf "\n\033[36m▸ %s\033[0m\n" "$1"
}

print_warn() {
    printf "\033[33m! %s\033[0m\n" "$1"
}

print_ok() {
    printf "\033[32m✓ %s\033[0m\n" "$1"
}

print_fail() {
    printf "\033[31m✗ %s\033[0m\n" "$1"
}

ensure_brew_present() {
    if ! command -v brew >/dev/null 2>&1; then
        print_fail "Homebrew is not installed. Install it from https://brew.sh and re-run this script."
        exit 1
    fi
    print_ok "Homebrew found ($(brew --version | head -1))"
}

ensure_lm_studio_app_present() {
    if [ -d "/Applications/LM Studio.app" ]; then
        print_ok "LM Studio.app present"
        return
    fi
    print_step "Installing LM Studio via brew..."
    brew install --cask lm-studio
    print_ok "LM Studio.app installed"
}

ensure_lms_cli_present() {
    if [ -x "$LM_STUDIO_BIN" ]; then
        print_ok "lms CLI present at $LM_STUDIO_BIN"
        return
    fi
    print_warn "lms CLI not yet installed."
    print_warn "Opening LM Studio once to bootstrap the CLI (first launch installs ~/.lmstudio/bin/lms)..."
    open -a "LM Studio"
    # Wait up to 60s for the CLI to appear.
    for _attempt in $(seq 1 30); do
        if [ -x "$LM_STUDIO_BIN" ]; then
            print_ok "lms CLI bootstrapped"
            return
        fi
        sleep 2
    done
    print_fail "lms CLI did not appear after 60s. Open LM Studio manually, finish the onboarding, then re-run this script."
    exit 1
}

ensure_server_running() {
    if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
        print_ok "LM Studio server already responding at ${LM_STUDIO_API_BASE}"
        return
    fi
    print_step "Starting LM Studio server..."
    "$LM_STUDIO_BIN" server start
    # Wait for it to come up.
    for _attempt in $(seq 1 15); do
        if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
            print_ok "Server is up"
            return
        fi
        sleep 1
    done
    print_fail "Server did not respond after 15s. Check 'lms server status'."
    exit 1
}

model_is_present_on_disk() {
    local target_model_name="$1"
    "$LM_STUDIO_BIN" ls 2>/dev/null | grep -q -i "$target_model_name"
}

download_model_if_missing() {
    local target_model_name="$1"
    if model_is_present_on_disk "$target_model_name"; then
        print_ok "Model already on disk: $target_model_name"
        return 0
    fi
    print_step "Downloading $target_model_name (this can be several GB)..."
    if "$LM_STUDIO_BIN" get "$target_model_name" --mlx --yes; then
        print_ok "Downloaded $target_model_name"
        return 0
    fi
    print_warn "Failed to download $target_model_name"
    return 1
}

ensure_vlm_available() {
    download_model_if_missing "$VLM_MODEL_NAME" || {
        print_fail "Vision model $VLM_MODEL_NAME could not be downloaded."
        exit 1
    }
}

ensure_models_loaded() {
    download_model_if_missing "$PLANNER_MODEL_NAME" || {
        print_fail "Planner model $PLANNER_MODEL_NAME could not be downloaded."
        exit 1
    }
    print_step "Loading planner ($PLANNER_MODEL_NAME) with ${PLANNER_CONTEXT_LENGTH} context..."
    "$LM_STUDIO_BIN" load "$PLANNER_MODEL_NAME" --context-length "$PLANNER_CONTEXT_LENGTH" 2>&1 | tail -2
    print_step "Planner and VLM share $VLM_MODEL_NAME; no second model load is required."
}

print_loaded_models_and_suggested_info_plist_values() {
    print_step "Loaded models in memory:"
    "$LM_STUDIO_BIN" ps 2>&1 | sed 's/^/    /'

    print_step "Models on disk:"
    "$LM_STUDIO_BIN" ls 2>&1 | sed 's/^/    /'

    print_step "Verifying the OpenAI-compatible /v1/models endpoint:"
    curl -sS "${LM_STUDIO_API_BASE}/models" | head -c 800
    printf "\n"

    print_step "Info.plist identifiers to confirm match what's loaded:"
    echo "    LocalPlannerModelIdentifier  → $PLANNER_MODEL_NAME"
    echo "    LocalVLMModelIdentifier      → $VLM_MODEL_NAME"
    echo "    (If the IDs in leanring-buddy/Info.plist don't match exactly, update them before Cmd+R.)"
}

case "${1:-provision}" in
    status)
        print_step "Status only — not provisioning."
        ensure_brew_present
        if [ -d "/Applications/LM Studio.app" ]; then print_ok "LM Studio.app present"; else print_warn "LM Studio.app missing"; fi
        if [ -x "$LM_STUDIO_BIN" ]; then print_ok "lms CLI present"; else print_warn "lms CLI missing"; fi
        if curl -sS --max-time 2 "${LM_STUDIO_API_BASE}/models" >/dev/null 2>&1; then
            print_ok "LM Studio server responding"
        else
            print_warn "LM Studio server not responding"
        fi
        if [ -x "$LM_STUDIO_BIN" ]; then
            print_loaded_models_and_suggested_info_plist_values
        fi
        ;;
    provision)
        print_step "Provisioning local stack for pace..."
        ensure_brew_present
        ensure_lm_studio_app_present
        ensure_lms_cli_present
        ensure_server_running
        ensure_vlm_available
        ensure_models_loaded
        print_loaded_models_and_suggested_info_plist_values
        print_step "Next manual steps:"
        echo "    1. Open leanring-buddy.xcodeproj in Xcode"
        echo "    2. Cmd+R to build and run. DO NOT run xcodebuild from terminal — it invalidates TCC permissions."
        echo "    3. When prompted, grant: Microphone, Accessibility, Screen Recording, Speech Recognition."
        echo
        echo "    Optional: to use WhisperKit STT instead of Apple Speech,"
        echo "    File → Add Package Dependencies → https://github.com/argmaxinc/WhisperKit"
        echo "    then set VoiceTranscriptionProvider=whisperkit in Info.plist."
        print_ok "Provisioning complete."
        ;;
    *)
        echo "Usage: $0 [status|provision]" >&2
        exit 1
        ;;
esac
