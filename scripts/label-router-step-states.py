#!/usr/bin/env python3
"""
Teacher-label the synthetic router step states (milestone 2b of
docs/product/prds/next-step-router.md).

Reads evals/router-data/{train,sealed}.jsonl from generate-router-step-states.py
(or {train,sealed}-extra.jsonl from its --extra-scenarios-only mode)
and asks TypeSafe Jev — through the exact `route_with_jev` call the experiment
harness measured — for the best next step. Writes one labelled row per state:

    {...original row..., "teacher_label": str, "teacher_probabilities": {label: p},
     "teacher_confidence": float, "teacher_ms": int}

Resumable: rows whose id is already in the output file are skipped, so an
interrupted run continues where it stopped.

PRIVACY: sends only SYNTHETIC step states to TypeSafe, at training time.
Requires TYPESAFE_API_KEY (the keyless endpoint cannot sustain this volume).

Usage:
    TYPESAFE_API_KEY=… python3 scripts/label-router-step-states.py --split train
    TYPESAFE_API_KEY=… python3 scripts/label-router-step-states.py --split sealed --limit 50
    TYPESAFE_API_KEY=… python3 scripts/label-router-step-states.py --split train-extra   # → train-extra.labelled.jsonl
"""

import argparse
import concurrent.futures
import importlib.util
import json
import os
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_PATH = REPO_ROOT / "scripts/experiment-jev-planner.py"


def load_experiment_harness():
    module_spec = importlib.util.spec_from_file_location("experiment_jev_planner", HARNESS_PATH)
    harness_module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(harness_module)
    return harness_module


def already_labelled_ids(output_path):
    if not output_path.exists():
        return set()
    labelled_ids = set()
    for line in output_path.read_text().splitlines():
        if line.strip():
            labelled_ids.add(json.loads(line)["id"])
    return labelled_ids


def main():
    argument_parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    argument_parser.add_argument("--split", choices=["train", "sealed", "train-extra", "sealed-extra"], required=True)
    argument_parser.add_argument("--data-dir", default=str(REPO_ROOT / "evals/router-data"))
    argument_parser.add_argument("--concurrency", type=int, default=4)
    argument_parser.add_argument("--limit", type=int, default=0)
    parsed_arguments = argument_parser.parse_args()

    if not os.environ.get("TYPESAFE_API_KEY"):
        raise SystemExit("TYPESAFE_API_KEY is required for teacher labelling.")

    harness_module = load_experiment_harness()
    tool_catalog = harness_module.load_tool_catalog()
    data_directory = Path(parsed_arguments.data_dir)
    input_path = data_directory / f"{parsed_arguments.split}.jsonl"
    output_path = data_directory / f"{parsed_arguments.split}.labelled.jsonl"

    step_state_rows = [json.loads(line) for line in input_path.read_text().splitlines() if line.strip()]
    labelled_ids = already_labelled_ids(output_path)
    pending_rows = [row for row in step_state_rows if row["id"] not in labelled_ids]
    if parsed_arguments.limit:
        pending_rows = pending_rows[:parsed_arguments.limit]
    print(f"{len(step_state_rows)} rows, {len(labelled_ids)} already labelled, {len(pending_rows)} to label")

    output_write_lock = threading.Lock()
    progress_counts = {"done": 0, "failed": 0}
    started = time.perf_counter()

    def label_one_row(step_state_row):
        # route_with_jev reads only these two fixture fields.
        fixture_view = {"user_request": step_state_row["request"], "screen_elements": step_state_row["screen_elements"]}
        try:
            chosen_label, probabilities, route_ms, _ = harness_module.route_with_jev(
                fixture_view, step_state_row["completed_steps"], tool_catalog)
        except Exception as error:  # keep going; failed rows are retried on the next run
            with output_write_lock:
                progress_counts["failed"] += 1
                print(f"  failed {step_state_row['id']}: {type(error).__name__}: {str(error)[:120]}")
            return
        labelled_row = {
            **step_state_row,
            "teacher_label": chosen_label,
            "teacher_probabilities": {label: round(probability, 4) for label, probability in probabilities.items()},
            "teacher_confidence": round(probabilities[chosen_label], 4),
            "teacher_ms": round(route_ms),
        }
        with output_write_lock:
            with output_path.open("a") as output_file:
                output_file.write(json.dumps(labelled_row) + "\n")
            progress_counts["done"] += 1
            if progress_counts["done"] % 250 == 0:
                elapsed_seconds = time.perf_counter() - started
                print(f"  {progress_counts['done']}/{len(pending_rows)} labelled, "
                      f"{progress_counts['failed']} failed, {elapsed_seconds:.0f}s", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=parsed_arguments.concurrency) as executor:
        list(executor.map(label_one_row, pending_rows))

    print(f"done: {progress_counts['done']} labelled, {progress_counts['failed']} failed → {output_path}")


if __name__ == "__main__":
    main()
