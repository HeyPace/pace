//
//  PaceOpportunityRankingTests.swift
//  leanring-buddyTests
//
//  Slice 1 tests for the opportunity-ranking proposal
//  (openspec/changes/2026-09-13-add-opportunity-ranking): coalescing,
//  category cooldowns, cap enforcement, expiry, the honest
//  acceptance-history-unavailable signal, and the type-level guarantee
//  that a gate-refused candidate can never become a `PaceOpportunity`.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceOpportunityRankingTests {
    private let referenceNow = Date(timeIntervalSince1970: 1_000_000)

    private func makeUtterance(
        spokenText: String = "test nudge",
        confidence: Double = 0.8,
        relevanceWindowExpiresAt: Date? = nil
    ) -> PaceProactiveUtterance {
        PaceProactiveUtterance(
            spokenText: spokenText,
            source: .watchNudge,
            confidence: confidence,
            relevanceWindowExpiresAt: relevanceWindowExpiresAt
        )
    }

    // MARK: - Type-level guarantee: ranking cannot widen what the gate approved

    @Test func stayQuietEvaluationNeverProducesAnOpportunity() {
        let evaluation: PaceProactiveNudgeEvaluation = (.stayQuiet(reason: "cooldown"), nil)
        let opportunity = PaceOpportunity(evaluation: evaluation, category: "focus-fatigue", now: referenceNow)
        #expect(opportunity == nil)
    }

    @Test func stayQuietWithStrayUtteranceStillNeverProducesAnOpportunity() {
        // Defensive: even if a decision/utterance pairing were malformed
        // (stayQuiet but a non-nil utterance), the type must still refuse.
        let evaluation: PaceProactiveNudgeEvaluation = (.stayQuiet(reason: "cooldown"), makeUtterance())
        let opportunity = PaceOpportunity(evaluation: evaluation, category: "focus-fatigue", now: referenceNow)
        #expect(opportunity == nil)
    }

    @Test func speakEvaluationProducesAnOpportunity() {
        let evaluation: PaceProactiveNudgeEvaluation = (.speak, makeUtterance())
        let opportunity = PaceOpportunity(evaluation: evaluation, category: "focus-fatigue", now: referenceNow)
        #expect(opportunity != nil)
        #expect(opportunity?.decision == .speak)
    }

    @Test func queueUntilIdleEvaluationProducesAnOpportunity() {
        let evaluation: PaceProactiveNudgeEvaluation = (.queueUntilIdle(reason: "on a call"), makeUtterance())
        let opportunity = PaceOpportunity(evaluation: evaluation, category: "focus-fatigue", now: referenceNow)
        #expect(opportunity != nil)
    }

    // MARK: - Coalescing

    @Test func sameCategoryCandidatesCoalesceToTheHighestScored() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        let lowerConfidence = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(confidence: 0.5),
            createdAt: referenceNow
        )
        let higherConfidence = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(confidence: 0.95),
            createdAt: referenceNow
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [lowerConfidence, higherConfidence],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow
        )

        #expect(result.winner?.identifier == higherConfidence.identifier)
        let loserRecord = result.records.first { $0.opportunity.identifier == lowerConfidence.identifier }
        #expect(loserRecord?.outcome == .coalescedInto(winnerIdentifier: higherConfidence.identifier))
    }

    @Test func differentCategoryCandidatesDoNotCoalesce() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        let focusFatigue = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(confidence: 0.9),
            createdAt: referenceNow
        )
        let calendarPreMeeting = PaceOpportunity(
            category: "calendar-pre-meeting",
            decision: .speak,
            utterance: makeUtterance(confidence: 0.5),
            createdAt: referenceNow
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [focusFatigue, calendarPreMeeting],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow
        )

        // Both survive coalescing (distinct categories); the cap (1)
        // still narrows to a single winner, the highest-scored.
        #expect(result.winner?.identifier == focusFatigue.identifier)
        let capturedOutcome = result.records.first { $0.opportunity.identifier == calendarPreMeeting.identifier }?.outcome
        if case .notSelectedByCap = capturedOutcome {
            #expect(true)
        } else {
            Issue.record("expected calendarPreMeeting to be recorded as not-selected-by-cap, got \(String(describing: capturedOutcome))")
        }
    }

    // MARK: - Category cooldown

    @Test func categoryCooldownSuppressesARepeatWithinTheWindow() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        tracker.markEmitted(category: "focus-fatigue", at: referenceNow)

        let repeatCandidate = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(),
            createdAt: referenceNow.addingTimeInterval(60)
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [repeatCandidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow.addingTimeInterval(60)
        )

        #expect(result.winner == nil)
        if case .suppressedByCategoryCooldown(let category, let remaining)? = result.records.first?.outcome {
            #expect(category == "focus-fatigue")
            #expect(remaining > 0)
        } else {
            Issue.record("expected suppressedByCategoryCooldown outcome")
        }
    }

    @Test func categoryCooldownDoesNotAffectAnUnrelatedCategory() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        tracker.markEmitted(category: "focus-fatigue", at: referenceNow)

        let unrelatedCandidate = PaceOpportunity(
            category: "calendar-pre-meeting",
            decision: .speak,
            utterance: makeUtterance(),
            createdAt: referenceNow.addingTimeInterval(60)
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [unrelatedCandidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow.addingTimeInterval(60)
        )

        #expect(result.winner?.identifier == unrelatedCandidate.identifier)
    }

    @Test func categoryCooldownClearsAfterTheConfiguredInterval() {
        var tracker = PaceOpportunityCategoryCooldownTracker(cooldownIntervalSeconds: 600)
        tracker.markEmitted(category: "focus-fatigue", at: referenceNow)

        let afterCooldown = referenceNow.addingTimeInterval(601)
        let candidate = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(),
            createdAt: afterCooldown
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [candidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: afterCooldown
        )

        #expect(result.winner?.identifier == candidate.identifier)
    }

    // MARK: - Cap enforcement

    @Test func capEnforcesExactlyOneWinnerAcrossDistinctCategories() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        let candidates = ["focus-fatigue", "calendar-pre-meeting", "watch-mode-observation"].enumerated().map { index, category in
            PaceOpportunity(
                category: category,
                decision: .speak,
                utterance: makeUtterance(confidence: 0.5 + Double(index) * 0.1),
                createdAt: referenceNow
            )
        }

        let result = PaceOpportunityRanker.rank(
            candidates: candidates,
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow
        )

        let emittedCount = result.records.filter {
            if case .emitted = $0.outcome { return true }
            return false
        }.count
        #expect(emittedCount == 1)
        // Highest confidence (last in the array, 0.7) should win.
        #expect(result.winner?.identifier == candidates.last?.identifier)
    }

    // MARK: - Expiry

    @Test func expiredCandidatesAreDroppedBeforeScoring() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        let expiredCandidate = PaceOpportunity(
            category: "calendar-pre-meeting",
            decision: .speak,
            utterance: makeUtterance(relevanceWindowExpiresAt: referenceNow.addingTimeInterval(-1)),
            createdAt: referenceNow.addingTimeInterval(-120)
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [expiredCandidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow
        )

        #expect(result.winner == nil)
        #expect(result.records.first?.outcome == .expired)
    }

    // MARK: - Honest acceptance-history signal

    @Test func acceptanceHistoryIsAlwaysMarkedUnavailable() {
        var tracker = PaceOpportunityCategoryCooldownTracker()
        let candidate = PaceOpportunity(
            category: "focus-fatigue",
            decision: .speak,
            utterance: makeUtterance(),
            createdAt: referenceNow
        )

        let result = PaceOpportunityRanker.rank(
            candidates: [candidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &tracker,
            now: referenceNow
        )

        guard case .emitted(let score)? = result.records.first?.outcome else {
            Issue.record("expected an emitted outcome")
            return
        }
        #expect(score.acceptanceHistory == .unavailable)
    }

    // MARK: - Relevance heuristic never penalizes, only boosts

    @Test func knownActivitySubjectMatchingCategoryBoostsRelevance() {
        var trackerWithMatch = PaceOpportunityCategoryCooldownTracker()
        var trackerWithoutMatch = PaceOpportunityCategoryCooldownTracker()

        let candidate = PaceOpportunity(
            category: "xcode-build-watch",
            decision: .speak,
            utterance: makeUtterance(confidence: 0.5),
            createdAt: referenceNow
        )

        let matchingActivityState = PaceActiveGoalState(
            subject: .known("xcode"),
            confidence: 0.8,
            supportingObservationIds: [],
            contradictingObservationIds: []
        )

        let matchedResult = PaceOpportunityRanker.rank(
            candidates: [candidate],
            activityGoalState: matchingActivityState,
            categoryCooldownTracker: &trackerWithMatch,
            now: referenceNow
        )
        let unmatchedResult = PaceOpportunityRanker.rank(
            candidates: [candidate],
            activityGoalState: .unknown,
            categoryCooldownTracker: &trackerWithoutMatch,
            now: referenceNow
        )

        guard case .emitted(let matchedScore)? = matchedResult.records.first?.outcome,
              case .emitted(let unmatchedScore)? = unmatchedResult.records.first?.outcome else {
            Issue.record("expected both results to be emitted")
            return
        }
        #expect(matchedScore.relevance > unmatchedScore.relevance)
        #expect(unmatchedScore.relevance == 0.5, "no match / unknown state must be neutral, never penalized")
    }
}
