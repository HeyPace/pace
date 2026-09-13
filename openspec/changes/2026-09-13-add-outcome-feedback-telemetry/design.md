## Context

See [proposal.md](./proposal.md) for motivation. The behavior contract is in
[outcome-feedback-telemetry](./specs/outcome-feedback-telemetry/spec.md).

Pace already owns the substrate this builds on:

- `PaceActivityGoalModel.swift`/`PaceActivityGoalPersistenceStore.swift`
  (`openspec/changes/2026-09-13-add-activity-goal-model`) — the immediately
  prior proposal's typed-observation/bounded-store/atomic-JSON-persistence
  shape. This proposal's outcome record follows the same shape rather than
  inventing a new one, for the same reason: keeps the store fully
  unit-testable and I/O-free at the model layer.
- `PaceActionApproval.swift`/`CompanionManager+PostureWatch.swift` — the
  existing accept/dismiss decision. `requestUserApprovalForActionPlan`
  (lines 106-152) already computes `PaceActionApprovalDecision` from the
  user's literal `NSAlert` button click at line 146-147; nothing downstream
  of that decision currently records it.
- `CompanionManager+TrustSurfacesRuntime.swift` — `noteReversibleActionExecuted`
  (line 40-51) records `mostRecentReversibleActionSummary`/`mostRecentReversibleActionAt`
  (a `String`/`Date` pair, no stable identifier) every time a reversible
  mutation executes; `triggerUndoLastMutation()` (line 69-84) fires only
  when the user taps the undo banner. Verified directly in source: as
  written today, an "undone" signal cannot be correlated back to which
  specific suggestion it undid, because nothing mints a stable id at
  execution time.
- `PaceTelemetryLog.swift` — a closed-enum (`PaceFailureKind`/`PaceFailureOutcome`),
  no-raw-content precedent for what "safe to log" looks like, but it is
  write-only `OSLog` (`Logger.info(...)`), not a queryable local store. Not
  reusable as this proposal's store — it establishes the "closed enum, no
  raw content" discipline, nothing more.
