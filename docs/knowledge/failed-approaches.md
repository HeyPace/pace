# Failed and deferred approaches

Approaches that were tried and rejected, or deliberately deferred, with the
reason. Read this before retrying a dead end — the next agent should not spend a
turn rediscovering why something doesn't work here. Update this page when an
approach is abandoned or a deferred idea is revisited.

The durable status record is [PROJECT_STATUS.md](https://github.com/HeyPace/pace/blob/main/PROJECT_STATUS.md); this
page is the curated "do not retry without new information" list.

## Rejected: test fixture storage under `.documentDirectory`

**Why rejected:** `QPlanExecutionTests.makeSandboxFilePath` rooted its
`q_plan_test_<UUID>` fixture directories under `FileManager.default.urls(for:
.documentDirectory, ...)` — the user's real, iCloud-syncable `~/Documents` —
with no cleanup. Found 2026-09-13 after 2,110 stale directories had
accumulated in a real `~/Documents` folder (each holding one small evidence
text file from `testStep2RequiresStep1Verification`/
`testRealMultiStepE2EExecution`). Fixed by rooting test fixtures under
`FileManager.default.temporaryDirectory` instead (mirrors the existing
`/tmp/q-sandbox` precedent in `QAgentE2ETests.swift`) and adding explicit
`defer`-based cleanup at every call site. Never point test-only fixture
storage at `.documentDirectory`, `.desktopDirectory`, or any other real
user-visible/iCloud-syncable location — always the system temporary
directory (or an explicitly test-scoped subdirectory of it), always cleaned
up by the test that created it.

## Rejected: cloud anything as a default

**Why rejected:** Pace's headline differentiator is fully-on-device operation
(speed + zero operating cost + "0 bytes sent off this Mac"). Cloud LLM, cloud
STT, cloud TTS, and cloud telemetry call paths have all been removed. Cloud
bridge / Direct API / CLI direct-spawn exist only as **opt-in** tiers, each
visibly indicated (amber capsule), audit-logged, and fail-loud. Making any cloud
path the default contradicts the moat. Do not reintroduce a cloud default or a
silent cloud fallback (the `directAPIFallsBackToLocalOnCloudFailure` opt-in is
the one explicit, off-by-default exception).

## Rejected: dual-agent prefetch (removed as dead code)

**Why rejected:** a partial-transcript-keyed RAG prewarm / dual-agent prefetch
was removed as dead code — it added hot-path complexity for negligible,
unmeasurable TTFSW upside. The expensive prewarm (VLM screen context) already
runs at PTT press via `PaceScreenContextService.prewarmScreenContext`, and local
retrieval (BM25 + in-memory episodic) is already sub-millisecond. Revisit only
if a `benchmark_ttfsw.sh` run shows retrieval on the critical path. (Tracked in
[`competitive/steal-catalog.md`](competitive/steal-catalog.md).)

## Rejected: meetily's meeting-notes shape (partially)

**What was taken:** the selectable meeting-note **profile** idea (general /
standup / one-on-one, with a `general` byte-for-byte compat anchor).

**Rejected as non-fits from meetily:**
- Its 7 markdown-table templates — too rigid; Pace uses one structured shape
  per profile.
- VAD (voice-activity detection) — Pace's `PaceMeetingTurnSegmenter` already
  covers segmentation (Accelerate RMS + hysteresis + echo trimming).
- RMS ducking — two-track capture (mic + system as separate tracks) is better
  than ducking one mixed track.
- Real-time transcription + diarization — separate large efforts, not in scope
  for the notes wedge.

## Deferred: persistent KV planner backend

**Why deferred:** blocked on TinyGPT oMLX qualification. The in-process MLX
planner (Qwen3-4B) is available behind the Settings → Models toggle but is
**not** the default — fresh installs talk via Apple Foundation Models or LM
Studio. Do not flip the bundled-MLX planner to default without a 4B-vs-30B
eval-gate run on real hardware; per project memory, Pace-side model work is
otherwise concluded.

## Deferred: grammar-constrained v10 as runtime default

**Why deferred:** TinyGPT / eval gated. The shipping planner remains the current
MLX / Qwen stack with `response_format: json_schema` decode constraining. The
grammar-constrained gate is a shipping-decision harness, not the runtime path.

## Deferred: real-app AX smokes in CI

**Why deferred:** TCC makes automated live-app tests fragile — terminal
`xcodebuild` invalidates permissions. Live-app executor smokes
(`scripts/smoke-executor-surface.sh`, `scripts/smoke-real-apps.sh`) are
manual-only. The 3 hardware-bound tests are gated behind `TEST_RUNNER_PACE_CI`
in CI and still run locally.

## Deferred: hosted telemetry or accounts

**Why deferred:** contradicts the on-device moat. Analytics are local-only
no-op/timing-safe hooks (`PaceAnalytics.swift`); no cloud analytics SDK is
linked. Do not add accounts or hosted telemetry.

## Deferred: speaking-time context prefetch (episodic/RAG)

**Why deferred:** the expensive prewarm already runs at PTT press and local
retrieval is sub-millisecond, so a partial-transcript-keyed RAG prewarm adds
hot-path complexity for negligible upside — and it mirrors the dual-agent
prefetch already removed as dead code. Revisit only if a benchmark shows
retrieval on the critical path.

## Known live-testing follow-ups (not failures — unfinished edges)

These are not rejected approaches; they are known rough edges surfaced by the
live gauntlet that should be fixed, not retried as-is:

- **Few-shot coordinate echo** — the planner can echo coordinates from few-shot
  examples; needs a prompt/parser guard.
- **`PacePlannerModelResolver` silent brain swap** — served gemma-3-12b when
  qwen unloaded; needs fail-loud + served-model in traces.
- **MCP fixture subprocess vs parallel test workers** — known CI interaction;
  CI runs serial because parallel workers crash on the image.

## Rejected: fixing the known non-blocking warnings

**Why rejected:** Swift 6 concurrency warnings and the deprecated `onChange` in
`OverlayWindow.swift` are intentionally not fixed (per `AGENTS.md`). Do not
attempt these unless explicitly asked — they are noise, not signal, and chasing
them risks churn on stable paths.

## Rejected: bundled recipes that overclaim recorded UI steps

The original five bundled recipes encoded literal app activation and keystrokes
while their descriptions promised higher-level outcomes. They were retired in
favor of typed local automations that must compile completely through Pace's
canonical tool registry.

- **Inbox triage pass:** opened Mail and selected the inbox but never judged or
  described which messages mattered. Revisit only with an explicit local mail
  read/triage contract and truthful privacy behavior.
- **Focus mode on:** opened Music but did not enable Do Not Disturb or play the
  preferred playlist. Revisit only when Pace has a validated local Focus-mode
  action and a complete playlist action.
- **Morning standup setup:** depended on Slack being installed and replayed a
  brittle `cmd+k`, text, and Return sequence; opening Calendar did not “pull”
  today's schedule. Revisit as an imported user-owned Shortcut or with native,
  availability-checked Slack and Calendar actions.
- **Weekly review draft:** retained as the typed `weekly-review-note`
  automation because the native Notes tool fulfills the complete outcome.
- **End-of-day shutdown:** narrowed and retained as `end-of-day-reset`; it now
  honestly opens Calendar and creates the promised reminder through native
  tools rather than pretending to review the schedule.
