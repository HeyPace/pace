"""Check artifact identity before loading torch, transformers, or checkpoint bytes."""
import importlib.util
import hashlib
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

SCRIPT = Path(__file__).with_name("train-router-student.py")
SPEC = importlib.util.spec_from_file_location("train_router_student", SCRIPT)
TRAINER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRAINER)
LABELLER_SPEC = importlib.util.spec_from_file_location("label_router_states", SCRIPT.with_name("label-router-step-states.py"))
LABELLER = importlib.util.module_from_spec(LABELLER_SPEC)
LABELLER_SPEC.loader.exec_module(LABELLER)


class StudentFormatTests(unittest.TestCase):
    def setUp(self):
        self.harness = TRAINER.load_experiment_harness()
        self.metadata = {
            "labels": TRAINER.sorted_router_labels(self.harness), "max_length": 512,
            "format_contract_version": 2,
            "format_sha256": self.harness.router_format_sha256(self.harness.load_tool_catalog())}

    def test_current_contract_is_accepted(self):
        TRAINER.validate_student_format(self.metadata, self.harness)

    def test_serializer_drift_is_rejected(self):
        self.metadata["format_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "format identity"):
            TRAINER.validate_student_format(self.metadata, self.harness)

    def test_reordered_labels_are_rejected_even_with_matching_hash(self):
        self.metadata["labels"] = list(reversed(self.metadata["labels"]))
        with self.assertRaisesRegex(ValueError, "label order"):
            TRAINER.validate_student_format(self.metadata, self.harness)

    def test_legacy_metadata_fails_before_dependency_or_model_loading(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            path.joinpath("labels.json").write_text(json.dumps({"labels": ["DONE"], "max_length": 512}))
            with self.assertRaisesRegex(ValueError, "format identity"):
                TRAINER.StudentRouter(path)

    def test_registry_description_changes_identity(self):
        catalog = self.harness.load_tool_catalog()
        original = self.harness.router_format_sha256(catalog)
        first_tool = next(iter(catalog))
        catalog[first_tool]["description"] += " changed"
        self.assertNotEqual(original, self.harness.router_format_sha256(catalog))

    def test_teacher_option_order_changes_identity(self):
        catalog = self.harness.load_tool_catalog()
        original = self.harness.router_format_sha256(catalog)
        reordered = dict(reversed(list(catalog.items())))
        self.assertNotEqual(original, self.harness.router_format_sha256(reordered))


class TeacherInputTests(unittest.TestCase):
    def setUp(self):
        self.harness = TRAINER.load_experiment_harness()
        self.labels = TRAINER.sorted_router_labels(self.harness)
        self.row = {"id": "synthetic-teacher-check", "request": "Who are you?", "screen_elements": [],
                    "completed_steps": [], "teacher_label": "RESPOND",
                    "teacher_probabilities": {label: float(label == "RESPOND") for label in self.labels},
                    "teacher_confidence": 1.0}
        self.row["teacher_input_identity"] = {
            "schema_version": "pace.router-teacher-input/v1", "format_contract_version": 2,
            "format_sha256": self.harness.router_format_sha256(self.harness.load_tool_catalog()),
            "input_sha256": hashlib.sha256(self.harness.router_input_text(
                TRAINER.fixture_view_for_step_state(self.row), []).encode()).hexdigest()}

    def encode(self):
        class Tokenizer:
            def __call__(self, text):
                return {"input_ids": [1]}
        return TRAINER.encode_rows(self.harness, Tokenizer(), [self.row], self.labels, 512)

    def test_current_teacher_input_is_accepted(self):
        encoded, truncated = self.encode()
        self.assertEqual(len(encoded), 1)
        self.assertEqual(truncated, 0)

    def test_legacy_teacher_labels_require_relabelling(self):
        del self.row["teacher_input_identity"]
        with self.assertRaisesRegex(ValueError, "Teacher input identity"):
            self.encode()

    def test_same_id_with_changed_request_is_rejected(self):
        self.row["request"] = "Open Safari."
        with self.assertRaisesRegex(ValueError, "Teacher input identity"):
            self.encode()

    def test_changed_progress_is_rejected(self):
        self.row["completed_steps"] = [{"tool": "open_app", "args": {"app": "Safari"}, "result": "ok: open"}]
        with self.assertRaisesRegex(ValueError, "Teacher input identity"):
            self.encode()

    def test_changed_teacher_instructions_are_rejected(self):
        self.harness.ROUTER_INSTRUCTIONS += " Additional policy."
        with self.assertRaisesRegex(ValueError, "Teacher input identity"):
            self.encode()

    def test_main_rejects_legacy_rows_before_model_dependencies_or_output(self):
        del self.row["teacher_input_identity"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "train.labelled.jsonl").write_text(json.dumps(self.row) + "\n")
            with patch("sys.argv", [str(SCRIPT), "--run-name", "identity-check", "--data-dir", directory]), \
                    patch.dict("sys.modules", {"torch": None, "transformers": None}):
                with self.assertRaisesRegex(ValueError, "Teacher input identity"):
                    TRAINER.main()
            self.assertFalse((root / "student").exists())

    def test_labeller_records_input_and_resumes_only_unchanged_states(self):
        source_row = {key: value for key, value in self.row.items() if not key.startswith("teacher_")}
        catalog = self.harness.load_tool_catalog()
        probabilities = self.row["teacher_probabilities"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "train.jsonl"
            source.write_text(json.dumps(source_row) + "\n")
            with patch("sys.argv", ["label-router-step-states.py", "--split", "train", "--data-dir", directory,
                                    "--concurrency", "1"]), \
                    patch.object(LABELLER.os, "environ", {"TYPESAFE_API_KEY": "synthetic-test-no-network"}), \
                    patch.object(LABELLER, "load_experiment_harness", return_value=self.harness), \
                    patch.object(self.harness, "route_with_jev", return_value=("RESPOND", probabilities, 1, None)) as teacher:
                LABELLER.main()
                saved = json.loads((root / "train.labelled.jsonl").read_text())
                self.assertEqual(saved["teacher_input_identity"], self.row["teacher_input_identity"])
                LABELLER.main()
                self.assertEqual(teacher.call_count, 1)
                source.write_text(json.dumps({**source_row, "request": "Open Safari."}) + "\n")
                with self.assertRaisesRegex(ValueError, "Saved teacher state"):
                    LABELLER.main()
                self.assertEqual(teacher.call_count, 1)
                source.write_text(json.dumps(source_row) + "\n")
                del saved["teacher_input_identity"]
                (root / "train.labelled.jsonl").write_text(json.dumps(saved) + "\n")
                with self.assertRaisesRegex(ValueError, "Teacher input identity"):
                    LABELLER.main()
                self.assertEqual(teacher.call_count, 1)
                saved["teacher_input_identity"] = self.row["teacher_input_identity"]
                (root / "train.labelled.jsonl").write_text(json.dumps(saved) + "\n")
            self.assertEqual(LABELLER.already_labelled_ids(root / "train.labelled.jsonl", [source_row],
                                                         self.harness, catalog), {source_row["id"]})

    def test_duplicate_input_ids_fail_before_a_first_teacher_call(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "Duplicate input state"):
                LABELLER.already_labelled_ids(Path(directory) / "not-created.jsonl", [self.row, self.row],
                                             self.harness, self.harness.load_tool_catalog())


if __name__ == "__main__":
    unittest.main()
