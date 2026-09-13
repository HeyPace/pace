## Why

`docs/current/plans/autonomous-companion-consolidation.md` names this the
plan's own next recommended step, ahead of the typed activity/goal model
(`openspec/changes/2026-09-13-add-activity-goal-model`, now shipped):
"Add outcome/feedback telemetry to existing local intervention records"
(Recommended order, item 3). Section "3. Learning from outcomes, not only
storing facts" is explicit about the gap: Pace already has facts,
corrections, routines, taught skills, and local turn collection, but nothing
records "what happened after Pace suggested or acted" — was it accepted,
dismissed, ignored, edited, undone, or completed successfully.

Two of the plan's five acceptance stories depend on this:

- **Learn a routine** — proposing a skill only after a repeated workflow has
  independent evidence requires a durable record of outcomes to count.
- **Remember and follow through** — recording whether a resurfaced promise
  was completed, deferred, corrected, or dismissed IS an outcome record.

A direct codebase survey (not invented) found real, already-computed
decision points with zero new capture required:

- `requestUserApprovalForActionPlan` (`CompanionManager+PostureWatch.swift:106-152`)
  already computes a `PaceActionApprovalDecision` (`.allowOnce`/`.cancel`)
  from the user's literal `NSAlert` button click — an accept/dismiss signal
  that is simply never recorded anywhere today.
- `triggerUndoLastMutation()` (`CompanionManager+TrustSurfacesRuntime.swift:69-84`)
  fires only when the user explicitly taps the undo banner — an "undone"
  signal, also never recorded. Correlating it to the specific action it
  undoes needs one new stable identifier at `noteReversibleActionExecuted`
  (same file, line 45) — a schema addition, not new capture, since that
  function already runs on every reversible-action execution.
- `PaceTelemetryLog.swift` already has a closed-enum, no-raw-content
  `PaceFailureKind`/`PaceFailureOutcome` taxonomy, but it is write-only
  `OSLog` — good precedent for "closed enum, no raw content," not usable as
  a queryable local store.

Two producers this survey ruled OUT for this proposal: proactive-nudge
"ignored" (`PaceProactiveUtterance` is spoken-only, no dismiss gesture, no
stable id yet) and "edited" (no editable-suggestion UI exists anywhere).
Both need Gap #2/#5's shared opportunity-ranking/card surface to exist
first — inventing a producer for them now would mean capturing a signal
that doesn't actually exist yet, which the plan's own constraint forbids
("self-learning must never mean... training on data outside the documented
local policy").

Per the handoff note at the bottom of the consolidation plan, this enters
the normal OpenSpec explore/propose/apply/archive workflow, sliced the same
way `2026-09-13-add-activity-goal-model` was: Slice 1 has standalone value
(proves the schema/retention in isolation) even if later slices are
deferred.

## What Changes

- Add `PaceInterventionOutcomeRecord`: a typed, append-only record of one
  outcome (`accepted`, `dismissed`, `undone`, `completed`, `failed` in this
  proposal's scope — `ignored`/`edited` reserved for a later slice once a
  card surface exists to observe them from) tied to an `interventionKind`
  (e.g. `actionApproval`, `reversibleMutationUndo`), a subject summary, a
  timestamp, and provenance. Mirrors `PaceActivityObservation`'s shape.
- Add `PaceInterventionOutcomeStore`: bounded, per-`interventionKind`
  retention (mirroring `PaceActivityGoalStore`'s per-subject cap), durable
  atomic-JSON persistence (mirroring `PaceActivityGoalPersistenceStore`).
- Add exactly two producers in this proposal's scope, both zero-new-capture:
  the action-approval accept/dismiss decision, and the undo-banner-tap
  "undone" signal (requiring one new stable identifier on the reversible-
  action-executed record so undo can correlate back to what it undid).
- Add a read-only query for per-`interventionKind` outcome counts/rates, for
  a future ranking layer (Gap #2) to consume — no ranking logic in this
  proposal.
- No skill-proposal-from-repeated-evidence logic, no "why Pace learned this"
  UI, no forget/reset UI, no morning-brief or meeting-commitment producers,
  and no ranking/timing tuning in this proposal — those need this data to
  exist first and are separate follow-up proposals once this is dogfooded.

## Capabilities

### New Capabilities

- `outcome-feedback-telemetry`: Maintain a typed, bounded, durable record of
  what happened after Pace suggested or acted (accepted, dismissed, undone,
  completed, failed), queryable by outcome kind, without recording or
  inferring anything beyond the existing decision points that already
  compute these outcomes.

### Modified Capabilities

- None. This is additive; no existing approval, undo, or telemetry behavior
  changes — the two producers only ADD a record alongside what already
  happens.

## Impact

- New runtime: `PaceInterventionOutcomeStore`/`PaceInterventionOutcomePersistenceStore`
  (new model + persistence files, mirroring the activity-goal-model shape),
  two small producer call sites (one line each) at the existing approval and
  undo decision points, and one new stable identifier field threaded through
  `noteReversibleActionExecuted` → `triggerUndoLastMutation`.
- Existing runtime: no behavior change to approval, undo, or any executor
  path — the two producers observe an existing decision, they do not gate,
  delay, or alter it.
- Test seam: fully unit-testable (schema, store, retention, retrieval) with
  no dependency on live NSAlert/AppKit modal presentation — the two
  producer call sites are exercised through the same pattern as
  `simulateApplicationActivatedForTesting` established in the prior
  proposal, or by testing the producer function directly where it is
  already a plain synchronous function.
- Storage: one new local atomic JSON file, no schema shared with unrelated
  data, no network path.
- Privacy: subject fields store only approval/undo summaries already shown
  to the user in-session (never secure-field or document content); no new
  permission, entitlement, or capture surface.
- Dependencies and deployment: no new dependency, no cloud path, no release
  action, no terminal `xcodebuild` — all verification through
  `bash scripts/test-pace.sh`.
