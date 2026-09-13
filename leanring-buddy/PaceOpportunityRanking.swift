//
//  PaceOpportunityRanking.swift
//  leanring-buddy
//
//  Slice 1 of the opportunity-ranking proposal
//  (openspec/changes/2026-09-13-add-opportunity-ranking): the missing half
//  of `proactive-companion-policy`'s already-accepted "resists repetition"
//  requirement (openspec/specs/proactive-companion-policy/spec.md, lines
//  31-36) — coalescing equivalent candidates, per-category cooldowns, and
//  ranking. None of this exists today; only `PaceRestraintGate`'s single
//  global cooldown does. `PaceProactiveNudgeOrchestrator` currently starts
//  three generators with zero cross-generator coordination (see
//  PaceProactiveNudgeFramework.swift / PaceProactiveNudges.swift) — if two
//  fire in the same tick, both can independently reach `.speak`.
//
//  Pure, I/O-free, nonisolated — mirrors PaceProactiveNudges.swift's style
//  (this operates on the same PaceProactiveUtterance/PaceRestraintDecision
//  types and sits in the same evaluation-tick pipeline) rather than the
//  durable-store shape of the two prior proposals in this series, since a
//  ranking decision is a per-tick computation, not a record worth
//  persisting.
//
//  Not yet wired into PaceProactiveNudgeOrchestrator — see design.md D1/D2
//  for the two owner-gated decisions before Slice 2 does that wiring.
//

import Foundation

// MARK: - Opportunity

/// One already-restraint-gate-approved candidate awaiting ranking.
///
/// A `PaceOpportunity` can only be constructed via
/// `init?(evaluation:category:now:)`, which returns `nil` whenever the
/// underlying `PaceProactiveNudgeEvaluation`'s decision was `.stayQuiet` (or
/// carried no utterance) — the type itself cannot represent a candidate the
/// restraint gate already refused, which is how this proposal enforces
/// "ranking never widens what the restraint gate already approved."
nonisolated struct PaceOpportunity: Equatable, Sendable {
    let identifier: String
    /// Coalescing/cooldown key — e.g. "focus-fatigue", "calendar-pre-meeting".
    /// Producer-supplied; this proposal defines no new categories, it only
    /// requires whatever string a future Slice 2 integration assigns per
    /// generator to be stable across ticks.
    let category: String
    let decision: PaceRestraintDecision
    let utterance: PaceProactiveUtterance
    let createdAt: Date

    init(
        identifier: String = UUID().uuidString,
        category: String,
        decision: PaceRestraintDecision,
        utterance: PaceProactiveUtterance,
        createdAt: Date
    ) {
        self.identifier = identifier
        self.category = category
        self.decision = decision
        self.utterance = utterance
        self.createdAt = createdAt
    }

    init?(
        evaluation: PaceProactiveNudgeEvaluation,
        category: String,
        now: Date
    ) {
        guard let utterance = evaluation.utterance else { return nil }
        switch evaluation.decision {
        case .speak, .queueUntilIdle:
            self.init(category: category, decision: evaluation.decision, utterance: utterance, createdAt: now)
        case .stayQuiet:
            return nil
        }
    }
}

// MARK: - Acceptance-history signal

/// Per design.md D1: no producer anywhere records a proactive-nudge-level
/// accepted/dismissed outcome today (nudges are spoken-only with no
/// dismiss gesture — the same reason
/// `openspec/changes/2026-09-13-add-outcome-feedback-telemetry`'s D1
/// deferred `ignored`/`edited` producers). This factor is always
/// `.unavailable` in this proposal rather than fabricated from an
/// unrelated signal.
nonisolated enum PaceOpportunityAcceptanceHistorySignal: Equatable, Sendable {
    case unavailable
}

// MARK: - Score

nonisolated struct PaceOpportunityScore: Equatable, Sendable {
    let relevance: Double
    let urgency: Double
    let confidence: Double
    let interruptionCost: Double
    let acceptanceHistory: PaceOpportunityAcceptanceHistorySignal
    let total: Double
}

// MARK: - Outcome + evidence

nonisolated enum PaceOpportunityOutcome: Equatable, Sendable {
    case emitted(score: PaceOpportunityScore)
    case coalescedInto(winnerIdentifier: String)
    case suppressedByCategoryCooldown(category: String, cooldownRemainingSeconds: TimeInterval)
    case expired
    case notSelectedByCap(score: PaceOpportunityScore)
}

nonisolated struct PaceOpportunityRankingRecord: Equatable, Sendable, Identifiable {
    let opportunity: PaceOpportunity
    let outcome: PaceOpportunityOutcome
    var id: String { opportunity.identifier }
}

