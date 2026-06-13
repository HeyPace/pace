//
//  PaceUserInputActivityMonitorTests.swift
//  leanring-buddyTests
//
//  Exercises the test seam on `PaceUserInputActivityMonitor`. The
//  live CGEvent tap path needs Accessibility permission and a real
//  CFRunLoop turn, so these tests drive the same publication code
//  via `recordEventForTesting(at:)` instead.
//

import XCTest
@testable import Pace

@MainActor
final class PaceUserInputActivityMonitorTests: XCTestCase {

    func testInitialLastUserInputAtIsNil() {
        let monitor = PaceUserInputActivityMonitor()

        XCTAssertNil(monitor.lastUserInputAt)
    }

    func testRecordEventForTestingSetsTimestamp() {
        let monitor = PaceUserInputActivityMonitor()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

        monitor.recordEventForTesting(at: recordedAt)

        XCTAssertEqual(monitor.lastUserInputAt, recordedAt)
    }

    func testMultipleEventsUpdateToMostRecent() {
        let monitor = PaceUserInputActivityMonitor()
        let firstObservedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let secondObservedTimestamp = firstObservedTimestamp.addingTimeInterval(5)
        let thirdObservedTimestamp = secondObservedTimestamp.addingTimeInterval(10)

        monitor.recordEventForTesting(at: firstObservedTimestamp)
        monitor.recordEventForTesting(at: secondObservedTimestamp)
        monitor.recordEventForTesting(at: thirdObservedTimestamp)

        XCTAssertEqual(monitor.lastUserInputAt, thirdObservedTimestamp)
    }

    func testRecordEventForTestingAcceptsBackwardsTimestamps() {
        // Defensive: nothing in the monitor enforces monotonic
        // ordering on `recordEventForTesting`. The CGEvent callback
        // always uses `Date()` so in production it does monotonically
        // advance, but the test seam should not silently reject an
        // earlier timestamp — that would mask real bugs in test setup.
        let monitor = PaceUserInputActivityMonitor()
        let later = Date(timeIntervalSince1970: 1_700_000_100)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)

        monitor.recordEventForTesting(at: later)
        monitor.recordEventForTesting(at: earlier)

        XCTAssertEqual(monitor.lastUserInputAt, earlier)
    }
}
