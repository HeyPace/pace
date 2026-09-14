//
//  PaceSurfaceProjectionTests.swift
//  leanring-buddyTests
//
//  Tests for the Gap #5 read-only surface projections
//  (PaceSurfaceProjection.swift): empty state, single/multiple candidates,
//  determinism, confidence boundaries, unavailable evidence, privacy
//  filtering (sensitive-topic exclusion, no literal result/error text),
//  and bounded output.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceSurfaceProjectionTests {
    // MARK: - Now: empty state

    @Test func nowProjectionIsEmptyWhenActivityUnknownAndNoRankingResult() {
        let state = PaceNowSurfaceProjection.project(
            activityGoalState: .unknown,
            mostRecentOpportunityRankingResult: nil
        )
        #expect(state == .empty)
    }

    @Test func nowProjectionNeverFabricatesAnActivitySubjectWhenUnknown() {
        // Even with a non-nil ranking result present, an .unknown activity
        // state must never produce a fabricated subject.
        let rankingResult = PaceOpportunityRankingResult(winner: nil, records: [])
        let state = PaceNowSurfaceProjection.project(
            activityGoalState: .unknown,
            mostRecentOpportunityRankingResult: rankingResult
        )
        #expect(state.activity == nil)
    }

    // MARK: - Now: single active state

    @Test func nowProjectionReflectsAKnownActivitySubjectAndConfidence() {
        let activityState = PaceActiveGoalState(
            subject: .known("Xcode"),
            confidence: 0.73,
            supportingObservationIds: ["obs-1"],
            contradictingObservationIds: []
        )
        let state = PaceNowSurfaceProjection.project(
            activityGoalState: activityState,
            mostRecentOpportunityRankingResult: nil
        )
        #expect(state.activity == PaceNowSurfaceActivity(subject: "Xcode", confidence: 0.73))
        #expect(state.opportunity == nil)
    }

    @Test func nowProjectionReflectsAtMostOneOpportunityFromTheRankingWinner() {
        let utterance = PaceProactiveUtterance(
            spokenText: "you've been on Figma for a while.",
            source: .watchNudge,
            confidence: 0.74,
            relevanceWindowExpiresAt: nil
        )
        let opportunity = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: utterance,
            createdAt: Date()
        )
        let rankingResult = PaceOpportunityRankingResult(
            winner: opportunity,
            records: [PaceOpportunityRankingRecord(
                opportunity: opportunity,
                outcome: .emitted(score: PaceOpportunityScore(
                    relevance: 0.5, urgency: 0.5, confidence: 0.74,
                    interruptionCost: 0.2, acceptanceHistory: .unavailable, total: 0.6
                ))
            )]
        )
        let state = PaceNowSurfaceProjection.project(
            activityGoalState: .unknown,
            mostRecentOpportunityRankingResult: rankingResult
        )
        #expect(state.opportunity == PaceNowSurfaceOpportunity(
            category: "focus-fatigue",
            spokenText: "you've been on Figma for a while.",
            confidence: 0.74
        ))
    }

    @Test func nowProjectionReportsNoOpportunityWhenRankingProducedNoWinner() {
        // A tick that was fully suppressed by cooldown still produces a
        // ranking result (with records) but no winner — the projection
        // must honestly report "no opportunity," not fabricate one from
        // the suppressed records.
        let utterance = PaceProactiveUtterance(
            spokenText: "suppressed", source: .watchNudge, confidence: 0.8, relevanceWindowExpiresAt: nil
        )
        let suppressed = PaceOpportunity(category: "focus-fatigue", decision: .speak, utterance: utterance, createdAt: Date())
        let rankingResult = PaceOpportunityRankingResult(
            winner: nil,
            records: [PaceOpportunityRankingRecord(
                opportunity: suppressed,
                outcome: .suppressedByCategoryCooldown(category: "focus-fatigue", cooldownRemainingSeconds: 120)
            )]
        )
        let state = PaceNowSurfaceProjection.project(
            activityGoalState: .unknown,
            mostRecentOpportunityRankingResult: rankingResult
        )
        #expect(state.opportunity == nil)
    }

    // MARK: - Now: determinism / confidence boundaries

    @Test func nowProjectionIsDeterministicForIdenticalInputs() {
        let activityState = PaceActiveGoalState(
            subject: .known("Slack"), confidence: 0.5, supportingObservationIds: [], contradictingObservationIds: []
        )
        let first = PaceNowSurfaceProjection.project(activityGoalState: activityState, mostRecentOpportunityRankingResult: nil)
        let second = PaceNowSurfaceProjection.project(activityGoalState: activityState, mostRecentOpportunityRankingResult: nil)
        #expect(first == second)
    }

    @Test func nowProjectionPassesThroughConfidenceBoundaryValues() {
        for boundaryConfidence in [0.0, 1.0] {
            let activityState = PaceActiveGoalState(
                subject: .known("Mail"), confidence: boundaryConfidence,
                supportingObservationIds: [], contradictingObservationIds: []
            )
            let state = PaceNowSurfaceProjection.project(activityGoalState: activityState, mostRecentOpportunityRankingResult: nil)
            #expect(state.activity?.confidence == boundaryConfidence)
        }
    }

    // MARK: - Working: empty / single / multiple / bounded

    @Test func workingProjectionIsEmptyWithNoTasks() {
        #expect(PaceWorkingSurfaceProjection.project(backgroundAgentTasks: []) == .empty)
    }

    @Test func workingProjectionReflectsASingleRunningTask() {
        let task = PaceBackgroundAgentTask(
            id: "bg-1", displayName: "Research competitors", prompt: "irrelevant to projection",
            priority: .normal, state: .running, startedAt: Date(), completedAt: nil,
            resultSummary: nil, stepCount: 1, currentStepDescription: "Searching..."
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [task])
        #expect(state.tasks.count == 1)
        #expect(state.tasks.first?.id == "bg-1")
        #expect(state.tasks.first?.state == .running)
        #expect(state.tasks.first?.currentStepDescription == "Searching...")
        #expect(state.tasks.first?.hasResult == false)
    }

    @Test func workingProjectionOrdersMostRecentlyStartedFirst() {
        let olderTask = PaceBackgroundAgentTask(
            id: "bg-old", displayName: "Older", prompt: "", priority: .normal, state: .completed,
            startedAt: Date(timeIntervalSince1970: 1_000), completedAt: nil, resultSummary: "done",
            stepCount: 1, currentStepDescription: nil
        )
        let newerTask = PaceBackgroundAgentTask(
            id: "bg-new", displayName: "Newer", prompt: "", priority: .normal, state: .running,
            startedAt: Date(timeIntervalSince1970: 2_000), completedAt: nil, resultSummary: nil,
            stepCount: 1, currentStepDescription: nil
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [olderTask, newerTask])
        #expect(state.tasks.map(\.id) == ["bg-new", "bg-old"])
    }

    @Test func workingProjectionBoundsOutputToTheConfiguredCap() {
        let manyTasks = (0..<(PaceWorkingSurfaceLimits.maximumProjectedTaskCount + 10)).map { index in
            PaceBackgroundAgentTask(
                id: "bg-\(index)", displayName: "Task \(index)", prompt: "", priority: .normal,
                state: .completed, startedAt: Date(timeIntervalSince1970: Double(index)), completedAt: nil,
                resultSummary: nil, stepCount: 1, currentStepDescription: nil
            )
        }
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: manyTasks)
        #expect(state.tasks.count == PaceWorkingSurfaceLimits.maximumProjectedTaskCount)
        // Uniqueness: bounded output must not contain duplicate ids.
        #expect(Set(state.tasks.map(\.id)).count == state.tasks.count)
    }

    @Test func workingProjectionNeverExposesLiteralResultOrFailureText() {
        let succeededTask = PaceBackgroundAgentTask(
            id: "bg-ok", displayName: "Draft email", prompt: "", priority: .normal, state: .completed,
            startedAt: Date(), completedAt: Date(), resultSummary: "Dear Jane, here is the sensitive draft...",
            stepCount: 1, currentStepDescription: "Done"
        )
        let failedTask = PaceBackgroundAgentTask(
            id: "bg-fail", displayName: "Failing task", prompt: "", priority: .normal,
            state: .failed("internal error at /Users/hani/secret/path"), startedAt: Date(), completedAt: Date(),
            resultSummary: nil, stepCount: 1, currentStepDescription: nil
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [succeededTask, failedTask])

        // The projected type has no field that could carry the literal
        // resultSummary or failure-detail string — this is a type-level
        // guarantee, not just a runtime check, but assert the runtime
        // shape too: hasResult reflects presence, never content.
        let succeeded = state.tasks.first { $0.id == "bg-ok" }
        #expect(succeeded?.hasResult == true)
        let failed = state.tasks.first { $0.id == "bg-fail" }
        #expect(failed?.state == .failed)
        #expect(failed?.hasResult == false)
    }

    // MARK: - Memory: empty / single / multiple / bounded / privacy

    @Test func memoryProjectionIsEmptyWithNoFacts() {
        #expect(PaceMemorySurfaceProjection.project(episodicFacts: []) == .empty)
    }

    @Test func memoryProjectionReflectsASingleFact() {
        let fact = PaceEpisodicFact(
            identifier: "fact-1", extractedAt: Date(), subject: "user", predicate: "prefers",
            value: "dark mode", confidence: 0.9, expiresAt: nil, topicHashtags: ["#preference"], sourceTurnId: nil
        )
        let state = PaceMemorySurfaceProjection.project(episodicFacts: [fact])
        #expect(state.facts.count == 1)
        #expect(state.facts.first == PaceMemorySurfaceFact(
            id: "fact-1", subject: "user", predicate: "prefers", value: "dark mode", confidence: 0.9
        ))
    }

    @Test func memoryProjectionExcludesSensitiveTopicFactsEvenWhenPassedDirectly() {
        let sensitiveFact = PaceEpisodicFact(
            identifier: "fact-sensitive", extractedAt: Date(), subject: "user's mother", predicate: "is in",
            value: "the hospital", confidence: 0.8, expiresAt: nil, topicHashtags: ["#health"], sourceTurnId: nil
        )
        let nonSensitiveFact = PaceEpisodicFact(
            identifier: "fact-normal", extractedAt: Date(), subject: "user", predicate: "prefers",
            value: "dark mode", confidence: 0.9, expiresAt: nil, topicHashtags: ["#preference"], sourceTurnId: nil
        )
        // Deliberately pass BOTH facts directly (as if a caller forgot to
        // pre-filter) — the projection must still exclude the sensitive one.
        let state = PaceMemorySurfaceProjection.project(episodicFacts: [sensitiveFact, nonSensitiveFact])
        #expect(state.facts.map(\.id) == ["fact-normal"])
    }

    @Test func memoryProjectionBoundsOutputToTheConfiguredCap() {
        let manyFacts = (0..<(PaceMemorySurfaceLimits.maximumProjectedFactCount + 10)).map { index in
            PaceEpisodicFact(
                identifier: "fact-\(index)", extractedAt: Date(timeIntervalSince1970: Double(index)),
                subject: "user", predicate: "likes", value: "topic \(index)", confidence: 0.5,
                expiresAt: nil, topicHashtags: [], sourceTurnId: nil
            )
        }
        let state = PaceMemorySurfaceProjection.project(episodicFacts: manyFacts)
        #expect(state.facts.count == PaceMemorySurfaceLimits.maximumProjectedFactCount)
        #expect(Set(state.facts.map(\.id)).count == state.facts.count)
    }

    @Test func memoryProjectionIsDeterministicForIdenticalInputs() {
        let facts = [PaceEpisodicFact(
            identifier: "fact-1", extractedAt: Date(timeIntervalSince1970: 1_000), subject: "user",
            predicate: "prefers", value: "dark mode", confidence: 0.9, expiresAt: nil,
            topicHashtags: [], sourceTurnId: nil
        )]
        let first = PaceMemorySurfaceProjection.project(episodicFacts: facts)
        let second = PaceMemorySurfaceProjection.project(episodicFacts: facts)
        #expect(first == second)
    }
}
