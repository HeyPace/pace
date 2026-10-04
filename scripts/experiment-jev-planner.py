#!/usr/bin/env python3
"""
EXPERIMENT — Jev "best next task?" router vs. the local planner model.

Loop under test (per fixture):

    request → router: "best next step?" (one of 29 tools | ASK_USER | RESPOND | DONE)
            → if tool: local model fills that tool's args from its schema
            → simulated execution (nothing touches the Mac) → append result
            → re-run router on same request + completed steps
            → ... until ASK_USER / RESPOND / DONE or the step cap

Two arms share the same labels, the same arg extractor (local qwen), and the
same simulated executor. Only the ROUTER differs:

    jev    — TypeSafe Jev. Uses the direct API (api.typesafe.ai, model
             jev-latest, `choice` question) when TYPESAFE_API_KEY is set,
             otherwise the keyless classifier.dev endpoint (tier fast).
    local  — the local LM Studio model picking from an enum (JSON schema).
    student — the distilled on-device encoder from scripts/train-router-student.py
             (temperature-scaled softmax over its saved labels; needs --student-dir).

PRIVACY: the jev arm sends fixture text to a cloud service. Fixtures are
synthetic. This script is an offline experiment and is NOT wired into the app;
shipping a cloud router would have to go through the non-local planner tier
rules in docs/architecture/systems.md.

Usage:
    python3 scripts/experiment-jev-planner.py --arms jev local
    python3 scripts/experiment-jev-planner.py --arms jev --limit 10
    python3 scripts/experiment-jev-planner.py --arms student --student-dir evals/router-data/student/<run>
"""

import argparse
import concurrent.futures
import json
import os
import re
import statistics
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY_JSON_PATH = REPO_ROOT / "leanring-buddy/Resources/v10-actions/registry.json"
REGISTRY_SWIFT_PATH = REPO_ROOT / "leanring-buddy/PaceToolRegistry.swift"
DEFAULT_FIXTURE_DIRECTORIES = [
    "fm-fixtures", "fm-fixtures-actions", "fm-fixtures-ambig", "fm-fixtures-compose",
    "fm-fixtures-destructive", "fm-fixtures-holdout", "fm-fixtures-oos", "fm-fixtures-v2",
]

CLASSIFIER_DEV_ENDPOINT = "https://classifier.dev/v1/classify"
TYPESAFE_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
TYPESAFE_MODEL = "jev-latest"
LM_STUDIO_ENDPOINT = os.environ.get("PACE_LM_STUDIO_URL", "http://localhost:1234/v1/chat/completions")

CONTROL_LABEL_DESCRIPTIONS = {
    "ASK_USER": "ask the user a clarifying question (several on-screen targets fit) or confirm before something destructive or irreversible (delete, send, pay)",
    "RESPOND": "reply in speech only: answer, describe the screen, or decline; no Mac action can or should satisfy the request",
    "DONE": "the completed steps already fully satisfy the request; stop",
}
ROUTER_INSTRUCTIONS = (
    "You route a macOS voice assistant. Choose the single best NEXT step given the user's request, "
    "what is on screen, and the steps already completed. Choose DONE when the completed steps already "
    "satisfy the request. Choose ASK_USER when the request could mean several on-screen targets, or would "
    "delete, send, or pay irreversibly. Choose RESPOND when no Mac action can or should satisfy it. "
    "Do not choose by shared keywords alone."
)
COMPOSE_TOOLS = {"mail", "messages", "notes", "things", "type", "set_value"}
COMPOSE_BODY_ARGUMENT_NAMES = ("body", "text", "notes")


# ---------------------------------------------------------------- tool catalog

