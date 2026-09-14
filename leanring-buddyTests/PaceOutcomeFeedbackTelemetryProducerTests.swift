//
//  PaceOutcomeFeedbackTelemetryProducerTests.swift
//  leanring-buddyTests
//
//  Slice 2 tests for the outcome-feedback-telemetry proposal
//  (openspec/changes/2026-09-13-add-outcome-feedback-telemetry): the two
//  producers wired into `CompanionManager` — the action-approval
//  accept/dismiss decision and the undo-banner "undone" signal — plus the
//  new stable-identifier minting on `noteReversibleActionExecuted`.
//
//  Presenting a real `NSAlert` isn't feasible (or desirable) in unit
//  tests, so the approval producer is exercised by calling
//  `recordApprovalInterventionOutcome` directly with each decision — the
//  same function the real `NSAlert.runModal()` call site invokes.
//
//  `triggerUndoLastMutation` itself is NOT called directly here: it spawns
//  an unawaited `Task` that dispatches through the real action executor,
//  which a synchronous unit test cannot safely wait on. Instead, the
//  outcome-recording logic it calls synchronously before spawning that
//  Task — `recordUndoInterventionOutcome` — is exercised directly, which
//  covers everything this proposal's Slice 2 actually added.
//
//  Every test constructs its `CompanionManager` via
//  `makeIsolatedCompanionManager()`, which redirects
//  `interventionOutcomePersistenceStore` to a temp file before any
//  persisting call runs. A bare `CompanionManager()` defaults this store to
//  the REAL `~/Library/Application Support/Pace/intervention-outcomes.json`
//  — an earlier version of these tests used a bare `CompanionManager()`
//  directly and leaked one record into that real file (found and fixed
//  2026-09-14 during the dogfood phase; see
//  `docs/knowledge/failed-approaches.md`).
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceOutcomeFeedbackTelemetryProducerTests {
    /// Constructs a `CompanionManager` with its outcome-telemetry
    /// persistence redirected to an isolated temp file, so no test in this
    /// file can write to the user's real Application Support directory.
    /// The temp directory is intentionally leaked (not removed) — these
    /// are tiny JSON files under the system temp dir, already covered by
    /// `PaceInterventionOutcomeModelTests.swift`'s persistence tests, and
    /// this suite's own concern is the producer wiring, not persistence
    /// cleanup.
    private func makeIsolatedCompanionManager() -> CompanionManager {
        let companionManager = CompanionManager()
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceOutcomeFeedbackTelemetryProducerTests-\(UUID().uuidString)", isDirectory: true)
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("intervention-outcomes.json")
        companionManager.interventionOutcomePersistenceStore = PaceInterventionOutcomePersistenceStore(fileURL: temporaryFileURL)
        return companionManager
    }

    // MARK: - Approval producer

    @Test func allowOnceDecisionRecordsAcceptedOutcome() {
        let companionManager = makeIsolatedCompanionManager()
        companionManager.recordApprovalInterventionOutcome(
            decision: .allowOnce,
            approvalSummary: "Step 1: [Medium risk] Send email to jane@example.com"
        )
        let records = companionManager.interventionOutcomeStore.allRecords
        #expect(records.count == 1)
        #expect(records.first?.interventionKind == .actionApproval)
        #expect(records.first?.outcome == .accepted)
        #expect(records.first?.subject == "Step 1: [Medium risk] Send email to jane@example.com")
    }

    @Test func cancelDecisionRecordsDismissedOutcome() {
        let companionManager = makeIsolatedCompanionManager()
        companionManager.recordApprovalInterventionOutcome(
            decision: .cancel,
            approvalSummary: "Step 1: [Medium risk] Send email to jane@example.com"
        )
        let records = companionManager.interventionOutcomeStore.allRecords
        #expect(records.count == 1)
        #expect(records.first?.outcome == .dismissed)
    }

    @Test func approvalOutcomesAccumulateAcrossMultipleDecisions() {
        let companionManager = makeIsolatedCompanionManager()
        companionManager.recordApprovalInterventionOutcome(decision: .allowOnce, approvalSummary: "Approval A")
        companionManager.recordApprovalInterventionOutcome(decision: .cancel, approvalSummary: "Approval B")
        companionManager.recordApprovalInterventionOutcome(decision: .allowOnce, approvalSummary: "Approval C")

        let counts = companionManager.interventionOutcomeStore.outcomeCounts(forInterventionKind: .actionApproval)
        #expect(counts.acceptedCount == 2)
        #expect(counts.dismissedCount == 1)
    }

    // MARK: - Undo producer + stable-identifier correlation

    @Test func noteReversibleActionExecutedMintsAStableIdentifier() {
        let companionManager = makeIsolatedCompanionManager()
        #expect(companionManager.mostRecentReversibleActionIdentifier == nil)

        let plan = PaceActionExecutionPlan.serial(actions: [
            .createNote(PaceNoteRequest(title: "Test note", body: "Body")),
        ])
        companionManager.noteReversibleActionExecuted(in: plan)

        #expect(companionManager.mostRecentReversibleActionIdentifier != nil)
        #expect(companionManager.mostRecentReversibleActionSummary == "Created note")
    }

    @Test func clearReversibleActionUndoStateClearsTheMintedIdentifierToo() {
        let companionManager = makeIsolatedCompanionManager()
        let plan = PaceActionExecutionPlan.serial(actions: [
            .createNote(PaceNoteRequest(title: "Test note", body: "Body")),
        ])
        companionManager.noteReversibleActionExecuted(in: plan)
        #expect(companionManager.mostRecentReversibleActionIdentifier != nil)

        companionManager.clearReversibleActionUndoState()

        #expect(companionManager.mostRecentReversibleActionIdentifier == nil)
        #expect(companionManager.mostRecentReversibleActionSummary == nil)
        #expect(companionManager.mostRecentReversibleActionAt == nil)
    }

    @Test func recordUndoInterventionOutcomeCorrelatesToTheMintedIdentifier() {
        let companionManager = makeIsolatedCompanionManager()
        let plan = PaceActionExecutionPlan.serial(actions: [
            .createNote(PaceNoteRequest(title: "Test note", body: "Body")),
        ])
        companionManager.noteReversibleActionExecuted(in: plan)
        let mintedIdentifier = companionManager.mostRecentReversibleActionIdentifier
        let mintedSummary = companionManager.mostRecentReversibleActionSummary
        #expect(mintedIdentifier != nil)

        // Mirrors exactly what triggerUndoLastMutation does synchronously
        // before it spawns its executor Task (see that function's doc
        // comment): capture the minted id/summary, then record.
        companionManager.recordUndoInterventionOutcome(
            actionIdentifier: mintedIdentifier,
            actionSummary: mintedSummary ?? "Last action"
        )

        let undoRecords = companionManager.interventionOutcomeStore.allRecords
            .filter { $0.interventionKind == .reversibleMutationUndo }
        #expect(undoRecords.count == 1)
        #expect(undoRecords.first?.identifier == mintedIdentifier)
        #expect(undoRecords.first?.outcome == .undone)
        #expect(undoRecords.first?.subject == "Created note")
    }

    @Test func undoWithoutAPriorReversibleActionStillRecordsAnOutcomeWithAFreshIdentifier() {
        // No noteReversibleActionExecuted call first — nil identifier. The
        // producer must not crash and must still record something bounded
        // rather than silently dropping the signal.
        let companionManager = makeIsolatedCompanionManager()
        companionManager.recordUndoInterventionOutcome(
            actionIdentifier: nil,
            actionSummary: "Last action"
        )

        let undoRecords = companionManager.interventionOutcomeStore.allRecords
            .filter { $0.interventionKind == .reversibleMutationUndo }
        #expect(undoRecords.count == 1)
        #expect(undoRecords.first?.outcome == .undone)
        #expect(undoRecords.first?.identifier != nil)
    }
}
