#!/usr/bin/env python3
"""Summarizes Pace's local API audit log into a per-subsystem latency table.

Reads ~/Library/Application Support/Pace/api-audit.jsonl (plus its rotated
.1 generation) and prints count, error rate, and p50/p95/p99/max latency per
(subsystem, target). Use it to find which local call is eating the turn
budget before tuning anything.

Usage:
  python3 scripts/audit-summary.py                # all recorded history
  python3 scripts/audit-summary.py --last 60      # only the last 60 minutes
"""

import argparse
import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path

LOG_PATH = os.path.expanduser("~/Library/Application Support/Pace/api-audit.jsonl")


def percentile(sorted_values, fraction):
    if not sorted_values:
        return None
    if fraction == 0.5 and len(sorted_values) % 2 == 0:
        middle = len(sorted_values) // 2
        return (sorted_values[middle - 1] + sorted_values[middle]) // 2
    index = math.ceil(len(sorted_values) * fraction) - 1
    return sorted_values[index]


def is_recorded_failure(outcome):
    if not isinstance(outcome, str):
        return False
    if outcome.startswith("http_") and outcome[5:].isdigit():
        return not 200 <= int(outcome[5:]) < 300
    return (
        outcome in {"error", "failed", "bad_response", "non_http_response", "non_2xx",
                    "invalid_structured_json", "count_mismatch"}
        or outcome.endswith(("_error", "_failed"))
        or outcome.startswith("failed_")
    )


@lru_cache(maxsize=1)
def timed_action_operations():
    resource = Path(__file__).resolve().parents[1] / "leanring-buddy/Resources/usage-powers.json"
    powers = json.loads(resource.read_text())
    return {operation for power in powers.values() for operation in power["operations"]}


def measured_duration(entry):
    if entry.get("subsystem") == "workflow" and entry.get("operation") == "dispatch":
        return None
    duration = entry.get("durationMilliseconds")
    if type(duration) is not int or duration < 0:
        return None
    if duration == 0:
        subsystem, operation = entry.get("subsystem"), entry.get("operation")
        measured_zero = entry.get("durationWasMeasured") is True or (subsystem == "mcp" and operation == "tools/call") or (
            subsystem == "action" and (operation == "mcp_call" or operation in timed_action_operations())
        )
        if not measured_zero:
            return None
    return duration


def load_entries(cutoff):
    entries = []
    now = datetime.now(timezone.utc)
    for path in (LOG_PATH + ".1", LOG_PATH):
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(entry, dict):
                    continue
                if cutoff is not None:
                    try:
                        at = datetime.fromisoformat(entry["at"].replace("Z", "+00:00"))
                    except (KeyError, ValueError, AttributeError, TypeError):
                        continue
                    if at.tzinfo is None or at < cutoff or at > now:
                        continue
                entries.append(entry)
    return entries


def render_turn_timeline(entries):
    by_turn = defaultdict(list)
    for entry in entries:
        turn_id = entry.get("turnId")
        if turn_id:
            by_turn[turn_id].append(entry)
    if not by_turn:
        print("(no turn-tagged entries — older log, or no turns recorded)")
        return
    print(f"\n{len(by_turn)} turn(s):\n")
    for turn_id in sorted(by_turn, key=lambda t: by_turn[t][0].get("at", "")):
        turn_entries = sorted(by_turn[turn_id], key=lambda e: e.get("at", ""))
        first_at = turn_entries[0].get("at", "")
        total_ms = sum(duration for entry in turn_entries if (duration := measured_duration(entry)) is not None)
        any_error = any(is_recorded_failure(e.get("outcome")) for e in turn_entries)
        marker = "✗" if any_error else "✓"
        print(f"{marker} turn {turn_id[:8]}  start={first_at}  total={total_ms}ms")
        for entry in turn_entries:
            outcome_marker = "!!" if is_recorded_failure(entry.get("outcome")) else "  "
            target = (entry.get("target") or "")[:36]
            duration = measured_duration(entry)
            print(f"   {outcome_marker} {entry.get('subsystem'):<10} {entry.get('operation','')[:22]:<22} {target:<36} {duration if duration is not None else '—':>6}ms  {entry.get('outcome')}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--last", type=int, metavar="MINUTES", help="only entries from the last N minutes")
    parser.add_argument("--turns", action="store_true", help="per-turn timeline view instead of subsystem rollup")
    args = parser.parse_args()

    cutoff = None
    if args.last:
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=args.last)

    entries = load_entries(cutoff)
    if not entries:
        print(f"no audit entries found at {LOG_PATH}")
        sys.exit(0)

    if args.turns:
        render_turn_timeline(entries)
        return

    groups = defaultdict(list)
    for entry in entries:
        key = (entry.get("subsystem", "?"), entry.get("target", "?"))
        groups[key].append(entry)

    print(f"{len(entries)} diagnostic event(s)\n")
    header = f"{'subsystem':<12} {'target':<42} {'events':>6} {'err%':>5} {'p50ms':>7} {'p95ms':>7} {'p99ms':>7} {'maxms':>7}"
    print(header)
    print("-" * len(header))
    for (subsystem, target), group in sorted(groups.items()):
        durations = sorted(duration for entry in group if (duration := measured_duration(entry)) is not None)
        latencies = [percentile(durations, fraction) for fraction in (0.50, 0.95, 0.99)]
        latencies.append(durations[-1] if durations else None)
        latency_columns = " ".join(f"{value if value is not None else '—':>7}" for value in latencies)
        errors = sum(1 for e in group if is_recorded_failure(e.get("outcome")))
        print(
            f"{subsystem:<12} {target[:42]:<42} {len(group):>6} "
            f"{100 * errors / len(group):>4.1f}% "
            f"{latency_columns}"
        )

    failures = [e for e in entries if is_recorded_failure(e.get("outcome"))]
    if failures:
        print(f"\nlast {min(5, len(failures))} failure(s):")
        for entry in failures[-5:]:
            print(f"  {entry.get('at')} {entry.get('subsystem')}/{entry.get('target')}: "
                  f"{entry.get('outcome')} {entry.get('detail') or ''}")


if __name__ == "__main__":
    main()
