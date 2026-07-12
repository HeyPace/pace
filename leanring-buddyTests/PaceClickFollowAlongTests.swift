//
//  PaceClickFollowAlongTests.swift
//  leanring-buddyTests
//
//  Click-follow-along verification logic. Tests cover the pure
//  matcher (point-in-rect with tolerance), the controller's state
//  machine, and the multi-step advance flow.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

struct PaceClickFollowAlongMatcherTests {

    @Test func clickInsideBoundsAdvances() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 80, height: 30)
        let click = CGPoint(x: 140, y: 115)
        #expect(
            PaceClickFollowAlongMatcher.clickMatchesStep(
                clickPointInScreenshotPixels: click,
                stepTargetBoundsInScreenshotPixels: bounds
            )
        )
    }

    @Test func clickWithinToleranceMarginCounts() async throws {
        // A click 5 px outside the bbox should still match — the
        // 6-px tolerance covers small drawing inaccuracies.
        let bounds = CGRect(x: 100, y: 100, width: 80, height: 30)
        let justOutside = CGPoint(x: 95, y: 100)  // 5 px to the left
        #expect(
            PaceClickFollowAlongMatcher.clickMatchesStep(
                clickPointInScreenshotPixels: justOutside,
                stepTargetBoundsInScreenshotPixels: bounds
            )
        )
    }

    @Test func clickBeyondToleranceMarginDoesNotCount() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 80, height: 30)
        let wellOutside = CGPoint(x: 80, y: 100)  // 20 px to the left
        #expect(
            !PaceClickFollowAlongMatcher.clickMatchesStep(
                clickPointInScreenshotPixels: wellOutside,
                stepTargetBoundsInScreenshotPixels: bounds
            )
        )
    }

    @Test func clickAtBoundsCornerCounts() async throws {
        // Edge case — exactly on the corner of the bbox.
        let bounds = CGRect(x: 100, y: 100, width: 80, height: 30)
        let topLeftCorner = CGPoint(x: 100, y: 100)
        let bottomRightCorner = CGPoint(x: 180, y: 130)
        #expect(
            PaceClickFollowAlongMatcher.clickMatchesStep(
                clickPointInScreenshotPixels: topLeftCorner,
                stepTargetBoundsInScreenshotPixels: bounds
            )
        )
        #expect(
            PaceClickFollowAlongMatcher.clickMatchesStep(
                clickPointInScreenshotPixels: bottomRightCorner,
                stepTargetBoundsInScreenshotPixels: bounds
            )
        )
    }
}

@MainActor
struct PaceClickFollowAlongControllerTests {

