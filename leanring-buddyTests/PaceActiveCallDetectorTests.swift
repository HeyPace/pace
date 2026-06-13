//
//  PaceActiveCallDetectorTests.swift
//  leanring-buddyTests
//
//  Exercises the bundle-identifier classifier directly via the
//  injected provider seam. The live `NSWorkspace.runningApplications`
//  path is exercised only by the production initializer; tests stub
//  the provider so they're deterministic without launching real call
//  apps.
//

import XCTest
@testable import Pace

@MainActor
final class PaceActiveCallDetectorTests: XCTestCase {

    func testNoCallBundlesReturnsFalse() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "com.apple.Xcode",
                    "com.apple.Safari",
                    "com.apple.finder",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertFalse(detector.isOnActiveCall)
    }

    func testZoomBundlePresentReturnsTrue() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "com.apple.Xcode",
                    "us.zoom.xos",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertTrue(detector.isOnActiveCall)
    }

    func testSlackBundleAlonePresentReturnsTrue() {
        // Slack alone is treated as "user might be on a call". This is
        // intentionally over-cautious for v1 because we err toward
        // staying quiet; the v1.1 CoreAudio check is what will let us
        // distinguish open-Slack from active-Slack-huddle. The test
        // pins the v1 behavior so a future tightening is an explicit
        // change, not an accidental regression.
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "com.tinyspeck.slackmacgap",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertTrue(detector.isOnActiveCall)
    }

    func testFaceTimeBundlePresentReturnsTrue() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "com.apple.FaceTime",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertTrue(detector.isOnActiveCall)
    }

    func testTeamsBundlePresentReturnsTrue() {
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "com.microsoft.teams2",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertTrue(detector.isOnActiveCall)
    }

    func testCaseInsensitiveBundleMatching() {
        // The macOS bundle identifier is canonically lowercase, but
        // some apps capitalize letters (`com.apple.FaceTime` vs
        // `com.apple.facetime`). The matching layer normalizes both
        // sides — pin that here so a refactor can't silently drop it.
        let detector = PaceActiveCallDetector(
            runningApplicationBundleIdentifiersProvider: {
                return [
                    "US.ZOOM.XOS",
                ]
            }
        )

        detector.recomputeForTesting()

        XCTAssertTrue(detector.isOnActiveCall)
    }

    func testPureClassifierMatchesInjectedSet() {
        XCTAssertFalse(
            PaceActiveCallDetector.anyCallBundleIdentifierIsRunning(
                among: ["com.apple.Xcode", "com.apple.Safari"]
            )
        )
        XCTAssertTrue(
            PaceActiveCallDetector.anyCallBundleIdentifierIsRunning(
                among: ["com.apple.facetime"]
            )
        )
    }
}