def load_tool_catalog():
    """Tools come from the bundled registry.json (schemas) + PaceToolRegistry.swift (descriptions)."""
    registry_actions = json.loads(REGISTRY_JSON_PATH.read_text())["actions"]
    swift_source = REGISTRY_SWIFT_PATH.read_text()
    description_by_tool_name = dict(re.findall(
        r'canonicalName:\s*"([^"]+)".*?description:\s*"([^"]*)"', swift_source, flags=re.DOTALL))
    tool_catalog = {}
    for action in registry_actions:
        tool_name = action["tool"]
        tool_catalog[tool_name] = {
            "description": description_by_tool_name.get(tool_name, action.get("exampleUtterance", "")),
            "schema_example": {key: value for key, value in action["schemaExample"].items() if key != "tool"},
            "example_utterance": action.get("exampleUtterance", ""),
        }
    return tool_catalog


def json_schema_from_example_value(example_value):
    if isinstance(example_value, bool):
        return {"type": "boolean"}
    if isinstance(example_value, int):
        return {"type": "integer"}
    if isinstance(example_value, float):
        return {"type": "number"}
    if isinstance(example_value, list):
        item_schema = json_schema_from_example_value(example_value[0]) if example_value else {"type": "string"}
        return {"type": "array", "items": item_schema}
    if isinstance(example_value, dict):
        return {
            "type": "object",
            "properties": {key: json_schema_from_example_value(value) for key, value in example_value.items()},
            "required": list(example_value.keys()),
        }
    return {"type": "string"}


def argument_schema_for_tool(tool_name, tool_catalog, screen_elements):
    """click/double_click are re-expressed as an element_id pick so args can be scored against fixture IDs."""
    if tool_name in ("click", "double_click") and screen_elements:
        return {
            "type": "object",
            "properties": {"element_id": {"type": "integer", "enum": [element["id"] for element in screen_elements]}},
            "required": ["element_id"],
        }
    return json_schema_from_example_value(tool_catalog[tool_name]["schema_example"])


# ---------------------------------------------------------------- fixtures

def parse_fixture(fixture_path):
    fields = {}
    screen_elements = []
    for raw_line in fixture_path.read_text().splitlines():
        if ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        key, value = key.strip(), value.strip()
        if key == "ELEMENT":
            element_match = re.match(r"\[(\d+)\]\s*([^|]*)\|(-?\d+),(-?\d+)\|([^|]*)\|?(.*)", value)
            if element_match:
                screen_elements.append({
                    "id": int(element_match.group(1)), "role": element_match.group(2).strip(),
                    "x": int(element_match.group(3)), "y": int(element_match.group(4)),
                    "label": element_match.group(5).strip(), "text": element_match.group(6).strip(),
                })
            continue
        fields.setdefault(key, []).append(value)

    first = lambda key: fields.get(key, [None])[0]
    expectation = {
        "forbidden_tools": set(fields.get("EXPECT_ACTION_NOT", [])),
        "min_actions": int(first("EXPECT_MIN_ACTIONS") or 0),
        "argument_checks": fields.get("EXPECT_ACTION_ARG", []),
        "body_required_min_words": None,
    }
    if first("BODY_MUST_NOT_BE_EMPTY"):
        expectation["body_required_min_words"] = int(first("BODY_MIN_WORDS") or 1)

    expected_click_ids = [int(value) for value in fields.get("EXPECT_CLICK_ID", [])]
    for one_of_value in fields.get("EXPECT_CLICK_ID_ONE_OF", []):
        expected_click_ids += [int(part) for part in re.split(r"[,\s]+", one_of_value) if part.strip()]

    if first("EXPECT_ACTION"):
        expectation["kind"] = "tool"
        expectation["acceptable_first_steps"] = {first("EXPECT_ACTION")}
    elif first("EXPECT_INTENT") in ("clarify", "confirm_destructive"):
        expectation["kind"] = "ask"
        expectation["acceptable_first_steps"] = {"ASK_USER"}
    elif first("EXPECT_INTENT") == "out_of_scope":
        expectation["kind"] = "respond"
        expectation["acceptable_first_steps"] = {"RESPOND"}
    elif expectation["body_required_min_words"]:
        expectation["kind"] = "compose"
        expectation["acceptable_first_steps"] = set(COMPOSE_TOOLS) | {"open_app"}
    elif expected_click_ids and all(click_id < 0 for click_id in expected_click_ids):
        expectation["kind"] = "respond"
        expectation["acceptable_first_steps"] = {"RESPOND"}
        expectation["forbidden_tools"] |= {"click", "double_click"}
    elif expected_click_ids:
        expectation["kind"] = "click"
        expectation["acceptable_first_steps"] = {"click", "double_click"}
        expectation["expected_click_ids"] = {click_id for click_id in expected_click_ids if click_id >= 0}
    else:
        return None  # nothing scorable for routing

    return {
        "id": f"{fixture_path.parent.name}/{fixture_path.stem}",
        "category": fixture_path.parent.name,
        "user_request": first("USER") or "",
        "screen_elements": screen_elements,
        "expectation": expectation,
    }


