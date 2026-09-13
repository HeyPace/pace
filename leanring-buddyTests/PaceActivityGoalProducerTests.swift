//
//  PaceActivityGoalProducerTests.swift
//  leanring-buddyTests
//
//  Slice 2 tests for the activity-goal-model proposal
//  (openspec/changes/2026-09-13-add-activity-goal-model): the deterministic
//  frontmost-app/window-transition producer wired into
//  `PaceAppUsageTracker.handleApplicationActivated`. Drives the tracker
//  through `simulateApplicationActivatedForTesting` (a test-only seam that
//  bypasses the real NSWorkspace observer/timer `start()` would register)
//  and asserts: exactly one bounded observation per transition, and zero
//  behavior change to the tracker's existing journal/flush responsibilities.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceActivityGoalProducerTests {
    @Test func activationEventProducesExactlyOneActivityObservation() {
        var observedActivations: [(applicationName: String, activationDate: Date)] = []
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { _ in },
            onActivityObserved: { applicationName, activationDate in
                observedActivations.append((applicationName, activationDate))
            }
        )

        tracker.simulateApplicationActivatedForTesting(named: "Xcode")

        #expect(observedActivations.count == 1)
        #expect(observedActivations.first?.applicationName == "Xcode")
    }

    @Test func multipleTransitionsProduceOneObservationEach() {
        var observedApplicationNames: [String] = []
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { _ in },
            onActivityObserved: { applicationName, _ in
                observedApplicationNames.append(applicationName)
            }
        )

        tracker.simulateApplicationActivatedForTesting(named: "Xcode")
        tracker.simulateApplicationActivatedForTesting(named: "Slack")
        tracker.simulateApplicationActivatedForTesting(named: "Xcode")

        #expect(observedApplicationNames == ["Xcode", "Slack", "Xcode"])
    }

    @Test func nilApplicationNameProducesNoObservation() {
        var observationCount = 0
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { _ in },
            onActivityObserved: { _, _ in observationCount += 1 }
        )

        tracker.simulateApplicationActivatedForTesting(named: nil)

        #expect(observationCount == 0)
    }

    @Test func onActivityObservedIsOptionalAndDefaultsToNilWithoutCrashing() {
        // No onActivityObserved passed — must not crash, and existing
        // journal-flush behavior must be unaffected by its absence.
        var flushedDocumentCount = 0
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { _ in flushedDocumentCount += 1 }
        )

        tracker.simulateApplicationActivatedForTesting(named: "Xcode")

        #expect(flushedDocumentCount == 1)
    }

    @Test func activationStillFlushesJournalDocumentExactlyAsBefore() {
        // Proves the producer is additive: the tracker's existing
        // journal/flush responsibility is unchanged by also having an
        // onActivityObserved hook wired.
        var flushedDocuments: [PaceRetrievalDocument] = []
        var observedActivations: [String] = []
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { document in flushedDocuments.append(document) },
            onActivityObserved: { applicationName, _ in observedActivations.append(applicationName) }
        )

        tracker.simulateApplicationActivatedForTesting(named: "Xcode")

        #expect(flushedDocuments.count == 1)
        #expect(flushedDocuments.first?.source == .appUsageHistory)
        #expect(observedActivations == ["Xcode"])
    }

    // MARK: - End-to-end: producer → store → derived state

    @Test func producerFeedsActivityGoalStoreAndDerivesCurrentState() {
        // `handleApplicationActivated` always timestamps with the real
        // wall clock (`Date()`), so the store must query the real clock
        // too — an injected fixed `now` here would see the just-recorded
        // observation as impossibly far in the future.
        let activityGoalStore = PaceActivityGoalStore()
        let tracker = PaceAppUsageTracker(
            rehydratedJournal: PaceAppUsageJournal(rehydratingFrom: [], now: Date()),
            onFlushedDocument: { _ in },
            onActivityObserved: { applicationName, activationDate in
                activityGoalStore.apply(PaceActivityObservation(
                    recordedAt: activationDate,
                    evidenceKind: .observed,
                    subject: applicationName,
                    confidence: 0.5,
                    provenanceSourceSystem: "PaceAppUsageTracker"
                ))
            }
        )

        tracker.simulateApplicationActivatedForTesting(named: "Xcode")

        #expect(activityGoalStore.allObservations.count == 1)
        let currentState = activityGoalStore.currentGoalState()
        #expect(currentState.subject == .known("Xcode"))
    }
}
