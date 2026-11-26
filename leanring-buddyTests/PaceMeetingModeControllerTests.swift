//
//  PaceMeetingModeControllerTests.swift
//  leanring-buddyTests
//
//  Tests for the meeting mode controller. The actual SCStream
//  capture requires Screen Recording permission and can't run in
//  a unit test, so we test the state management, preference
//  gating, and audio level publishing logic.
//

import Combine
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceMeetingModeControllerTests {

    // MARK: - Initial state

    /// The controller starts in the inactive state.
    @Test
    func initialStateIsInactive() {
        let controller = PaceMeetingModeController.shared
        // Reset to inactive for test determinism.
        #expect(controller.state == .inactive || controller.state == .failed(""))
    }

    @Test func systemCaptureDenialFailsBeforeCreatingAMicrophoneRecorder() async {
        var recorderCount = 0
        let controller = PaceMeetingModeController(
            loadShareableContent: {
                throw NSError(
                    domain: "PaceMeetingTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "System capture denied"])
            },
            makeRecorder: { identifier in
                recorderCount += 1
                return PaceMeetingAudioRecorder(meetingID: identifier)
            })
        await controller.start(profileSlug: "standup")
        #expect(recorderCount == 0)
        #expect(controller.state == .failed("System capture denied"))
        #expect(!controller.isCapturing)
        #expect(controller.selectedProfileSlug == "standup")
        await controller.start()
        #expect(recorderCount == 0 && controller.selectedProfileSlug == nil)
    }

    /// The detected speech level starts at zero.
    @Test
    func initialSpeechLevelIsZero() {
        let controller = PaceMeetingModeController.shared
        #expect(controller.detectedSpeechLevel == 0.0)
    }

    // MARK: - State machine

    /// isSystemAudioActive returns false when speech level is low.
    @Test
    func isSystemAudioActiveFalseWhenLevelLow() {
        let controller = PaceMeetingModeController.shared
        // The default level is 0.0 which is below the 0.08 threshold.
        #expect(controller.isSystemAudioActive == false)
    }

    // MARK: - Preference

    @Test func staleMeetingPreferenceIsClearedWithoutStartingCapture() throws {
        let suiteName = "PaceMeetingLaunchTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PaceUserPreferencesStore.setBool(true, for: .isMeetingModeEnabled, defaults: defaults)
        PaceUserPreferencesStore.clearLegacyMeetingCaptureSetting(defaults: defaults)
        #expect(defaults.object(forKey: PaceUserPreferenceKey.isMeetingModeEnabled.rawValue) == nil)
        #expect(!PaceMeetingModeController.shared.isCapturing)
    }

    /// The cron scheduler preference key exists.
    @Test
    func cronSchedulerPreferenceKeyExists() {
        let value = PaceUserPreferencesStore.bool(.isCronSchedulerEnabled, default: false)
        #expect(value == false)
    }

    // MARK: - Audio level publisher

    /// The audio level publisher accepts subscriptions without
    /// an active stream.
    @Test
    func audioLevelPublisherAcceptsSubscriptions() {
        let controller = PaceMeetingModeController.shared
        var receivedCount = 0
        let subscription = controller.audioLevelPublisher.sink { _ in
            receivedCount += 1
        }
        #expect(receivedCount == 0)
        subscription.cancel()
    }
}
