//
//  PaceSurfaceProjection.swift
//  leanring-buddy
//
//  Deterministic, read-only Gap #5 foundation
//  (docs/current/plans/autonomous-companion-consolidation.md, "5.
//  Product-surface consolidation" — Now / Working / Memory). Each
//  projection is a pure function composing an EXISTING, already-shipped
//  production model — never a new source of truth:
//
//    NOW      <- PaceActivityGoalStore (Slices 1-2, 2026-09-13/14) +
//                PaceProactiveNudgeOrchestrator.mostRecentRankingResult
//                (opportunity-ranking, 2026-09-13/14)
//    WORKING  <- PaceBackgroundAgentRunner (pre-existing; no UI consumed
//                it before this file)
//    MEMORY   <- PaceEpisodicFactStore (pre-existing)
//
//  No new persistence, no new durable state, no new capture surface. This
//  file only reshapes what already exists into the three surfaces the
//  consolidation plan names — the actual Now/Working/Memory UI (Gap #5's
//  remaining, genuinely UX-decision-dependent work) is NOT built here; see
//  docs/product/consolidation-dogfood.md for what evidence is still
//  pending before that UI is designed.
//
//  Privacy: every field below was individually reviewed against "is it
//  sensitive, does it need to persist, does it need to reach the UI" (see
//  the per-surface comments). Nothing here is model-authored free text
//  presented as authoritative fact — activity subjects are `observed`-only
//  today (Slice 2's app-transition producer), and MEMORY reuses the
//  existing sensitive-topic exclusion rather than re-implementing it, so a
//  future bug in that exclusion can't silently un-gate this projection.
//

import Foundation

// MARK: - Now

/// A non-empty, known activity subject with its confidence. `nil` at the
/// `PaceNowSurfaceState.activity` call site means "unknown" — the caller
/// must never fabricate a subject when the underlying `PaceActiveGoalState`
/// reports `.unknown`.
nonisolated struct PaceNowSurfaceActivity: Equatable, Sendable {
    let subject: String
    let confidence: Double
}

/// At most one opportunity — the same cap `PaceOpportunityRanker` already
/// enforces (`PaceOpportunityRankingLimits.maximumWinnersPerTick == 1`).
/// `spokenText` is the exact utterance already destined for TTS (already
/// judged safe to say aloud to the user by the existing generator/gate
/// pipeline) — this is not a new content-exposure surface, only a second
/// (visual) presentation of speech that already happens.
nonisolated struct PaceNowSurfaceOpportunity: Equatable, Sendable {
    let category: String
    let spokenText: String
    let confidence: Double
}

nonisolated struct PaceNowSurfaceState: Equatable, Sendable {
    let activity: PaceNowSurfaceActivity?
    let opportunity: PaceNowSurfaceOpportunity?

    static let empty = PaceNowSurfaceState(activity: nil, opportunity: nil)
}

nonisolated enum PaceNowSurfaceProjection {
    /// `mostRecentOpportunityRankingResult` is `nil` before any nudge
    /// evaluation has ever run in this session — reported as "no
    /// opportunity" rather than treated as an error.
    static func project(
        activityGoalState: PaceActiveGoalState,
        mostRecentOpportunityRankingResult: PaceOpportunityRankingResult?
    ) -> PaceNowSurfaceState {
        let activity: PaceNowSurfaceActivity?
        if case .known(let subject) = activityGoalState.subject {
            activity = PaceNowSurfaceActivity(subject: subject, confidence: activityGoalState.confidence)
        } else {
            activity = nil
        }

        let opportunity: PaceNowSurfaceOpportunity?
        if let winner = mostRecentOpportunityRankingResult?.winner {
            opportunity = PaceNowSurfaceOpportunity(
                category: winner.category,
                spokenText: winner.utterance.spokenText,
                confidence: winner.utterance.confidence
            )
        } else {
            opportunity = nil
        }

        return PaceNowSurfaceState(activity: activity, opportunity: opportunity)
    }
}

// MARK: - Working

nonisolated enum PaceWorkingSurfaceTaskState: Equatable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed
}

