"""Check artifact identity before loading torch, transformers, or checkpoint bytes."""
import importlib.util
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