- `PaceEpisodicTombstone` (`PaceEpisodicMemory.swift:45-74`) — precedent for
  "user explicitly rejected this," but fact-triplet-shaped; not directly
  reusable here (same reasoning as the prior proposal's D2).

What Pace does not own is any durable record of what happened after it
suggested or acted. The consolidation plan is explicit that "learning must
never mean self-granting permissions, silently changing a high-risk
workflow, or training on data outside the documented local policy" — this
proposal only records outcomes at decision points that already exist; it
adds no new capture surface and no new authority.

## Goals / Non-Goals

**Goals:**

- Represent an intervention outcome as a typed, bounded, provenance-bearing
  record — never an unstructured log line.
- Record exactly the outcome kinds this proposal can source with zero new
  capture: `accepted`, `dismissed` (from the existing approval alert
  decision), and `undone` (from the existing undo-banner tap).
- Make the "undone" record correlate back to the specific reversible action
  it undoes, by minting one new stable identifier at
  `noteReversibleActionExecuted` time.
- Keep the store fully unit-testable with zero dependency on live
  `NSAlert`/AppKit modal presentation.
- Provide a read-only query (count/rate per `interventionKind`) for a
  future ranking layer to consume, with zero ranking logic in this
  proposal.

**Non-Goals:**

- No `ignored` or `edited` outcome kinds in this proposal. `ignored` needs a
  card/notification surface with a real "the user saw this and did nothing"
  gesture (Gap #2/#5, not yet built); `edited` needs an editable-suggestion
  UI that does not exist anywhere in the app today. Inventing a producer
  for either would mean capturing a signal that doesn't actually exist yet.
- No `completed`/`failed` action-execution producer. Every action already
  produces a `PaceActionExecutionObservation`/failure outcome per the
  executor's own return value — logging every one of those would record
  "did this specific action run," not "was this suggestion's outcome good,"
  and would swamp the store with high-volume, low-signal rows. Deferred to
  a later slice if a genuine per-suggestion completion signal is scoped.
- No ranking/timing-tuning consumer, no skill-proposal-from-repeated-
  evidence logic, no "why Pace learned this" UI, no forget/reset UI, and no
  morning-brief or meeting-commitment producers in this proposal — Gap #2's
  ranking layer and any learning-loop UI need this data to exist first.
- No change to `PaceActionApprovalPolicy`'s existing approval decision
  logic, the undo executor path, or any existing telemetry (`PaceTelemetryLog`)
  behavior — this proposal only ADDS a record alongside what already
  happens.

## Decisions

### D1 — Outcome-kind and producer scope for this proposal (OWNER DECISION: CONFIRMED 2026-09-13)

Recommendation: ship exactly two producers — the action-approval
accept/dismiss decision, and the undo-banner "undone" signal — and leave
`ignored`, `edited`, and `completed`/`failed` for follow-up proposals once
Gap #2/#5 (or a more targeted per-suggestion completion signal) exists to
source them honestly. This keeps the schema stable (adding a producer later
needs no schema change, only a new `PaceInterventionOutcomeKind` case and a
new call site) while never inventing capture ahead of a real gesture.

Alternative considered: also wire a `completed` producer off every
successful action execution. Rejected for this proposal — without a
specific "this was a suggestion, and here is whether it worked" pairing,
per-action completion logging just duplicates `PaceTelemetryLog` at higher
volume with no new signal.

**Owner confirmed 2026-09-13**: approval+undo-only producer scope for
this proposal. `ignored`/`edited`/`completed`/`failed` producers are
follow-up proposals once Slices 1-3 are dogfooded.

### D2 — Storage shape: cap per `interventionKind`, not per free-form subject (OWNER DECISION: CONFIRMED 2026-09-13)

Recommendation: a new `PaceInterventionOutcomeStore` (not extending
`PaceActivityGoalStore` — different subject shape and no "current state"
concept to derive; an outcome record is a historical fact, not evidence
toward a live hypothesis), with retention capped per `interventionKind` (a
small closed set: `actionApproval`, `reversibleMutationUndo`) rather than
per free-form `subject` string. Approval/undo subjects are near-unique
human-readable summaries each time ("Step 1: [Medium risk] Send email to
..."), so a per-subject cap (as `PaceActivityGoalStore` uses, correctly, for
repeating app names) would not bound anything meaningfully here — nearly
every subject would be its own single-row "subject."

Alternative considered: cap per subject like `PaceActivityGoalStore`.
Rejected — would not bound total storage since subjects are rarely
repeated verbatim.

**Owner confirmed 2026-09-13**: per-`interventionKind` capping, as built
in `PaceInterventionOutcomeStore`.

### D3 — Retention default (OWNER DECISION: CONFIRMED 2026-09-13)

Recommendation: 200 records per `interventionKind`, matching
`PaceActivityGoalLimits`/`PaceEpisodicMemoryLimits`'s existing 200-cap
convention for consistency across memory kinds. No staleness/freshness
window is needed (unlike the activity-goal model): an outcome record is a
settled historical fact the moment it's written, not evidence toward a
"current state" that can go stale.

**Owner confirmed 2026-09-13**: the 200-per-`interventionKind` cap, as
built in `PaceInterventionOutcomeLimits`.

## Slices

| # | Slice | Standalone value | Depends on |
| --- | --- | --- | --- |
| 1 | Typed outcome record + store + retention | Proves the schema/retention policy in isolation; zero runtime wiring | D2, D3 |
| 2 | Approval accept/dismiss + undo producers | Store starts accumulating real outcomes from two existing decision points | Slice 1, D1 |
| 3 | Read-only retrieval (counts/rates per `interventionKind`) | Gives a future ranking layer (Gap #2) something to query | Slice 1, 2 |

Slice 4 (`ignored`/`edited`/`completed` producers) and Gap #2 (opportunity
ranking, which would consume this data) are explicitly out of this
proposal's scope; they are the natural next proposals once Slices 1-3 are
dogfooded.

## Stop conditions

- If per-`interventionKind` retention does not actually bound storage in
  practice (e.g. a new producer's subjects turn out to repeat far less than
  expected, defeating the point of the cap choice in D2), return to design
  rather than layering a second cap dimension on top.
- If the two producers in this proposal turn out too sparse to be useful
  signal once dogfooded, that is evidence for D1's next owner decision, not
  a reason to add more producers to compensate.
