//
//  PaceInterventionOutcomeModelTests.swift
//  leanring-buddyTests
//
//  Slice 1 tests for the outcome-feedback-telemetry proposal
//  (openspec/changes/2026-09-13-add-outcome-feedback-telemetry): schema
//  round-trip, per-interventionKind retention cap and compaction, the
//  privacy-boundary field-set proof, and the durable-persistence round
//  trip.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceInterventionOutcomeModelTests {
    // MARK: - Schema round-trip

    @Test func recordSurvivesJSONEncodeDecodeRoundTrip() throws {
        let originalRecord = PaceInterventionOutcomeRecord(
            identifier: "outcome-1",
            recordedAt: Date(timeIntervalSince1970: 1_726_000_000),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Step 1: [Medium risk] Send email to jane@example.com",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encodedData = try encoder.encode(originalRecord)
        let decodedRecord = try decoder.decode(PaceInterventionOutcomeRecord.self, from: encodedData)

        #expect(decodedRecord == originalRecord)
    }

    @Test func undoneOutcomeRoundTripsForReversibleMutationKind() throws {
        let undoneRecord = PaceInterventionOutcomeRecord(
            recordedAt: Date(),
            interventionKind: .reversibleMutationUndo,
            outcome: .undone,
            subject: "Created a Reminder: Follow up with Jane",
            provenanceSourceSystem: "triggerUndoLastMutation"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            PaceInterventionOutcomeRecord.self,
            from: try encoder.encode(undoneRecord)
        )
        #expect(decoded.interventionKind == .reversibleMutationUndo)
        #expect(decoded.outcome == .undone)
    }

    // MARK: - Per-interventionKind retention cap and compaction

    @Test func perInterventionKindRetentionCapCompactsOldestFirst() {
        let store = PaceInterventionOutcomeStore()
        let cap = PaceInterventionOutcomeLimits.maximumStoredRecordCountPerInterventionKind
        for index in 0..<(cap + 10) {
            store.apply(PaceInterventionOutcomeRecord(
                identifier: "outcome-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                interventionKind: .actionApproval,
                outcome: .accepted,
                subject: "Approval #\(index)",
                provenanceSourceSystem: "requestUserApprovalForActionPlan"
            ))
        }
        let storedIdentifiers = Set(store.allRecords.map(\.identifier))
        #expect(storedIdentifiers.count == cap)
        #expect(!storedIdentifiers.contains("outcome-0"))
        #expect(!storedIdentifiers.contains("outcome-9"))
        #expect(storedIdentifiers.contains("outcome-\(cap + 9)"))
    }

    @Test func retentionCapIsScopedPerInterventionKindNotGlobal() {
        let store = PaceInterventionOutcomeStore()
        let cap = PaceInterventionOutcomeLimits.maximumStoredRecordCountPerInterventionKind
        for index in 0..<cap {
            store.apply(PaceInterventionOutcomeRecord(
                identifier: "approval-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                interventionKind: .actionApproval,
                outcome: .accepted,
                subject: "Approval #\(index)",
                provenanceSourceSystem: "requestUserApprovalForActionPlan"
            ))
        }
        // A single record for an unrelated interventionKind must not be
        // evicted by the other kind's full cap.
        store.apply(PaceInterventionOutcomeRecord(
            identifier: "undo-1",
            recordedAt: Date(timeIntervalSince1970: 500_000),
            interventionKind: .reversibleMutationUndo,
            outcome: .undone,
            subject: "Created a Reminder",
            provenanceSourceSystem: "triggerUndoLastMutation"
        ))
        let storedIdentifiers = Set(store.allRecords.map(\.identifier))
        #expect(storedIdentifiers.contains("undo-1"))
        #expect(storedIdentifiers.count == cap + 1)
    }

    // MARK: - Read-only retrieval (Slice 3)

    @Test func outcomeCountsReportsAcceptedAndDismissedForApprovalKind() {
        let store = PaceInterventionOutcomeStore()
        store.apply(PaceInterventionOutcomeRecord(
            recordedAt: Date(timeIntervalSince1970: 1),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval A",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        ))
        store.apply(PaceInterventionOutcomeRecord(
            recordedAt: Date(timeIntervalSince1970: 2),
            interventionKind: .actionApproval,
            outcome: .dismissed,
            subject: "Approval B",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        ))
        store.apply(PaceInterventionOutcomeRecord(
            recordedAt: Date(timeIntervalSince1970: 3),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval C",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        ))

        let counts = store.outcomeCounts(forInterventionKind: .actionApproval)
        #expect(counts.acceptedCount == 2)
        #expect(counts.dismissedCount == 1)
        #expect(counts.undoneCount == 0)
    }

    @Test func outcomeCountsReturnsZeroForInterventionKindWithNoRecordsRatherThanFabricatingARate() {
        let store = PaceInterventionOutcomeStore()
        #expect(store.outcomeCounts(forInterventionKind: .reversibleMutationUndo) == .zero)
    }

    @Test func outcomeCountsQueryNeverMutatesStoreContents() {
        let store = PaceInterventionOutcomeStore()
        store.apply(PaceInterventionOutcomeRecord(
            recordedAt: Date(timeIntervalSince1970: 1),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval A",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        ))
        let recordsBeforeQuery = store.allRecords

        _ = store.outcomeCounts(forInterventionKind: .actionApproval)
        _ = store.outcomeCounts(forInterventionKind: .reversibleMutationUndo)

        #expect(store.allRecords == recordsBeforeQuery)
    }

    // MARK: - Privacy-boundary field-set proof

    @Test func recordExposesOnlyTheDocumentedStructuralFields() {
        let record = PaceInterventionOutcomeRecord(
            recordedAt: Date(),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval summary",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        )
        let mirroredFieldNames = Set(Mirror(reflecting: record).children.compactMap(\.label))
        // If this fails, a new field was added to
        // `PaceInterventionOutcomeRecord` without deliberate review of
        // whether it could carry raw document/field/secure content.
        #expect(mirroredFieldNames == [
            "identifier",
            "recordedAt",
            "interventionKind",
            "outcome",
            "subject",
            "provenanceSourceSystem",
        ])
    }

    // MARK: - Durable persistence round trip

    @Test func persistenceStoreRoundTripsThroughATemporaryFile() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceInterventionOutcomeModelTests-\(UUID().uuidString)", isDirectory: true)
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("intervention-outcomes.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let persistenceStore = PaceInterventionOutcomePersistenceStore(fileURL: temporaryFileURL)
        #expect(persistenceStore.load().isEmpty)

        let recordToPersist = PaceInterventionOutcomeRecord(
            identifier: "outcome-persisted",
            recordedAt: Date(timeIntervalSince1970: 12_345),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval summary",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        )
        persistenceStore.save([recordToPersist])

        let reloadedRecords = persistenceStore.load()
        #expect(reloadedRecords == [recordToPersist])

        persistenceStore.clear()
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func persistenceStoreLoadReturnsEmptyForCorruptFileRatherThanThrowing() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceInterventionOutcomeModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("intervention-outcomes.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        try Data("not valid json".utf8).write(to: temporaryFileURL)
        let persistenceStore = PaceInterventionOutcomePersistenceStore(fileURL: temporaryFileURL)
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func persistenceStoreWithNilFileURLIsInertRatherThanCrashing() {
        let persistenceStore = PaceInterventionOutcomePersistenceStore(fileURL: nil)
        #expect(persistenceStore.load().isEmpty)
        persistenceStore.save([PaceInterventionOutcomeRecord(
            recordedAt: Date(),
            interventionKind: .actionApproval,
            outcome: .accepted,
            subject: "Approval summary",
            provenanceSourceSystem: "requestUserApprovalForActionPlan"
        )])
        persistenceStore.clear()
        #expect(persistenceStore.load().isEmpty)
    }

    @Test func storeRestoreRehydratesFromPersistedRecordsAndReappliesCap() {
        let store = PaceInterventionOutcomeStore()
        let cap = PaceInterventionOutcomeLimits.maximumStoredRecordCountPerInterventionKind
        let persistedRecords = (0..<(cap + 5)).map { index in
            PaceInterventionOutcomeRecord(
                identifier: "outcome-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)),
                interventionKind: .actionApproval,
                outcome: .accepted,
                subject: "Approval #\(index)",
                provenanceSourceSystem: "requestUserApprovalForActionPlan"
            )
        }
        store.restore(from: persistedRecords)
        #expect(store.allRecords.count == cap)
    }
}
