//
//  QPlan.swift
//  leanring-buddy
//
//  Q Security Architecture — Multi-Step Agent Planning Foundation (Phase 2A.1).
//  Strongly typed, immutable-by-default, Sendable data structures for multi-step plans.
//  A plan is DATA, not authority — execution capabilities and executors are strictly excluded.
//

import Foundation

// MARK: - Plan & Step States

public enum QPlanState: Codable, Sendable, Equatable {
    case pending
    case running
    case waitingForPermission(stepIndex: Int, reason: String)
    case executing(stepIndex: Int)
    case verifying(stepIndex: Int)
    case completed(summary: String)
    case failed(reason: String, failedStepIndex: Int?)
    case blocked(reason: String, blockedStepIndex: Int?)
    case cancelled(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .blocked, .cancelled:
            return true
        case .pending, .running, .waitingForPermission, .executing, .verifying:
            return false
        }
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

public enum QPlanStepState: Codable, Sendable, Equatable {
    case pending
    case waitingForPermission(reason: String)
    case executing
    case verifying
    case completed
    case failed(reason: String)
    case blocked(reason: String)
    case skipped(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .blocked, .skipped:
            return true
        case .pending, .waitingForPermission, .executing, .verifying:
            return false
        }
    }
}

// MARK: - Planned Action & Step Models

public struct QPlannedAction: Codable, Sendable, Equatable {
    public let actionName: String
    public let toolFamily: String
    public let riskLevel: QCapabilityLevel
    public let literalAction: String
    public let targetResources: [String]
    public let arguments: [String: String]

    public init(
        actionName: String,
        toolFamily: String = "general",
        riskLevel: QCapabilityLevel = .level0ReadOnly,
        literalAction: String,
        targetResources: [String] = [],
        arguments: [String: String] = [:]
    ) {
        self.actionName = actionName
        self.toolFamily = toolFamily
        self.riskLevel = riskLevel
        self.literalAction = literalAction
        self.targetResources = targetResources
        self.arguments = arguments
    }

    /// Conversion to runtime action request for execution provider
    public func toActionRequest(stepId: UUID) -> QActionRequest {
        QActionRequest(
            actionId: stepId.uuidString,
            toolName: actionName,
            toolFamily: toolFamily,
            riskLevel: riskLevel,
            literalAction: literalAction,
            targetResources: targetResources,
            parameters: arguments
        )
    }
}

public struct QPlanStepResult: Codable, Sendable, Equatable {
    public let stepId: UUID
    public let success: Bool
    public let summary: String
    public let verifiedEvidence: String?
    public let error: String?
    public let outputData: [String: String]
    public let completedAt: Date

    public init(
        stepId: UUID,
        success: Bool,
        summary: String,
        verifiedEvidence: String? = nil,
        error: String? = nil,
        outputData: [String: String] = [:],
        completedAt: Date = Date()
    ) {
        self.stepId = stepId
        self.success = success
        self.summary = summary
        self.verifiedEvidence = verifiedEvidence
        self.error = error
        self.outputData = outputData
        self.completedAt = completedAt
    }
}

public struct QPlanStep: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let index: Int
    public let action: QPlannedAction
    public let description: String
    public var state: QPlanStepState
    public var result: QPlanStepResult?

    public init(
        id: UUID = UUID(),
        index: Int,
        action: QPlannedAction,
        description: String,
        state: QPlanStepState = .pending,
        result: QPlanStepResult? = nil
    ) {
        self.id = id
        self.index = index
        self.action = action
        self.description = description
        self.state = state
        self.result = result
    }

    public var isBlocked: Bool {
        if case .blocked = state { return true }
        return false
    }
}

// MARK: - Multi-Step Plan Root

public struct QPlan: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskId: String
    public let sessionId: String
    public let taskPrompt: String
    public let createdAt: Date
    public var state: QPlanState
    public var steps: [QPlanStep]

    public var isComplete: Bool {
        if case .completed = state { return true }
        return false
    }

    public var stepCount: Int {
        steps.count
    }

    public init(
        id: UUID = UUID(),
        taskId: String = UUID().uuidString,
        sessionId: String = UUID().uuidString,
        taskPrompt: String,
        createdAt: Date = Date(),
        state: QPlanState = .pending,
        steps: [QPlanStep] = []
    ) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.taskPrompt = taskPrompt
        self.createdAt = createdAt
        self.state = state
        self.steps = steps
    }
}

// MARK: - State Machine Transition Validator

public enum QPlanTransitionError: Error, Equatable, Sendable {
    case invalidPlanTransition(from: QPlanState, to: QPlanState)
    case invalidStepTransition(from: QPlanStepState, to: QPlanStepState)
    case outOfOrderExecution(expectedIndex: Int, actualIndex: Int)
    case stepVerificationMissing(stepIndex: Int)
}

public enum QPlanStateValidator {

    /// Validates whether a plan-level state transition is legally permissible.
    public static func canTransition(from current: QPlanState, to next: QPlanState) -> Bool {
        if current == next { return true }

        switch current {
        case .pending:
            switch next {
            case .running, .failed, .blocked, .cancelled:
                return true
            default:
                return false
            }

        case .running:
            switch next {
            case .waitingForPermission, .executing, .verifying, .completed, .failed, .blocked, .cancelled:
                return true
            default:
                return false
            }

        case .waitingForPermission:
            switch next {
            case .executing, .blocked, .failed, .cancelled:
                return true
            default:
                return false
            }

        case .executing:
            switch next {
            case .verifying, .failed, .blocked, .cancelled:
                return true
            default:
                return false
            }

        case .verifying:
            switch next {
            case .running, .executing, .completed, .failed, .blocked, .cancelled:
                return true
            default:
                return false
            }

        case .completed, .failed, .blocked, .cancelled:
            // Terminal states CANNOT transition further
            return false
        }
    }

    /// Validates step-level state transition.
    public static func canTransitionStep(from current: QPlanStepState, to next: QPlanStepState) -> Bool {
        if current == next { return true }

        switch current {
        case .pending:
            switch next {
            case .waitingForPermission, .executing, .blocked, .failed, .skipped:
                return true
            default:
                return false
            }

        case .waitingForPermission:
            switch next {
            case .executing, .blocked, .failed, .skipped:
                return true
            default:
                return false
            }

        case .executing:
            switch next {
            case .verifying, .failed, .blocked:
                return true
            default:
                return false
            }

        case .verifying:
            switch next {
            case .completed, .failed, .blocked:
                return true
            default:
                return false
            }

        case .completed, .failed, .blocked, .skipped:
            // Terminal step states cannot transition
            return false
        }
    }
}
