## Context

See [proposal.md](./proposal.md) for motivation. The behavior contract is in
[opportunity-ranking](./specs/opportunity-ranking/spec.md), and this proposal
also brings implementation into line with the already-accepted
`openspec/specs/proactive-companion-policy/spec.md`'s "resists repetition"
requirement.

Pace already owns the substrate this builds on (verified directly in
source, file:line):

- `PaceProactiveNudgeFramework.swift` — `PaceProactiveNudgeOrchestrator`
  starts a fixed set of `PaceProactiveNudgeGenerator`-conforming generators
  with the same `emit`/`queueForLater` closures. Zero cross-generator
  coordination exists today; `PaceProactiveNudgeFrameworkRouting.route`
  fires per-candidate with no awareness of any other generator's output in
  the same tick. `PaceProactiveNudgeCooldown` (same file) is an existing
  *per-generator* cooldown struct (one `Date?` + a minimum interval) — the
  precedent this proposal's category-cooldown tracker mirrors, generalized
  across generators instead of within one.
- `PaceProactiveNudges.swift` — three generators
  (`PaceFocusFatigueNudgeDecision`, `PaceCalendarPreMeetingNudgeDecision`,
  `PaceWatchModeObservationNudgeDecision`), each with a pure `utterance(...)`
  trigger-condition function and a gate-aware `evaluate(...)` that calls
  `resolveDecision`, which itself calls `PaceRestraintGate.decide(_:)`
  inline. `PaceProactiveNudgeEvaluation` is a typealias tuple
  `(decision: PaceRestraintDecision, utterance: PaceProactiveUtterance?)`.
  `PaceProactiveUtterance` already carries `spokenText`, `source`,
  `confidence` (a **hardcoded literal per generator** — 0.74/0.86/0.78 —
  not computed from any signal today), and `relevanceWindowExpiresAt` (set
  by producers but not currently enforced by any consumer).
- `PaceRestraintGate.swift` — `PaceRestraintGate.decide(_ context:
  PaceRestraintContext) -> PaceRestraintDecision` (`.speak` /
  `.stayQuiet(reason:)` / `.queueUntilIdle(reason:)`). `PaceRestraintContext`
  carries a single global `lastProactiveUtteranceAt` — the only cooldown
  that exists today. This proposal does not change this function, its call
  sites, or its authority.
- `PaceActivityGoalModel.swift` (`openspec/changes/2026-09-13-add-activity-goal-model`)
  — `PaceActivityGoalStore.currentGoalState() -> PaceActiveGoalState`
  (subject `.unknown`/`.known(String)`, confidence, supporting/contradicting
  observation ids). Usable now for a relevance signal: does an opportunity's
  category/utterance plausibly relate to the user's current activity
  subject.
