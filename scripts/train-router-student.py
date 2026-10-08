#!/usr/bin/env python3
"""
Train + calibrate the on-device next-step router student (milestone 3 of
docs/product/prds/next-step-router.md).

    teacher-labelled step states (label-router-step-states.py)
        → router_input_text  (byte-identical to the experiment harness)
        → ModernBERT-base sequence classifier, 32 labels
        → loss = alpha * KL(teacher soft probs ‖ student) + (1 - alpha) * CE(teacher hard label)
        → single temperature fitted on the validation split
        → evaluation: validation, sealed set, latency (MPS + CPU, batch 1)

Data rules:
  - Trains on evals/router-data/train.labelled.jsonl, plus train-extra.labelled.jsonl
    (goal-phrased / disfluent / ambiguous click states) with --include-extra-train. The sealed set is
    scored, never trained on; sealed-extra.labelled.jsonl, when present, is scored and reported
    separately as "sealed_extra". The 123 harness fixtures are never seen here; score
    them with `experiment-jev-planner.py --arms student --student-dir <run dir>`.
  - A deterministic ~8% validation split is taken by hash of the row id.
  - Train rows whose teacher_confidence < --min-teacher-confidence go to
    evals/router-data/review.jsonl (rewritten every run) instead of training.
    Validation keeps every row so calibration reflects the real distribution.
  - Inputs that exceed --max-length tokens drop trailing SCREEN elements first,
    so the request and the completed steps (the decision-critical parts) survive.

Outputs (evals/router-data/student/<run-name>/, gitignored):
    model + tokenizer (save_pretrained), labels.json, temperature.json, metrics.json

Needs torch + transformers (not stdlib). Offline after the base encoder is cached.

Usage:
    python scripts/train-router-student.py --run-name modernbert-v1
    python scripts/train-router-student.py --run-name smoke --epochs 1 --limit-train-rows 400
"""

import argparse
import collections
import hashlib
import importlib.util
import json
import math
import random
import statistics
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_PATH = REPO_ROOT / "scripts/experiment-jev-planner.py"
DEFAULT_DATA_DIRECTORY = REPO_ROOT / "evals/router-data"
DEFAULT_BASE_MODEL = "answerdotai/ModernBERT-base"


def load_experiment_harness():
    module_spec = importlib.util.spec_from_file_location("experiment_jev_planner", HARNESS_PATH)
    harness_module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(harness_module)
    return harness_module


def sorted_router_labels(harness_module):
    """Fixed label order: alphabetical over the 29 registry tools + ASK_USER/RESPOND/DONE."""
    return sorted(harness_module.router_label_descriptions(harness_module.load_tool_catalog()))


def fixture_view_for_step_state(step_state_row):
    # router_input_text reads only these two fixture fields (same view label-router-step-states.py uses).
    return {"user_request": step_state_row["request"], "screen_elements": step_state_row["screen_elements"]}


def router_text_within_token_budget(harness_module, tokenizer, fixture, completed_steps, max_length):
    """Returns (text, was_truncated). The untruncated text is byte-identical to the harness's
    router_input_text. When it is too long, trailing screen elements are dropped one at a time,
    because SCREEN sits between REQUEST and COMPLETED STEPS and plain right-truncation would cut
    the completed steps, which decide DONE vs. the next tool."""
    full_text = harness_module.router_input_text(fixture, completed_steps)
    if len(tokenizer(full_text)["input_ids"]) <= max_length:
        return full_text, False
    kept_screen_elements = list(fixture["screen_elements"])
    while kept_screen_elements:
        kept_screen_elements.pop()
        shortened_text = harness_module.router_input_text(
            {**fixture, "screen_elements": kept_screen_elements}, completed_steps)
        if len(tokenizer(shortened_text)["input_ids"]) <= max_length:
            return shortened_text, True
    # Even with no screen it does not fit; the tokenizer's right-truncation is the last resort.
    return harness_module.router_input_text({**fixture, "screen_elements": []}, completed_steps), True


def read_jsonl_rows_tolerating_partial_tail(jsonl_path):
    """The teacher labeller appends while we read; a half-written last line is skipped."""
    parsed_rows = []
    if not jsonl_path.exists():
        return parsed_rows
    for line in jsonl_path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            parsed_rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return parsed_rows