/// Full result of one `PaceOpportunityRanker.rank(...)` call. `records`
/// retains every input candidate's fate — this IS the evidence trail
/// Slice 3's read-only query exposes.
nonisolated struct PaceOpportunityRankingResult: Equatable, Sendable {
    let winner: PaceOpportunity?
    let records: [PaceOpportunityRankingRecord]
}

// MARK: - Limits

/// Defaults per design.md D3.
nonisolated enum PaceOpportunityRankingLimits {
    /// Pace has exactly one voice channel; emitting more than one
    /// candidate per tick was an unintended gap, not a goal.
    static let maximumWinnersPerTick = 1
    /// Same-category candidates within one ranking call are always
    /// coalesced (they are effectively simultaneous); this window governs
    /// the *cross-tick* category cooldown instead (see
    /// `PaceOpportunityCategoryCooldownTracker`), chosen to match so the
    /// two mechanisms reinforce rather than fight each other.
    static let categoryCooldownIntervalSeconds: TimeInterval = 10 * 60
    /// Urgency saturates (reaches 1.0) once a candidate's own
    /// `relevanceWindowExpiresAt` is this close.
    static let urgencySaturationIntervalSeconds: TimeInterval = 30 * 60
}

/// Scoring weights. Sum to 1.0. `acceptanceHistory` carries zero weight in
/// this proposal since it is always `.unavailable` (D1) — see
/// `PaceOpportunityScore.acceptanceHistory`.
nonisolated enum PaceOpportunityRankingWeights {
    static let confidence = 0.4
    static let urgency = 0.3
    static let relevance = 0.2
    static let interruptionCost = 0.1
}

// MARK: - Category cooldown tracker

/// In-memory per-category last-emitted-at bookkeeping, mirroring
/// `PaceProactiveNudgeCooldown`'s existing per-generator shape
/// (`PaceProactiveNudgeFramework.swift`) generalized across categories
/// instead of within one generator. The caller owns a single instance
/// across ticks (e.g. one property on whatever orchestrates ranking) and
/// passes it `inout` to `PaceOpportunityRanker.rank`.
nonisolated struct PaceOpportunityCategoryCooldownTracker {
    private var lastEmittedAtByCategory: [String: Date] = [:]
    let cooldownIntervalSeconds: TimeInterval

    init(cooldownIntervalSeconds: TimeInterval = PaceOpportunityRankingLimits.categoryCooldownIntervalSeconds) {
        self.cooldownIntervalSeconds = cooldownIntervalSeconds
    }

    /// Returns the remaining cooldown in seconds if `category` is still
    /// cooling down at `now`, or `nil` if it's clear to emit.
    func remainingCooldownSeconds(forCategory category: String, now: Date) -> TimeInterval? {
        guard let lastEmittedAt = lastEmittedAtByCategory[category] else { return nil }
        let elapsed = now.timeIntervalSince(lastEmittedAt)
        guard elapsed < cooldownIntervalSeconds else { return nil }
        return cooldownIntervalSeconds - elapsed
    }

    mutating func markEmitted(category: String, at now: Date) {
        lastEmittedAtByCategory[category] = now
    }
}

// MARK: - Ranker

