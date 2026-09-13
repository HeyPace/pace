//
//  PaceActivityGoalModelTests.swift
//  leanring-buddyTests
//
//  Slice 1 tests for the activity-goal-model proposal
//  (openspec/changes/2026-09-13-add-activity-goal-model): schema
//  round-trip, supersession-never-deletes, stale-vs-unknown reporting,
//  per-subject retention cap/compaction, decay timing, the privacy-
//  boundary field-set proof, and the durable-persistence round trip.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceActivityGoalModelTests {
    // MARK: - Schema round-trip

    @Test func observationSurvivesJSONEncodeDecodeRoundTrip() throws {
        let originalObservation = PaceActivityObservation(
            identifier: "obs-1",
            recordedAt: Date(timeIntervalSince1970: 1_726_000_000),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.7,
            provenanceSourceSystem: "PaceAppUsageTracker",
            provenanceEvidenceReferenceId: "activation-42",
            expiresAt: nil,
            supersedesObservationId: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encodedData = try encoder.encode(originalObservation)
        let decodedObservation = try decoder.decode(PaceActivityObservation.self, from: encodedData)

        #expect(decodedObservation == originalObservation)
    }

    @Test func correctionObservationRoundTripsSupersedesLink() throws {
        let correctionObservation = PaceActivityObservation(
            identifier: "obs-correction",
            recordedAt: Date(),
            evidenceKind: .userStated,
            subject: "Writing the Q3 report",
            confidence: 0.95,
            provenanceSourceSystem: "userCorrection",
            supersedesObservationId: "obs-1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            PaceActivityObservation.self,
            from: try encoder.encode(correctionObservation)
        )
        #expect(decoded.supersedesObservationId == "obs-1")
    }

    // MARK: - Supersession never deletes

    @Test func correctionSupersedesButRetainsPriorObservation() {
        let store = PaceActivityGoalStore(now: { Date(timeIntervalSince1970: 2_000) })
        let originalObservation = PaceActivityObservation(
            identifier: "obs-1",
            recordedAt: Date(timeIntervalSince1970: 1_000),
            evidenceKind: .observed,
            subject: "Slack",
            confidence: 0.6,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        store.apply(originalObservation)

        let correctionObservation = PaceActivityObservation(
            identifier: "obs-2",
            recordedAt: Date(timeIntervalSince1970: 1_500),
            evidenceKind: .userStated,
            subject: "Writing the launch email",
            confidence: 0.97,
            provenanceSourceSystem: "userCorrection",
            supersedesObservationId: "obs-1"
        )
        let applyOutcome = store.apply(correctionObservation)

        #expect(applyOutcome == .insertedAsCorrection(supersedesObservationId: "obs-1"))
        // The superseded observation is still retrievable as history.
        #expect(store.allObservations.contains(where: { $0.identifier == "obs-1" }))
        #expect(store.allObservations.count == 2)

        // But it no longer counts toward the current state.
        let currentState = store.currentGoalState()
        #expect(currentState.subject == .known("Writing the launch email"))
        #expect(!currentState.supportingObservationIds.contains("obs-1"))
        #expect(!currentState.contradictingObservationIds.contains("obs-1"))
    }

    // MARK: - Stale-vs-unknown reporting

    @Test func freshObservedEvidenceIsReportedAsCurrent() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recentObservation = PaceActivityObservation(
            identifier: "obs-fresh",
            recordedAt: now.addingTimeInterval(-60),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.5,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [recentObservation],
            now: now
        )
        #expect(derivedState.subject == .known("Xcode"))
        #expect(derivedState.supportingObservationIds == ["obs-fresh"])
    }

    @Test func staleObservedEvidenceWithNoCorroborationReportsUnknown() {
        let now = Date(timeIntervalSince1970: 100_000)
        let staleObservation = PaceActivityObservation(
            identifier: "obs-stale",
            recordedAt: now.addingTimeInterval(-2 * PaceActivityGoalLimits.defaultFreshnessWindowInSeconds),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.9,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [staleObservation],
            now: now
        )
        #expect(derivedState == .unknown)
    }

    @Test func staleObservedEvidenceCorroboratedByNewerSameSubjectSampleStaysCurrent() {
        let now = Date(timeIntervalSince1970: 100_000)
        let oldObservation = PaceActivityObservation(
            identifier: "obs-old",
            recordedAt: now.addingTimeInterval(-2 * PaceActivityGoalLimits.defaultFreshnessWindowInSeconds),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.4,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let corroboratingObservation = PaceActivityObservation(
            identifier: "obs-corroborating",
            recordedAt: now.addingTimeInterval(-30),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.4,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [oldObservation, corroboratingObservation],
            now: now
        )
        #expect(derivedState.subject == .known("Xcode"))
        #expect(Set(derivedState.supportingObservationIds) == ["obs-old", "obs-corroborating"])
    }

    @Test func userStatedEvidenceNeverAutoExpiresOnStalenessClock() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let longAgoUserStatedObservation = PaceActivityObservation(
            identifier: "obs-user-stated",
            recordedAt: now.addingTimeInterval(-10 * PaceActivityGoalLimits.defaultFreshnessWindowInSeconds),
            evidenceKind: .userStated,
            subject: "Planning the offsite",
            confidence: 0.9,
            provenanceSourceSystem: "userUtterance"
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [longAgoUserStatedObservation],
            now: now
        )
        #expect(derivedState.subject == .known("Planning the offsite"))
    }

    @Test func explicitExpiryStillAppliesToUserStatedEvidence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiredUserStatedObservation = PaceActivityObservation(
            identifier: "obs-expired",
            recordedAt: now.addingTimeInterval(-100),
            evidenceKind: .userStated,
            subject: "Planning the offsite",
            confidence: 0.9,
            provenanceSourceSystem: "userUtterance",
            expiresAt: now.addingTimeInterval(-1)
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [expiredUserStatedObservation],
            now: now
        )
        #expect(derivedState == .unknown)
    }

    @Test func noObservationsReportsUnknownRatherThanCrashing() {
        let derivedState = PaceActivityGoalStateDerivation.derive(from: [], now: Date())
        #expect(derivedState == .unknown)
    }

    @Test func higherConfidenceObservationSupersedesLowerConfidenceContradictingSubject() {
        let now = Date(timeIntervalSince1970: 50_000)
        let lowerConfidenceObservation = PaceActivityObservation(
            identifier: "obs-low",
            recordedAt: now.addingTimeInterval(-100),
            evidenceKind: .observed,
            subject: "Mail",
            confidence: 0.3,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let higherConfidenceObservation = PaceActivityObservation(
            identifier: "obs-high",
            recordedAt: now.addingTimeInterval(-50),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.8,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let derivedState = PaceActivityGoalStateDerivation.derive(
            from: [lowerConfidenceObservation, higherConfidenceObservation],
            now: now
        )
        #expect(derivedState.subject == .known("Xcode"))
        #expect(derivedState.contradictingObservationIds == ["obs-low"])
    }

    // MARK: - Retention cap and compaction

    @Test func perSubjectRetentionCapCompactsOldestFirst() {
        let store = PaceActivityGoalStore(now: { Date(timeIntervalSince1970: 1_000_000) })
        let cap = PaceActivityGoalLimits.maximumStoredObservationCountPerSubject
        for index in 0..<(cap + 10) {
            store.apply(PaceActivityObservation(
                identifier: "obs-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                evidenceKind: .observed,
                subject: "Xcode",
                confidence: 0.5,
                provenanceSourceSystem: "PaceAppUsageTracker"
            ))
        }
        let storedIdentifiers = Set(store.allObservations.map(\.identifier))
        #expect(storedIdentifiers.count == cap)
        // The 10 oldest (index 0...9) should have been compacted away.
        #expect(!storedIdentifiers.contains("obs-0"))
        #expect(!storedIdentifiers.contains("obs-9"))
        #expect(storedIdentifiers.contains("obs-\(cap + 9)"))
    }

    @Test func retentionCapIsScopedPerSubjectNotGlobal() {
        let store = PaceActivityGoalStore(now: { Date(timeIntervalSince1970: 1_000_000) })
        let cap = PaceActivityGoalLimits.maximumStoredObservationCountPerSubject
        for index in 0..<cap {
            store.apply(PaceActivityObservation(
                identifier: "xcode-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                evidenceKind: .observed,
                subject: "Xcode",
                confidence: 0.5,
                provenanceSourceSystem: "PaceAppUsageTracker"
            ))
        }
        // A single observation for an unrelated subject must not be evicted
        // by the other subject's full cap.
        store.apply(PaceActivityObservation(
            identifier: "slack-1",
            recordedAt: Date(timeIntervalSince1970: 500_000),
            evidenceKind: .observed,
            subject: "Slack",
            confidence: 0.5,
            provenanceSourceSystem: "PaceAppUsageTracker"
        ))
        let storedIdentifiers = Set(store.allObservations.map(\.identifier))
        #expect(storedIdentifiers.contains("slack-1"))
        #expect(storedIdentifiers.count == cap + 1)
    }

    // MARK: - Privacy-boundary field-set proof

    @Test func observationExposesOnlyTheDocumentedStructuralFields() {
        let observation = PaceActivityObservation(
            recordedAt: Date(),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.5,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        let mirroredFieldNames = Set(Mirror(reflecting: observation).children.compactMap(\.label))
        // If this fails, a new field was added to `PaceActivityObservation`
        // without deliberate review of whether it could carry raw
        // document/field/secure content — see design.md's privacy boundary.
        #expect(mirroredFieldNames == [
            "identifier",
            "recordedAt",
            "evidenceKind",
            "subject",
            "confidence",
            "provenanceSourceSystem",
            "provenanceEvidenceReferenceId",
            "expiresAt",
            "supersedesObservationId",
        ])
    }

    // MARK: - Durable persistence round trip

    @Test func persistenceStoreRoundTripsThroughATemporaryFile() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceActivityGoalModelTests-\(UUID().uuidString)", isDirectory: true)
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("activity-goal-model.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let persistenceStore = PaceActivityGoalPersistenceStore(fileURL: temporaryFileURL)
        #expect(persistenceStore.load().isEmpty)

        let observationToPersist = PaceActivityObservation(
            identifier: "obs-persisted",
            recordedAt: Date(timeIntervalSince1970: 12_345),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.55,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        persistenceStore.save([observationToPersist])

        let reloadedObservations = persistenceStore.load()
        #expect(reloadedObservations == [observationToPersist])

        persistenceStore.clear()
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func persistenceStoreLoadReturnsEmptyForCorruptFileRatherThanThrowing() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceActivityGoalModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("activity-goal-model.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        try Data("not valid json".utf8).write(to: temporaryFileURL)
        let persistenceStore = PaceActivityGoalPersistenceStore(fileURL: temporaryFileURL)
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func persistenceStoreWithNilFileURLIsInertRatherThanCrashing() {
        let persistenceStore = PaceActivityGoalPersistenceStore(fileURL: nil)
        #expect(persistenceStore.load().isEmpty)
        persistenceStore.save([PaceActivityObservation(
            recordedAt: Date(),
            evidenceKind: .observed,
            subject: "Xcode",
            confidence: 0.5,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )])
        persistenceStore.clear()
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func storeRestoreRehydratesFromPersistedObservationsAndReappliesCap() {
        let store = PaceActivityGoalStore(now: { Date(timeIntervalSince1970: 1_000_000) })
        let cap = PaceActivityGoalLimits.maximumStoredObservationCountPerSubject
        let persistedObservations = (0..<(cap + 5)).map { index in
            PaceActivityObservation(
                identifier: "obs-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                evidenceKind: .observed,
                subject: "Xcode",
                confidence: 0.5,
                provenanceSourceSystem: "PaceAppUsageTracker"
            )
        }
        store.restore(from: persistedObservations)
        #expect(store.allObservations.count == cap)
    }
}
