//
//  PaceRestraintGateFocusModeTests.swift
//  leanring-buddyTests
//
//  Pins the gate's behavior when macOS reports a system Focus is
//  active. Regression here = Pace nudges the user mid-meeting
//  despite a Work Focus or Do Not Disturb.
//

import Foundation
import Testing
@testable import Pace

struct PaceRestraintGateFocusModeTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func calendarBypassesSuggestionCooldownButStillDefersDuringCallsAndFocus() {
        for (isOnActiveCall, isInUserFocusMode) in [(false, false), (true, false), (false, true)] {
            let context = PaceRestraintContext(
                now: referenceDate,
                lastProactiveUtteranceAt: referenceDate.addingTimeInterval(-30),
                lastEpisodicRecallAt: nil, lastUserInputAt: nil,
                frontmostAppBundleIdentifier: "com.apple.Notes",
                isOnActiveCall: isOnActiveCall, wakeWordConfidence: nil,
                intent: .pureKnowledge, proactiveSource: .calendarEvent,
                profile: .balanced, isInUserFocusMode: isInUserFocusMode
            )
            if isOnActiveCall || isInUserFocusMode {
                guard case .queueUntilIdle = PaceRestraintGate.decide(context) else {
                    Issue.record("Calendar must still defer for calls or Focus.")
                    continue
                }
            } else {
                #expect(PaceRestraintGate.decide(context) == .speak)
            }
        }
    }

    @Test func morningTriageStaysQueuedWhenUserIsInFocusMode() async throws {
        let context = PaceRestraintContext(
            now: referenceDate,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "com.apple.Notes",
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: .balanced,
            isInUserFocusMode: true
        )
        let decision = PaceRestraintGate.decide(context)
        guard case .queueUntilIdle(let reason) = decision else {
            Issue.record("Expected queueUntilIdle when Focus is active, got \(decision)")
            return
        }
        #expect(reason.contains("Focus"))
    }

    @Test func morningTriageSpeaksWhenFocusIsNotActiveAndNoOtherBlockers() async throws {
        let context = PaceRestraintContext(
            now: referenceDate,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "com.apple.Notes",
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: .balanced,
            isInUserFocusMode: false
        )
        #expect(PaceRestraintGate.decide(context) == .speak)
    }

    @Test func activeCallTakesPrecedenceOverFocusReason() async throws {
        // When both are true (e.g. Work Focus + Zoom call), the gate
        // surfaces "active call" — slightly more actionable in logs
        // and indicates the more pressing override.
        let context = PaceRestraintContext(
            now: referenceDate,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: .balanced,
            isInUserFocusMode: true
        )
        guard case .queueUntilIdle(let reason) = PaceRestraintGate.decide(context) else {
            Issue.record("Expected queueUntilIdle")
            return
        }
        #expect(reason.contains("active call"))
    }

    @Test func pushToTalkBypassesFocusGateBecauseUserExplicitlyInitiated() async throws {
        // The user pressing PTT mid-Focus IS the override. The gate
        // must not silence a turn the user explicitly initiated.
        let context = PaceRestraintContext(
            now: referenceDate,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "com.apple.Notes",
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .userPushToTalk,
            profile: .balanced,
            isInUserFocusMode: true
        )
        #expect(PaceRestraintGate.decide(context) == .speak)
    }

    @Test func defaultIsInUserFocusModeIsFalseForBackwardsCompat() async throws {
        // Existing call sites that don't pass `isInUserFocusMode`
        // should keep the pre-Focus-integration behaviour exactly.
        let context = PaceRestraintContext(
            now: referenceDate,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "com.apple.Notes",
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: .balanced
        )
        #expect(context.isInUserFocusMode == false)
        #expect(PaceRestraintGate.decide(context) == .speak)
    }
}
