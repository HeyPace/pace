# Next-step router (distilled, on-device)

Status: **in progress** — best student v3 65.0% full pass at 14 ms (2026-10-04); see the experiment README. Experiment evidence: [`evals/jev-experiment/README.md`](https://github.com/HeyPace/pace/blob/main/evals/jev-experiment/README.md).

## Problem

Pace's planner loop asks a local LLM, every step, to both *decide* what to do
next and *write* the action. The decision half is where it fails:

- It does not ask when it should. On ambiguous or destructive requests the local
  `qwen3.5-4b` router chose ASK_USER 40% of the time; Jev chose it 80%.
- It does not stop. After a successful click it re-picked the same click in 8 of
  123 fixtures (a double-fire in the app). Jev never did.
- It is slow for a classification: ~690 ms p50 per step on the local model.

The 2026-10-04 experiment showed the decision can be split out as a pure
classification ("best next step?") and that a strong classifier (TypeSafe Jev)
reaches 85% full pass vs 72% for the local model. Jev is a cloud service, which
breaks the on-device moat, and the network costs ~370–950 ms per step. Zero-shot
open-weights classifiers (GLiNER2.5-base) failed outright (≤18% full pass; see
[`failed-approaches.md`](../../knowledge/failed-approaches.md)).

## Goal

Own a small on-device router that matches the cloud teacher on Pace's
distribution, at encoder speed.

| Metric | Target | Today (local 4b router) |
|---|---|---|
| Full pass, current 123 fixtures | ≥ 85% | 71.5% |
| ASK_USER recall (ambiguous + destructive) | ≥ 80% | 40% |
| Repeat-action rate after a successful step | 0 | 8 / 123 |
| Router latency p50 on M-series | ≤ 30 ms | ~690 ms |
| Sealed set (never trained on) full pass | within 5 pp of teacher | — |
| Bytes sent off the Mac at runtime | 0 | 0 |

## Non-goals

- Argument filling. The local LLM keeps filling the chosen tool's args from its
  schema (the experiment's arg extractor was ≥95% correct where scored).
- Replacing the spoken-answer path (RESPOND hands back to the existing planner).
- Open-label zero-shot over arbitrary new tools. The head is fixed-label; new
  tools need a retrain (see Risks).

## Design

```
step state (request + screen elements + completed steps)
   → tokenizer (BPE, ≤ 512 tokens)
   → small bidirectional encoder (ModernBERT-base / Ettin-150M class)
   → 32-way softmax: 29 registry tools + ASK_USER + RESPOND + DONE
   → temperature-scaled confidence
        ≥ threshold → act on it (tool → local arg fill; control → stop/ask/answer)
        < threshold → fall back to today's full local planner step
```

- **Labels** come from `Resources/v10-actions/registry.json` plus the three
  control labels, so the label set drift-checks against the shipped registry.
- **Input serialization** is the harness's `router_input_text` (request, screen
  list, numbered completed steps with results), shared by training, eval and
  app so the three cannot diverge.
- **Runtime:** export to MLX-Swift or CoreML int8 and call it in-process from
  the agent loop. No server, no Python in the app.

## Data plan

1. **Generate step states, not utterances.** Each row = request + screen + 0..N
   completed steps. Cover single-step, multi-step, already-done, ambiguous
   (several on-screen targets), destructive (delete/send/pay), out-of-scope,
   describe-screen, compose. Diversity from paraphrase sources (existing
   `evals/intent-corpus`, MASSIVE, CLINC OOS, ToolACE/xLAM in the HF cache)
   rather than templates.
2. **Label with the teacher** (Jev direct API, `choice` question over the same
   32 label descriptions). Keep the full probability vector for soft-label
   distillation. Cost is negligible (~$0.042 per million input tokens).
3. **Filter** low-confidence teacher labels into a review pile instead of
   training on them.
4. **Seal** a fresh held-out set before training starts; never train on it or on
   the 123 harness fixtures.

Every prior routing/planning model attempt, why it failed, and the guardrails this router follows (human sealed set, label policy, per-class no-regression gates, kill criteria) are in [#200](https://github.com/HeyPace/pace/issues/200). The 123 harness fixtures are **dev**, not the final score.

Lesson carried over from posttrainllm `pace-intent-router-v8`: 95.5% on its
synthetic holdout but 57% on a sealed benchmark, because template data
overfit. Diversity of phrasing and state is the main risk, not model size.

## Privacy

Teacher labelling sends **synthetic** step states to TypeSafe at *training
time only*. No user data is labelled. The shipped router is fully local; the
runtime sends nothing. The teacher's terms must permit training on its outputs;
confirm before the first training run.

## Milestones

1. Teacher baseline on the direct API (accuracy, latency, calibration).
2. Step-state generator + sealed set + teacher labels (10–20k rows).
3. Train + calibrate encoder; score on harness fixtures and sealed set.
4. Swift export + in-process latency measurement on hardware.
5. Wire behind an Info.plist switch with confidence fallback; dogfood.

## Risks

- **New tools need a retrain.** Mitigation: the confidence fallback routes
  unseen intents to the full planner; retraining is a scripted step.
- **Teacher ceiling.** The student inherits Jev's over-asking on single-target
  clicks. Mitigation: relabel disputed classes by hand on the review pile.
- **Synthetic-only states** do not test real screen observation. Mitigation:
  add real dogfood traces (opt-in, local) to the sealed set when available.
