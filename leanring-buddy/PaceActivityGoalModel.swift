//
//  PaceActivityGoalModel.swift
//  leanring-buddy
//
//  Slice 1 of the activity-goal-model proposal
//  (openspec/changes/2026-09-13-add-activity-goal-model): a typed,
//  provenance-bearing observation of what the user appears to be doing,
//  and a derived current-state hypothesis over a set of observations.
//
//  This answers a question none of the existing memory tiers answer:
//  `PaceEpisodicFactStore` (PaceEpisodicMemory.swift) stores "what is true",
//  and `temporal-world-model` stores "where is this object" — neither
//  represents "what is the user's active outcome, and how confident are we."
//
//  Shape mirrors `PaceEpisodicFact`/`PaceEpisodicFactStore`'s dedup/cap
//  discipline, but the consistency model is deliberately different (see
//  design.md D2): a correction is a new observation carrying
//  `supersedesObservationId` rather than a separate tombstone list, and the
//  current-state derivation retains supporting AND contradicting evidence
//  instead of doing a simple replace-in-place.
//
//  I/O-free: durable persistence lives in
//  PaceActivityGoalPersistenceStore.swift, mirroring how PaceMemoryStore.swift
//  keeps PaceMemoryIndex I/O-free.
//

import Foundation

// MARK: - Evidence kind

/// The four evidence kinds required by
/// `docs/current/plans/autonomous-companion-consolidation.md`'s "clear
/// distinction between observation, inference, user-stated intent, and an
/// authorized task." Only `.observed` has a producer in this proposal (the
/// frontmost-app/window-transition hook in `PaceAppUsageTracker`); the other
/// three are modeled now so the schema never needs to change to add a
/// producer later (see design.md D1).
enum PaceActivityEvidenceKind: String, Codable, Equatable, Sendable {
    /// A deterministic runtime/perception signal.
    case observed
    /// A deterministic heuristic correlating multiple observed signals.
    case inferred
    /// An explicit statement from the user (e.g. "I'm working on X").
    case userStated
    /// An approved, execution-backed task run.
    case authorizedTask

    /// `userStated` and `authorizedTask` evidence never auto-expires on the
    /// staleness clock — see design.md D3. It only stops being current via
    /// explicit correction (a new observation with `supersedesObservationId`
    /// set) or its own `expiresAt`.
    var autoExpiresOnStalenessClock: Bool {
        switch self {
        case .observed, .inferred:
            return true
        case .userStated, .authorizedTask:
            return false
        }
    }
}

// MARK: - Observation

/// One append-only, typed evidence record about the user's active activity
/// or goal. Never carries document/field/secure content — only structural
/// metadata (e.g. an application name), per design.md's privacy boundary.
struct PaceActivityObservation: Codable, Equatable, Identifiable, Sendable {
    let identifier: String
    let recordedAt: Date
    let evidenceKind: PaceActivityEvidenceKind
    /// What the observation is about — e.g. the frontmost application name
    /// for the Slice 2 producer. Structural metadata only.
    let subject: String
    let confidence: Double
    let provenanceSourceSystem: String
    let provenanceEvidenceReferenceId: String?
    /// Explicit expiry. Independent of the staleness clock: an
    /// `authorizedTask` observation can still carry an `expiresAt` if the
    /// authorization itself was time-boxed.
    let expiresAt: Date?
    /// Non-nil exactly when this observation is a correction: it names the
    /// prior observation it supersedes. The superseded observation is never
    /// deleted (per the accepted spec's "corrections supersede rather than
    /// erase" requirement) — it simply stops counting as active evidence.
    let supersedesObservationId: String?

    var id: String { identifier }

    init(
        identifier: String = UUID().uuidString,
        recordedAt: Date,
        evidenceKind: PaceActivityEvidenceKind,
        subject: String,
        confidence: Double,
        provenanceSourceSystem: String,
        provenanceEvidenceReferenceId: String? = nil,
        expiresAt: Date? = nil,
        supersedesObservationId: String? = nil
    ) {
        self.identifier = identifier
        self.recordedAt = recordedAt
        self.evidenceKind = evidenceKind
        self.subject = subject
        self.confidence = confidence
        self.provenanceSourceSystem = provenanceSourceSystem
        self.provenanceEvidenceReferenceId = provenanceEvidenceReferenceId
        self.expiresAt = expiresAt
        self.supersedesObservationId = supersedesObservationId
    }
}

// MARK: - Derived current state

/// The current activity/goal-state hypothesis derived from a set of
/// observations. Mirrors `temporal-world-model`'s "current state remains
/// linked to evidence" shape: it never discards which observations support
/// or contradict it, and reports `.unknown` rather than a stale guess when
/// evidence is insufficient.
struct PaceActiveGoalState: Equatable, Sendable {
    enum Subject: Equatable, Sendable {
        case unknown
        case known(String)
    }

    let subject: Subject
    let confidence: Double
    let supportingObservationIds: [String]
    let contradictingObservationIds: [String]

    static let unknown = PaceActiveGoalState(
        subject: .unknown,
        confidence: 0,
        supportingObservationIds: [],
        contradictingObservationIds: []
    )
}

// MARK: - Derivation

/// Bounds and defaults for activity-goal retention and staleness, per
/// design.md D3.
enum PaceActivityGoalLimits {
    /// 200 mirrors `PaceEpisodicMemoryLimits.maximumStoredFactCount` for
    /// consistency across memory kinds — but scoped per subject here (the
    /// accepted spec's retention requirement is per-subject, not global),
    /// since an unrelated subject's observation volume must never crowd out
    /// this one's history.
    static let maximumStoredObservationCountPerSubject: Int = 200
    /// Long enough that a real context switch is reflected quickly, short
    /// enough that transient app-switching does not thrash the derived
    /// state.
    static let defaultFreshnessWindowInSeconds: TimeInterval = 30 * 60
}

