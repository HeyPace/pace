//
//  PaceActionObservationWaiterTests.swift
//  leanring-buddyTests
//
//  Locks in bounded state-driven settling without touching the live desktop.
//

import Testing
@testable import Pace

@MainActor
struct PaceActionObservationWaiterTests {
    @Test func immediateStateChangeSkipsEverySleep() async {
        var sleepCallCount = 0

        let outcome = await PaceActionObservationWaiter.waitForChange(
            from: 0,
            configuration: PaceActionObservationConfiguration(
                pollIntervalNanoseconds: 1,
                maximumPollCount: 3
            ),
            currentState: { 1 },
            sleep: { _ in sleepCallCount += 1 }
        )

        #expect(outcome == .changed(completedPollCount: 0))
        #expect(sleepCallCount == 0)
    }

    @Test func delayedStateChangeReturnsAfterTheMatchingPoll() async {
        var currentStateReadCount = 0
        var sleepCallCount = 0

        let outcome = await PaceActionObservationWaiter.waitForChange(
            from: 0,
            configuration: PaceActionObservationConfiguration(
                pollIntervalNanoseconds: 1,
                maximumPollCount: 4
            ),
            currentState: {
                currentStateReadCount += 1
                return currentStateReadCount >= 3 ? 1 : 0
            },
            sleep: { _ in sleepCallCount += 1 }
        )

        #expect(outcome == .changed(completedPollCount: 2))
        #expect(currentStateReadCount == 3)
        #expect(sleepCallCount == 2)
    }

    @Test func unchangedStateUsesTheCompleteBoundedWindow() async {
        var currentStateReadCount = 0
        var sleepCallCount = 0

        let outcome = await PaceActionObservationWaiter.waitForChange(
            from: 0,
            configuration: PaceActionObservationConfiguration(
                pollIntervalNanoseconds: 1,
                maximumPollCount: 3
            ),
            currentState: {
                currentStateReadCount += 1
                return 0
            },
            sleep: { _ in sleepCallCount += 1 }
        )

        #expect(outcome == .timedOut)
        #expect(currentStateReadCount == 4)
        #expect(sleepCallCount == 3)
    }

    @Test func cancellationStopsBeforeAnotherStateRead() async {
        var currentStateReadCount = 0
        var sleepCallCount = 0

        let outcome = await PaceActionObservationWaiter.waitForChange(
            from: 0,
            configuration: PaceActionObservationConfiguration(
                pollIntervalNanoseconds: 1,
                maximumPollCount: 3
            ),
            currentState: {
                currentStateReadCount += 1
                return 0
            },
            sleep: { _ in
                sleepCallCount += 1
                throw CancellationError()
            }
        )

        #expect(outcome == .cancelled)
        #expect(currentStateReadCount == 1)
        #expect(sleepCallCount == 1)
    }

    @Test func runtimeConfigurationsPreserveLegacyMaximumWaits() {
        #expect(PaceActionObservationConfiguration.clickVerification.maximumWaitNanoseconds == 200_000_000)
        #expect(PaceActionObservationConfiguration.agentLoopSettling.maximumWaitNanoseconds == 600_000_000)
    }
}
