import XCTest
@testable import Pace

@MainActor
final class PaceActiveCallDetectorTests: XCTestCase {
    private let slackBundleIdentifier = "com.tinyspeck.slackmacgap"

    func testIdleSlackDoesNotPauseWatch() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { .available(activeBundleIdentifiers: []) }
        )
        detector.recomputeForTesting()
        XCTAssertFalse(detector.isOnActiveCall)
    }

    func testKnownCallAppsWithAudioPauseWatch() {
        for bundleIdentifier in PaceActiveCallDetector.callBundleIdentifiers {
            XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                runningBundleIdentifiers: [bundleIdentifier],
                processAudioSnapshot: .available(activeBundleIdentifiers: [bundleIdentifier])
            ))
        }
    }

    func testKnownCallAppsWithUnknownAudioRemainPaused() {
        for bundleIdentifier in PaceActiveCallDetector.callBundleIdentifiers {
            XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                runningBundleIdentifiers: [bundleIdentifier], processAudioSnapshot: .unavailable
            ))
        }
    }

    func testSlackAudioHelperPausesWatch() {
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier],
            processAudioSnapshot: .available(activeBundleIdentifiers: [slackBundleIdentifier + ".helper"])
        ))
    }

    func testUnrelatedDictationAndSpeechDoNotMakeIdleSlackACall() {
        XCTAssertFalse(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier],
            processAudioSnapshot: .available(activeBundleIdentifiers: ["com.pace.app", "com.electron.wispr-flow.helper"])
        ))
    }

    func testSimilarBundlePrefixIsNotACallHelper() {
        XCTAssertFalse(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: ["us.zoom.xos"],
            processAudioSnapshot: .available(activeBundleIdentifiers: ["us.zoom.xos-unrelated"])
        ))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: ["COM.APPLE.FACETIME"],
            processAudioSnapshot: .available(activeBundleIdentifiers: ["com.apple.FaceTime"])
        ))
    }

    func testFaceTimeSystemAudioServicePausesWatch() {
        for serviceBundleIdentifier in ["com.apple.avconferenced", "com.apple.TelephonyUtilities"] {
            XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                runningBundleIdentifiers: ["com.apple.FaceTime"],
                processAudioSnapshot: .available(activeBundleIdentifiers: [serviceBundleIdentifier])
            ))
        }
    }

    func testUnknownAudioWithoutKnownCallAppDoesNotPauseWatch() {
        XCTAssertFalse(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: ["com.apple.Safari", "com.apple.Xcode"],
            processAudioSnapshot: .unavailable
        ))
    }

    func testNoCallAppSkipsCoreAudioSampling() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { ["com.apple.Safari"] },
            processAudioSnapshotProvider: {
                XCTFail("No call app requires no CoreAudio process read")
                return .unavailable
            }
        )
        detector.recomputeForTesting()
        XCTAssertFalse(detector.isOnActiveCall)
    }

    func testExitedAudioProcessDoesNotInterruptIdleSlackNotes() {
        var snapshot: PaceActiveCallDetector.ProcessAudioSnapshot = .available(activeBundleIdentifiers: [])
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { snapshot }
        )
        for processExited in [false, true, false] {
            snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1]) { _ in
                if processExited { throw PaceActiveCallDetector.ProcessAudioReadError.exited }
                return nil
            }
            detector.recomputeForTesting()
            XCTAssertFalse(detector.isOnActiveCall)
        }
    }

    func testExitedProcessDoesNotEraseAnotherActiveCall() {
        let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1, 2]) { processObject in
            if processObject == 2 { throw PaceActiveCallDetector.ProcessAudioReadError.exited }
            return self.slackBundleIdentifier + ".helper"
        }
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
        ))
    }

    func testUnreadableOrUnidentifiedActiveProcessRetainsPrivacyPause() {
        let unreadableSnapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1]) { _ in
            throw PaceActiveCallDetector.ProcessAudioReadError.unavailable
        }
        let unidentifiedSnapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1]) { _ in "" }
        for snapshot in [unreadableSnapshot, unidentifiedSnapshot] {
            XCTAssertEqual(snapshot, .unavailable)
            XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
            ))
        }
    }

    func testAudioCallTransitionsResumeAndPauseWatch() {
        var snapshot: PaceActiveCallDetector.ProcessAudioSnapshot = .available(activeBundleIdentifiers: [])
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { snapshot }
        )
        detector.recomputeForTesting()
        XCTAssertFalse(detector.isOnActiveCall)
        snapshot = .available(activeBundleIdentifiers: [slackBundleIdentifier + ".helper"])
        detector.recomputeForTesting()
        XCTAssertTrue(detector.isOnActiveCall)
        snapshot = .unavailable
        detector.recomputeForTesting()
        XCTAssertTrue(detector.isOnActiveCall)
        snapshot = .available(activeBundleIdentifiers: [])
        detector.recomputeForTesting()
        XCTAssertFalse(detector.isOnActiveCall)
    }
}
