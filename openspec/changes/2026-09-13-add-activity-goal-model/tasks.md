## 0. Owner Gate

- [x] 0.1 Owner answers D1 (producer scope for this proposal), D2 (new store
      vs. extending the episodic fact store), and D3 (retention/staleness
      defaults) in [design.md](./design.md) before Slice 2 merges. Slice 1 may
      proceed on the recommended defaults since it is purely additive and
      easily adjusted before anything else depends on it.
- [x] 0.2 Record the answers in this change and adjust scope rather than
      starting Slice 2+ past the approved boundary. Owner confirmed all three
      recommended defaults on 2026-09-13: D1 app-transition-only producer
      scope, D2 new dedicated store, D3 200-per-subject cap / 30-minute
      freshness window. See the "OWNER DECISION" lines in design.md.

## 1. Slice 1 — Typed Observation + Derived State Schema

- [x] 1.1 Add `PaceActivityObservation` (identifier, timestamp, evidence kind,
      subject, confidence, provenance, optional expiry) as a `Codable`,
      `Equatable`, `Identifiable` value type, mirroring `PaceEpisodicFact`'s
      shape. Implemented in `PaceActivityGoalModel.swift`.
- [x] 1.2 Add `PaceActiveGoalState` derivation: current subject or `unknown`,
      confidence, supporting observation ids, contradicting observation ids.
      `PaceActivityGoalStateDerivation.derive(from:now:)`.
- [x] 1.3 Add `PaceActivityGoalStore`: in-memory store with the 200-observation
      cap (per subject, per D3), oldest-first compaction. No separate
      tombstone list: a correction is an observation carrying
      `supersedesObservationId`, and the superseded observation is retained
      (never deleted) — see the type's doc comment for why this differs from
      `PaceEpisodicTombstone`.
- [x] 1.4 Add staleness handling: `observed`/`inferred` evidence older than the
      freshness window (default 30 minutes) with no corroborating newer
      observation yields a stale/unknown derived state; `userStated`/
      `authorizedTask` evidence never auto-expires on this clock.
- [x] 1.5 Add durable persistence following the existing
      `PaceMemoryStore`/`PaceThreadMemoryStore` atomic-JSON-file pattern in
      `PaceActivityGoalPersistenceStore.swift` (`fileURL` injectable for
      tests, unlike the two it mirrors). Not yet wired into
      `CompanionManager` — no runtime call site in this slice.
- [x] 1.6 Add focused tests: schema round-trip, supersession-never-deletes,
      stale-vs-unknown reporting, retention cap and compaction (including
      per-subject scoping), decay timing, privacy-boundary field-set proof,
      and the persistence round trip (including corrupt-file and nil-fileURL
      cases). 17 tests in `PaceActivityGoalModelTests.swift`, all passing.
- [x] 1.7 Evaluate the stop condition: supporting/contradicting evidence stays
      bounded by the existing per-subject retention cap and the freshness-
      window filter applied before derivation; no ad-hoc cap was needed. Not
      returning to design.

## 2. Slice 2 — Deterministic App/Window-Transition Producer

- [x] 2.1 Add a producer that calls into `PaceActivityGoalStore` from
      `PaceAppUsageTracker.handleApplicationActivated(named:)` (or an
      equivalent seam), recording an `observed` observation naming the newly
      frontmost application. Implemented via a new optional
      `onActivityObserved` closure parameter on `PaceAppUsageTracker`, wired
      in `CompanionManager.appUsageTracker` to
      `CompanionManager+ActivityGoalModel.swift`'s
      `recordActivityGoalObservation(applicationName:at:)`. Persistence is
      also wired end-to-end (save after every apply; restore at `start()`
      via `restorePersistedActivityGoalObservations()`) so Slice 1's store
      isn't left unfinished scaffolding.
- [x] 2.2 Ensure the producer performs no new capture, no new permission
      prompt, and no model call — it reads only the signal
      `PaceAppUsageTracker` already receives. Confirmed: the closure fires
      from the exact `applicationName`/`Date()` already computed inside
      `handleApplicationActivated`; it inherits the same `isRunning`
      (`appUsageHistory` toggle) gate the journal recording already has.
- [x] 2.3 Add tests driving the existing app-activation test seam and
      asserting the store receives exactly one bounded observation per
      transition, with no behavior change to `PaceAppUsageTracker`'s existing
      journal/tracking responsibilities. Added a new
      `simulateApplicationActivatedForTesting(named:)` test-only seam (no
      prior seam existed for this tracker) and 6 tests in
      `PaceActivityGoalProducerTests.swift`, all passing.
- [x] 2.4 Evaluate the stop condition: not yet dogfooded, so noise cannot be
      assessed yet; no second producer was added preemptively. Revisit once
      real usage data exists.

## 3. Slice 3 — Read-Only Retrieval

- [x] 3.1 Add a read-only query API returning the current `PaceActiveGoalState`
      with confidence and supporting observation ids, for any future consumer
      (a later ranking layer, a debug/settings view, or the "Resume work"
      story) to call. Already existed as `PaceActivityGoalStore.currentGoalState()`
      from Slice 1 (needed there to prove the derivation in tests) — no new
      production code required for this slice.
- [x] 3.2 Add tests proving the query never mutates store state and correctly
      reports `unknown` when evidence is insufficient.
      `currentGoalStateQueryNeverMutatesStoreContents` and
      `currentGoalStateQueryReportsUnknownOnAnEmptyStore` added to
      `PaceActivityGoalModelTests.swift`, both passing (19 tests total in
      that file now).
- [x] 3.3 Evaluate the stop condition: no consumer is planned yet (Gap #2
      opportunity ranking, Gap #5/#6 surface consolidation are explicitly out
      of this proposal's scope per proposal.md). Stopping here rather than
      building a speculative consumer — this proposal is complete as scoped.