def is_validation_row(row_id, validation_fraction):
    id_hash_bucket = int(hashlib.sha256(row_id.encode()).hexdigest()[:8], 16) % 10000
    return id_hash_bucket < validation_fraction * 10000


def percentile_value(values, fraction):
    ordered_values = sorted(values)
    return ordered_values[min(len(ordered_values) - 1, int(round(fraction * (len(ordered_values) - 1))))]


def token_length_summary(token_lengths):
    return {
        "n": len(token_lengths), "mean": round(statistics.mean(token_lengths), 1),
        "p50": percentile_value(token_lengths, .5), "p95": percentile_value(token_lengths, .95),
        "p99": percentile_value(token_lengths, .99), "max": max(token_lengths),
    }


# ---------------------------------------------------------------- student router (also used by the harness)

class StudentRouter:
    """Loads a trained run directory and routes one step state at a time (batch 1),
    returning temperature-scaled probabilities over the saved label order."""

    def __init__(self, student_directory, device_name=None):
        student_directory = Path(student_directory)
        self.harness_module = load_experiment_harness()
        metadata = json.loads((student_directory / "labels.json").read_text())
        validate_student_format(metadata, self.harness_module)
        self.router_labels = metadata["labels"]
        self.temperature = json.loads((student_directory / "temperature.json").read_text())["temperature"]
        self.max_length = metadata["max_length"]
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
        self.torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(student_directory)
        if device_name is None:
            device_name = "mps" if torch.backends.mps.is_available() else "cpu"
        self.device = torch.device(device_name)
        self.model = AutoModelForSequenceClassification.from_pretrained(student_directory).to(self.device).eval()

    def route(self, fixture, completed_steps):
        """Returns (chosen_label, {label: probability}, elapsed_ms) — tokenization included in the timing."""
        torch = self.torch
        started = time.perf_counter()
        input_text, _ = router_text_within_token_budget(
            self.harness_module, self.tokenizer, fixture, completed_steps, self.max_length)
        encoded_inputs = self.tokenizer(input_text, return_tensors="pt", truncation=True,
                                        max_length=self.max_length).to(self.device)
        with torch.no_grad():
            logits = self.model(**encoded_inputs).logits[0]
        probabilities = torch.softmax(logits / self.temperature, dim=-1).cpu().tolist()  # .cpu() syncs MPS
        elapsed_ms = (time.perf_counter() - started) * 1000
        probability_by_label = dict(zip(self.router_labels, probabilities))
        chosen_label = max(probability_by_label, key=probability_by_label.get)
        return chosen_label, probability_by_label, elapsed_ms


# ---------------------------------------------------------------- training helpers

def validate_student_format(metadata, harness_module):
    expected_hash = harness_module.router_format_sha256(harness_module.load_tool_catalog())
    if metadata.get("format_contract_version") != 2 or metadata.get("format_sha256") != expected_hash:
        raise ValueError("Student format identity is missing or differs from the current serializer/registry; "
                         "historical checkpoints remain unqualified and must not be relabelled with a new hash.")
    if metadata.get("labels") != sorted_router_labels(harness_module):
        raise ValueError("Student label order differs from the current registry")
    maximum_length = metadata.get("max_length")
    if type(maximum_length) is not int or maximum_length <= 0:
        raise ValueError("Student token limit must be a positive integer")

def encode_rows(harness_module, tokenizer, step_state_rows, router_labels, max_length):
    """Adds input_text, hard label index and renormalised teacher distribution to each row."""
    label_index_by_name = {label: index for index, label in enumerate(router_labels)}
    encoded_rows = []
    truncated_row_count = 0
    for step_state_row in step_state_rows:
        input_text, was_truncated = router_text_within_token_budget(
            harness_module, tokenizer, fixture_view_for_step_state(step_state_row),
            step_state_row["completed_steps"], max_length)
        truncated_row_count += was_truncated
        teacher_distribution = [max(0.0, float(step_state_row["teacher_probabilities"].get(label, 0.0)))
                                for label in router_labels]
        distribution_total = sum(teacher_distribution)
        teacher_distribution = [probability / distribution_total for probability in teacher_distribution]
        encoded_rows.append({
            "row": step_state_row, "input_text": input_text,
            "teacher_label_index": label_index_by_name[step_state_row["teacher_label"]],
            "teacher_distribution": teacher_distribution,
        })
    return encoded_rows, truncated_row_count


