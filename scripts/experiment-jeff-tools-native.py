#!/usr/bin/env python3
"""Evaluate Jeff tools using its published request contract in Pace's simulated loop.

The adapter has 31 options: 29 tools plus answer_directly and ask_user. The
former maps to RESPOND (also ends the loop); explicit DONE selection is untested.
This arm is a format adaptation, separately reported from the 32-option arm.
"""
import importlib.util
import json
import time
from pathlib import Path

harness_path = Path(__file__).with_name("experiment-jev-planner.py")
spec = importlib.util.spec_from_file_location("pace_router", harness_path)
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


def route_with_native_tools(fixture, completed_steps, tool_catalog):
    if harness.jeff_loaded_model is None:
        from jeff.mlx_backend import MlxDecisionModel
        if not harness.JEFF_ADAPTER_DIRECTORY:
            raise ValueError("native tools requires --jeff-adapter-dir")
        harness.jeff_loaded_model = MlxDecisionModel(
            harness.JEFF_CHECKPOINT, adapters={"tools": Path(harness.JEFF_ADAPTER_DIRECTORY)})
        harness.jeff_loaded_model.use("tools")
    criteria = {
        "answer_directly": "No tool is needed: answer the user directly from the conversation",
        "ask_user": "A tool is needed but required information is missing: ask the user first",
    }
    label_mapping = {"answer_directly": "RESPOND", "ask_user": "ASK_USER"}
    for index, (tool_name, tool_info) in enumerate(tool_catalog.items(), 1):
        option_key = f"t{index}"
        argument_names = ", ".join(tool_info["schema_example"])
        criteria[option_key] = f"{tool_name}({argument_names}): {tool_info['description']}"
        label_mapping[option_key] = tool_name
    conversation = [{"role": "assistant", "text": "Observed screen:\n" + harness.screen_text(fixture["screen_elements"])}]
    for step in completed_steps:
        conversation.append({"role": "assistant", "text":
            f"Completed action: {step['tool']} {json.dumps(step['args'])} -> {step['result']}"})
    decision_input = {
        "state": {"agent": harness.ROUTER_INSTRUCTIONS, "conversation": conversation,
                  "user_message": fixture["user_request"]},
        "question": {"type": "choice", "instructions":
            "Which tool should the agent call next to handle the user's latest message? Use the conversation for context. If no tool is needed, choose answer directly. If a tool is needed but information it requires is missing, choose ask the user.",
            "criteria": criteria},
    }
    started = time.perf_counter()
    values, _ = harness.jeff_loaded_model.decide([decision_input])[0]
    elapsed_ms = (time.perf_counter() - started) * 1000
    probabilities = {label_mapping[key]: value for key, value in zip(criteria, values, strict=True)}
    return max(probabilities, key=probabilities.get), probabilities, elapsed_ms, None


harness.route_with_jeff = route_with_native_tools
if __name__ == "__main__":
    harness.main()