/// Pure derivation logic, pulled out so tests can drive it without a store.
enum PaceActivityGoalStateDerivation {
    static func derive(
        from observations: [PaceActivityObservation],
        now: Date,
        freshnessWindowInSeconds: TimeInterval = PaceActivityGoalLimits.defaultFreshnessWindowInSeconds
    ) -> PaceActiveGoalState {
        let supersededObservationIds = Set(observations.compactMap { $0.supersedesObservationId })

        let nonExpired = observations.filter { observation in
            guard let expiresAt = observation.expiresAt else { return true }
            return expiresAt > now
        }

        // "Active" evidence: not itself superseded, not explicitly expired,
        // and — for the two evidence kinds that decay on the staleness clock
        // — corroborated by some same-subject observation still inside the
        // freshness window. A `userStated`/`authorizedTask` observation is
        // active until superseded or explicitly expired; it never ages out
        // on this clock (per design.md D3 / the accepted spec).
        let activeEvidence = nonExpired.filter { observation in
            guard !supersededObservationIds.contains(observation.identifier) else { return false }
            guard observation.evidenceKind.autoExpiresOnStalenessClock else { return true }
            return nonExpired.contains { candidate in
                !supersededObservationIds.contains(candidate.identifier)
                    && candidate.subject == observation.subject
                    && now.timeIntervalSince(candidate.recordedAt) <= freshnessWindowInSeconds
                    && now.timeIntervalSince(candidate.recordedAt) >= 0
            }
        }

        guard !activeEvidence.isEmpty else {
            return .unknown
        }

        // Highest confidence wins; ties broken by recency. Mirrors the
        // accepted spec's "a higher-confidence observation names a
        // different active subject" supersession scenario.
        let topObservation = activeEvidence.max { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence < rhs.confidence
            }
            return lhs.recordedAt < rhs.recordedAt
        }!

        let supportingObservations = activeEvidence.filter { $0.subject == topObservation.subject }
        let contradictingObservations = activeEvidence.filter { $0.subject != topObservation.subject }

        return PaceActiveGoalState(
            subject: .known(topObservation.subject),
            confidence: topObservation.confidence,
            supportingObservationIds: supportingObservations.map(\.identifier).sorted(),
            contradictingObservationIds: contradictingObservations.map(\.identifier).sorted()
        )
    }
}

// MARK: - Store

/// Outcome of applying an observation, surfaced so callers can log/audit
/// without re-querying the store.
enum PaceActivityGoalStoreApplyOutcome: Equatable {
    case inserted
    case insertedAsCorrection(supersedesObservationId: String)
}

/// In-memory storage of `PaceActivityObservation`s plus the per-subject
/// retention cap. A correction is just an observation with
/// `supersedesObservationId` set — there is no separate tombstone list,
/// since nothing is ever deleted by a correction (see design.md D2/the
/// type's doc comment).
final class PaceActivityGoalStore {
    private var observationsById: [String: PaceActivityObservation] = [:]
    private var now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var allObservations: [PaceActivityObservation] {
        observationsById.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Insert an observation through the per-subject retention cap.
    @discardableResult
    func apply(_ incomingObservation: PaceActivityObservation) -> PaceActivityGoalStoreApplyOutcome {
        observationsById[incomingObservation.identifier] = incomingObservation
        enforcePerSubjectRetentionCap(subject: incomingObservation.subject)
        if let supersedesObservationId = incomingObservation.supersedesObservationId {
            return .insertedAsCorrection(supersedesObservationId: supersedesObservationId)
        }
        return .inserted
    }

    /// Read-only current-state query (Slice 3's retrieval surface). Never
    /// mutates the store.
    func currentGoalState() -> PaceActiveGoalState {
        PaceActivityGoalStateDerivation.derive(from: allObservations, now: now())
    }

    /// Replace the store's contents wholesale — used by the persistence
    /// store to rehydrate on launch. Bypasses the cap check per insert
    /// (the persisted set was already within bounds when it was saved) but
    /// still normalizes through the cap once, defensively, in case the
    /// bound itself changed between app versions.
    func restore(from persistedObservations: [PaceActivityObservation]) {
        observationsById.removeAll()
        for observation in persistedObservations {
            observationsById[observation.identifier] = observation
        }
        let distinctSubjects = Set(observationsById.values.map(\.subject))
        for subject in distinctSubjects {
            enforcePerSubjectRetentionCap(subject: subject)
        }
    }

    /// Drop the oldest observations for this subject until back under the
    /// per-subject cap. Mirrors `PaceEpisodicFactStore.enforceLRUCap`: a
    /// correction's superseded observation is not specially protected here
    /// — it can still age out under the cap over time, exactly like an
    /// episodic fact can. "Corrections supersede rather than erase" governs
    /// the correction operation itself, not long-run retention bounding.
    private func enforcePerSubjectRetentionCap(subject: String) {
        let subjectObservations = observationsById.values.filter { $0.subject == subject }
        let cap = PaceActivityGoalLimits.maximumStoredObservationCountPerSubject
        guard subjectObservations.count > cap else { return }
        let sortedOldestFirst = subjectObservations.sorted { $0.recordedAt < $1.recordedAt }
        let overflowCount = subjectObservations.count - cap
        for evictedObservation in sortedOldestFirst.prefix(overflowCount) {
            observationsById.removeValue(forKey: evictedObservation.identifier)
        }
    }
}
