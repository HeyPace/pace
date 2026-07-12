#!/usr/bin/env bash
#
# smoke-test.sh — Autonomous test layer for Pace. Catches regressions
# in everything that doesn't require TCC permissions or visual UI.
#
# Usage:
#   ./scripts/smoke-test.sh --all         # run every check, exit non-zero on any fail
#   ./scripts/smoke-test.sh --build       # xcodebuild only
#   ./scripts/smoke-test.sh --unit        # xcodebuild test on leanring-buddyTests
#   ./scripts/smoke-test.sh --planner     # hit LM Studio planner with representative prompts
#   ./scripts/smoke-test.sh --vlm         # hit LM Studio VLM with a sample screenshot
#   ./scripts/smoke-test.sh --lint        # plutil + grep-for-stale-brand checks
#
# Each subcommand is idempotent and prints PASS / FAIL lines so you can
# scan the output. Exits 0 only when every selected check passes.
#

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/leanring-buddy.xcodeproj"
SCHEME="leanring-buddy"
DERIVED_DATA="/tmp/pace-build"
LM_STUDIO_API="http://localhost:1234/v1"
PLANNER_MODEL="qwen/qwen3-14b"
VLM_MODEL="ui-venus-1.5-8b"

# Counter — incremented by check_pass / check_fail. Exit code returns
# the failure count so the caller can detect regressions.
FAILURE_COUNT=0
DEVELOPER_DIR_FOR_BUILD="/Applications/Xcode.app/Contents/Developer"

print_section() {
    printf "\n\033[36m▸▸ %s\033[0m\n" "$1"
}

check_pass() {
    printf "\033[32m✓ %s\033[0m\n" "$1"
}

check_fail() {
    printf "\033[31m✗ %s\033[0m\n" "$1"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        check_fail "required command not found: $1"
        exit 1
    fi
}

# ---------------- check: build ----------------

run_build_check() {
    print_section "build"

    if [ ! -d "$PROJECT_PATH" ]; then
        check_fail "project not found at $PROJECT_PATH"
        return
    fi

    DEVELOPER_DIR="$DEVELOPER_DIR_FOR_BUILD" xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'platform=macOS,arch=arm64' \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
        build > /tmp/pace-smoke-build.log 2>&1

    if grep -q "BUILD SUCCEEDED" /tmp/pace-smoke-build.log; then
        check_pass "xcodebuild build (full log: /tmp/pace-smoke-build.log)"
    else
        check_fail "xcodebuild build — last 20 lines of /tmp/pace-smoke-build.log:"
        tail -20 /tmp/pace-smoke-build.log | sed 's/^/    /'
    fi
}

# ---------------- check: unit tests ----------------

run_unit_check() {
    print_section "unit tests"

    DEVELOPER_DIR="$DEVELOPER_DIR_FOR_BUILD" xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'platform=macOS,arch=arm64' \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
        test > /tmp/pace-smoke-test.log 2>&1

    local passed_count
    passed_count=$(grep -c "passed on" /tmp/pace-smoke-test.log || true)
    local failed_count
    failed_count=$(grep -c "failed on" /tmp/pace-smoke-test.log || true)

    if grep -q "TEST SUCCEEDED" /tmp/pace-smoke-test.log; then
        check_pass "unit tests: $passed_count passed, $failed_count failed"
    else
        check_fail "unit tests: $passed_count passed, $failed_count failed (log: /tmp/pace-smoke-test.log)"
        grep -E "✘ Test|failed on" /tmp/pace-smoke-test.log | head -10 | sed 's/^/    /'
    fi
}

# ---------------- check: planner contract ----------------

planner_completion() {
    local user_text="$1"
    local system_prompt="$2"
    curl -sS -X POST "${LM_STUDIO_API}/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c "
import json, sys
payload = {
    'model': '${PLANNER_MODEL}',
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 600,
    'temperature': 0.2,
    'stream': False
}
print(json.dumps(payload))
" "$system_prompt" "$user_text")" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
choice = data['choices'][0]
print(choice['message'].get('content', ''))
" 2>/dev/null
}

