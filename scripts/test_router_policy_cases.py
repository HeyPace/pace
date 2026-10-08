"""Offline freeze/progress contracts; these tests do not establish model accuracy."""
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name):
    path = Path(__file__).with_name(name)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load("router-policy-cases.py")
HARNESS = load("experiment-jev-planner.py")


class PolicyCaseTests(unittest.TestCase):
    def test_splits_have_distinct_identities_and_explicit_provenance(self):
        acceptance = GENERATOR.bundle("policy_acceptance", 16)
        calibration = GENERATOR.bundle("policy_calibration", 4)
        self.assertEqual(len(acceptance["cases"]), 96)
        self.assertEqual(len(calibration["cases"]), 24)
        self.assertFalse({case["id"] for case in acceptance["cases"]} &
                         {case["id"] for case in calibration["cases"]})
        self.assertEqual(acceptance["origin"], "machine_generated")

    def test_changed_bytes_and_duplicate_identities_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "cases.json"
            data = GENERATOR.bundle("policy_acceptance", 1)
            path.write_text(json.dumps(data))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            HARNESS.load_policy_fixture_bundle(path, digest)
            path.write_text(path.read_text() + " ")
            with self.assertRaisesRegex(ValueError, "hash changed"):
                HARNESS.load_policy_fixture_bundle(path, digest)
            data["cases"].append(data["cases"][0])
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                HARNESS.load_policy_fixture_bundle(path, hashlib.sha256(path.read_bytes()).hexdigest())

    def test_already_completed_state_reaches_router_without_reexecuting_it(self):
        fixture = next(case for case in GENERATOR.make_cases("policy_acceptance", 1)
                       if case["expectation"]["kind"] == "done")
        fixture["expectation"]["acceptable_first_steps"] = {"DONE"}
        fixture["expectation"]["forbidden_tools"] = {"click", "double_click"}
        with patch.object(HARNESS, "route_with_local_model", return_value=("DONE", {}, 0, None)) as router:
            result = HARNESS.run_fixture(fixture, "local", {}, "unused", 5)
        self.assertEqual(router.call_args.args[1], fixture["initial_completed_steps"])
        self.assertTrue(result["full_pass"])
        self.assertEqual(result["steps"], [])

    def test_keyword_baseline_exposes_template_difficulty_without_model_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "cases.json"
            path.write_text(json.dumps(GENERATOR.bundle("policy_acceptance", 2)))
            _, fixtures = HARNESS.load_policy_fixture_bundle(path, hashlib.sha256(path.read_bytes()).hexdigest())
            with patch.object(HARNESS, "call_local_model", side_effect=AssertionError("unexpected model call")):
                results = [HARNESS.run_fixture(fixture, "rules", {}, "unused", 5) for fixture in fixtures]
        self.assertTrue(all(result["full_pass"] for result in results))


if __name__ == "__main__":
    unittest.main()
