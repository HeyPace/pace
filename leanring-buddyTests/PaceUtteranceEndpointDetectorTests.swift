import Foundation
import Testing
@testable import Pace

struct PaceUtteranceEndpointDetectorTests {
    @Test func leadingSilenceWaitsThenEndsWithoutClaimingSpeech() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.001, seconds: 7).isEmpty)
        #expect(!detector.hasDetectedSpeech)
        #expect(feed(&detector, level: 0.001, seconds: 1.2) == [.noSpeech])
        #expect(!detector.hasDetectedSpeech)
    }

    @Test func speechThenPauseEndsExactlyOnce() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.02, seconds: 0.4).isEmpty)
        #expect(detector.hasDetectedSpeech)
        #expect(feed(&detector, level: 0.001, seconds: 0.8).isEmpty)
        #expect(feed(&detector, level: 0.001, seconds: 0.4) == [.speechPause])
        #expect(feed(&detector, level: 0.001, seconds: 5).isEmpty)
    }

    @Test func resumedSpeechResetsThePauseClock() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.02, seconds: 0.3).isEmpty)
        #expect(feed(&detector, level: 0.001, seconds: 0.6).isEmpty)
        #expect(feed(&detector, level: 0.02, seconds: 0.3).isEmpty)
        #expect(feed(&detector, level: 0.001, seconds: 0.6).isEmpty)
        #expect(feed(&detector, level: 0.001, seconds: 0.6) == [.speechPause])
    }

    @Test func isolatedSoundDoesNotArmASpeechPauseSubmission() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.03, seconds: 0.04).isEmpty)
        #expect(feed(&detector, level: 0.001, seconds: 1.5).isEmpty)
        #expect(!detector.hasDetectedSpeech)
    }

    @Test func lowBackgroundNoiseAdaptsWithoutExtendingCaptureIndefinitely() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.004, seconds: 8.2) == [.noSpeech])
        #expect(!detector.hasDetectedSpeech)
    }

    @Test func backgroundAboveTheSpeechGateStillHasAMaximumDuration() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.03, seconds: 44).isEmpty)
        #expect(feed(&detector, level: 0.03, seconds: 1.2) == [.maximumDuration])
    }

    @Test func hysteresisAllowsAQuietSpeechTailThenAdaptsToBackground() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.02, seconds: 0.3).isEmpty)
        #expect(feed(&detector, level: 0.004, seconds: 0.2).isEmpty)
        #expect(feed(&detector, level: 0.004, seconds: 2.5) == [.speechPause])
    }

    @Test func pushToTalkNeverAutoEndsDuringSilenceOrLongSpeech() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .pushToTalk)
        #expect(feed(&detector, level: 0.001, seconds: 10).isEmpty)
        #expect(feed(&detector, level: 0.02, seconds: 60).isEmpty)
        #expect(feed(&detector, level: 0, seconds: 10).isEmpty)
        #expect(!detector.hasFinished)
    }

    @Test func invalidSamplesAndMissingBufferTimeDoNotFabricateAPause() {
        var detector = PaceUtteranceEndpointDetector(captureMode: .handsFree)
        #expect(feed(&detector, level: 0.02, seconds: 0.3).isEmpty)
        for (level, duration) in [(Float.nan, 10.0), (-1, 1), (0, 2), (0, -.infinity), (0, 0)] {
            #expect(
                detector.observe(
                    rootMeanSquare: level, audioDuration: duration,
                    captureSessionIdentifier: detector.captureSessionIdentifier) == nil)
        }
        #expect(!detector.hasFinished)
        #expect(feed(&detector, level: 0, seconds: 1.1) == [.speechPause])
    }

    @MainActor @Test func triggerOwnershipUsesHandsFreeOnlyForNonKeyboardStarts() {
        #expect(CompanionManager.DictationTrigger.keyboard.captureMode == .pushToTalk)
        #expect(CompanionManager.DictationTrigger.microphoneButton.captureMode == .handsFree)
        #expect(CompanionManager.DictationTrigger.avatar.captureMode == .handsFree)
        #expect(CompanionManager.DictationTrigger.wakeWord.captureMode == .handsFree)
    }

    @Test func lateAudioFromAnOldCaptureCannotFinishTheNextSession() {
        let oldCaptureIdentifier = UUID()
        let currentCaptureIdentifier = UUID()
        var detector = PaceUtteranceEndpointDetector(
            captureMode: .handsFree, captureSessionIdentifier: currentCaptureIdentifier)
        #expect(feed(&detector, level: 0.02, seconds: 0.3).isEmpty)
        for _ in 0..<100 {
            #expect(
                detector.observe(
                    rootMeanSquare: 0, audioDuration: 0.02,
                    captureSessionIdentifier: oldCaptureIdentifier) == nil)
        }
        #expect(!detector.hasFinished)
        #expect(feed(&detector, level: 0, seconds: 1.1) == [.speechPause])
    }

    @MainActor @Test func automaticReleaseClearsShortcutOwnershipForTheNextHandsFreeTurn() {
        let monitor = GlobalPushToTalkShortcutMonitor()
        for _ in 0..<2 {
            monitor.simulateShortcutPressed()
            #expect(monitor.isShortcutCurrentlyPressed)
            let captureIdentifier = UUID()
            var endpointCount = 0
            let endpoint = PaceHandsFreeCaptureEndpoint(
                captureMode: .handsFree, captureSessionIdentifier: captureIdentifier
            ) { _ in
                endpointCount += 1
                monitor.simulateShortcutReleased()
            }
            feed(endpoint, level: 0.02, seconds: 0.3, captureIdentifier: captureIdentifier)
            feed(endpoint, level: 0, seconds: 2, captureIdentifier: captureIdentifier)
            #expect(endpointCount == 1)
            #expect(!monitor.isShortcutCurrentlyPressed)
        }
    }

    @MainActor @Test func cancelledAndStaleEndpointsCannotReleaseANewCapture() {
        let monitor = GlobalPushToTalkShortcutMonitor()
        let oldCaptureIdentifier = UUID()
        let currentCaptureIdentifier = UUID()
        let oldEndpoint = PaceHandsFreeCaptureEndpoint(
            captureMode: .handsFree, captureSessionIdentifier: oldCaptureIdentifier
        ) { _ in monitor.simulateShortcutReleased() }
        oldEndpoint.cancel()
        monitor.simulateShortcutPressed()
        let endpoint = PaceHandsFreeCaptureEndpoint(
            captureMode: .handsFree, captureSessionIdentifier: currentCaptureIdentifier
        ) { _ in monitor.simulateShortcutReleased() }
        oldEndpoint.finish(reason: .speechPause, captureSessionIdentifier: oldCaptureIdentifier)
        endpoint.finish(reason: .speechPause, captureSessionIdentifier: oldCaptureIdentifier)
        feed(endpoint, level: 0, seconds: 9, captureIdentifier: oldCaptureIdentifier)
        #expect(monitor.isShortcutCurrentlyPressed)
        endpoint.finish(reason: .maximumDuration, captureSessionIdentifier: currentCaptureIdentifier)
        #expect(!monitor.isShortcutCurrentlyPressed)
    }

    @MainActor @Test func physicalPushToTalkEndpointCannotReleaseAHeldShortcut() {
        let captureIdentifier = UUID()
        var endpointCount = 0
        let endpoint = PaceHandsFreeCaptureEndpoint(
            captureMode: .pushToTalk, captureSessionIdentifier: captureIdentifier
        ) { _ in endpointCount += 1 }
        feed(endpoint, level: 0.02, seconds: 0.5, captureIdentifier: captureIdentifier)
        feed(endpoint, level: 0, seconds: 50, captureIdentifier: captureIdentifier)
        endpoint.finish(reason: .maximumDuration, captureSessionIdentifier: captureIdentifier)
        #expect(endpointCount == 0)
    }

    @MainActor
    private func feed(
        _ endpoint: PaceHandsFreeCaptureEndpoint,
        level: Float,
        seconds: TimeInterval,
        captureIdentifier: UUID
    ) {
        for _ in 0..<Int((seconds / 0.02).rounded()) {
            endpoint.observe(rootMeanSquare: level, audioDuration: 0.02, captureSessionIdentifier: captureIdentifier)
        }
    }

    private func feed(
        _ detector: inout PaceUtteranceEndpointDetector,
        level: Float,
        seconds: TimeInterval
    ) -> [PaceUtteranceEndpointReason] {
        var reasons: [PaceUtteranceEndpointReason] = []
        for _ in 0..<Int((seconds / 0.02).rounded()) {
            if let reason = detector.observe(
                rootMeanSquare: level, audioDuration: 0.02,
                captureSessionIdentifier: detector.captureSessionIdentifier)
            {
                reasons.append(reason)
            }
        }
        return reasons
    }
}