def batched(sequence, batch_size):
    for start_index in range(0, len(sequence), batch_size):
        yield sequence[start_index:start_index + batch_size]


def predict_logits(model, tokenizer, input_texts, device, max_length, batch_size=32):
    import torch
    collected_logits = []
    model.eval()
    with torch.no_grad():
        for text_batch in batched(input_texts, batch_size):
            encoded_batch = tokenizer(text_batch, return_tensors="pt", padding=True, truncation=True,
                                      max_length=max_length).to(device)
            collected_logits.append(model(**encoded_batch).logits.float().cpu())
    return torch.cat(collected_logits) if collected_logits else torch.zeros(0)


def fit_temperature(validation_logits, validation_label_indices):
    """Single scalar T minimising NLL of softmax(logits / T) against the teacher hard labels."""
    import torch
    log_temperature = torch.zeros(1, requires_grad=True)
    optimizer = torch.optim.LBFGS([log_temperature], lr=0.1, max_iter=200)

    def closure():
        optimizer.zero_grad()
        loss = torch.nn.functional.cross_entropy(validation_logits / log_temperature.exp(), validation_label_indices)
        loss.backward()
        return loss

    optimizer.step(closure)
    return float(log_temperature.exp().item())


def expected_calibration_error(probabilities, label_indices, bin_count=15):
    confidences, predictions = probabilities.max(dim=-1)
    correctness = (predictions == label_indices).float()
    calibration_error = 0.0
    for bin_index in range(bin_count):
        lower_bound, upper_bound = bin_index / bin_count, (bin_index + 1) / bin_count
        in_bin = (confidences > lower_bound) & (confidences <= upper_bound)
        if in_bin.any():
            bin_weight = in_bin.float().mean().item()
            calibration_error += bin_weight * abs(confidences[in_bin].mean().item() - correctness[in_bin].mean().item())
    return round(calibration_error, 4)


def coverage_at_confidence_thresholds(probabilities, label_indices, thresholds=(0.5, 0.7, 0.8, 0.9)):
    """How often the student would act (confidence ≥ threshold) and how accurate those acts are —
    the PRD's confidence-fallback knob."""
    confidences, predictions = probabilities.max(dim=-1)
    report = {}
    for threshold in thresholds:
        acted = confidences >= threshold
        acted_count = int(acted.sum())
        report[str(threshold)] = {
            "coverage": round(acted_count / len(confidences), 3) if len(confidences) else None,
            "accuracy_when_acting": round(float((predictions[acted] == label_indices[acted]).float().mean()), 3)
            if acted_count else None,
        }
    return report


def accuracy(predicted_labels, reference_labels):
    pairs = list(zip(predicted_labels, reference_labels))
    return round(sum(1 for predicted, reference in pairs if predicted == reference) / len(pairs), 4) if pairs else None


def evaluate_sealed_set(sealed_rows, sealed_predicted_labels):
    teacher_labels = [row["teacher_label"] for row in sealed_rows]
    intended_labels = [row["intended_label"] for row in sealed_rows]
    per_scenario = {}
    for scenario_name in sorted({row["scenario"] for row in sealed_rows}):
        scenario_indices = [index for index, row in enumerate(sealed_rows) if row["scenario"] == scenario_name]
        per_scenario[scenario_name] = {
            "n": len(scenario_indices),
            "vs_teacher": accuracy([sealed_predicted_labels[i] for i in scenario_indices], [teacher_labels[i] for i in scenario_indices]),
            "vs_intended": accuracy([sealed_predicted_labels[i] for i in scenario_indices], [intended_labels[i] for i in scenario_indices]),
            "teacher_vs_intended": accuracy([teacher_labels[i] for i in scenario_indices], [intended_labels[i] for i in scenario_indices]),
        }
    confusion_pair_counts = collections.Counter(
        f"teacher={teacher_label} → student={predicted_label}"
        for predicted_label, teacher_label in zip(sealed_predicted_labels, teacher_labels) if predicted_label != teacher_label)
    ask_user_rows = [index for index, label in enumerate(teacher_labels) if label == "ASK_USER"]
    return {
        "n": len(sealed_rows),
        "accuracy_vs_teacher": accuracy(sealed_predicted_labels, teacher_labels),
        "accuracy_vs_intended": accuracy(sealed_predicted_labels, intended_labels),
        "teacher_vs_intended": accuracy(teacher_labels, intended_labels),
        "ask_user_recall_vs_teacher": accuracy([sealed_predicted_labels[i] for i in ask_user_rows], ["ASK_USER"] * len(ask_user_rows)),
        "per_scenario": per_scenario,
        "top_confusions_vs_teacher": confusion_pair_counts.most_common(12),
    }


