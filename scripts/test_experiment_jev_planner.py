"""Offline regressions for the development scorer; no model or app execution."""
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


class TeacherAccessTests(unittest.TestCase):
    def setUp(self):
        specification = importlib.util.spec_from_file_location("fresh_jev_access", SCRIPT_PATH)
        self.harness = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(self.harness)

    def test_denied_access_is_not_retried_or_repeated_by_the_next_case(self):
        def denied(*args, **kwargs):
            raise self.harness.urllib.error.HTTPError(self.harness.CLASSIFIER_DEV_ENDPOINT, 403,
                "Forbidden", {}, io.BytesIO(b'{"code":"proxy_requires_payment","retryable":false}'))
        with patch.object(self.harness.urllib.request, "urlopen", side_effect=denied) as request, \
                patch.object(self.harness.time, "sleep") as sleep:
            for _ in range(2):
                with self.assertRaises(self.harness.JevAccessDenied):
                    self.harness.post_json(self.harness.CLASSIFIER_DEV_ENDPOINT, {}, max_attempts=6)
            self.assertEqual(request.call_count, 1)
            sleep.assert_not_called()

    def test_keyless_synthetic_requests_explicitly_disable_data_sharing(self):
        fixture = {"user_request": "Who are you?", "screen_elements": []}
        response = {"results": [{"scores": {"RESPOND: " + self.harness.CONTROL_LABEL_DESCRIPTIONS["RESPOND"]: 1}}]}
        with patch.object(self.harness.os, "environ", {}), \
                patch.object(self.harness, "wait_for_keyless_jev_pacing_slot"), \
                patch.object(self.harness, "post_json", return_value=response) as post:
            self.harness.last_successful_attempt.elapsed_ms = 1
            self.harness.route_with_jev(fixture, [], self.harness.load_tool_catalog())
            self.assertIs(post.call_args.kwargs["payload"].get("share_data"), False)
            self.assertEqual(post.call_args.kwargs.get("headers", {}).get("X-Classifier-Share-Data"), "false")

    def test_local_access_error_does_not_block_the_teacher_route(self):
        error = self.harness.urllib.error.HTTPError(self.harness.LM_STUDIO_ENDPOINT, 403, "Forbidden", {}, io.BytesIO(b"local error"))
        with patch.object(self.harness.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(self.harness.urllib.error.HTTPError):
                self.harness.post_json(self.harness.LM_STUDIO_ENDPOINT, {}, max_attempts=1)
        self.assertFalse(self.harness.teacher_access_denied.is_set())


if __name__ == "__main__":
    unittest.main()
