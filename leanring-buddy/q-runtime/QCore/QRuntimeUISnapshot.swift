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
    /// Typed risk level, alongside the pre-existing human-readable `riskLevel` string.
    /// Added in Phase 2F so `QRuntimeUISnapshot.pendingApproval` can reconstruct a real,
    /// resolvable `QApprovalRequest` without parsing `riskLevel`'s free-text description.
    public let riskLevelValue: QCapabilityLevel
    /// Target resources for this step's action. Added in Phase 2F for the same reason as
    /// `riskLevelValue` — needed to reconstruct `QApprovalRequest.affectedResources`.
    public let targetResources: [String]

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
        verifiedEvidence: String? = nil,
        riskLevelValue: QCapabilityLevel = .level0ReadOnly,
        targetResources: [String] = []
    ) {
        self.id = id
        self.index = index
        self.description = description
        self.actionName = actionName
        self.riskLevel = riskLevel
        self.state = state
        self.verifiedEvidence = verifiedEvidence
        self.riskLevelValue = riskLevelValue
        self.targetResources = targetResources
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
                verifiedEvidence: step.result?.verifiedEvidence,
                riskLevelValue: step.action.riskLevel,
                targetResources: step.action.targetResources
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

    // MARK: - Phase 2F: Approval Reconstruction

    /// Reconstructs the exact `QApprovalRequest` a live `QPlanExecutor` halt recorded for the
    /// currently-waiting step, using the same deterministic execution-identity-derived id
    /// (`QApprovalRequest.deterministicId`) that `QApprovalCoordinator` itself used when the
    /// halt actually occurred. This projection carries no execution authority of its own —
    /// `QCoreRuntime.resolveApproval` always re-validates the id against `QApprovalCoordinator`'s
    /// own live record before granting anything — but it is safe to use both for UI display and
    /// as the `approvalId` passed to `resolveApproval`/`QAgent.approve`, since two independent
    /// reconstructions from the same task/plan/step/action inputs always agree.
    ///
    /// Returns `nil` unless the plan is genuinely halted on `.waitingForPermission` with enough
    /// identifying data (`taskId`, `planId`, an in-range step) to derive a resolvable id — a
    /// request that couldn't actually be resolved is not presented as pending at all.
    public var pendingApproval: QApprovalRequest? {
        guard case .waitingForPermission(let idx, let reason) = planState,
              let taskId,
              let planId,
              steps.indices.contains(idx) else {
            return nil
        }

        let step = steps[idx]
        let identity = QExecutionIdentity(
            taskId: taskId,
            planId: planId.uuidString,
            stepId: step.id.uuidString,
            actionName: step.actionName,
            targetResources: step.targetResources
        )

        return QApprovalRequest(
            taskId: taskId,
            toolName: step.actionName,
            riskLevel: step.riskLevelValue,
            literalAction: step.description,
            affectedResources: step.targetResources,
            scope: .global,
            reason: reason,
            // Taint is not currently tracked on QPlan/QRuntimeUISnapshot, so this reconstruction
            // cannot know the real value. It only affects display text here, never authorization
            // (the actual grant, when minted, is validated against the live coordinator record).
            isContextTainted: false,
            expectedEffect: step.description,
            isReversible: step.riskLevelValue.isConsideredReversible,
            executionIdentity: identity
        )
    }
}