- `PaceInterventionOutcomeModel.swift` (`openspec/changes/2026-09-13-add-outcome-feedback-telemetry`)
  — `PaceInterventionOutcomeStore.outcomeCounts(forInterventionKind:) ->
  PaceInterventionOutcomeCounts`. Verified directly: this has **real data
  only** for `.actionApproval` and `.reversibleMutationUndo` — there is no
  producer anywhere that records a proactive-nudge-level accepted/dismissed
  outcome (nudges are spoken-only with no dismiss gesture, exactly the
  reason that proposal's D1 deferred `ignored`/`edited` producers). "Recent
  acceptance/rejection history" for opportunities specifically does not
  exist as real data yet — see D1.
- `PaceMorningTriageScheduler.swift` — `pendingMorningBriefCard`/
  `dismissPendingCard()` is an informal single-slot cap scoped only to the
  morning brief, not shared across producers. Precedent for "at most one
  card/utterance outstanding," not a general mechanism.

No existing `Opportunity` type exists anywhere in `leanring-buddy/` — this
proposal introduces one, not a duplicate.

## Goals / Non-Goals

**Goals:**

- Satisfy `proactive-companion-policy`'s existing "coalesce equivalent
  candidates, enforce category and global cooldowns" requirement, which is
  accepted but unimplemented today (only a global cooldown exists).
- Make ranking deterministic, bounded, and fully evidence-backed: every
  selection or suppression decision must be reconstructable from retained
  inputs.
- Change nothing about `PaceRestraintGate`'s existing authority or call
  sites — ranking is a pure post-restraint-gate selection step, so it can
  only narrow what gets emitted, never widen it, and can never let a
  candidate speak that the existing gate would have refused.
- Keep the ranking function fully unit-testable with fabricated candidate
  sets — no dependency on live capture paths.
- Be honest where "recent acceptance/rejection history" cannot yet be
  computed from real per-opportunity data (see D1) rather than fabricating
  a signal.

**Non-Goals:**

- No new nudge generator, no new trigger condition, no new capture surface,
  no new permission, no new model call.
- No change to `PaceRestraintGate`'s decision logic itself in this
  proposal — only how many of its already-approved outputs actually reach
  `emit()`.
- No persisted opportunity history. A ranking decision is a per-tick
  computation over live candidates plus the two already-durable evidence
  stores (activity-goal, intervention-outcome); the category-cooldown
  tracker is in-memory only, scoped to the running companion session,
  mirroring the existing per-generator `PaceProactiveNudgeCooldown`.
- No `Now`/`Working`/`Memory` UI surface change (Gap #5/#6) and no
  dynamic "next-move card" UI (the consolidation plan's own recommended
  order places surface consolidation after this).

## Decisions

### D1 — What "recent acceptance/rejection history" means today (OWNER DECISION: CONFIRMED 2026-09-13)

Recommendation: score this factor as **neutral/inert** for every candidate
in this proposal, and say so explicitly in the evidence trail (e.g. an
`acceptanceHistorySignal: .noDataYet` case), rather than either fabricating
a nudge-level accept/dismiss producer now or silently pretending the factor
is meaningfully populated. A real signal needs a genuine dismiss/accept
gesture at the nudge/card level, which does not exist until Gap #5's
surface consolidation ships a real card UI — inventing one now (e.g.
treating "did the user interrupt Pace mid-utterance" as an implicit
rejection) would be guessing at a signal shape a future proposal might
design differently.

Alternative considered: use the existing `actionApproval`/
`reversibleMutationUndo` outcome counts as a coarse global proxy for "is
the user generally receptive to Pace initiating things right now."
Rejected — those outcomes are about executed actions the user explicitly
approved or undid, not about proactive speech; conflating the two would
misrepresent what the evidence actually shows.

**Owner confirmed 2026-09-13**: neutral/inert scoring for now, as built.

### D2 — Sequencing: rank-after-gate vs. rank-before-gate (OWNER DECISION: CONFIRMED 2026-09-13)

Recommendation: keep `PaceRestraintGate.decide(_:)`'s call sites exactly
where they are today (inside each generator's `resolveDecision`, called
independently per-candidate) and insert ranking as a pure selection step
applied to the **set of candidates that already independently reached
`.speak` or `.queueUntilIdle` in one evaluation tick**, before the
orchestrator calls `emit`/`queueForLater`. This is the more conservative of
two designs: it changes zero existing call sites or gate semantics, and it
can only coalesce/cap/discard, never approve something the gate would have
refused. The tradeoff is that each generator still independently consumes
one global-cooldown check via the shared `PaceRestraintContext` before
ranking ever sees the candidate — so a candidate that would have won
ranking but whose generator's own gate call landed on `.stayQuiet` (e.g.
because a different generator's candidate updated `lastProactiveUtteranceAt`
first, in a genuinely concurrent tick) is not recoverable by ranking. Given
the existing framework evaluates generators sequentially per tick today,
this is a narrow edge case, not a correctness gap for the common case.

Alternative considered: move the restraint-gate call to run once, after
ranking, against only the chosen winner. This is more architecturally
"correct" (ranking chooses first, gate approves once) but requires
re-plumbing every generator's `evaluate` function and is a real behavior
change to code that ships and works today — a bigger, riskier edit for a
first slice.

**Owner confirmed 2026-09-13**: the conservative "rank the gate's own
already-approved outputs" sequencing, as built — zero changes to the three
existing generators' own trigger/gate logic.

### D3 — Cap count, coalescing window, and cooldown defaults

Recommendation:

- Cap: **1** concurrent winner per evaluation tick. Pace has exactly one
  voice channel; emitting more than one candidate in the same tick was
  already an unintended gap, not a real product goal.
- Coalescing window: candidates sharing the same `category` string within
  **10 minutes** of each other are treated as equivalent (the newest,
  highest-scored one wins; the rest are recorded as coalesced in the
  evidence trail, not silently dropped).
- Category cooldown: **10 minutes** per category after an emission,
  independent of the existing global cooldown in `PaceRestraintContext`
  (which remains unchanged). Chosen to match the coalescing window so the
  two mechanisms reinforce rather than fight each other.

**Needs an explicit owner answer before Slice 1 merges**: confirm cap=1,
a 10-minute coalescing window, and a 10-minute category cooldown, or supply
different defaults.

## Slices

| # | Slice | Standalone value | Depends on |
| --- | --- | --- | --- |
| 1 | Typed opportunity + pure ranker (coalesce, score, cap) + category cooldown tracker | Proves the ranking policy in isolation with fabricated candidates; zero runtime wiring | D3 |
| 2 | Wire the ranker into `PaceProactiveNudgeOrchestrator`'s emit path | Existing generators' output actually gets coalesced/capped for the first time | Slice 1, D1, D2 |
| 3 | Read-only evidence query ("why did/didn't this opportunity get emitted") | Gives a future debug/settings view something to query | Slice 1, 2 |

Gap #5/#6 (surface consolidation, a real "next move" card UI) and a
nudge-level accept/dismiss producer (which would upgrade D1's neutral
default to a real signal) are explicitly out of this proposal's scope —
natural follow-ups once this is dogfooded.

## Stop conditions

- If the conservative rank-after-gate sequencing (D2) proves to regularly
  suppress a candidate that should have won because a different
  generator's gate call consumed the shared cooldown first, that is
  evidence D2 should be revisited toward the gate-after-rank design, not a
  reason to add a workaround on top of the current sequencing.
- If three generators' worth of candidates essentially never coincide in
  the same tick once dogfooded (making coalescing/capping a no-op in
  practice), that is useful evidence for how much this gap actually
  mattered day-to-day, not a reason to keep expanding scope looking for a
  problem to solve.