def load_fixtures(fixture_directory_names):
    fixtures = []
    for directory_name in fixture_directory_names:
        for fixture_path in sorted((REPO_ROOT / "evals" / directory_name).glob("*.txt")):
            parsed_fixture = parse_fixture(fixture_path)
            if parsed_fixture:
                fixtures.append(parsed_fixture)
    return fixtures


# ---------------------------------------------------------------- shared context text

def screen_text(screen_elements):
    if not screen_elements:
        return "(no screen elements captured)"
    return "\n".join(
        f"[{element['id']}] {element['role']} '{element['label']}'"
        + (f" ({element['text']})" if element["text"] else "")
        + f" at {element['x']},{element['y']}"
        for element in screen_elements
    )


def completed_steps_text(completed_steps):
    if not completed_steps:
        return "(none yet)"
    return "\n".join(
        f"{index + 1}. {step['tool']} {json.dumps(step['args'])} -> {step['result']}"
        for index, step in enumerate(completed_steps)
    )


def router_input_text(fixture, completed_steps):
    return (
        f"REQUEST: {fixture['user_request']}\n"
        f"SCREEN:\n{screen_text(fixture['screen_elements'])}\n"
        f"COMPLETED STEPS:\n{completed_steps_text(completed_steps)}"
    )


def router_label_descriptions(tool_catalog):
    label_descriptions = {
        tool_name: f"{tool_info['description']} e.g. \"{tool_info['example_utterance']}\""
        for tool_name, tool_info in tool_catalog.items()
    }
    label_descriptions.update(CONTROL_LABEL_DESCRIPTIONS)
    return label_descriptions


class JevAccessDenied(Exception):
    """Keyless classifier.dev traffic outside the free allowance gets a non-retryable 403."""


# Wall time of the attempt that succeeded, per thread — retries/backoff sleeps are excluded.
last_successful_attempt = threading.local()


