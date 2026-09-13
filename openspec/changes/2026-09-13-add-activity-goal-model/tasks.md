## 0. Owner Gate

- [ ] 0.1 Owner answers D1 (producer scope for this proposal), D2 (new store
      vs. extending the episodic fact store), and D3 (retention/staleness
      defaults) in [design.md](./design.md) before Slice 2 merges. Slice 1 may
      proceed on the recommended defaults since it is purely additive and
      easily adjusted before anything else depends on it.
- [ ] 0.2 Record the answers in this change and adjust scope rather than
      starting Slice 2+ past the approved boundary.

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

- [ ] 2.1 Add a producer that calls into `PaceActivityGoalStore` from
      `PaceAppUsageTracker.handleApplicationActivated(named:)` (or an
      equivalent seam), recording an `observed` observation naming the newly
      frontmost application.
- [ ] 2.2 Ensure the producer performs no new capture, no new permission
      prompt, and no model call — it reads only the signal
      `PaceAppUsageTracker` already receives.
- [ ] 2.3 Add tests driving the existing app-activation test seam and
      asserting the store receives exactly one bounded observation per
      transition, with no behavior change to `PaceAppUsageTracker`'s existing
      journal/tracking responsibilities.
- [ ] 2.4 Evaluate the stop condition: if app-transition signal proves too
      noisy to produce a useful current-state derivation once dogfooded, treat
      that as evidence for D1's next owner decision, not a reason to add a
      second producer to compensate.

## 3. Slice 3 — Read-Only Retrieval

- [ ] 3.1 Add a read-only query API returning the current `PaceActiveGoalState`
      with confidence and supporting observation ids, for any future consumer
      (a later ranking layer, a debug/settings view, or the "Resume work"
      story) to call.
- [ ] 3.2 Add tests proving the query never mutates store state and correctly
      reports `unknown` when evidence is insufficient.
- [ ] 3.3 Evaluate the stop condition: this slice adds no new behavior surface
      by itself; if no consumer is planned to use the query within a
      reasonable follow-up window, stop here rather than building Gap #2/#5
      speculatively.
