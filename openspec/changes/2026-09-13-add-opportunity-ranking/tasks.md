## 0. Owner Gate

- [x] 0.1 Owner answers D1 (score acceptance-history as neutral/inert for
      now, or require a nudge-level accept/dismiss producer first), D2
      (keep the restraint-gate call sites exactly as-is and rank their
      already-approved outputs, or refactor generators to gate once after
      ranking), and D3 (cap=1 / 10-minute coalescing window / 10-minute
      category cooldown) in [design.md](./design.md) before Slice 2 merges.
      Slice 1 may proceed on the recommended defaults since it is purely
      additive with zero runtime wiring.
- [x] 0.2 Record the answers in this change and adjust scope rather than
      starting Slice 2+ past the approved boundary. Owner confirmed both
      recommended defaults on 2026-09-13: D1 neutral/inert acceptance-history
      scoring, D2 the conservative rank-the-gate's-own-approved-outputs
      sequencing. See the "OWNER DECISION" lines in design.md.

## 1. Slice 1 — Typed Opportunity + Pure Ranker + Category Cooldown Tracker

- [x] 1.1 Add `PaceOpportunity` (identifier, category, `decision`, the
      existing `PaceProactiveUtterance`, createdAt) as a value type wrapping
      one already-restraint-gate-approved candidate. Implemented in
      `PaceOpportunityRanking.swift`; the failable
      `init?(evaluation:category:now:)` is the sole construction path and
      returns `nil` for `.stayQuiet`, making a gate-refused candidate
      unrepresentable by construction (no separate `urgency` input field —
      urgency is derived from the existing `relevanceWindowExpiresAt`
      instead, so no existing generator needs a new field).
- [x] 1.2 Add `PaceOpportunityRanker.rank(candidates:activityGoalState:
      categoryCooldownTracker:now:)` — a pure function: coalesce
      same-category candidates within one tick, apply category cooldowns
      (D3 default 10 min), score survivors on relevance (activity-goal-state
      substring heuristic, boost-only)/urgency (derived from expiry
      proximity)/confidence (existing field)/interruption-cost (derived from
      the gate's own decision)/acceptance-history (D1: always
      `.unavailable`, zero weight), expire anything past its own
      `relevanceWindowExpiresAt`, and cap to at most 1 winner (D3).
- [x] 1.3 Add `PaceOpportunityCategoryCooldownTracker`: in-memory
      last-emitted-at per category, mirroring `PaceProactiveNudgeCooldown`'s
      shape.
- [x] 1.4 Add `PaceOpportunityRankingResult`/`PaceOpportunityRankingRecord`/
      `PaceOpportunityOutcome` retaining every candidate's fate (emitted /
      coalesced-into-winner / suppressed-by-cooldown / expired /
      not-selected-by-cap) and the score breakdown that produced it.
- [x] 1.5 Add focused tests: coalescing picks the highest-scored duplicate
      and retains the other as evidence; category cooldown suppresses a
      repeat within the window, does not affect an unrelated category, and
      clears after the configured interval; cap enforces exactly 1 winner
      across distinct categories; expired candidates are dropped before
      scoring; acceptance-history factor is always marked unavailable;
      relevance heuristic only ever boosts, never penalizes; a `.stayQuiet`
      evaluation (with or without a stray utterance) can never produce a
      `PaceOpportunity`. 13 tests in `PaceOpportunityRankingTests.swift`,
      all passing.
- [x] 1.6 Evaluate the stop condition: ranking state resets every call by
      construction (each `rank(...)` call takes the tick's live candidates
      as an argument and returns a fresh result; only the cooldown tracker
      persists across calls, and it is bounded by the small fixed set of
      real category strings). Not returning to design.

## 2. Slice 2 — Wire Into `PaceProactiveNudgeOrchestrator`

- [x] 2.1 Per D2's confirmed sequencing, integrate the ranker into the
      orchestrator so each generator's `.speak`/`.queueUntilIdle` result
      passes through the ranker before `emit`/`queueForLater` is called,
      using the confirmed cap/window/cooldown defaults from D3. Implemented
      by wrapping the `emit`/`queueForLater` closures the orchestrator hands
      each generator in `start()`/`setGeneratorEnabled` (per-generator
      `category` = its own `identifier`) rather than modifying
      `PaceProactiveNudges.swift` or any of the 3 generator files, which
      stay completely untouched. Each generator fires on its own
      independent timer/subscription (confirmed: there is no shared
      synchronous "tick"), so in practice `rank(...)` is usually called with
      one candidate at a time; the category-cooldown mechanism is what
      actually enforces cross-generator repetition resistance in that
      architecture, and the same pure `rank(...)` function handles both the
      single-candidate common case and the near-simultaneous multi-candidate
      case identically.
- [x] 2.2 Per D1's confirmed answer (neutral/inert), acceptance-history
      stays `.unavailable` with zero weight — `PaceInterventionOutcomeStore`
      is intentionally NOT wired as an evidence source in this slice, since
      its two real kinds (`actionApproval`/`reversibleMutationUndo`) are
      unrelated to nudge categories and D1 rejected using them as a proxy
      (see design.md D1's "Alternative considered").
- [x] 2.3 Add tests proving the three existing generators' own trigger
      logic and restraint-gate calls are byte-identical to before this
      slice. Verified two ways: (a) zero changes to
      `PaceProactiveNudges.swift` or the 3 generator files — the diff is
      scoped to `PaceProactiveNudgeFramework.swift`,
      `PaceProactivityPipeline.swift`, and `CompanionManager.swift`; (b) all
      pre-existing generator-level tests
      (`PaceFocusFatigueNudgeGeneratorTests`,
      `PaceCalendarPreMeetingNudgeGeneratorTests`,
      `PaceWatchModeObservationNudgeGeneratorTests`, and the pre-existing
      `PaceProactiveNudgeFrameworkOrchestratorTests`) pass unmodified. 5 new
      wiring tests added in `PaceProactiveNudgeOrchestratorRankingTests`
      (same file) prove ranking actually intercepts `start`/
      `setGeneratorEnabled`'s closures.
- [x] 2.4 Evaluate the stop condition: not yet dogfooded (the wiring just
      shipped), so coincidence frequency can't be assessed yet. No second
      producer or additional scope added preemptively.

## 3. Slice 3 — Read-Only Evidence Query

- [ ] 3.1 Add a read-only query returning the full evidence trail for the
      most recent ranking decision(s), for a future debug/settings view or
      the "why did Pace say that" trust surface to call.
- [ ] 3.2 Add tests proving the query never mutates ranker state.
- [ ] 3.3 Evaluate the stop condition: this slice adds no new behavior
      surface by itself; if no consumer is planned within a reasonable
      follow-up window, stop here rather than building a UI speculatively.