def post_json(url, payload, headers=None, timeout_seconds=30, max_attempts=3):
    request_body = json.dumps(payload).encode()
    for attempt_index in range(max_attempts):
        attempt_started = time.perf_counter()
        request = urllib.request.Request(
            url, data=request_body, method="POST",
            headers={"content-type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                response_json = json.loads(response.read())
            last_successful_attempt.elapsed_ms = (time.perf_counter() - attempt_started) * 1000
            last_successful_attempt.attempt_count = attempt_index + 1
            return response_json
        except urllib.error.HTTPError as http_error:
            error_body = http_error.read().decode(errors="replace")[:300]
            if http_error.code == 403:
                # Keyless classifier.dev has a small shared allowance that refills; back off and retry
                # before giving up. The direct TypeSafe API never needs this path.
                if url == CLASSIFIER_DEV_ENDPOINT and attempt_index + 1 < max_attempts:
                    time.sleep(20 * (attempt_index + 1))
                    continue
                raise JevAccessDenied(error_body) from http_error
            if http_error.code == 429 and attempt_index + 1 < max_attempts:
                time.sleep(float(http_error.headers.get("Retry-After") or 2))
                continue
            raise


# ---------------------------------------------------------------- routers

KEYLESS_JEV_MINIMUM_SECONDS_BETWEEN_CALLS = float(os.environ.get("JEV_KEYLESS_PACING_SECONDS", "7"))
KEYLESS_JEV_PACING_LOCK = threading.Lock()
keyless_jev_last_call_monotonic = 0.0


def wait_for_keyless_jev_pacing_slot():
    """Spaces keyless calls out so the shared free allowance keeps refilling. Pacing happens
    before the timer starts, so it never inflates the measured route latency."""
    global keyless_jev_last_call_monotonic
    with KEYLESS_JEV_PACING_LOCK:
        seconds_to_wait = KEYLESS_JEV_MINIMUM_SECONDS_BETWEEN_CALLS - (time.monotonic() - keyless_jev_last_call_monotonic)
        if seconds_to_wait > 0:
            time.sleep(seconds_to_wait)
        keyless_jev_last_call_monotonic = time.monotonic()


def route_with_jev(fixture, completed_steps, tool_catalog):
    """Returns (chosen_label, {label: probability}, elapsed_ms, model_reported_ms)."""
    label_descriptions = router_label_descriptions(tool_catalog)
    typesafe_api_key = os.environ.get("TYPESAFE_API_KEY")
    if not typesafe_api_key:
        wait_for_keyless_jev_pacing_slot()
    if typesafe_api_key:
        response = post_json(TYPESAFE_ENDPOINT, {
            "model": TYPESAFE_MODEL,
            "state": {
                "task": ROUTER_INSTRUCTIONS,
                "request": fixture["user_request"],
                "screen": screen_text(fixture["screen_elements"]),
                "completed_steps": completed_steps_text(completed_steps),
            },
            "questions": {"next_step": {
                "type": "choice",
                "instructions": "Which is the single best next step? Follow `task`.",
                "criteria": label_descriptions,
            }},
        }, headers={"authorization": f"Bearer {typesafe_api_key}"})
        elapsed_ms = last_successful_attempt.elapsed_ms
        probabilities = {label: float(value) for label, value in response["answers"]["next_step"]["probabilities"].items()}
        model_reported_ms = None
    else:
        label_text_by_name = {name: f"{name}: {description}" for name, description in label_descriptions.items()}
        response = post_json(CLASSIFIER_DEV_ENDPOINT, max_attempts=6, payload={
            "inputs": [router_input_text(fixture, completed_steps)],
            "labels": list(label_text_by_name.values()),
            "tier": "fast",
            "instructions": ROUTER_INSTRUCTIONS,
        })
        elapsed_ms = last_successful_attempt.elapsed_ms
        result = response["results"][0]
        name_by_label_text = {text: name for name, text in label_text_by_name.items()}
        probabilities = {name_by_label_text[text]: float(score) for text, score in result["scores"].items()}
        model_reported_ms = result.get("ms")
    chosen_label = max(probabilities, key=probabilities.get)
    return chosen_label, probabilities, elapsed_ms, model_reported_ms


LOCAL_MODEL_LOCK = threading.Lock()  # LM Studio serves one request at a time; keep timings honest


def call_local_model(system_prompt, user_prompt, response_schema, local_model_identifier, max_tokens=400):
    with LOCAL_MODEL_LOCK:
        started = time.perf_counter()
        response = post_json(LM_STUDIO_ENDPOINT, {
            "model": local_model_identifier,
            "temperature": 0,
            "max_tokens": max_tokens,
            "reasoning_effort": "none",
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_prompt}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "out", "strict": True, "schema": response_schema}},
        }, timeout_seconds=120)
        elapsed_ms = (time.perf_counter() - started) * 1000
    content = response["choices"][0]["message"]["content"]
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    return json.loads(content), elapsed_ms


# GLiNER2.5 (Fastino, open weights) runs in-process. It needs the `gliner2[local]` extra
# (torch + transformers), so it is imported lazily and only for the gliner arms.
GLINER_MODEL_IDENTIFIER = "fastino/gliner2.5-base-v1"
GLINER_LOAD_LOCK = threading.Lock()
gliner_loaded_model = None