    private func makeStep(
        identifier: String,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 80, height: 30),
        screen: String = "primary"
    ) -> PaceClickFollowAlongStep {
        PaceClickFollowAlongStep(
            screenLabel: screen,
            targetBoundsInScreenshotPixels: bounds,
            spokenInstructionForUser: "click step \(identifier)",
            stepIdentifier: identifier
        )
    }

    @Test func startingASequenceMovesToAwaitingClickOnStepZero() async throws {
        let controller = PaceClickFollowAlongController()
        var activatedSteps: [PaceClickFollowAlongStep] = []
        controller.onStepActivated = { activatedSteps.append($0) }

        let sequence = PaceClickFollowAlongSequence(
            steps: [makeStep(identifier: "a"), makeStep(identifier: "b")],
            completionMessage: nil
        )
        controller.startSequence(sequence)

        #expect(controller.isAwaitingClick)
        #expect(controller.currentStepIndex == 0)
        #expect(activatedSteps.count == 1)
        #expect(activatedSteps.first?.stepIdentifier == "a")
    }

    @Test func startingEmptySequenceLeavesControllerIdle() async throws {
        let controller = PaceClickFollowAlongController()
        controller.startSequence(
            PaceClickFollowAlongSequence(steps: [], completionMessage: nil)
        )
        #expect(controller.currentState == .idle)
    }

    @Test func clickInsideBoundsAdvancesToNextStep() async throws {
        let controller = PaceClickFollowAlongController()
        var activated: [String] = []
        controller.onStepActivated = { activated.append($0.stepIdentifier) }

        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [
                    makeStep(
                        identifier: "first",
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                    ),
                    makeStep(
                        identifier: "second",
                        bounds: CGRect(x: 200, y: 200, width: 100, height: 100)
                    ),
                ],
                completionMessage: nil
            )
        )

        // Click inside step 1's bbox → advance to step 2
        let didAdvance = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 50, y: 50),
            clickedScreenLabel: "primary"
        )
        #expect(didAdvance)
        #expect(controller.currentStepIndex == 1)
        #expect(activated == ["first", "second"])
    }

    @Test func clickOutsideBoundsDoesNotAdvance() async throws {
        let controller = PaceClickFollowAlongController()
        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [
                    makeStep(
                        identifier: "first",
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                    ),
                    makeStep(identifier: "second"),
                ],
                completionMessage: nil
            )
        )
        let didAdvance = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 500, y: 500),
            clickedScreenLabel: "primary"
        )
        #expect(!didAdvance)
        #expect(controller.currentStepIndex == 0)
    }

    @Test func clickOnDifferentScreenDoesNotAdvance() async throws {
        // Step's screenLabel is "primary"; the user clicks on
        // "external" — must not advance even if coordinates match.
        let controller = PaceClickFollowAlongController()
        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [
                    makeStep(
                        identifier: "primary-step",
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                        screen: "primary"
                    ),
                    makeStep(identifier: "next"),
                ],
                completionMessage: nil
            )
        )
        let didAdvance = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 50, y: 50),
            clickedScreenLabel: "external"
        )
        #expect(!didAdvance)
        #expect(controller.currentStepIndex == 0)
    }

    @Test func clickingThroughAllStepsFiresCompletion() async throws {
        let controller = PaceClickFollowAlongController()
        var completionMessages: [String?] = []
        controller.onSequenceCompleted = { completionMessages.append($0) }

        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [
                    makeStep(
                        identifier: "a",
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                    ),
                    makeStep(
                        identifier: "b",
                        bounds: CGRect(x: 200, y: 200, width: 100, height: 100)
                    ),
                ],
                completionMessage: "nice work"
            )
        )
        _ = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 50, y: 50),
            clickedScreenLabel: "primary"
        )
        _ = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 250, y: 250),
            clickedScreenLabel: "primary"
        )
        #expect(controller.currentState == .completed)
        #expect(completionMessages == ["nice work"])
    }

    @Test func cancelMovesBackToIdleAndFiresCallback() async throws {
        let controller = PaceClickFollowAlongController()
        var cancelReasons: [String] = []
        controller.onSequenceCancelled = { cancelReasons.append($0) }

        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [makeStep(identifier: "a")],
                completionMessage: nil
            )
        )
        controller.cancel(reason: "user said stop")

        #expect(controller.currentState == .idle)
        #expect(cancelReasons == ["user said stop"])
    }

    @Test func startingNewSequenceCancelsActiveOne() async throws {
        // Mid-sequence, the planner could emit a NEW follow-along
        // (e.g. user said "actually nevermind, show me X instead").
        // The active sequence should be cancelled with the
        // "superseded" reason before the new one starts.
        let controller = PaceClickFollowAlongController()
        var cancelReasons: [String] = []
        controller.onSequenceCancelled = { cancelReasons.append($0) }

        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [makeStep(identifier: "old")],
                completionMessage: nil
            )
        )
        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [makeStep(identifier: "new")],
                completionMessage: nil
            )
        )
        #expect(cancelReasons == ["superseded by new sequence"])
        #expect(controller.currentStepIndex == 0)
    }

    @Test func markCompletionAcknowledgedResetsToIdle() async throws {
        let controller = PaceClickFollowAlongController()
        controller.startSequence(
            PaceClickFollowAlongSequence(
                steps: [
                    makeStep(
                        identifier: "only",
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                    ),
                ],
                completionMessage: nil
            )
        )
        _ = controller.handleGlobalClick(
            clickPointInScreenshotPixels: CGPoint(x: 50, y: 50),
            clickedScreenLabel: "primary"
        )
        #expect(controller.currentState == .completed)
        controller.markCompletionAcknowledged()
        #expect(controller.currentState == .idle)
    }
}
