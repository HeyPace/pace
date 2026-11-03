import XCTest
@testable import Pace

@MainActor
final class PaceActiveCallDetectorTests: XCTestCase {
    private let slackBundleIdentifier = "com.tinyspeck.slackmacgap"

    func testIdleSlackDoesNotPauseWatch() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { .idle }
        )
        detector.recomputeForTesting()
        XCTAssertFalse(detector.isOnActiveCall)
    }

    func testAudioActivityOrUnknownStatePausesEveryKnownCallApp() {
        for bundleIdentifier in PaceActiveCallDetector.callBundleIdentifiers {
            for snapshot in [PaceActiveCallDetector.ProcessAudioSnapshot.active, .unavailable] {
                XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                    runningBundleIdentifiers: [bundleIdentifier], processAudioSnapshot: snapshot
                ))
            }
        }
    }

    func testUnattributedOrUnrelatedAudioConservativelyPausesIdleSlack() {
        let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1], ownProcessIdentifier: 100) { _ in
            .init(processIdentifier: 200, inputIsRunning: true, outputIsRunning: false)
        }
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
        ))
    }

    func testOwnWakeWordCaptureAndSpeechDoNotPauseIdleSlack() {
        let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1], ownProcessIdentifier: 100) { _ in
            .init(processIdentifier: 100, inputIsRunning: true, outputIsRunning: true)
        }
        XCTAssertEqual(snapshot, .idle)
        XCTAssertFalse(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
        ))
    }

    func testOtherProcessInputOrOutputPausesEvenAlongsidePaceAudio() {
        for inputIsRunning in [true, false] {
            let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1, 2], ownProcessIdentifier: 100) { processObject in
                if processObject == 1 { return .init(processIdentifier: 100, inputIsRunning: true, outputIsRunning: true) }
                return .init(processIdentifier: 200, inputIsRunning: inputIsRunning, outputIsRunning: !inputIsRunning)
            }
            XCTAssertEqual(snapshot, .active)
            XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
                runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
            ))
        }
    }

    func testMatchingIsCaseInsensitiveAndKnownIdentifiersAreNormalized() {
        XCTAssertTrue(PaceActiveCallDetector.callBundleIdentifiers.allSatisfy { $0 == $0.lowercased() })
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: ["COM.APPLE.FACETIME"], processAudioSnapshot: .active
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
        var snapshot: PaceActiveCallDetector.ProcessAudioSnapshot = .idle
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { snapshot }
        )
        for processExited in [false, true, false] {
            snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1], ownProcessIdentifier: 100) { _ in
                if processExited { throw PaceActiveCallDetector.ProcessAudioReadError.exited }
                return .init(processIdentifier: 200, inputIsRunning: false, outputIsRunning: false)
            }
            detector.recomputeForTesting()
            XCTAssertFalse(detector.isOnActiveCall)
        }
    }

    func testExitedProcessDoesNotEraseAnotherActiveCall() {
        let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1, 2], ownProcessIdentifier: 100) { processObject in
            if processObject == 1 { throw PaceActiveCallDetector.ProcessAudioReadError.exited }
            return .init(processIdentifier: 200, inputIsRunning: true, outputIsRunning: false)
        }
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
        ))
    }

    func testUnreadableProcessRetainsPrivacyPause() {
        let snapshot = PaceActiveCallDetector.processAudioSnapshot(processObjects: [1], ownProcessIdentifier: 100) { _ in
            throw PaceActiveCallDetector.ProcessAudioReadError.unavailable
        }
        XCTAssertEqual(snapshot, .unavailable)
        XCTAssertTrue(PaceActiveCallDetector.hasActiveCall(
            runningBundleIdentifiers: [slackBundleIdentifier], processAudioSnapshot: snapshot
        ))
    }

    func testAudioTransitionsResumeAndPauseWatch() {
        var snapshot: PaceActiveCallDetector.ProcessAudioSnapshot = .idle
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: { [self.slackBundleIdentifier] },
            processAudioSnapshotProvider: { snapshot }
        )
        for (nextSnapshot, expectedPause) in [(PaceActiveCallDetector.ProcessAudioSnapshot.idle, false), (.active, true), (.unavailable, true), (.idle, false)] {
            snapshot = nextSnapshot
            detector.recomputeForTesting()
            XCTAssertEqual(detector.isOnActiveCall, expectedPause)
        }
    }
}