/// Deliberately excludes `PaceBackgroundAgentTask.resultSummary` (planner-
/// produced free text — could contain anything the background task
/// touched, e.g. a drafted email body) and the `.failed(String)` error
/// detail (could contain an internal error path). No UI has ever consumed
/// `PaceBackgroundAgentRunner` before this file, so no prior design
/// decision approved surfacing that literal content — `hasResult` reports
/// only whether a result exists, not what it says. Showing the actual
/// result/error text is a real Gap #5 UX decision, not plumbing.
nonisolated struct PaceWorkingSurfaceTask: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let state: PaceWorkingSurfaceTaskState
    let currentStepDescription: String?
    let startedAt: Date?
    let hasResult: Bool
}

nonisolated struct PaceWorkingSurfaceState: Equatable, Sendable {
    let tasks: [PaceWorkingSurfaceTask]

    static let empty = PaceWorkingSurfaceState(tasks: [])
}

nonisolated enum PaceWorkingSurfaceLimits {
    /// `PaceBackgroundAgentRunner.tasks` has no cap of its own (it relies
    /// on `clearCompleted()` being called); this projection bounds its own
    /// output defensively regardless of how large the source array grows.
    static let maximumProjectedTaskCount = 20
}

nonisolated enum PaceWorkingSurfaceProjection {
    static func project(backgroundAgentTasks: [PaceBackgroundAgentTask]) -> PaceWorkingSurfaceState {
        let projectedTasks = backgroundAgentTasks
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .prefix(PaceWorkingSurfaceLimits.maximumProjectedTaskCount)
            .map { task -> PaceWorkingSurfaceTask in
                let projectedState: PaceWorkingSurfaceTaskState
                switch task.state {
                case .queued: projectedState = .queued
                case .running: projectedState = .running
                case .completed: projectedState = .completed
                case .cancelled: projectedState = .cancelled
                case .failed: projectedState = .failed
                }
                return PaceWorkingSurfaceTask(
                    id: task.id,
                    displayName: task.displayName,
                    state: projectedState,
                    currentStepDescription: task.currentStepDescription,
                    startedAt: task.startedAt,
                    hasResult: task.resultSummary?.isEmpty == false
                )
            }
        return PaceWorkingSurfaceState(tasks: Array(projectedTasks))
    }
}

// MARK: - Memory

/// Mirrors `PaceEpisodicFact`'s structural fields only (no
/// `sourceTurnId`/`topicHashtags` — internal bookkeeping, not user-facing).
nonisolated struct PaceMemorySurfaceFact: Equatable, Sendable, Identifiable {
    let id: String
    let subject: String
    let predicate: String
    let value: String
    let confidence: Double
}

nonisolated struct PaceMemorySurfaceState: Equatable, Sendable {
    let facts: [PaceMemorySurfaceFact]

    static let empty = PaceMemorySurfaceState(facts: [])
}

nonisolated enum PaceMemorySurfaceLimits {
    /// Independent of `PaceEpisodicMemoryLimits.maximumStoredFactCount`
    /// (200) — this bounds what one projection call returns, not what the
    /// store retains.
    static let maximumProjectedFactCount = 50
}

nonisolated enum PaceMemorySurfaceProjection {
    /// Re-applies `PaceEpisodicSensitiveTopics`'s exclusion itself rather
    /// than trusting the caller to have already filtered — defense in
    /// depth: a caller that mistakenly passes `store.allFacts` (instead of
    /// `store.factsForInjection(includeSensitiveTopics: false)`) still
    /// cannot leak a sensitive-topic fact through this projection.
    static func project(episodicFacts: [PaceEpisodicFact]) -> PaceMemorySurfaceState {
        let nonSensitiveFacts = episodicFacts.filter { !PaceEpisodicSensitiveTopics.isFactSensitive($0) }
        let projectedFacts = nonSensitiveFacts
            .sorted { $0.extractedAt > $1.extractedAt }
            .prefix(PaceMemorySurfaceLimits.maximumProjectedFactCount)
            .map { fact in
                PaceMemorySurfaceFact(
                    id: fact.identifier,
                    subject: fact.subject,
                    predicate: fact.predicate,
                    value: fact.value,
                    confidence: fact.confidence
                )
            }
        return PaceMemorySurfaceState(facts: Array(projectedFacts))
    }
}