def gliner_model():
    global gliner_loaded_model
    with GLINER_LOAD_LOCK:
        if gliner_loaded_model is None:
            from gliner2 import AutoExtractor
            import torch
            gliner_loaded_model = AutoExtractor.from_pretrained(GLINER_MODEL_IDENTIFIER)
            if torch.backends.mps.is_available():
                gliner_loaded_model = gliner_loaded_model.to("mps")  # ~160 ms vs ~570 ms on CPU for 32 labels
    return gliner_loaded_model


def gliner_prose_input_text(fixture, completed_steps):
    """GLiNER takes no instructions, so state is phrased as plain sentences instead of headed sections."""
    if completed_steps:
        progress_sentence = "Already done: " + "; ".join(
            f"{step['tool']} ({step['result']})" for step in completed_steps) + "."
    else:
        progress_sentence = "Nothing has been done yet."
    on_screen = ", ".join(f"[{element['id']}] {element['label']}" for element in fixture["screen_elements"])
    return (f"The user said: \"{fixture['user_request']}\". "
            + (f"On screen: {on_screen}. " if on_screen else "")
            + progress_sentence)


def route_with_gliner(fixture, completed_steps, tool_catalog, use_prose_input):
    label_descriptions = router_label_descriptions(tool_catalog)
    input_text = (gliner_prose_input_text(fixture, completed_steps) if use_prose_input
                  else router_input_text(fixture, completed_steps))
    model = gliner_model()
    started = time.perf_counter()
    # multi_label with threshold 0 returns a score for every label; we take the argmax.
    result = model.classify_text(
        input_text, {"next_step": {"labels": label_descriptions, "multi_label": True, "cls_threshold": 0.0}},
        include_confidence=True)
    elapsed_ms = (time.perf_counter() - started) * 1000
    probabilities = {entry["label"]: float(entry["confidence"]) for entry in result["next_step"]}
    chosen_label = max(probabilities, key=probabilities.get)
    return chosen_label, probabilities, elapsed_ms, None


# The distilled student (milestone 3 of docs/product/prds/next-step-router.md) also needs torch +
# transformers, so it is loaded lazily; the router class lives with its training script so the
# training input text and this arm's input text come from one function.
STUDENT_DIRECTORY = None
STUDENT_LOAD_LOCK = threading.Lock()
student_loaded_router = None


def student_router():
    global student_loaded_router
    with STUDENT_LOAD_LOCK:
        if student_loaded_router is None:
            import importlib.util
            module_spec = importlib.util.spec_from_file_location(
                "train_router_student", REPO_ROOT / "scripts/train-router-student.py")
            training_module = importlib.util.module_from_spec(module_spec)
            module_spec.loader.exec_module(training_module)
            student_loaded_router = training_module.StudentRouter(STUDENT_DIRECTORY)
            for _ in range(3):  # warm MPS kernels so the first timed call excludes compile cost
                student_loaded_router.route({"user_request": "warm up", "screen_elements": []}, [])
    return student_loaded_router


def route_with_student(fixture, completed_steps):
    chosen_label, probabilities, elapsed_ms = student_router().route(fixture, completed_steps)
    return chosen_label, probabilities, elapsed_ms, None


def route_with_local_model(fixture, completed_steps, tool_catalog, local_model_identifier):
    label_descriptions = router_label_descriptions(tool_catalog)
    options_text = "\n".join(f"- {name}: {description}" for name, description in label_descriptions.items())
    parsed, elapsed_ms = call_local_model(
        f"{ROUTER_INSTRUCTIONS}\n\nOptions:\n{options_text}\n\nReply with JSON {{\"next_step\": <option name>}}.",
        router_input_text(fixture, completed_steps),
        {"type": "object", "properties": {"next_step": {"type": "string", "enum": list(label_descriptions)}},
         "required": ["next_step"]},
        local_model_identifier, max_tokens=60)
    return parsed["next_step"], {}, elapsed_ms, None


# ---------------------------------------------------------------- args + simulated execution

