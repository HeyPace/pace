# Jev "best next step?" router experiment (2026-10-04)

Offline experiment, **not wired into the app**. Harness: [`scripts/experiment-jev-planner.py`](../../scripts/experiment-jev-planner.py).

## Question

Can [TypeSafe Jev](https://classifier.dev/agents.md) (a cloud zero-shot classifier, already used by meme-lab for ranking) replace the local model as the planner's **router** in this loop?

```
request → router: best next step? (29 registry tools | ASK_USER | RESPOND | DONE)
        → local model fills that tool's args from its schema
        → simulated execution → append result → re-ask router … until a control label or 5 steps
```

Both arms share labels, the arg extractor (`qwen/qwen3.5-4b`, Pace's default planner), and the simulated executor. Only the router differs.

## Setup

- 123 scorable fixtures from `evals/fm-fixtures*` (excluding VLM). Expected first step comes from `EXPECT_ACTION` (tool), `EXPECT_INTENT` clarify/confirm_destructive (ASK_USER), out_of_scope or `EXPECT_CLICK_ID: -1` (RESPOND), `EXPECT_CLICK_ID ≥ 0` (click with that element), `BODY_MUST_NOT_BE_EMPTY` (compose).
- "Full pass" = right first step + right args + no forbidden tool + min actions + the loop ended on a control label (not the repeat guard or step cap).
- Jev route: **keyless `classifier.dev`, tier fast (`jev-1.13.0`)**, not the direct `api.typesafe.ai` `jev-latest` API — no `TYPESAFE_API_KEY` was found in any Infisical project. Keyless calls were paced ≥7 s apart (shared free allowance); pacing and retry backoff are excluded from latency.

## Results

| | Jev router | Local qwen3.5-4b router |
|---|---|---|
| First-step accuracy | **85.4%** | 78.9% |
| Full pass | **85.4%** | 71.5% |
| Ask user (n=30) | **80%** | 40% |
| Click on-screen element (n=39) | 74% | **92%** first step / 69% full |
| Speak only, or decline (n=38) | 97% | 92% |
| Named tool (n=8) | 100% | 88% |
| Compose (n=8) | 88% | 88% |
| Router latency p50 / p95 | 950 / 1878 ms | **687 / 901 ms** |
| Jev model time p50 (server-reported) | 118 ms | — |

Teacher re-run on the **direct API** (`jev-latest` → served as `jev-1.13.0`, `results-jev-direct.json`): full pass **85.4%** (ask user 87%, click 80%, speak-only/decline 92%, named tool 88%, compose 75%), router p50 / p95 **385 / 772 ms**, no repeat-guard hits. Confidence ≥ 0.95 was right 38/38; < 0.5 was right 65% (n=17).

Open-weights zero-shot follow-up, GLiNER2.5-base (local, PyTorch MPS), results in `results-gliner2.5-base.json`:

| | GLiNER headed input | GLiNER prose input |
|---|---|---|
| First-step accuracy | 31.7% | 39.8% |
| Full pass | 0% | 17.9% |
| Ask user | 0% | 0% |
| Router latency p50 | 549 ms | 587 ms |

It picks DONE before acting and re-picks the same tool after success (repeat guard hit in 76 / 67 of 123 cases). Recorded in [`failed-approaches.md`](../../docs/knowledge/failed-approaches.md).

Per-case: both pass 80, Jev-only 25, local-only 8. Raw rows: `results-jev-classifier-dev.json`, `results-local-qwen3.5-4b.json`.

## Distilled student (on-device router)

Plan: [`docs/product/prds/next-step-router.md`](../../docs/product/prds/next-step-router.md). ModernBERT-base + 32-way head, trained on Jev labels of synthetic step states (`scripts/generate-router-step-states.py` → `label-router-step-states.py` → `train-router-student.py`). Run metrics in `students/<run>/`.

| Run | Data / label policy | Fixture full pass | Click | Ask user | Route p50 (MPS) |
|---|---|---|---|---|---|
| v1 | 13.4k base rows, teacher labels (conf ≥ 0.5) | 58.5% | 26% | 80% | 16 ms |
| v2 | same rows, agreement filter (teacher = generator guess, or teacher ≥ 0.8) | 53.7% | 28% | 67% | 18 ms* |
| **v3** | agreement + 2.25k goal-phrased click rows | **65.0%** | **64%** | 70% | **14 ms** |

\*measured while another run trained on the GPU; standalone ~18 ms. Sealed accuracy vs teacher: v1 80%, v2 75%, v3 76%.

Takeaways: data coverage, not label filtering, moved the needle (v3 clicks 26% → 64%). Still below the local 4b router (71.5%) and Jev (85.4%). Remaining misses: single-target clicks routed to ASK_USER (12), RESPOND cases routed to ASK_USER/click (10). Next: more realistic coverage for those, then newer base encoders ([#200](https://github.com/HeyPace/pace/issues/200)).

## What we learned

1. **Jev knows when to stop.** After a tool step it said DONE 44/52 times and never tripped the repeat guard. The local router re-picked the same click in 8 cases — in the app that is a double-fire. This is the single biggest full-pass gap.
2. **Jev is much better at "should I ask?"** — clarify 75% vs 25%, destructive-confirm 90% vs 70%. The local model answers in speech instead of asking.
3. **Jev over-asks on single-target clicks.** 6 click misses chose ASK_USER (e.g. "click save" 0.80 ASK_USER). Some are defensible ("send this to the trash", "pay my electric bill") — fixture expectations, not only router errors.
4. **Latency is network, not model.** 118 ms model vs ~950 ms round trip from here (Cloudflare SIN). Per-step cloud hops cost more than the local router already costs.
5. **Confidence is calibrated** (≥0.95 → 98% correct, n=42), but a "fall back to local below threshold" hybrid did not beat Jev alone (best 84.6% first-step at 0.5).

## Caveats

- Keyless fast tier, not `jev-latest`; the direct API may score differently.
- Fixtures are synthetic, single-screen; the executor is simulated, so step 2+ only tests stop/continue judgment, not real observation.
- Shipping a cloud router breaks the on-device default; it would have to be a non-local planner tier (amber capsule, audit log) per [`docs/architecture/systems.md`](../../docs/architecture/systems.md).

## Re-run

```bash
lms load qwen/qwen3.5-4b
python3 scripts/experiment-jev-planner.py --arms local --output evals/jev-experiment/results-local-qwen3.5-4b.json
TYPESAFE_API_KEY=… python3 scripts/experiment-jev-planner.py --arms jev --output evals/jev-experiment/results-jev-direct.json
# GLiNER arms need a venv with `pip install "gliner2[local]" protobuf sentencepiece`
HF_HUB_OFFLINE=1 <venv>/bin/python scripts/experiment-jev-planner.py --arms gliner gliner-prose --output evals/jev-experiment/results-gliner2.5-base.json
```
