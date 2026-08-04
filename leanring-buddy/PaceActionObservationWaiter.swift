//
//  PaceActionObservationWaiter.swift
//  leanring-buddy
//
//  Bounded state-driven settling shared by action verification and the
//  screen-dependent agent loop.
//

import Foundation

nonisolated struct PaceActionObservationConfiguration: Equatable {
    let pollIntervalNanoseconds: UInt64
    let maximumPollCount: Int

    init(
        pollIntervalNanoseconds: UInt64,
        maximumPollCount: Int
    ) {
        self.pollIntervalNanoseconds = max(1, pollIntervalNanoseconds)
        self.maximumPollCount = max(1, maximumPollCount)
    }

    var maximumWaitNanoseconds: UInt64 {
        pollIntervalNanoseconds * UInt64(maximumPollCount)
    }

    static let clickVerification = PaceActionObservationConfiguration(
        pollIntervalNanoseconds: 25_000_000,
        maximumPollCount: 8
    )

    static let agentLoopSettling = PaceActionObservationConfiguration(
        pollIntervalNanoseconds: 40_000_000,
        maximumPollCount: 15
    )
}

nonisolated enum PaceActionObservationOutcome: Equatable {
    case changed(completedPollCount: Int)
    case timedOut
    case cancelled
}

@MainActor
enum PaceActionObservationWaiter {
    typealias Sleep = @MainActor (_ nanoseconds: UInt64) async throws -> Void

    static func waitForChange<State: Equatable>(
        from baselineState: State,
        configuration: PaceActionObservationConfiguration,
        currentState: @escaping @MainActor () -> State,
        sleep: @escaping Sleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> PaceActionObservationOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }

        if currentState() != baselineState {
            return .changed(completedPollCount: 0)
        }

        for completedPollCount in 1...configuration.maximumPollCount {
            do {
                try await sleep(configuration.pollIntervalNanoseconds)
            } catch is CancellationError {
                return .cancelled
            } catch {
                // The runtime sleep only throws for cancellation. Treat an
                // injected or future sleep failure as cancellation so the
                // caller never continues a dependent action on an unknown
                // settling state.
                return .cancelled
            }

            guard !Task.isCancelled else {
                return .cancelled
            }

            if currentState() != baselineState {
                return .changed(completedPollCount: completedPollCount)
            }
        }

        return .timedOut
    }
}