def extract_arguments(fixture, completed_steps, tool_name, tool_catalog, local_model_identifier):
    argument_schema = argument_schema_for_tool(tool_name, tool_catalog, fixture["screen_elements"])
    if not argument_schema.get("properties"):
        return {}, 0.0
    tool_info = tool_catalog[tool_name]
    click_hint = ("Pick the element_id of the on-screen element to click. " if "element_id" in argument_schema["properties"] else "")
    parsed, elapsed_ms = call_local_model(
        f"You fill arguments for the macOS tool `{tool_name}`: {tool_info['description']} "
        f"Example call: {json.dumps(tool_info['schema_example'])}. {click_hint}"
        "When a tool writes text for the user (email body, message, note), write the full text, not a placeholder. "
        "Reply with JSON arguments only.",
        router_input_text(fixture, completed_steps),
        argument_schema, local_model_identifier, max_tokens=500)
    return parsed, elapsed_ms


def simulated_result(tool_name, tool_arguments, fixture):
    if tool_name in ("click", "double_click") and "element_id" in tool_arguments:
        element = next((element for element in fixture["screen_elements"] if element["id"] == tool_arguments["element_id"]), None)
        return f"ok: clicked '{element['label']}'" if element else "error: no such element"
    if tool_name == "open_app":
        return f"ok: {tool_arguments.get('app', 'app')} is now open and frontmost"
    if tool_name == "open_url":
        return f"ok: opened {tool_arguments.get('url', '')} in the browser"
    return "ok: done"


# ---------------------------------------------------------------- loop + scoring

def run_fixture(fixture, arm_name, tool_catalog, local_model_identifier, max_steps):
    completed_steps = []
    route_calls = []
    argument_call_ms = []
    terminal_label = None
    error_text = None
    try:
        for _ in range(max_steps):
            if arm_name == "jev":
                chosen_label, probabilities, route_ms, model_ms = route_with_jev(fixture, completed_steps, tool_catalog)
            elif arm_name in ("gliner", "gliner-prose"):
                chosen_label, probabilities, route_ms, model_ms = route_with_gliner(
                    fixture, completed_steps, tool_catalog, use_prose_input=(arm_name == "gliner-prose"))
            elif arm_name == "student":
                chosen_label, probabilities, route_ms, model_ms = route_with_student(fixture, completed_steps)
            else:
                chosen_label, probabilities, route_ms, model_ms = route_with_local_model(
                    fixture, completed_steps, tool_catalog, local_model_identifier)
            top_alternatives = sorted(probabilities.items(), key=lambda item: -item[1])[:3]
            route_calls.append({"label": chosen_label, "ms": round(route_ms), "model_ms": model_ms,
                                "top3": [[label, round(score, 3)] for label, score in top_alternatives]})
            if chosen_label in CONTROL_LABEL_DESCRIPTIONS:
                terminal_label = chosen_label
                break
            tool_arguments, argument_ms = extract_arguments(
                fixture, completed_steps, chosen_label, tool_catalog, local_model_identifier)
            argument_call_ms.append(argument_ms)
            # Loop guard: identical repeated call means the router is not seeing progress.
            if completed_steps and completed_steps[-1]["tool"] == chosen_label and completed_steps[-1]["args"] == tool_arguments:
                terminal_label = "REPEAT_GUARD"
                break
            completed_steps.append({"tool": chosen_label, "args": tool_arguments,
                                    "result": simulated_result(chosen_label, tool_arguments, fixture)})
    except JevAccessDenied:
        raise
    except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as error:
        error_text = f"{type(error).__name__}: {error}"
    return score_fixture(fixture, completed_steps, route_calls, argument_call_ms, terminal_label, error_text)


def argument_check_passes(argument_check, completed_steps):
    # Format: tool.arg~=substring   (case-insensitive contains)
    check_match = re.match(r"(\w+)\.(\w+)~=(.+)", argument_check)
    if not check_match:
        return True
    tool_name, argument_name, expected_substring = check_match.groups()
    return any(step["tool"] == tool_name and expected_substring.lower() in str(step["args"].get(argument_name, "")).lower()
               for step in completed_steps)


