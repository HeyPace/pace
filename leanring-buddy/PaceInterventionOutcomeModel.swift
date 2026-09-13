//
//  PaceInterventionOutcomeModel.swift
//  leanring-buddy
//
//  Slice 1 of the outcome-feedback-telemetry proposal
//  (openspec/changes/2026-09-13-add-outcome-feedback-telemetry): a typed,
//  bounded record of what happened after Pace suggested or acted — was it
//  accepted, dismissed, or undone (this proposal's scope; `ignored`/
//  `edited`/`completed` are deferred, see design.md D1).
//
//  This answers a question none of the existing memory tiers answer:
//  `PaceActivityGoalModel.swift` answers "what is the user's active
//  outcome"; this answers "what happened after Pace intervened." Shape
//  mirrors `PaceActivityObservation`/`PaceActivityGoalStore`, but retention
//  is capped per `interventionKind` rather than per free-form subject
//  (see design.md D2 — approval/undo subjects are near-unique summaries,
//  so a per-subject cap would not bound anything meaningfully here).
//
//  I/O-free: durable persistence lives in
//  PaceInterventionOutcomePersistenceStore.swift, mirroring
//  PaceActivityGoalPersistenceStore.swift.
//

import Foundation

// MARK: - Intervention kind

/// Which existing decision point produced this outcome record. Each case
/// corresponds to a real, already-computed decision in the app — never an
/// invented capture surface (see design.md's Non-Goals).
enum PaceInterventionKind: String, Codable, Equatable, Sendable {
    /// The action-approval `NSAlert` (`requestUserApprovalForActionPlan`).
    case actionApproval
    /// The undo-banner tap (`triggerUndoLastMutation`).
    case reversibleMutationUndo
}

// MARK: - Outcome

/// The outcome this proposal can source with zero new capture.
/// `ignored`/`edited`/`completed` are deferred to a later slice — see
/// design.md D1.
enum PaceInterventionOutcome: String, Codable, Equatable, Sendable {
    case accepted
    case dismissed
    case undone
}

// MARK: - Record

/// One append-only record of an intervention outcome. Never carries
/// document/field/secure content — only the structural summary text
/// already shown to the user in-session (an approval or undo summary).
struct PaceInterventionOutcomeRecord: Codable, Equatable, Identifiable, Sendable {
    let identifier: String
    let recordedAt: Date
    let interventionKind: PaceInterventionKind
    let outcome: PaceInterventionOutcome
    /// The human-readable summary already shown to the user (e.g. the
    /// approval alert's summary, or the reversible action's summary) —
    /// never the underlying action's content.
    let subject: String
    let provenanceSourceSystem: String

    var id: String { identifier }

    init(
        identifier: String = UUID().uuidString,
        recordedAt: Date,
        interventionKind: PaceInterventionKind,
        outcome: PaceInterventionOutcome,
        subject: String,
        provenanceSourceSystem: String
    ) {
        self.identifier = identifier
        self.recordedAt = recordedAt
        self.interventionKind = interventionKind
        self.outcome = outcome
        self.subject = subject
        self.provenanceSourceSystem = provenanceSourceSystem
    }
}

// MARK: - Query result

/// Outcome counts for one `interventionKind`, returned by the read-only
/// query (Slice 3). All three counts are always present; a kind that
/// cannot produce a given outcome (e.g. `actionApproval` never produces
/// `undone`) simply reports zero for it rather than omitting the field.
struct PaceInterventionOutcomeCounts: Equatable, Sendable {
    let acceptedCount: Int
    let dismissedCount: Int
    let undoneCount: Int

    static let zero = PaceInterventionOutcomeCounts(acceptedCount: 0, dismissedCount: 0, undoneCount: 0)
}

// MARK: - Limits

/// Bounds for outcome-record retention, per design.md D3.
enum PaceInterventionOutcomeLimits {
    /// 200 mirrors `PaceActivityGoalLimits`/`PaceEpisodicMemoryLimits`'s
    /// existing 200-cap convention — but scoped per `interventionKind`
    /// (a small closed set), not per subject, since subjects here are
    /// near-unique human-readable summaries that rarely repeat verbatim.
    static let maximumStoredRecordCountPerInterventionKind: Int = 200
}

// MARK: - Store

/// In-memory storage of `PaceInterventionOutcomeRecord`s, capped per
/// `interventionKind`. An outcome record is a settled historical fact the
/// moment it is written — unlike `PaceActivityGoalStore`, there is no
/// "current state" to derive and no staleness clock.
final class PaceInterventionOutcomeStore {
    private var recordsById: [String: PaceInterventionOutcomeRecord] = [:]

    var allRecords: [PaceInterventionOutcomeRecord] {
        recordsById.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Insert a record through the per-`interventionKind` retention cap.
    func apply(_ incomingRecord: PaceInterventionOutcomeRecord) {
        recordsById[incomingRecord.identifier] = incomingRecord
        enforcePerInterventionKindRetentionCap(interventionKind: incomingRecord.interventionKind)
    }

    /// Read-only query (Slice 3's retrieval surface). Never mutates the
    /// store. Returns `.zero` rather than a fabricated rate when no
    /// records exist for the queried kind.
    func outcomeCounts(forInterventionKind interventionKind: PaceInterventionKind) -> PaceInterventionOutcomeCounts {
        let matchingRecords = recordsById.values.filter { $0.interventionKind == interventionKind }
        guard !matchingRecords.isEmpty else { return .zero }
        return PaceInterventionOutcomeCounts(
            acceptedCount: matchingRecords.filter { $0.outcome == .accepted }.count,
            dismissedCount: matchingRecords.filter { $0.outcome == .dismissed }.count,
            undoneCount: matchingRecords.filter { $0.outcome == .undone }.count
        )
    }

    /// Replace the store's contents wholesale — used by the persistence
    /// store to rehydrate on launch. Re-applies the per-kind cap once,
    /// defensively, in case the bound changed between app versions.
    func restore(from persistedRecords: [PaceInterventionOutcomeRecord]) {
        recordsById.removeAll()
        for record in persistedRecords {
            recordsById[record.identifier] = record
        }
        let distinctInterventionKinds = Set(recordsById.values.map(\.interventionKind))
        for interventionKind in distinctInterventionKinds {
            enforcePerInterventionKindRetentionCap(interventionKind: interventionKind)
        }
    }

    /// Drop the oldest records for this `interventionKind` until back
    /// under the cap. Mirrors `PaceActivityGoalStore.enforcePerSubjectRetentionCap`,
    /// scoped by kind instead of subject (see design.md D2).
    private func enforcePerInterventionKindRetentionCap(interventionKind: PaceInterventionKind) {
        let matchingRecords = recordsById.values.filter { $0.interventionKind == interventionKind }
        let cap = PaceInterventionOutcomeLimits.maximumStoredRecordCountPerInterventionKind
        guard matchingRecords.count > cap else { return }
        let sortedOldestFirst = matchingRecords.sorted { $0.recordedAt < $1.recordedAt }
        let overflowCount = matchingRecords.count - cap
        for evictedRecord in sortedOldestFirst.prefix(overflowCount) {
            recordsById.removeValue(forKey: evictedRecord.identifier)
        }
    }
}
