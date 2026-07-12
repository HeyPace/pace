#!/usr/bin/env bash
#
# profile-pace-turn.sh — CPU-sample Pace + LM Studio while you do one
# voice turn, then digest the hottest call stacks.
#
# Usage
# -----
#   1. Make sure Pace is running.
#   2. Run this script (default samples 30s):
#        ./scripts/profile-pace-turn.sh
#      or with a custom window:
#        ./scripts/profile-pace-turn.sh 45
#   3. Within the first ~2 seconds, hold push-to-talk and do a normal
#      voice turn. Release. Wait for the response.
#   4. When the sampling window ends, this prints the hottest frames
#      and saves the raw `sample` output under /tmp/pace-profile-<ts>/.
#
# Caveat
# ------
# `sample` is a CPU profiler. LM Studio's prefill mostly runs on the
# GPU / ANE — that work shows up here as a thread "waiting on Metal".
# This script confirms WHERE the time is, not which GPU kernel is hot.
# For GPU profiling proper you need Instruments → Metal System Trace
# or Xcode → Capture GPU Frame.
#

set -euo pipefail

SAMPLE_DURATION_SECONDS="${1:-30}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIRECTORY="/tmp/pace-profile-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIRECTORY"

# Pace's executable is named `Pace` (PRODUCT_NAME=Pace) — pgrep -x
# matches whole-name. There may briefly be two during the user's
# launch race; we sample the first one and warn if there's more.
PACE_PIDS=$(pgrep -x Pace 2>/dev/null || true)
if [[ -z "$PACE_PIDS" ]]; then
    echo "❌ Pace is not running. Start it (Cmd+R in Xcode) before running this script."
    exit 2
fi
PACE_PID=$(echo "$PACE_PIDS" | head -1)
PACE_INSTANCE_COUNT=$(echo "$PACE_PIDS" | wc -l | tr -d ' ')
if [[ "$PACE_INSTANCE_COUNT" -gt 1 ]]; then
    echo "⚠️  Multiple Pace processes detected ($PACE_INSTANCE_COUNT); sampling pid $PACE_PID only."
fi

# LM Studio's planner runs in a child helper process. The exact name
# varies by LM Studio version — try the common ones.
LM_STUDIO_PID=""
for candidateName in "LM Studio Helper (Plugin)" "LM Studio Helper" "LM Studio" "lms"; do
    foundPid=$(pgrep -f "$candidateName" 2>/dev/null | head -1 || true)
    if [[ -n "$foundPid" ]]; then
        LM_STUDIO_PID="$foundPid"
        LM_STUDIO_PROCESS_NAME="$candidateName"
        break
    fi
done

echo "▶ Sampling for ${SAMPLE_DURATION_SECONDS}s — start your voice turn NOW."
echo "  Pace pid=$PACE_PID"
[[ -n "$LM_STUDIO_PID" ]] && echo "  LM Studio pid=$LM_STUDIO_PID ($LM_STUDIO_PROCESS_NAME)"
echo "  Output → $OUTPUT_DIRECTORY"
echo

# Sample Pace and LM Studio in parallel.
PACE_SAMPLE_FILE="$OUTPUT_DIRECTORY/pace.sample.txt"
sample "$PACE_PID" "$SAMPLE_DURATION_SECONDS" -mayDie -file "$PACE_SAMPLE_FILE" >/dev/null 2>&1 &
PACE_SAMPLE_JOB=$!

if [[ -n "$LM_STUDIO_PID" ]]; then
    LM_STUDIO_SAMPLE_FILE="$OUTPUT_DIRECTORY/lmstudio.sample.txt"
    sample "$LM_STUDIO_PID" "$SAMPLE_DURATION_SECONDS" -mayDie -file "$LM_STUDIO_SAMPLE_FILE" >/dev/null 2>&1 &
    LM_STUDIO_SAMPLE_JOB=$!
fi

wait $PACE_SAMPLE_JOB
[[ -n "${LM_STUDIO_SAMPLE_JOB:-}" ]] && wait $LM_STUDIO_SAMPLE_JOB

echo "📊 Sampling complete. Digesting…"
echo

# `sample` produces a hierarchical call-graph followed by a flat
# "binary images" summary. Pull the top-of-stack frames from the call
# graph by greping for lines where the leading sample count is high.
# `sample` indents nested frames; we keep only the leaf-ish lines
# (4-12 spaces of indent) to surface where time actually lands.
echo "═════════════════════════════════════════════════════"
echo "📊 Pace — top hot frames"
echo "═════════════════════════════════════════════════════"
if [[ -s "$PACE_SAMPLE_FILE" ]]; then
    grep -E "^\s+[0-9]+ " "$PACE_SAMPLE_FILE" \
        | awk '{
            indent = match($0, /[^ ]/) - 1
            sampleCount = $1
            if (indent >= 4 && sampleCount >= 5) print
        }' \
        | sort -rnk1,1 \
        | head -30
else
    echo "(no Pace sample output captured)"
fi

if [[ -n "${LM_STUDIO_SAMPLE_JOB:-}" && -s "$LM_STUDIO_SAMPLE_FILE" ]]; then
    echo
    echo "═════════════════════════════════════════════════════"
    echo "📊 LM Studio — top hot frames"
    echo "═════════════════════════════════════════════════════"
    grep -E "^\s+[0-9]+ " "$LM_STUDIO_SAMPLE_FILE" \
        | awk '{
            indent = match($0, /[^ ]/) - 1
            sampleCount = $1
            if (indent >= 4 && sampleCount >= 5) print
        }' \
        | sort -rnk1,1 \
        | head -30
fi

echo
echo "→ Raw sample files preserved in $OUTPUT_DIRECTORY for deeper digging."
echo "  Open the .txt files in any editor, or run:"
echo "    open $OUTPUT_DIRECTORY"