nonisolated enum PaceOpportunityRanker {
    /// Ranks one evaluation tick's worth of already-gate-approved
    /// candidates. Pure aside from mutating `categoryCooldownTracker` to
    /// record any winner's emission time.
    static func rank(
        candidates: [PaceOpportunity],
        activityGoalState: PaceActiveGoalState,
        categoryCooldownTracker: inout PaceOpportunityCategoryCooldownTracker,
        now: Date
    ) -> PaceOpportunityRankingResult {
        var records: [PaceOpportunityRankingRecord] = []

        // 1. Expire candidates whose own relevance window already elapsed.
        var liveCandidates: [PaceOpportunity] = []
        for candidate in candidates {
            if let expiresAt = candidate.utterance.relevanceWindowExpiresAt, expiresAt <= now {
                records.append(PaceOpportunityRankingRecord(opportunity: candidate, outcome: .expired))
            } else {
                liveCandidates.append(candidate)
            }
        }

        // 2. Suppress anything still inside its category's cooldown.
        var cooldownSurvivors: [PaceOpportunity] = []
        for candidate in liveCandidates {
            if let remaining = categoryCooldownTracker.remainingCooldownSeconds(forCategory: candidate.category, now: now) {
                records.append(PaceOpportunityRankingRecord(
                    opportunity: candidate,
                    outcome: .suppressedByCategoryCooldown(category: candidate.category, cooldownRemainingSeconds: remaining)
                ))
            } else {
                cooldownSurvivors.append(candidate)
            }
        }

        // 3. Score every survivor.
        let scoredSurvivors = cooldownSurvivors.map { candidate in
            (candidate, score(for: candidate, activityGoalState: activityGoalState, now: now))
        }

        // 4. Coalesce same-category candidates within this tick — keep
        //    only the highest-scored one per category.
        let groupedByCategory = Dictionary(grouping: scoredSurvivors, by: { $0.0.category })
        var coalescedWinners: [(PaceOpportunity, PaceOpportunityScore)] = []
        for group in groupedByCategory.values {
            let sortedGroup = group.sorted { $0.1.total > $1.1.total }
            guard let categoryWinner = sortedGroup.first else { continue }
            coalescedWinners.append(categoryWinner)
            for coalesced in sortedGroup.dropFirst() {
                records.append(PaceOpportunityRankingRecord(
                    opportunity: coalesced.0,
                    outcome: .coalescedInto(winnerIdentifier: categoryWinner.0.identifier)
                ))
            }
        }

        // 5. Cap across categories.
        let sortedOverall = coalescedWinners.sorted { $0.1.total > $1.1.total }
        let cap = PaceOpportunityRankingLimits.maximumWinnersPerTick
        let winners = Array(sortedOverall.prefix(cap))
        let notSelected = sortedOverall.dropFirst(cap)

        for (candidate, candidateScore) in winners {
            records.append(PaceOpportunityRankingRecord(opportunity: candidate, outcome: .emitted(score: candidateScore)))
            categoryCooldownTracker.markEmitted(category: candidate.category, at: now)
        }
        for (candidate, candidateScore) in notSelected {
            records.append(PaceOpportunityRankingRecord(opportunity: candidate, outcome: .notSelectedByCap(score: candidateScore)))
        }

        return PaceOpportunityRankingResult(winner: winners.first?.0, records: records)
    }

    private static func score(
        for candidate: PaceOpportunity,
        activityGoalState: PaceActiveGoalState,
        now: Date
    ) -> PaceOpportunityScore {
        let confidence = candidate.utterance.confidence
        let urgency = urgencyScore(for: candidate, now: now)
        let relevance = relevanceScore(for: candidate, activityGoalState: activityGoalState)
        let interruptionCost = interruptionCostScore(for: candidate)
        let acceptanceHistory = PaceOpportunityAcceptanceHistorySignal.unavailable

        let total = PaceOpportunityRankingWeights.confidence * confidence
            + PaceOpportunityRankingWeights.urgency * urgency
            + PaceOpportunityRankingWeights.relevance * relevance
            + PaceOpportunityRankingWeights.interruptionCost * (1 - interruptionCost)

        return PaceOpportunityScore(
            relevance: relevance,
            urgency: urgency,
            confidence: confidence,
            interruptionCost: interruptionCost,
            acceptanceHistory: acceptanceHistory,
            total: total
        )
    }

    /// Closer expiry → higher urgency, saturating at
    /// `urgencySaturationIntervalSeconds`. No expiry at all → neutral
    /// baseline (0.5) rather than either extreme.
    private static func urgencyScore(for candidate: PaceOpportunity, now: Date) -> Double {
        guard let expiresAt = candidate.utterance.relevanceWindowExpiresAt else { return 0.5 }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return 1.0 } // defensive; already-expired candidates are filtered out earlier
        let saturationInterval = PaceOpportunityRankingLimits.urgencySaturationIntervalSeconds
        let normalized = 1.0 - min(remaining, saturationInterval) / saturationInterval
        return max(0.0, min(1.0, normalized))
    }

    /// A narrow, explainable substring heuristic: a `.known` activity
    /// subject that textually appears in the candidate's category or
    /// spoken text boosts relevance; everything else (including
    /// `.unknown` activity state) gets the same neutral baseline. This can
    /// only ever boost, never penalize — it never asserts an opportunity is
    /// irrelevant, only that a specific match wasn't found.
    private static func relevanceScore(for candidate: PaceOpportunity, activityGoalState: PaceActiveGoalState) -> Double {
        guard case .known(let subject) = activityGoalState.subject else { return 0.5 }
        let haystack = "\(candidate.category) \(candidate.utterance.spokenText)".lowercased()
        return haystack.contains(subject.lowercased()) ? 1.0 : 0.5
    }

    /// The existing restraint gate already judged interruption cost when
    /// it produced `decision` — `.queueUntilIdle` means "not a good time to
    /// speak now," a coarse but real, already-computed signal this proposal
    /// reuses rather than re-deriving from restraint context this layer
    /// does not receive (see design.md D2).
    private static func interruptionCostScore(for candidate: PaceOpportunity) -> Double {
        switch candidate.decision {
        case .speak: return 0.2
        case .queueUntilIdle: return 0.8
        case .stayQuiet: return 1.0 // unreachable — PaceOpportunity's failable init excludes this case
        }
    }
}
