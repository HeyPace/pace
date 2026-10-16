#!/usr/bin/env python3
"""
Teacher-label the synthetic router step states (milestone 2b of
docs/product/prds/next-step-router.md).

Reads evals/router-data/{train,sealed}.jsonl from generate-router-step-states.py
(or {train,sealed}-extra.jsonl from its --extra-scenarios-only mode)
and asks TypeSafe Jev — through the exact `route_with_jev` call the experiment
harness measured — for the best next step. Writes one labelled row per state:

    {...original row..., "teacher_label": str, "teacher_probabilities": {label: p},
     "teacher_confidence": float, "teacher_ms": int, "teacher_input_identity": {...}}

Resumable only when the saved label's router-input identity and original state
still match. Legacy or changed rows require a fresh output dataset; never restamp them.

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


def already_labelled_ids(output_path, step_state_rows, harness_module, tool_catalog):
    current_by_id = {row["id"]: row for row in step_state_rows}
    if len(current_by_id) != len(step_state_rows):
        raise ValueError("Duplicate input state ids; refusing ambiguous resume")
    if not output_path.exists():
        return set()
    labelled_ids = set()
    for line in output_path.read_text().splitlines():
        if line.strip():
            labelled_row = json.loads(line)
            harness_module.validate_teacher_input_identity(labelled_row, tool_catalog)
            row_id = labelled_row["id"]
            current = current_by_id.get(row_id)
            if row_id in labelled_ids or current is None or any(labelled_row.get(key) != value for key, value in current.items()):
                raise ValueError("Saved teacher state is duplicate, missing or changed; use a fresh output dataset")
            labelled_ids.add(row_id)
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
    labelled_ids = already_labelled_ids(output_path, step_state_rows, harness_module, tool_catalog)
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
        input_identity = harness_module.router_teacher_input_identity(step_state_row, tool_catalog)
        try:
            chosen_label, probabilities, route_ms, _ = harness_module.route_with_jev(
                fixture_view, step_state_row["completed_steps"], tool_catalog)
        except harness_module.JevAccessDenied:
            raise  # Stop the batch; later rows must not repeat a non-retryable denial.
        except Exception as error:  # keep going; failed rows are retried on the next run
            with output_write_lock:
                progress_counts["failed"] += 1
                print(f"  failed {step_state_row['id']}: {type(error).__name__}: {str(error)[:120]}")
            return
        labelled_row = {
            **step_state_row,
            "teacher_input_identity": input_identity,
            "teacher_route": "typesafe-direct",
            "teacher_requested_model": harness_module.TYPESAFE_MODEL,
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
