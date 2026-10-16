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


if __name__ == "__main__":
    unittest.main()