def score_fixture(fixture, completed_steps, route_calls, argument_call_ms, terminal_label, error_text):
    expectation = fixture["expectation"]
    first_step_label = route_calls[0]["label"] if route_calls else None
    tools_called = [step["tool"] for step in completed_steps]

    first_step_correct = first_step_label in expectation["acceptable_first_steps"]
    if expectation["kind"] == "click" and not first_step_correct:
        # Clicking a dock icon and open_app of that same app are equivalent outcomes.
        expected_labels = {element["label"].lower() for element in fixture["screen_elements"]
                           if element["id"] in expectation["expected_click_ids"] and element["role"] == "dock_icon"}
        first_step_correct = (first_step_label == "open_app" and completed_steps
                              and str(completed_steps[0]["args"].get("app", "")).lower() in expected_labels)

    arguments_correct = True
    if expectation["kind"] == "click" and first_step_label in ("click", "double_click") and completed_steps:
        arguments_correct = completed_steps[0]["args"].get("element_id") in expectation["expected_click_ids"]
    for argument_check in expectation["argument_checks"]:
        arguments_correct = arguments_correct and argument_check_passes(argument_check, completed_steps)
    if expectation["body_required_min_words"]:
        longest_body_word_count = max(
            [len(str(step["args"].get(argument_name, "")).split())
             for step in completed_steps if step["tool"] in COMPOSE_TOOLS
             for argument_name in COMPOSE_BODY_ARGUMENT_NAMES] or [0])
        arguments_correct = arguments_correct and longest_body_word_count >= expectation["body_required_min_words"]

    no_forbidden_tools = not (set(tools_called) & expectation["forbidden_tools"])
    enough_actions = len(completed_steps) >= expectation["min_actions"]
    # Tool-kind cases should end with an explicit DONE (the loop knew when to stop).
    terminated_cleanly = terminal_label in CONTROL_LABEL_DESCRIPTIONS
    full_pass = (not error_text and first_step_correct and arguments_correct and no_forbidden_tools
                 and enough_actions and terminated_cleanly)
    return {
        "id": fixture["id"], "category": fixture["category"], "kind": expectation["kind"],
        "request": fixture["user_request"],
        "expected_first": sorted(expectation["acceptable_first_steps"]),
        "first_step": first_step_label, "first_step_correct": bool(first_step_correct),
        "arguments_correct": bool(arguments_correct), "no_forbidden_tools": no_forbidden_tools,
        "enough_actions": enough_actions, "terminal": terminal_label, "terminated_cleanly": terminated_cleanly,
        "full_pass": full_pass, "error": error_text,
        "steps": completed_steps, "route_calls": route_calls,
        "route_ms": [call["ms"] for call in route_calls], "argument_ms": [round(ms) for ms in argument_call_ms],
    }


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))])


def summarize(arm_results):
    def rate(rows, key):
        return round(sum(1 for row in rows if row[key]) / len(rows), 3) if rows else None
    route_ms = [ms for row in arm_results for ms in row["route_ms"]]
    argument_ms = [ms for row in arm_results for ms in row["argument_ms"] if ms]
    model_ms = [call["model_ms"] for row in arm_results for call in row["route_calls"] if call["model_ms"]]
    summary = {
        "cases": len(arm_results),
        "errors": sum(1 for row in arm_results if row["error"]),
        "first_step_accuracy": rate(arm_results, "first_step_correct"),
        "full_pass": rate(arm_results, "full_pass"),
        "route_calls": len(route_ms),
        "route_ms_p50": percentile(route_ms, .5), "route_ms_p95": percentile(route_ms, .95),
        "route_model_ms_p50": percentile(model_ms, .5),
        "argument_ms_p50": percentile(argument_ms, .5), "argument_ms_p95": percentile(argument_ms, .95),
        "by_kind": {}, "by_category": {},
    }
    for group_key, group_field in (("by_kind", "kind"), ("by_category", "category")):
        for group_value in sorted({row[group_field] for row in arm_results}):
            group_rows = [row for row in arm_results if row[group_field] == group_value]
            summary[group_key][group_value] = {
                "n": len(group_rows),
                "first_step": rate(group_rows, "first_step_correct"),
                "args": rate(group_rows, "arguments_correct"),
                "full_pass": rate(group_rows, "full_pass"),
            }
    return summary


