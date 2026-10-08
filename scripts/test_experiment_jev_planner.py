"""Offline regressions for the development scorer; no model or app execution."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("experiment-jev-planner.py")
MODULE_SPEC = importlib.util.spec_from_file_location("experiment_jev_planner", SCRIPT_PATH)
HARNESS = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(HARNESS)


class ClickAlternativesTests(unittest.TestCase):
    def setUp(self):
        self.fixture = HARNESS.parse_fixture(
            HARNESS.REPO_ROOT / "evals/fm-fixtures/mumbled-target.txt")

    def score(self, first_label, element_id=None, terminal="RESPOND", error=None):
        steps = [] if element_id is None else [
            {"tool": first_label, "args": {"element_id": element_id}, "result": "ok"}]
        return HARNESS.score_fixture(self.fixture, steps, [{"label": first_label, "ms": 0}],
                                     [], terminal, error)

    def test_existing_mixed_fixture_accepts_refusal_without_action(self):
        self.assertTrue(self.score("RESPOND")["full_pass"])

    def test_existing_mixed_fixture_preserves_click_id_constraint(self):
        for tool in ("click", "double_click"):
            with self.subTest(tool=tool):
                self.assertTrue(self.score(tool, 1, "DONE")["full_pass"])
                self.assertFalse(self.score(tool, 0, "DONE")["full_pass"])

    def test_repeat_guard_and_execution_error_still_fail(self):
        self.assertFalse(self.score("click", 1, "REPEAT_GUARD")["full_pass"])
        self.assertFalse(self.score("RESPOND", error="execution failed")["full_pass"])

    def test_single_outcome_fixtures_keep_their_original_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_path = Path(temporary) / "fixture.txt"
            for expectation, refusal_allowed in (("1", False), ("-1", True)):
                with self.subTest(expectation=expectation):
                    fixture_path.write_text("USER: click save\nEXPECT_CLICK_ID_ONE_OF: " + expectation + "\n")
                    self.fixture = HARNESS.parse_fixture(fixture_path)
                    self.assertEqual(self.score("RESPOND")["full_pass"], refusal_allowed)
                    if refusal_allowed:
                        self.assertFalse(self.score("click", 1, "DONE")["full_pass"])

    def test_explicit_tool_expectation_keeps_precedence(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_path = Path(temporary) / "fixture.txt"
            fixture_path.write_text("USER: scroll down\nEXPECT_ACTION: scroll\nEXPECT_CLICK_ID_ONE_OF: -1,1\n")
            self.fixture = HARNESS.parse_fixture(fixture_path)
            self.assertEqual(self.fixture["expectation"]["acceptable_first_steps"], {"scroll"})
            self.assertFalse(self.score("RESPOND")["full_pass"])


if __name__ == "__main__":
    unittest.main()
