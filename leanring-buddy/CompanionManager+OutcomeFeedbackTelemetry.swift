//
//  CompanionManager+OutcomeFeedbackTelemetry.swift
//  leanring-buddy
//
//  Slice 2 of the outcome-feedback-telemetry proposal
//  (openspec/changes/2026-09-13-add-outcome-feedback-telemetry): the two
//  zero-new-capture producers this proposal scopes — the action-approval
//  accept/dismiss decision, and the undo-banner "undone" signal. Neither
//  producer gates, delays, or alters the decision it observes; both just
//  add a record alongside what already happens.
//

import Foundation

@MainActor
extension CompanionManager {
    /// Called from `requestUserApprovalForActionPlan` right after the
    /// existing `NSAlert` decision is computed
    /// (`CompanionManager+PostureWatch.swift`). No new capture — the
    /// decision already happened; this only records it.
    func recordApprovalInterventionOutcome(
        decision: PaceActionApprovalDecision,
        approvalSummary: String
    ) {
        let outcome: PaceInterventionOutcome = decision == .allowOnce ? .accepted : .dismissed
        let record = PaceInterventionOutcomeRecord(
            recordedAt: Date(),
            interventionKind: .actionApproval,
            outcome: outcome,
            subject: approvalSummary,
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        )
        applyInterventionOutcomeAndPersist(record)
    }

    /// Called from `triggerUndoLastMutation` (`CompanionManager+TrustSurfacesRuntime.swift`)
    /// right after the user's existing undo-banner tap. `actionIdentifier`
    /// is the stable id minted at `noteReversibleActionExecuted` time, used
    /// as this record's own identifier so a later producer referencing the
    /// same action (if one is ever added) can correlate by id.
    func recordUndoInterventionOutcome(
        actionIdentifier: String?,
        actionSummary: String
    ) {
        let record = PaceInterventionOutcomeRecord(
            identifier: actionIdentifier ?? UUID().uuidString,
            recordedAt: Date(),
            interventionKind: .reversibleMutationUndo,
            outcome: .undone,
            subject: actionSummary,
            provenanceSourceSystem: "triggerUndoLastMutation"
        )
        applyInterventionOutcomeAndPersist(record)
    }

    private func applyInterventionOutcomeAndPersist(_ record: PaceInterventionOutcomeRecord) {
        interventionOutcomeStore.apply(record)
        interventionOutcomePersistenceStore.save(interventionOutcomeStore.allRecords)
    }

    /// Rehydrate persisted outcome records at launch. Called once from
    /// `start()`, mirroring `restorePersistedActivityGoalObservations()`.
    func restorePersistedInterventionOutcomes() {
        let persistedRecords = interventionOutcomePersistenceStore.load()
        guard !persistedRecords.isEmpty else { return }
        interventionOutcomeStore.restore(from: persistedRecords)
        print("📋 Intervention outcome records restored: \(persistedRecords.count)")
    }
}
