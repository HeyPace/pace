## Context

See [proposal.md](./proposal.md) for motivation. The behavior contract is in
[activity-goal-model](./specs/activity-goal-model/spec.md).

Pace already owns the substrate this builds on:

- `PaceEpisodicFactStore`/`PaceEpisodicMemory.swift` — the existing pattern for
  a typed, confidence-scored, expiring, tombstone-correctable fact store with
  an LRU cap. This proposal's observation store follows the same shape rather
  than inventing a new one. Note: as verified directly in the source,
  `PaceEpisodicFactStore` itself holds no durable persistence today — it is
  constructed fresh in `CompanionManager.swift` with no load/save path, so it
  does not survive relaunch. It is precedent for the in-memory dedup/cap/
  tombstone shape only, not for persistence.
- `PaceMemoryStore.swift`/`PaceThreadMemoryStore.swift` — the actual durable-
  persistence precedent used by the companion memory stack: an I/O-free model
  type plus a dedicated `@MainActor` store that loads/saves one atomic JSON
  file under `~/Library/Application Support/Pace/`, treating a missing or
  corrupt file as "start empty" rather than throwing, so persistence never
  blocks launch. This proposal's durable persistence follows that pattern
  (a new `activity-goal-model.json` file), not `QSQLiteMemoryStore` (which
  backs an unrelated subsystem — the Q agent runtime's task memory — and is
  not part of the companion memory tier).
- `companion-memory-policy` (spec) — deterministic promotion, confidence decay,
  bounded retention, and correction/forgetting requirements already accepted
  for episodic/semantic/spatial/routine memory.
- `temporal-world-model` (spec) — the existing precedent for deriving a
  "current state" hypothesis from typed observations while retaining
  supporting/contradicting evidence and reporting "unknown" honestly instead
  of a stale guess. This proposal's `PaceActiveGoalState` mirrors that
  requirement shape for activity/goal state instead of spatial state.
- `PaceAppUsageTracker`/`PaceAppUsageJournal.swift` — already listens to
  `NSWorkspace.didActivateApplicationNotification` and calls
  `handleApplicationActivated(named:)` on every frontmost-app change. This is
  the existing, permission-free signal Slice 2's producer taps; it is not a
  new capture surface.

What Pace does not own is any typed representation of "what the user is
currently trying to accomplish." Every existing memory tier answers "what is
true" (episodic/semantic), "where is this object" (spatial), or "what did the
user do repeatedly" (routine) — none answer "what is the user's active
outcome, and how confident are we." Gap #2 (opportunity ranking) and the
"Resume work"/"Remember and follow through" acceptance stories in the
consolidation plan need that subject to exist before they can be built.

## Goals / Non-Goals

**Goals:**

- Represent activity/goal state as typed, provenance-bearing, confidence-
  scored evidence — never an unstructured summary string.
- Distinguish `observed`, `inferred`, `userStated`, and `authorizedTask`
  evidence kinds explicitly, per the consolidation plan's own requirement.
- Derive a current-state hypothesis that retains supporting/contradicting
  observation ids and reports "unknown" rather than a stale or fabricated
  guess when evidence is insufficient — mirroring `temporal-world-model`.
- Make correction supersede rather than erase, mirroring
  `PaceEpisodicTombstone` and the accepted `companion-memory-policy` spec.
- Keep the store fully unit-testable with zero dependency on live AX/screen
  capture, and zero behavior change to any existing runtime path in this
  proposal.

**Non-Goals:**

- No proactive card, notification, or spoken intervention driven by this data
  in this proposal (Gap #2 / `proactive-companion-policy` already owns
  intervention decisions; this proposal only supplies a subject for a future
  one to rank).
