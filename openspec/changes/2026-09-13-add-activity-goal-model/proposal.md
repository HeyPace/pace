## Why

`docs/current/plans/autonomous-companion-consolidation.md` names this the first
unaddressed gap: Pace records observations and retrieves history, but nothing
represents *what the user is currently trying to accomplish* as a first-class,
typed, evidence-linked state. `companion-memory-policy` already promotes
observations into episodic, semantic, spatial, and routine memory with
confidence, provenance, decay, correction, and forgetting; `temporal-world-model`
already does the same for physical-object location. Neither answers "what is
the user working on right now, and why do we believe that."

Two of the plan's five acceptance stories depend directly on this gap:

- **Resume work** — restoring useful context after an idle period or relaunch
  requires a durable, evidence-backed notion of the active outcome, not a
  fresh guess from the latest screen sample.
- **Remember and follow through** — resurfacing a promise "at an appropriate
  time" requires knowing what the user is doing *now* well enough to judge
  whether now is appropriate.

The plan's own recommended order places this after outcome/feedback telemetry
and before opportunity ranking (Gap #2) and surface consolidation (Gap #5/#6):
those depend on a typed subject to rank and render, so they cannot start
before this lands.

This is not a small change, and per the handoff note at the bottom of the
consolidation plan ("each substantial behavior change should enter the normal
OpenSpec explore/propose/apply/archive workflow"), it is sequenced here as
slices the owner can approve, reduce, or stop at any boundary — the same
discipline `2026-08-30-add-spatial-teach-mode` already established for this
project. Slice 1 has standalone value even if later slices are deferred: it
proves the schema and retention policy in isolation, with zero behavior change
to any existing runtime path, before anything reads or writes it live.

## What Changes

- Add `PaceActivityObservation`: an append-only, typed evidence record with an
  explicit `evidenceKind` — `observed` (perception/runtime signal), `inferred`
  (deterministic heuristic, no model call in this proposal), `userStated`
  (explicit user statement), or `authorizedTask` (an approved, execution-backed
  task) — plus subject, confidence, provenance (source system + evidence
  reference id), timestamp, and optional expiry. This directly satisfies the
  plan's "clear distinction between observation, inference, user-stated
  intent, and an authorized task."
- Add `PaceActiveGoalState`: a derived current-state hypothesis over
  observations, mirroring `temporal-world-model`'s "current state remains
  linked to evidence" requirement — it retains supporting and contradicting
  observation ids rather than replacing history, and reports "unknown" rather
  than a stale guess when evidence is insufficient.
- Add correction-as-supersession: a user correction is a new, high-confidence
  `userStated` observation that supersedes the prior state; the superseded
  observation is retained, never deleted, mirroring `PaceEpisodicTombstone`'s
  existing discipline for facts.
- Add confidence decay over idle/app-switch time, mirroring the existing
  spatial-memory freshness/staleness requirement in `companion-memory-policy`.
- Add bounded retention (a fixed cap on stored observations per subject,
  oldest-compacted-first) so this cannot grow unbounded, matching the existing
  "memory is compressed and bounded" requirement.
- Wire exactly one deterministic, model-free producer in this proposal's
  scope: frontmost-app/window transition observations, sourced from state
  Pace's runtime already tracks. No new capture surface, no new permission.
- No proactive card, no ranking, no UI surface, and no cross-app inference
  model in this proposal. Those are the plan's Gap #2/#5/#6 and depend on this
  landing first; naming them here would exceed what one proposal should decide.

## Capabilities

### New Capabilities

- `activity-goal-model`: Maintain a typed, provenance-bearing, confidence-
  scored, correctable record of the user's current activity/goal, derived
  from explicit evidence, queryable by any future consumer (ranking, resume-
  work restoration, background-work return) without those consumers needing
  their own inference logic.

### Modified Capabilities

- None. `companion-memory-policy` and `temporal-world-model` are precedent,
  not modified — this proposal adds a parallel memory kind rather than
  changing either existing one.

## Impact

- New runtime: a new `PaceActivityGoalStore` (in-memory logic, mirroring
  `PaceEpisodicFactStore`'s dedup/cap/tombstone shape) plus a dedicated
  durable-persistence store following the `PaceMemoryStore`/
  `PaceThreadMemoryStore` atomic-JSON-file pattern (the verified actual
  persistence precedent in this codebase), a new `PaceActivityObservation`/
  `PaceActiveGoalState` model file, and a small producer hook for
  frontmost-app/window transitions.
- Existing runtime: no changes to `CompanionManager`'s existing memory
  dual-write, retrieval, restraint gate, or intervention policy in this
  proposal — Slice 1 and Slice 2 are additive and do not gate any existing
  behavior. Slice 3 adds a read-only query path; it does not write into any
  existing surface.
- Test seam: fully unit-testable in isolation (schema, decay, supersession,
  retention, retrieval) with no dependency on live AX/screen capture. The one
  producer added in Slice 2 is exercised through existing app/window-change
  test seams, not a new observation surface.
- Storage: a new local atomic JSON file (`activity-goal-model.json` under
  `~/Library/Application Support/Pace/`) following the existing
  `PaceMemoryStore`/`PaceThreadMemoryStore` durable-store pattern; no new
  dependency, no schema shared with unrelated data, no network path.
- Privacy: this proposal stores only structural activity metadata (which app,
  which window title if already permitted elsewhere, activity confidence) —
  never document/field content, never secure-field content, never raw
  AXUIElement or CF objects. Expiry and forgetting reuse the existing
  correction/forgetting requirement pattern from `companion-memory-policy`.
- Permissions: none beyond what Pace already holds for app/window
  observation; no new entitlement, no new TCC prompt.
- Dependencies and deployment: no new dependency, no cloud path, no release
  action, no terminal `xcodebuild` — all verification through
  `bash scripts/test-pace.sh`.
