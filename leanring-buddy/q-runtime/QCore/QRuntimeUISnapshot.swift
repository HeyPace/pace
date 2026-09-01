//
//  QRuntimeUISnapshot.swift
//  leanring-buddy
//
//  Q Security Architecture — Live UI Runtime Snapshot (Phase 2A.2).
//  A strictly read-only, presentation-safe projection of the QPlan runtime state.
//  Contains NO execution references, NO permission tokens, and NO secret access.
//

import Foundation

public struct QRuntimeStepSnapshot: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let index: Int
    public let description: String
    public let actionName: String
    public let riskLevel: String
    public let state: QPlanStepState
    public let verifiedEvidence: String?

    public var isExecuting: Bool {
        if case .executing = state { return true }
        return false
    }

    public var isVerifying: Bool {
        if case .verifying = state { return true }
        return false
    }

    public var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .blocked = state { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    public var isSkipped: Bool {
        if case .skipped = state { return true }
        return false
    }

    public var isWaitingForPermission: Bool {
        if case .waitingForPermission = state { return true }
        return false
    }

    public var statusGlyph: String {
        switch state {
        case .completed:
            return "✓"
        case .executing:
            return "●"
        case .verifying:
            return "◐"
        case .waitingForPermission:
            return "⏸"
        case .pending:
            return "○"
        case .blocked:
            return "⊘"
        case .failed:
            return "✗"
        case .skipped:
            return "–"
        }
    }

    public init(
        id: UUID,
        index: Int,
        description: String,
        actionName: String,
        riskLevel: String,
        state: QPlanStepState,
        verifiedEvidence: String? = nil
    ) {
        self.id = id
        self.index = index
        self.description = description
        self.actionName = actionName
        self.riskLevel = riskLevel
        self.state = state
        self.verifiedEvidence = verifiedEvidence
    }
}

public struct QRuntimeUISnapshot: Sendable, Equatable, Codable {
    public let planId: UUID?
    public let taskId: String?
    public let taskPrompt: String?
    public let planState: QPlanState?
    public let currentStepIndex: Int?
    public let totalSteps: Int
    public let currentStepDescription: String?
    public let currentStepState: QPlanStepState?
    public let statusMessage: String?
    public let replanAttempt: Int?
    public let maxReplanAttempts: Int?
    public let goalEvaluationState: QGoalEvaluationState?
    public let recoveryMessage: String?
    public let isRecovering: Bool
    public let isPaused: Bool
    public let uncertainStepIndex: Int?
    public let budgetDecision: String?
    public let steps: [QRuntimeStepSnapshot]
    public let timestamp: Date

    public var isTerminal: Bool {
        planState?.isTerminal ?? true
    }

    public var isReplanning: Bool {
        if let attempt = replanAttempt, attempt > 0 {
            return true
        }
        return false
    }

    public init(
        planId: UUID? = nil,
        taskId: String? = nil,
        taskPrompt: String? = nil,
        planState: QPlanState? = nil,
        currentStepIndex: Int? = nil,
        totalSteps: Int = 0,
        currentStepDescription: String? = nil,
        currentStepState: QPlanStepState? = nil,
        statusMessage: String? = nil,
        replanAttempt: Int? = nil,
        maxReplanAttempts: Int? = nil,
        goalEvaluationState: QGoalEvaluationState? = nil,
        recoveryMessage: String? = nil,
        isRecovering: Bool = false,
        isPaused: Bool = false,
        uncertainStepIndex: Int? = nil,
        budgetDecision: String? = nil,
        steps: [QRuntimeStepSnapshot] = [],
        timestamp: Date = Date()
    ) {
        self.planId = planId
        self.taskId = taskId
        self.taskPrompt = taskPrompt
        self.planState = planState
        self.currentStepIndex = currentStepIndex
        self.totalSteps = totalSteps
        self.currentStepDescription = currentStepDescription
        self.currentStepState = currentStepState
        self.statusMessage = statusMessage
        self.replanAttempt = replanAttempt
        self.maxReplanAttempts = maxReplanAttempts
        self.goalEvaluationState = goalEvaluationState
        self.recoveryMessage = recoveryMessage
        self.isRecovering = isRecovering
        self.isPaused = isPaused
        self.uncertainStepIndex = uncertainStepIndex
        self.budgetDecision = budgetDecision
        self.steps = steps
        self.timestamp = timestamp
    }

    /// Pure projection mapping from authoritative QPlan data model to UI presentation snapshot
    public static func from(plan: QPlan, statusMessage: String? = nil) -> QRuntimeUISnapshot {
        var activeStepIndex: Int? = nil
        var activeStepDesc: String? = nil
        var activeStepState: QPlanStepState? = nil

        switch plan.state {
        case .executing(let idx), .verifying(let idx):
            activeStepIndex = idx
            if idx < plan.steps.count {
                activeStepDesc = plan.steps[idx].description
                activeStepState = plan.steps[idx].state
            }
        case .waitingForPermission(let idx, _):
            activeStepIndex = idx
            if idx < plan.steps.count {
                activeStepDesc = plan.steps[idx].description
                activeStepState = plan.steps[idx].state
            }
        case .failed(_, let idx), .blocked(_, let idx):
            if let idx, idx < plan.steps.count {
                activeStepIndex = idx
                activeStepDesc = plan.steps[idx].description
                activeStepState = plan.steps[idx].state
            }
        default:
            break
        }

        let stepSnapshots: [QRuntimeStepSnapshot] = plan.steps.map { step in
            QRuntimeStepSnapshot(
                id: step.id,
                index: step.index,
                description: step.description,
                actionName: step.action.actionName,
                riskLevel: step.action.riskLevel.description,
                state: step.state,
                verifiedEvidence: step.result?.verifiedEvidence
            )
        }

        return QRuntimeUISnapshot(
            planId: plan.id,
            taskId: plan.taskId,
            taskPrompt: plan.taskPrompt,
            planState: plan.state,
            currentStepIndex: activeStepIndex,
            totalSteps: plan.steps.count,
            currentStepDescription: activeStepDesc,
            currentStepState: activeStepState,
            statusMessage: statusMessage,
            steps: stepSnapshots,
            timestamp: Date()
        )
    }
}