- No `Now`/`Working`/`Memory` UI surface change (Gap #5/#6).
- No LLM-based or VLM-based goal inference. Slice 2's one producer is a
  deterministic app/window-transition signal only.
- No new permission, entitlement, or capture surface. Slice 2 reads a signal
  Pace already collects.
- No change to `companion-memory-policy`'s existing episodic/semantic/
  spatial/routine promotion rules.

## Decisions

### D1 — Evidence-kind vocabulary and producer scope for this proposal (OWNER DECISION NEEDED)

Recommendation: ship exactly one producer in this proposal — frontmost-app/
window transitions as `observed` evidence — and leave `inferred` (e.g.
correlating a transition with a meeting or a background task),
`authorizedTask` (an approved task run linked to the active goal), and richer
`userStated` capture (an explicit "I'm working on X" utterance) for follow-up
proposals once Slice 1-3 here are proven. This keeps the slice genuinely
standalone: the schema does not need to change to add a producer later, only
to add one now would risk scope creep into the model-inference work the plan
explicitly defers.

Alternative considered: ship the `userStated` producer (parsing an explicit
utterance) alongside the app-transition producer, since it requires no model
call either. Rejected for this proposal only to keep Slice 2 reviewable in
isolation; it is a natural Slice 4 if the owner wants it pulled forward.

**Needs an explicit owner answer before Slice 2 merges**: is the
app-transition-only producer scope acceptable, or should `userStated` capture
be pulled into this proposal now?

### D2 — Storage: new store vs. extending the episodic fact store

Recommendation: a new, small `PaceActivityGoalStore` following
`PaceEpisodicFactStore`'s shape (dedup/cap/tombstone discipline) rather than
extending `PaceEpisodicFactStore` itself. Activity observations have a
different subject shape (an app/window/task reference, not a `(subject,
predicate, value)` fact triplet) and a different current-state derivation
(supporting/contradicting links, not simple dedup-and-overwrite). Coupling the
two would force one store to serve two different consistency models.

Alternative considered: extend `PaceEpisodicFactStore` with an
`isActivityObservation` flag. Rejected — it would let an unrelated future
change to fact dedup semantics silently affect activity-state derivation.

**Needs an explicit owner answer before Slice 1 merges**: confirm a new store
is preferred over extending the existing fact store.

### D3 — Retention and staleness defaults

Recommendation, mirroring the existing spatial-memory freshness requirement:

- Retain the most recent 200 observations per tracked subject (matching
  `PaceEpisodicMemoryLimits`' existing 200-fact cap for consistency across
  memory kinds), compacting oldest-first once exceeded.
- An observation older than 30 minutes with no corroborating newer
  observation marks the derived state "stale" rather than current — short
  enough that a real context switch is reflected quickly, long enough that
  transient app-switching (checking Slack mid-task) does not thrash the
  derived state.
- `userStated` and `authorizedTask` evidence never auto-expire on the 30-minute
  clock; only decays via explicit correction/forgetting, since the user or an
  authorized run said something durable, not a transient signal.

**Needs an explicit owner answer before Slice 1 merges**: confirm the 30-minute
staleness window and 200-observation cap, or supply different defaults.

## Slices

Each slice ships independently, has its own tests, and states the condition
under which it is not worth continuing.

| # | Slice | Standalone value | Depends on |
| --- | --- | --- | --- |
| 1 | Typed observation + derived state schema, store, decay, supersession, retention | Proves the schema and policy in isolation; zero runtime wiring | D2, D3 |
| 2 | Deterministic app/window-transition producer | Store starts accumulating real evidence from an existing signal | Slice 1, D1 |
| 3 | Read-only retrieval query ("what is the active goal state now") | Gives "Resume work" and any future ranking layer something to query | Slice 1, 2 |

Slice 4 (pulling `userStated`/`authorizedTask` producers forward) and the
consolidation plan's Gap #2 (opportunity ranking) / Gap #5 (surface
consolidation) are explicitly out of this proposal's scope; they are the
natural next proposals once Slices 1-3 are dogfooded.

## Stop conditions

- If the derived-state supporting/contradicting evidence model cannot stay
  bounded (an unbounded number of "contradicting" observations accumulating
  without ever resolving), the derivation rule is wrong — return to design
  rather than adding an ad-hoc cap.
- If the app/window-transition producer proves too noisy to be useful signal
  (e.g. constant thrash from utility-app switching) once dogfooded, that is
  evidence for D1, not a reason to add a second producer to compensate.