def main():
    argument_parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    argument_parser.add_argument("--arms", nargs="+", default=["jev", "local"], choices=["jev", "local", "gliner", "gliner-prose", "student"])
    argument_parser.add_argument("--fixtures-dirs", nargs="+", default=DEFAULT_FIXTURE_DIRECTORIES)
    argument_parser.add_argument("--local-model", default="qwen/qwen3.5-4b")
    argument_parser.add_argument("--gliner-model", default="fastino/gliner2.5-base-v1")
    argument_parser.add_argument("--student-dir", default=None, help="trained run dir for the student arm")
    argument_parser.add_argument("--max-steps", type=int, default=5)
    argument_parser.add_argument("--limit", type=int, default=0)
    argument_parser.add_argument("--concurrency", type=int, default=2)
    argument_parser.add_argument("--output", default=str(REPO_ROOT / "evals/jev-experiment/results.json"))
    parsed_arguments = argument_parser.parse_args()

    global GLINER_MODEL_IDENTIFIER, STUDENT_DIRECTORY
    GLINER_MODEL_IDENTIFIER = parsed_arguments.gliner_model
    STUDENT_DIRECTORY = parsed_arguments.student_dir
    if "student" in parsed_arguments.arms and not STUDENT_DIRECTORY:
        argument_parser.error("--arms student needs --student-dir")
    tool_catalog = load_tool_catalog()
    fixtures = load_fixtures(parsed_arguments.fixtures_dirs)
    if parsed_arguments.limit:
        fixtures = fixtures[:parsed_arguments.limit]
    jev_route = "typesafe direct (jev-latest)" if os.environ.get("TYPESAFE_API_KEY") else "classifier.dev (tier fast)"
    print(f"{len(tool_catalog)} tools, {len(fixtures)} scorable fixtures, jev route: {jev_route}")

    # Warm the local model so the first timed call does not include load/compile cost.
    try:
        call_local_model("Reply with JSON.", "warm up", {"type": "object", "properties": {"ok": {"type": "boolean"}},
                         "required": ["ok"]}, parsed_arguments.local_model, max_tokens=40)
    except ValueError:
        pass  # warm-up output is irrelevant; only the load cost matters

    report = {"created_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "jev_route": jev_route,
              "local_model": parsed_arguments.local_model, "max_steps": parsed_arguments.max_steps, "arms": {}}
    for arm_name in parsed_arguments.arms:
        # Local-router arm is bound by the single LM Studio slot anyway; jev arm parallelizes the network calls.
        worker_count = parsed_arguments.concurrency if arm_name == "jev" else 1
        started = time.perf_counter()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
                arm_results = list(executor.map(
                    lambda fixture: run_fixture(fixture, arm_name, tool_catalog, parsed_arguments.local_model,
                                                parsed_arguments.max_steps), fixtures))
        except JevAccessDenied as access_error:
            print(f"\n== {arm_name}: ABORTED — Jev denied access ({access_error}). "
                  "Set TYPESAFE_API_KEY to use the direct API.")
            continue
        arm_summary = summarize(arm_results)
        arm_summary["wall_seconds"] = round(time.perf_counter() - started, 1)
        report["arms"][arm_name] = {"summary": arm_summary, "rows": arm_results}
        print(f"\n== {arm_name}")
        print(json.dumps({key: value for key, value in arm_summary.items() if key != "by_category"}, indent=2))

    output_path = Path(parsed_arguments.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, default=list) + "\n")
    print(f"\nwrote {output_path}")


if __name__ == "__main__":
    main()
