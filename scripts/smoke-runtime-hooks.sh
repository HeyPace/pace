#!/usr/bin/env bash
#
# App-level smoke checks for Pace runtime behavior that is brittle to drive
# through SwiftUI Accessibility. Requires a built Debug Pace.app and launches it
# with PACE_ENABLE_SMOKE_HOOKS=1.

set -euo pipefail

APP_PATH="${PACE_APP_PATH:-}"
if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Pace.app 2>/dev/null | head -1)"
fi

if [[ -z "$APP_PATH" || ! -x "$APP_PATH/Contents/MacOS/Pace" ]]; then
    echo "missing Debug Pace.app; build from Xcode first" >&2
    exit 1
fi

APP_BUNDLE_IDENTIFIER="$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [[ -z "$APP_BUNDLE_IDENTIFIER" ]]; then
    echo "missing CFBundleIdentifier in $APP_PATH" >&2
    exit 1
fi

post_notification() {
    local notification_name="$1"
    swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"${notification_name}\"), object: nil, userInfo: nil, deliverImmediately: true)"
}

read_default() {
    local key="$1"
    defaults read "$APP_BUNDLE_IDENTIFIER" "$key" 2>/dev/null || true
}

wait_for_default() {
    local key="$1"
    local expected_value="$2"
    for _attempt in {1..30}; do
        local actual_value
        actual_value="$(read_default "$key")"
        if [[ "$actual_value" == "$expected_value" ]]; then
            return 0
        fi
        sleep 0.2
    done
    echo "expected $key=$expected_value, got $(read_default "$key")" >&2
    return 1
}

wait_for_default_contains() {
    local key="$1"
    local expected_substring="$2"
    for _attempt in {1..30}; do
        local actual_value
        actual_value="$(read_default "$key")"
        if [[ "$actual_value" == *"$expected_substring"* ]]; then
            return 0
        fi
        sleep 0.2
    done
    echo "expected $key to contain '$expected_substring', got $(read_default "$key")" >&2
    return 1
}

cancel_approval_if_visible() {
    osascript >/dev/null 2>&1 <<APPLESCRIPT || true
tell application "System Events"
    set smokeProcesses to every process whose unix id is ${SMOKE_APP_PID}
    if (count of smokeProcesses) is 1 then
        tell item 1 of smokeProcesses
            set frontmost to true
            repeat with currentWindow in windows
                if exists button "Cancel" of currentWindow then
                    click button "Cancel" of currentWindow
                    exit repeat
                end if
                if exists sheet 1 of currentWindow then
                    if exists button "Cancel" of sheet 1 of currentWindow then
                        click button "Cancel" of sheet 1 of currentWindow
                        exit repeat
                    end if
                end if
            end repeat
        end tell
    end if
end tell
APPLESCRIPT
}

wait_for_approval_cancel() {
    for _attempt in {1..30}; do
        cancel_approval_if_visible
        local actual_value
        actual_value="$(read_default PaceSmoke.lastApprovalAllowed)"
        if [[ "$actual_value" == "0" ]]; then
            return 0
        fi
        sleep 0.2
    done
    echo "expected PaceSmoke.lastApprovalAllowed=0, got $(read_default PaceSmoke.lastApprovalAllowed)" >&2
    return 1
}

cleanup() {
    launchctl unsetenv PACE_ENABLE_SMOKE_HOOKS 2>/dev/null || true
    if [[ -n "${SMOKE_APP_PID:-}" ]]; then
        kill "$SMOKE_APP_PID" 2>/dev/null || true
        wait "$SMOKE_APP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastPanelCommand 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastCursorAnnotationsEnabled 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastApprovalAllowed 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastClarificationState 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastClarifiedTranscript 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastClickTargetClarificationState 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastClickTargetResolution 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.lastClickAllFailSummary 2>/dev/null || true
defaults delete "$APP_BUNDLE_IDENTIFIER" PaceSmoke.ready 2>/dev/null || true

launchctl setenv PACE_ENABLE_SMOKE_HOOKS 1
open -n "$APP_PATH"
sleep 1
SMOKE_APP_PID="$(pgrep -n -x Pace || true)"
if [[ -z "$SMOKE_APP_PID" ]]; then
    echo "Pace did not launch for runtime smoke testing" >&2
    exit 1
fi

wait_for_default PaceSmoke.ready 1

post_notification "com.pace.smoke.showPanel"
wait_for_default PaceSmoke.lastPanelCommand show

post_notification "com.pace.smoke.cursorAnnotationsOff"
wait_for_default PaceSmoke.lastCursorAnnotationsEnabled 0

post_notification "com.pace.smoke.cursorAnnotationsOn"
wait_for_default PaceSmoke.lastCursorAnnotationsEnabled 1

post_notification "com.pace.smoke.showClarification"
wait_for_default PaceSmoke.lastClarificationState shown

post_notification "com.pace.smoke.resolveClarification"
wait_for_default PaceSmoke.lastClarifiedTranscript "rewrite the selected text"

post_notification "com.pace.smoke.showClickTargetClarification"
wait_for_default PaceSmoke.lastClickTargetClarificationState shown

post_notification "com.pace.smoke.resolveClickTargetClarification"
wait_for_default PaceSmoke.lastClickTargetResolution Save

post_notification "com.pace.smoke.simulateClickAllFailObservation"
wait_for_default_contains PaceSmoke.lastClickAllFailSummary "Click failed after trying 1 of 1 candidate"

post_notification "com.pace.smoke.requestApproval"
wait_for_approval_cancel

post_notification "com.pace.smoke.hidePanel"
wait_for_default PaceSmoke.lastPanelCommand hide

echo "runtime smoke hooks passed"
