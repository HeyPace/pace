## Why

`docs/current/plans/autonomous-companion-consolidation.md`'s "Recommended
order" places this next (item 5) now that item 3 (outcome/feedback
telemetry, `openspec/changes/2026-09-13-add-outcome-feedback-telemetry`) and
item 4 (the typed activity/goal model,
`openspec/changes/2026-09-13-add-activity-goal-model`) have both shipped.
Section "### 2. One prioritization path for proactive opportunities" (lines
42-55) is explicit about the gap: "Meeting context, calendar events, watch
mode, routines, background agents, and physical-world observations can all
produce useful opportunities. They need a shared ranking layer before the
existing intervention/restraint policy decides."

A direct codebase survey (not invented) found this is not a greenfield
feature — it is the unimplemented half of an **already-accepted** spec
requirement. `openspec/specs/proactive-companion-policy/spec.md` (lines
31-36), accepted before this session, already commits to:

> "The system SHALL coalesce equivalent candidates, enforce category and
> global cooldowns, and incorporate explicit negative feedback into future
> thresholds."

Today only a single **global** cooldown exists
(`PaceRestraintGate`'s `lastProactiveUtteranceAt` in `PaceRestraintContext`).
There is no coalescing, no per-category cooldown, and no negative-feedback
incorporation: `PaceProactiveNudgeOrchestrator`
(`PaceProactiveNudgeFramework.swift`) starts three independent generators
(`PaceFocusFatigueNudgeGenerator`, `PaceCalendarPreMeetingNudgeGenerator`,
`PaceWatchModeObservationNudgeGenerator`, each in its own file) with the same
`emit`/`queueForLater` closures and zero cross-generator coordination — each
one independently calls `PaceRestraintGate.decide(_:)`
(`PaceProactiveNudges.swift`'s `resolveDecision`) and, if two trigger in the
same tick, both can independently reach `.speak` and both get emitted. This
proposal builds the missing coalesce/cap/rank layer this spec already
promises, satisfying an existing accepted contract rather than introducing a
new one.

## What Changes

- Add `PaceOpportunity`: a typed wrapper around one generator's
  already-restraint-gate-approved candidate (an existing
  `PaceProactiveUtterance` plus a `category` string for coalescing, a
  producer-supplied `urgency`, and the existing `confidence`/
  `relevanceWindowExpiresAt` fields already on `PaceProactiveUtterance`).
  No new generator, no new trigger logic — this proposal only adds the
  selection step between "N candidates reached `.speak` this tick" and
  "the framework calls `emit()`."
- Add `PaceOpportunityRanker`: a pure function that, given the set of
  candidates that independently passed their own restraint-gate check in
  one evaluation tick, (a) coalesces candidates sharing the same `category`
  within a cooldown window, (b) scores the survivors by relevance (against
  `PaceActivityGoalStore.currentGoalState()`), urgency, confidence,
  interruption cost (derived from the existing restraint context), and
  recent acceptance/rejection history (from
  `PaceInterventionOutcomeStore.outcomeCounts(forInterventionKind:)` where
  real data exists — see D1 in design.md for what "recent history" honestly
  means today), and (c) returns at most one winner to actually emit, with
  every input to the decision retained as evidence.
- Add `PaceOpportunityCategoryCooldownTracker`: in-memory per-category
  last-emitted-at bookkeeping (mirrors the existing per-generator
  `PaceProactiveNudgeCooldown` struct already in
  `PaceProactiveNudgeFramework.swift`), fulfilling the spec's "category...
  cooldowns" clause (today only the global cooldown exists).
- This proposal does NOT change `PaceRestraintGate`'s existing authority,
  call sites, or decision logic — the ranking layer is a pure selection
  step applied to candidates that have already independently passed the
  existing gate; it can only narrow (coalesce/cap) what gets emitted, never
  widen it.
- No new producer, no new capture, no new permission, no new model call.

## Capabilities

### New Capabilities

- `opportunity-ranking`: A deterministic, evidence-carrying selection layer
  that coalesces equivalent proactive-nudge candidates, enforces
  per-category cooldowns, ranks survivors by relevance/urgency/confidence/
  interruption-cost/acceptance-history, and caps simultaneous emission —
  queryable for the evidence behind any decision it makes.

### Modified Capabilities

- `proactive-companion-policy`: this proposal is how the already-accepted
  "Intervention policy resists repetition" requirement (lines 31-36 of that
  spec) gets actually implemented. No requirement text changes; behavior
  catches up to the existing contract.

## Impact

- New runtime: `PaceOpportunity`/`PaceOpportunityRanker`/
  `PaceOpportunityCategoryCooldownTracker` (new model + pure-logic file, no
  I/O, no persistence — a ranking decision is a per-tick computation, not a
  durable record like the two prior proposals' stores).
- Existing runtime: Slice 1 (this proposal's first slice) makes zero
  changes to any existing file — pure, isolated, unit-testable logic only.
  Wiring the ranker into `PaceProactiveNudgeOrchestrator`'s actual emit path
  (Slice 2) is scoped separately behind an Owner Gate (see design.md D1-D3)
  because it changes the sequencing of already-shipping, working
  behavior — the one part of this proposal that is not purely additive.
- Test seam: fully unit-testable with fabricated candidate sets — no
  dependency on live AppKit, NSWorkspace, calendar, or watch-mode capture.
- Privacy: opportunity records carry only the same structural fields
  `PaceProactiveUtterance` already carries (spoken text already destined for
  TTS, source, confidence, expiry) plus a category label and a score
  breakdown — no new content surface, no new persistence, no new
  cross-boundary data.
- Dependencies and deployment: no new dependency, no cloud path, no release
  action, no terminal `xcodebuild` — all verification through
  `bash scripts/test-pace.sh`.