run_planner_check() {
    print_section "planner contract"

    if ! curl -sS --max-time 2 "${LM_STUDIO_API}/models" >/dev/null 2>&1; then
        check_fail "LM Studio server not reachable at $LM_STUDIO_API — skipping planner checks"
        return
    fi

    local planner_loaded
    planner_loaded=$(curl -sS "${LM_STUDIO_API}/models" | grep -c "$PLANNER_MODEL" || true)
    if [ "$planner_loaded" -eq 0 ]; then
        check_fail "planner $PLANNER_MODEL not loaded — skipping planner checks"
        return
    fi
    check_pass "planner $PLANNER_MODEL is loaded"

    # 1. Pure Q&A — should NOT emit any [CLICK]/[TYPE]/[DONE] action tags.
    local qa_system="answer briefly in one sentence."
    local qa_response
    qa_response=$(planner_completion "what does HTML stand for?" "$qa_system")
    if echo "$qa_response" | grep -qE "\[CLICK:|\[TYPE:|\[KEY:|\[SCROLL:"; then
        check_fail "Q&A prompt should not emit action tags. Got: $(echo "$qa_response" | head -c 200)"
    else
        check_pass "Q&A prompt produces tag-free content"
    fi

    # 2. Action prompt — should emit at least one tag and ideally [DONE].
    local action_system="you are an agent. when asked to do something, emit one or more tags like [KEY:cmd+s], [TYPE:text], or [CLICK:x,y]. end with [DONE] when the task is complete. keep narration to one short sentence."
    local action_response
    action_response=$(planner_completion "save the current document" "$action_system")
    if echo "$action_response" | grep -qE "\[KEY:|\[CLICK:|\[TYPE:"; then
        check_pass "action prompt emitted at least one tag"
    else
        check_fail "action prompt should emit an action tag. Got: $(echo "$action_response" | head -c 200)"
    fi

    if echo "$action_response" | grep -q "\[DONE\]"; then
        check_pass "action prompt emitted [DONE]"
    else
        # Not a hard fail — some prompts the planner may not emit [DONE]
        # immediately. Warn rather than fail so the smoke test isn't flaky.
        printf "\033[33m! action prompt did not emit [DONE] — borderline acceptable, watch for regressions\033[0m\n"
    fi
}

# ---------------- check: VLM contract ----------------

run_vlm_check() {
    print_section "VLM contract"

    if ! curl -sS --max-time 2 "${LM_STUDIO_API}/models" >/dev/null 2>&1; then
        check_fail "LM Studio server not reachable — skipping VLM checks"
        return
    fi

    local vlm_loaded
    vlm_loaded=$(curl -sS "${LM_STUDIO_API}/models" | grep -c "$VLM_MODEL" || true)
    if [ "$vlm_loaded" -eq 0 ]; then
        check_fail "VLM $VLM_MODEL not loaded — skipping VLM checks"
        return
    fi
    check_pass "VLM $VLM_MODEL is loaded"

    # Send a 1x1 PNG as a smoke test image. Tests the *request shape*
    # roundtrip, not real screen understanding — that needs a captured
    # screenshot which only the running app produces.
    local tiny_png_b64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    local vlm_response
    vlm_response=$(curl -sS -X POST "${LM_STUDIO_API}/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c "
import json
print(json.dumps({
    'model': '${VLM_MODEL}',
    'messages': [{'role': 'user', 'content': [
        {'type': 'text', 'text': 'describe what you see in one short sentence.'},
        {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,${tiny_png_b64}'}}
    ]}],
    'max_tokens': 60,
    'stream': False
}))
")" \
        | python3 -c "import json, sys; print(json.load(sys.stdin)['choices'][0]['message'].get('content',''))" 2>/dev/null)

    if [ -n "$vlm_response" ]; then
        check_pass "VLM responded to image-in-message"
    else
        check_fail "VLM returned empty/missing content for image-in-message"
    fi
}

# ---------------- check: lint ----------------

run_lint_check() {
    print_section "lint"

    if plutil -lint "$REPO_ROOT/leanring-buddy/Info.plist" >/dev/null 2>&1; then
        check_pass "Info.plist passes plutil -lint"
    else
        check_fail "Info.plist failed plutil -lint"
    fi

    # Info.plist defaults should still reference qwen/qwen3-14b for the
    # planner (we documented this in SETUP_LOCAL.md). If someone bumps
    # the default, the docs should follow.
    if grep -q "qwen/qwen3-14b" "$REPO_ROOT/leanring-buddy/Info.plist"; then
        check_pass "Info.plist planner default still qwen/qwen3-14b"
    else
        printf "\033[33m! Info.plist planner default changed — verify SETUP_LOCAL.md is in sync\033[0m\n"
    fi
}

# ---------------- main ----------------

main() {
    local mode="${1:-}"
    require_command xcodebuild
    require_command curl
    require_command python3

    case "$mode" in
        --build)   run_build_check ;;
        --unit)    run_unit_check ;;
        --planner) run_planner_check ;;
        --vlm)     run_vlm_check ;;
        --lint)    run_lint_check ;;
        --all)
            run_build_check
            run_unit_check
            run_planner_check
            run_vlm_check
            run_lint_check
            ;;
        *)
            echo "Usage: $0 [--build|--unit|--planner|--vlm|--lint|--all]" >&2
            exit 1
            ;;
    esac

    print_section "summary"
    if [ "$FAILURE_COUNT" -eq 0 ]; then
        check_pass "all selected checks passed"
        exit 0
    else
        check_fail "$FAILURE_COUNT check(s) failed"
        exit "$FAILURE_COUNT"
    fi
}

main "$@"