def measure_routing_latency(student_directory, step_state_rows, device_name, warmup_calls=10, timed_calls=100):
    student_router = StudentRouter(student_directory, device_name=device_name)
    sample_rows = (step_state_rows * (1 + (warmup_calls + timed_calls) // max(1, len(step_state_rows))))
    for step_state_row in sample_rows[:warmup_calls]:
        student_router.route(fixture_view_for_step_state(step_state_row), step_state_row["completed_steps"])
    route_ms = [student_router.route(fixture_view_for_step_state(step_state_row), step_state_row["completed_steps"])[2]
                for step_state_row in sample_rows[warmup_calls:warmup_calls + timed_calls]]
    return {"device": device_name, "calls": len(route_ms),
            "p50_ms": round(percentile_value(route_ms, .5), 1), "p95_ms": round(percentile_value(route_ms, .95), 1)}


# ---------------------------------------------------------------- main

def main():
    argument_parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    argument_parser.add_argument("--run-name", required=True)
    argument_parser.add_argument("--data-dir", default=str(DEFAULT_DATA_DIRECTORY))
    argument_parser.add_argument("--base-model", default=DEFAULT_BASE_MODEL)
    argument_parser.add_argument("--max-length", type=int, default=512)
    argument_parser.add_argument("--epochs", type=float, default=3)
    argument_parser.add_argument("--batch-size", type=int, default=16)
    argument_parser.add_argument("--learning-rate", type=float, default=3e-5)
    argument_parser.add_argument("--warmup-fraction", type=float, default=0.06)
    argument_parser.add_argument("--weight-decay", type=float, default=0.01)
    argument_parser.add_argument("--distillation-alpha", type=float, default=0.5,
                                 help="weight of the KL-to-teacher-probabilities term; 1 - alpha weights CE on the hard label")
    argument_parser.add_argument("--min-teacher-confidence", type=float, default=0.5)
    argument_parser.add_argument("--label-policy", choices=["teacher", "agreement"], default="teacher",
                                 help="agreement: train only where teacher == generator guess, or teacher is very sure")
    argument_parser.add_argument("--agreement-override-confidence", type=float, default=0.8)
    argument_parser.add_argument("--validation-fraction", type=float, default=0.08)
    argument_parser.add_argument("--limit-train-rows", type=int, default=0, help="smoke runs only")
    argument_parser.add_argument("--seed", type=int, default=13)
    argument_parser.add_argument("--device", default=None, help="default: mps when available, else cpu")
    argument_parser.add_argument("--latency-calls", type=int, default=100)
    argument_parser.add_argument("--include-extra-train", action="store_true",
                                 help="also train on train-extra.labelled.jsonl (review rows go to review-extra.jsonl)")
    parsed_arguments = argument_parser.parse_args()

    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer, get_linear_schedule_with_warmup

    random.seed(parsed_arguments.seed)
    torch.manual_seed(parsed_arguments.seed)
    device_name = parsed_arguments.device or ("mps" if torch.backends.mps.is_available() else "cpu")
    device = torch.device(device_name)

    harness_module = load_experiment_harness()
    router_labels = sorted_router_labels(harness_module)
    format_sha256 = harness_module.router_format_sha256(harness_module.load_tool_catalog())
    data_directory = Path(parsed_arguments.data_dir)
    run_directory = data_directory / "student" / parsed_arguments.run_name
    run_directory.mkdir(parents=True, exist_ok=True)
    tokenizer = AutoTokenizer.from_pretrained(parsed_arguments.base_model)

    # ---- data
    labelled_train_rows = read_jsonl_rows_tolerating_partial_tail(data_directory / "train.labelled.jsonl")
    sealed_rows = read_jsonl_rows_tolerating_partial_tail(data_directory / "sealed.labelled.jsonl")
    labelled_extra_train_rows = (read_jsonl_rows_tolerating_partial_tail(data_directory / "train-extra.labelled.jsonl")
                                 if parsed_arguments.include_extra_train else [])
    extra_sealed_rows = read_jsonl_rows_tolerating_partial_tail(data_directory / "sealed-extra.labelled.jsonl")
    labelled_train_rows = labelled_train_rows + labelled_extra_train_rows
    extra_train_ids = {row["id"] for row in labelled_extra_train_rows}
    sealed_ids = {row["id"] for row in sealed_rows + extra_sealed_rows}
    if any(row["id"] in sealed_ids for row in labelled_train_rows):
        raise SystemExit("sealed ids found in the labelled train rows — refusing to train")
    unknown_teacher_labels = {row["teacher_label"] for row in labelled_train_rows + sealed_rows + extra_sealed_rows} - set(router_labels)
    if unknown_teacher_labels:
        raise SystemExit(f"teacher labels not in the registry label set: {sorted(unknown_teacher_labels)}")

    validation_rows = [row for row in labelled_train_rows if is_validation_row(row["id"], parsed_arguments.validation_fraction)]
    training_candidate_rows = [row for row in labelled_train_rows if not is_validation_row(row["id"], parsed_arguments.validation_fraction)]
    def row_is_trainable(row):
        if row["teacher_confidence"] < parsed_arguments.min_teacher_confidence:
            return False
        if parsed_arguments.label_policy == "teacher":
            return True
        # "agreement": the teacher over-asks (e.g. ASK_USER on plain mail/messages drafts) and the
        # generator's guess is noisy, so keep a row only when the two agree or the teacher is very sure.
        teacher_agrees_with_generator = row["teacher_label"] == row.get("intended_label")
        return teacher_agrees_with_generator or row["teacher_confidence"] >= parsed_arguments.agreement_override_confidence

    training_rows = [row for row in training_candidate_rows if row_is_trainable(row)]
    review_rows = [row for row in labelled_train_rows if not row_is_trainable(row)]
    review_path = data_directory / "review.jsonl"
    review_path.write_text("".join(json.dumps(row) + "\n" for row in review_rows if row["id"] not in extra_train_ids))
    if labelled_extra_train_rows:
        (data_directory / "review-extra.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in review_rows if row["id"] in extra_train_ids))
    if parsed_arguments.limit_train_rows:
        random.shuffle(training_rows)
        training_rows = training_rows[:parsed_arguments.limit_train_rows]
    print(f"labelled train rows {len(labelled_train_rows)} (extra {len(labelled_extra_train_rows)}) → train {len(training_rows)}, validation {len(validation_rows)}, "
          f"review (policy {parsed_arguments.label_policy}) {len(review_rows)} → {review_path}; sealed {len(sealed_rows)}")
    if not training_rows or not validation_rows:
        raise SystemExit("not enough labelled rows yet to train and validate")

    encoded_training_rows, truncated_training_count = encode_rows(harness_module, tokenizer, training_rows, router_labels, parsed_arguments.max_length)
    encoded_validation_rows, truncated_validation_count = encode_rows(harness_module, tokenizer, validation_rows, router_labels, parsed_arguments.max_length)
    encoded_sealed_rows, truncated_sealed_count = encode_rows(harness_module, tokenizer, sealed_rows, router_labels, parsed_arguments.max_length)
    harness_fixtures = harness_module.load_fixtures(harness_module.DEFAULT_FIXTURE_DIRECTORIES)
    token_length_report = {
        "train": token_length_summary([len(tokenizer(row["input_text"])["input_ids"]) for row in encoded_training_rows]),
        "sealed": token_length_summary([len(tokenizer(row["input_text"])["input_ids"]) for row in encoded_sealed_rows]),
        "harness_fixtures_first_step": token_length_summary(
            [len(tokenizer(harness_module.router_input_text(fixture, []))["input_ids"]) for fixture in harness_fixtures]),
        "truncated_rows": {"train": truncated_training_count, "validation": truncated_validation_count, "sealed": truncated_sealed_count},
    }
    print("token lengths:", json.dumps(token_length_report))

    # ---- model
    model = AutoModelForSequenceClassification.from_pretrained(
        parsed_arguments.base_model, num_labels=len(router_labels),
        id2label=dict(enumerate(router_labels)), label2id={label: index for index, label in enumerate(router_labels)},
    ).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=parsed_arguments.learning_rate, weight_decay=parsed_arguments.weight_decay)
    steps_per_epoch = math.ceil(len(encoded_training_rows) / parsed_arguments.batch_size)
    total_training_steps = max(1, int(steps_per_epoch * parsed_arguments.epochs))
    learning_rate_scheduler = get_linear_schedule_with_warmup(
        optimizer, int(parsed_arguments.warmup_fraction * total_training_steps), total_training_steps)

    # ---- train
    training_started = time.perf_counter()
    training_step_index = 0
    epoch_log = []
    while training_step_index < total_training_steps:
        model.train()
        shuffled_training_rows = list(encoded_training_rows)
        random.shuffle(shuffled_training_rows)
        epoch_losses = []
        for training_batch in batched(shuffled_training_rows, parsed_arguments.batch_size):
            if training_step_index >= total_training_steps:
                break
            encoded_batch = tokenizer([row["input_text"] for row in training_batch], return_tensors="pt", padding=True,
                                      truncation=True, max_length=parsed_arguments.max_length).to(device)
            teacher_distributions = torch.tensor([row["teacher_distribution"] for row in training_batch], device=device)
            teacher_label_indices = torch.tensor([row["teacher_label_index"] for row in training_batch], device=device)
            student_log_probabilities = torch.log_softmax(model(**encoded_batch).logits.float(), dim=-1)
            # Forward KL(teacher ‖ student): the standard distillation direction; zero-probability
            # teacher labels contribute nothing (kl_div treats 0 * log 0 as 0).
            distillation_loss = torch.nn.functional.kl_div(student_log_probabilities, teacher_distributions, reduction="batchmean")
            hard_label_loss = torch.nn.functional.nll_loss(student_log_probabilities, teacher_label_indices)
            combined_loss = (parsed_arguments.distillation_alpha * distillation_loss
                             + (1 - parsed_arguments.distillation_alpha) * hard_label_loss)
            combined_loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            learning_rate_scheduler.step()
            optimizer.zero_grad()
            epoch_losses.append(combined_loss.item())
            training_step_index += 1
            if training_step_index % 50 == 0:
                print(f"  step {training_step_index}/{total_training_steps} loss {statistics.mean(epoch_losses[-50:]):.4f} "
                      f"{time.perf_counter() - training_started:.0f}s", flush=True)
        validation_logits = predict_logits(model, tokenizer, [row["input_text"] for row in encoded_validation_rows], device, parsed_arguments.max_length)
        validation_label_indices = torch.tensor([row["teacher_label_index"] for row in encoded_validation_rows])
        validation_accuracy = float((validation_logits.argmax(-1) == validation_label_indices).float().mean())
        epoch_log.append({"epoch": len(epoch_log) + 1, "train_loss": round(statistics.mean(epoch_losses), 4),
                          "validation_accuracy_vs_teacher": round(validation_accuracy, 4)})
        print(f"epoch {len(epoch_log)}: {epoch_log[-1]}", flush=True)
    training_seconds = time.perf_counter() - training_started

    # ---- calibrate on validation
    validation_logits = predict_logits(model, tokenizer, [row["input_text"] for row in encoded_validation_rows], device, parsed_arguments.max_length)
    validation_label_indices = torch.tensor([row["teacher_label_index"] for row in encoded_validation_rows])
    fitted_temperature = fit_temperature(validation_logits, validation_label_indices)
    uncalibrated_validation_probabilities = torch.softmax(validation_logits, -1)
    calibrated_validation_probabilities = torch.softmax(validation_logits / fitted_temperature, -1)
    confident_validation_mask = torch.tensor([row["row"]["teacher_confidence"] >= parsed_arguments.min_teacher_confidence
                                              for row in encoded_validation_rows])
    validation_predictions = validation_logits.argmax(-1)
    validation_report = {
        "n": len(encoded_validation_rows),
        "accuracy_vs_teacher": round(float((validation_predictions == validation_label_indices).float().mean()), 4),
        "accuracy_vs_teacher_confident_rows": round(float(
            (validation_predictions[confident_validation_mask] == validation_label_indices[confident_validation_mask]).float().mean()), 4)
        if confident_validation_mask.any() else None,
        "nll_before": round(float(torch.nn.functional.cross_entropy(validation_logits, validation_label_indices)), 4),
        "nll_after": round(float(torch.nn.functional.cross_entropy(validation_logits / fitted_temperature, validation_label_indices)), 4),
        "ece_before": expected_calibration_error(uncalibrated_validation_probabilities, validation_label_indices),
        "ece_after": expected_calibration_error(calibrated_validation_probabilities, validation_label_indices),
        "coverage_at_threshold_after": coverage_at_confidence_thresholds(calibrated_validation_probabilities, validation_label_indices),
    }
    print("validation:", json.dumps(validation_report))

    # ---- sealed set (never trained on)
    sealed_logits = predict_logits(model, tokenizer, [row["input_text"] for row in encoded_sealed_rows], device, parsed_arguments.max_length)
    sealed_predicted_labels = [router_labels[index] for index in sealed_logits.argmax(-1).tolist()] if sealed_rows else []
    sealed_report = evaluate_sealed_set(sealed_rows, sealed_predicted_labels) if sealed_rows else None
    if sealed_rows:
        sealed_label_indices = torch.tensor([row["teacher_label_index"] for row in encoded_sealed_rows])
        sealed_calibrated_probabilities = torch.softmax(sealed_logits / fitted_temperature, -1)
        sealed_report["ece_after"] = expected_calibration_error(sealed_calibrated_probabilities, sealed_label_indices)
        sealed_report["coverage_at_threshold_after"] = coverage_at_confidence_thresholds(sealed_calibrated_probabilities, sealed_label_indices)
    print("sealed:", json.dumps({key: value for key, value in (sealed_report or {}).items() if key != "per_scenario"}))

    # ---- sealed-extra (goal-phrased / disfluent / ambiguous clicks; never trained on), reported on its own
    extra_sealed_report = None
    if extra_sealed_rows:
        encoded_extra_sealed_rows, _ = encode_rows(harness_module, tokenizer, extra_sealed_rows, router_labels, parsed_arguments.max_length)
        extra_sealed_logits = predict_logits(model, tokenizer, [row["input_text"] for row in encoded_extra_sealed_rows], device, parsed_arguments.max_length)
        extra_sealed_predicted_labels = [router_labels[index] for index in extra_sealed_logits.argmax(-1).tolist()]
        extra_sealed_report = evaluate_sealed_set(extra_sealed_rows, extra_sealed_predicted_labels)
        print("sealed_extra:", json.dumps({key: value for key, value in extra_sealed_report.items() if key != "top_confusions_vs_teacher"}))

    # ---- save
    model.save_pretrained(run_directory)
    tokenizer.save_pretrained(run_directory)
    (run_directory / "labels.json").write_text(json.dumps(
        {"labels": router_labels, "max_length": parsed_arguments.max_length, "base_model": parsed_arguments.base_model,
         "format_contract_version": 2, "format_sha256": format_sha256}, indent=2) + "\n")
    (run_directory / "temperature.json").write_text(json.dumps({"temperature": round(fitted_temperature, 5)}, indent=2) + "\n")
    del model
    if device_name == "mps":
        torch.mps.empty_cache()

    # ---- latency, batch 1, after warmup (reloads from disk so it measures the saved artefact)
    latency_sample_rows = sealed_rows or validation_rows
    latency_report = [measure_routing_latency(run_directory, latency_sample_rows, latency_device, timed_calls=parsed_arguments.latency_calls)
                      for latency_device in (["mps", "cpu"] if torch.backends.mps.is_available() else ["cpu"])]
    print("latency:", json.dumps(latency_report))

    metrics = {
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "run_name": parsed_arguments.run_name,
        "arguments": vars(parsed_arguments), "device": device_name,
        "rows": {"labelled_train": len(labelled_train_rows), "labelled_extra_train": len(labelled_extra_train_rows),
                 "train": len(training_rows), "validation": len(validation_rows),
                 "review": len(review_rows), "sealed": len(sealed_rows), "sealed_extra": len(extra_sealed_rows)},
        "token_lengths": token_length_report, "training_seconds": round(training_seconds, 1), "epochs": epoch_log,
        "temperature": round(fitted_temperature, 5), "validation": validation_report, "sealed": sealed_report,
        "sealed_extra": extra_sealed_report,
        "latency": latency_report,
        "format_contract_version": 2, "format_sha256": format_sha256,
        "checkpoint_size_bytes": sum(path.stat().st_size for path in run_directory.rglob("*")
                                     if path.is_file() and path.name not in ("metrics.json", "harness-results.json")),
    }
    (run_directory / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(f"\nwrote {run_directory}")
    print(f"harness fixtures: python scripts/experiment-jev-planner.py --arms student --student-dir {run_directory} "
          f"--output {run_directory / 'harness-results.json'}")


if __name__ == "__main__":
    main()
