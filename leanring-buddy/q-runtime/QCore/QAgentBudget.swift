//
//  QAgentBudget.swift
//  leanring-buddy
//
//  Q Security Architecture — Task Execution Budgets & Bounds (Phase 2D).
//  Provides strict resource, step count, replanning attempt, and execution duration bounds
//  with fail-closed budget exhaustion enforcement.
//

import Foundation

public enum QBudgetExhaustionReason: String, Codable, Sendable, Equatable {
    case stepLimitExceeded = "step_limit_exceeded"
    case replanLimitExceeded = "replan_limit_exceeded"
    case durationExceeded = "duration_exceeded"
    case consecutiveFailuresExceeded = "consecutive_failures_exceeded"
    case modelPlanningAttemptsExceeded = "model_planning_attempts_exceeded"
}

public enum QBudgetDecision: Sendable, Equatable {
    case withinBudget
    case exhausted(reason: QBudgetExhaustionReason, explanation: String)
}

public struct QAgentBudget: Codable, Sendable, Equatable {
    public let maxExecutionSteps: Int
    public let maxReplans: Int
    public let maxDurationSeconds: Double
    public let maxConsecutiveFailures: Int
    public let maxModelPlanningAttempts: Int

    public private(set) var executedStepsCount: Int
    public private(set) var replansCount: Int
    public private(set) var consecutiveFailuresCount: Int
    public private(set) var modelPlanningAttemptsCount: Int
    public let startedAt: Date

    public init(
        maxExecutionSteps: Int = 20,
        maxReplans: Int = 2,
        maxDurationSeconds: Double = 300.0,
        maxConsecutiveFailures: Int = 3,
        maxModelPlanningAttempts: Int = 3,
        executedStepsCount: Int = 0,
        replansCount: Int = 0,
        consecutiveFailuresCount: Int = 0,
        modelPlanningAttemptsCount: Int = 0,
        startedAt: Date = Date()
    ) {
        self.maxExecutionSteps = maxExecutionSteps
        self.maxReplans = maxReplans
        self.maxDurationSeconds = maxDurationSeconds
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.maxModelPlanningAttempts = maxModelPlanningAttempts
        self.executedStepsCount = executedStepsCount
        self.replansCount = replansCount
        self.consecutiveFailuresCount = consecutiveFailuresCount
        self.modelPlanningAttemptsCount = modelPlanningAttemptsCount
        self.startedAt = startedAt
    }

    public mutating func recordStepExecution(success: Bool) {
        executedStepsCount += 1
        if success {
            consecutiveFailuresCount = 0
        } else {
            consecutiveFailuresCount += 1
        }
    }

    public mutating func recordReplan() {
        replansCount += 1
    }

    public mutating func recordModelCall() {
        modelPlanningAttemptsCount += 1
    }

    public func evaluateBudget(currentTime: Date = Date()) -> QBudgetDecision {
        if executedStepsCount >= maxExecutionSteps {
            return .exhausted(
                reason: .stepLimitExceeded,
                explanation: "Exceeded maximum allowed execution steps (\(executedStepsCount)/\(maxExecutionSteps))."
            )
        }

        if replansCount > maxReplans {
            return .exhausted(
                reason: .replanLimitExceeded,
                explanation: "Exceeded maximum allowed replan iterations (\(replansCount)/\(maxReplans))."
            )
        }

        if consecutiveFailuresCount >= maxConsecutiveFailures {
            return .exhausted(
                reason: .consecutiveFailuresExceeded,
                explanation: "Exceeded maximum consecutive step failures (\(consecutiveFailuresCount)/\(maxConsecutiveFailures))."
            )
        }

        if modelPlanningAttemptsCount > maxModelPlanningAttempts {
            return .exhausted(
                reason: .modelPlanningAttemptsExceeded,
                explanation: "Exceeded maximum model planning attempts (\(modelPlanningAttemptsCount)/\(maxModelPlanningAttempts))."
            )
        }

        let elapsed = currentTime.timeIntervalSince(startedAt)
        if elapsed > maxDurationSeconds {
            return .exhausted(
                reason: .durationExceeded,
                explanation: "Task execution timed out after \(String(format: "%.1f", elapsed))s (limit: \(maxDurationSeconds)s)."
            )
        }

        return .withinBudget
    }

    public var isExhausted: Bool {
        if case .exhausted = evaluateBudget() { return true }
        return false
    }
}
