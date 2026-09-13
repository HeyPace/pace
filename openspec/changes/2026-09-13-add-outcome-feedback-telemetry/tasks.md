## 0. Owner Gate

- [x] 0.1 Owner answers D1 (producer scope: approval+undo only, or also
      `completed`/`failed`), D2 (cap per `interventionKind`, not per
      subject), and D3 (retention default) in [design.md](./design.md)
      before Slice 2 merges. Slice 1 may proceed on the recommended
      defaults since it is purely additive and easily adjusted before
      anything else depends on it.
- [x] 0.2 Record the answers in this change and adjust scope rather than
      starting Slice 2+ past the approved boundary. Owner confirmed all
      three recommended defaults on 2026-09-13: D1 approval+undo-only
      producer scope, D2 per-`interventionKind` capping, D3 200-per-kind
      retention. See the "OWNER DECISION" lines in design.md.

## 1. Slice 1 — Typed Outcome Record + Store + Retention

- [x] 1.1 Add `PaceInterventionOutcomeRecord` (identifier, timestamp,
      `interventionKind`, `outcome`, subject summary, provenance source
      system) as a `Codable`, `Equatable`, `Identifiable`, `Sendable` value
      type, mirroring `PaceActivityObservation`'s shape. Implemented in
      `PaceInterventionOutcomeModel.swift`.
- [x] 1.2 Add `PaceInterventionOutcomeStore`: in-memory store capped per
      `interventionKind` (per D2/D3 defaults), oldest-first compaction
      within each kind. Also includes the Slice 3 read-only
      `outcomeCounts(forInterventionKind:)` query, added now since it was
      needed to prove the store under test (same pattern as the prior
      proposal's Slice 1/3 overlap).
- [x] 1.3 Add durable persistence following
      `PaceActivityGoalPersistenceStore`'s atomic-JSON-file pattern
      (`fileURL` injectable for tests) in
      `PaceInterventionOutcomePersistenceStore.swift`. Not yet wired into
      `CompanionManager` — no runtime call site in this slice.
- [x] 1.4 Add focused tests: schema round-trip, per-`interventionKind`
      retention cap and compaction (proving one kind's cap doesn't affect
      another's), privacy-boundary field-set proof, and the persistence
      round trip (including corrupt-file and nil-fileURL cases). 12 tests
      in `PaceInterventionOutcomeModelTests.swift`, all passing.
- [x] 1.5 Evaluate the stop condition: per-`interventionKind` capping
      bounds storage correctly since the two in-scope kinds are a small
      closed set; not returning to design.

## 2. Slice 2 — Approval Accept/Dismiss + Undo Producers

- [x] 2.1 Add one new stable identifier to the reversible-action-executed
      record (`noteReversibleActionExecuted` in
      `CompanionManager+TrustSurfacesRuntime.swift`) so a later "undone"
      outcome can correlate back to the specific action it undoes.
      Implemented as `mostRecentReversibleActionIdentifier` (a new
      `@Published` field on `CompanionManager`, mirroring the existing
      summary/timestamp pair), minted in `noteReversibleActionExecuted`
      and cleared in `clearReversibleActionUndoState`.
- [x] 2.2 Record an `accepted`/`dismissed` outcome at
      `requestUserApprovalForActionPlan`'s existing approval-decision
      computation (`CompanionManager+PostureWatch.swift`) — no new
      capture, the decision is already computed from the `NSAlert` result.
- [x] 2.3 Record an `undone` outcome at `triggerUndoLastMutation()`
      (`CompanionManager+TrustSurfacesRuntime.swift`), correlated via the
      identifier from 2.1 — no new capture, the trigger is the user's
      existing undo-banner tap. The identifier/summary are captured before
      `clearReversibleActionUndoState()` runs.
- [x] 2.4 Wire durable persistence end-to-end (save after every apply,
      restore at `start()`) so Slice 1's store isn't left as unfinished
      scaffolding, mirroring the prior proposal's Slice 2 discipline.
      `CompanionManager+OutcomeFeedbackTelemetry.swift` owns both producers
      plus `restorePersistedInterventionOutcomes()`.
- [x] 2.5 Add tests proving each producer records exactly one bounded
      outcome per decision, with no behavior change to the existing
      approval or undo execution paths. 7 tests in
      `PaceOutcomeFeedbackTelemetryProducerTests.swift`. Note: the real
      `NSAlert`/executor call sites aren't invoked directly in tests (an
      unawaited `Task` from `triggerUndoLastMutation` proved unsafe to
      exercise synchronously in a unit test — see that file's header
      comment); the synchronous outcome-recording logic each site calls is
      tested directly instead, which covers everything this slice added.
- [x] 2.6 Evaluate the stop condition: not yet dogfooded, so sparsity
      cannot be assessed yet. Not adding more producers preemptively.

## 3. Slice 3 — Read-Only Retrieval

- [ ] 3.1 Add a read-only query returning outcome counts (and derived
      rates) per `interventionKind`, for a future ranking layer to call.
- [ ] 3.2 Add tests proving the query never mutates store state and
      returns zero counts (not a fabricated rate) when no records exist
      for a queried `interventionKind`.
- [ ] 3.3 Evaluate the stop condition: this slice adds no new behavior
      surface by itself; if no consumer is planned to use the query within
      a reasonable follow-up window, stop here rather than building Gap #2
      speculatively.
