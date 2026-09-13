//
//  CompanionManager+ActivityGoalModel.swift
//  leanring-buddy
//
//  Slice 2 of the activity-goal-model proposal
//  (openspec/changes/2026-09-13-add-activity-goal-model): the deterministic
//  frontmost-app/window-transition producer. Reuses the exact signal
//  `PaceAppUsageTracker` already receives from `NSWorkspace` — no new
//  capture, no new permission prompt, no model call. When the
//  `appUsageHistory` toggle has `appUsageTracker` stopped, this producer is
//  silent too (it only fires from inside `handleApplicationActivated`,
//  which the same `isRunning` gate protects).
//

import Foundation

@MainActor
extension CompanionManager {
    /// Confidence assigned to a raw frontmost-app-transition observation.
    /// Deliberately modest: an app switch is real signal about what the
    /// user is doing, but far weaker evidence than an explicit user
    /// statement (`userStated`, confidence ~0.9+) or an authorized task run.
    private static let frontmostApplicationObservationConfidence: Double = 0.5

    /// Called from `PaceAppUsageTracker.onActivityObserved` on every
    /// frontmost-app transition. Records one bounded `observed` activity
    /// observation and persists the store.
    func recordActivityGoalObservation(applicationName: String, at activationDate: Date) {
        let observation = PaceActivityObservation(
            recordedAt: activationDate,
            evidenceKind: .observed,
            subject: applicationName,
            confidence: Self.frontmostApplicationObservationConfidence,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        activityGoalStore.apply(observation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Rehydrate persisted activity observations at launch. Called once
    /// from `start()`, mirroring `restorePersistedThreadMemoryIfEnabled()`.
    func restorePersistedActivityGoalObservations() {
        let persistedObservations = activityGoalPersistenceStore.load()
        guard !persistedObservations.isEmpty else { return }
        activityGoalStore.restore(from: persistedObservations)
        print("🧭 Activity-goal observations restored: \(persistedObservations.count)")
    }
}
