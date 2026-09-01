//
//  QReplanController.swift
//  leanring-buddy
//
//  Q Security Architecture — Replan Controller (Phase 2C).
//  Governs autonomous failure recovery, enforces hard replanning limits (max 2),
//  detects infinite loops and repeated identical failures, and constructs sanitized replan requests.
//

import Foundation

// MARK: - Replan Decision & Models

public enum QReplanDecision: Equatable, Sendable {
    case allow(request: QReplanRequest)
    case denied(reason: String)
}

public struct QPlanIterationRecord: Codable, Sendable, Equatable {
    public let attemptNumber: Int
    public let planId: UUID
    public let stepSignatures: [String]
    public let evaluation: QGoalEvaluation
    public let replanReason: String?
    public let timestamp: Date

    public init(
        attemptNumber: Int,
        planId: UUID,
        stepSignatures: [String],
        evaluation: QGoalEvaluation,
        replanReason: String? = nil,
        timestamp: Date = Date()
    ) {
        self.attemptNumber = attemptNumber
        self.planId = planId
        self.stepSignatures = stepSignatures
        self.evaluation = evaluation
        self.replanReason = replanReason
        self.timestamp = timestamp
    }
}

public struct QReplanRequest: Codable, Sendable, Equatable {
    public let originalGoal: String
    public let attemptNumber: Int
    public let maxAttempts: Int
    public let missingConditions: [String]
    public let completedEvidence: [String]
    public let priorFailureReason: String
    public let sanitizedPrompt: String

    public init(
        originalGoal: String,
        attemptNumber: Int,
        maxAttempts: Int,
        missingConditions: [String],
        completedEvidence: [String],
        priorFailureReason: String,
        sanitizedPrompt: String
    ) {
        self.originalGoal = originalGoal
        self.attemptNumber = attemptNumber
        self.maxAttempts = maxAttempts
        self.missingConditions = missingConditions
        self.completedEvidence = completedEvidence
        self.priorFailureReason = priorFailureReason
        self.sanitizedPrompt = sanitizedPrompt
    }
}

// MARK: - Replan Controller Implementation

public final class QReplanController: @unchecked Sendable {
    public let maxReplans: Int
    private let lock = NSRecursiveLock()
    private var history: [QPlanIterationRecord] = []

    public init(maxReplans: Int = 2) {
        self.maxReplans = maxReplans
    }

    /// Resets iteration history for a new top-level task.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
    }

    /// Records an execution iteration in structured history.
    public func recordIteration(
        plan: QPlan,
        evaluation: QGoalEvaluation,
        replanReason: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let signatures = plan.steps.map { "\($0.action.actionName):\($0.action.targetResources.joined(separator: ","))" }
        let record = QPlanIterationRecord(
            attemptNumber: history.count + 1,
            planId: plan.id,
            stepSignatures: signatures,
            evaluation: evaluation,
            replanReason: replanReason
        )
        history.append(record)
    }

    /// Returns a copy of the iteration history.
    public func getHistory() -> [QPlanIterationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    /// Evaluates whether a new plan should be generated or if the agent must halt.
    public func evaluateReplan(
        goal: String,
        currentPlan: QPlan,
        evaluation: QGoalEvaluation
    ) -> QReplanDecision {
        lock.lock()
        defer { lock.unlock() }

        // 1. If Goal is already satisfied, no replan needed
        if evaluation.isSatisfied {
            return .denied(reason: "Goal is already fully satisfied")
        }

        // 2. If Blocked by Security Policy, NEVER replan around security
        if evaluation.isBlocked || currentPlan.state.isBlocked {
            return .denied(reason: "Execution was blocked by security policy; replanning around security blocks is prohibited.")
        }

        // 3. Enforce Hard Replan Limit (Default: max 2 attempts)
        let currentAttempts = history.count
        if currentAttempts >= maxReplans {
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: currentPlan.sessionId,
                    taskId: currentPlan.taskId,
                    tool: "replan.limit_reached",
                    riskLevel: .level0ReadOnly,
                    rawArguments: "attempt=\(currentAttempts), max=\(maxReplans)",
                    authorizationResult: "halt",
                    provenance: "trusted:system",
                    executionSummary: "Hard replan limit reached (\(currentAttempts)/\(maxReplans)). Halting loop."
                )
            )
            return .denied(reason: "Exceeded maximum replan limit of \(maxReplans) attempts.")
        }

        // 4. Detect Repeated Identical Plan (Loop Detection)
        let currentSignatures = currentPlan.steps.map { "\($0.action.actionName):\($0.action.targetResources.joined(separator: ","))" }
        if history.contains(where: { $0.stepSignatures == currentSignatures && $0.evaluation.state != .satisfied }) {
            return .denied(reason: "Loop detected: Generated plan is identical to a prior failed attempt.")
        }

        // 5. Detect Repeated Failed Action
        if let failedStep = currentPlan.steps.first(where: { $0.isFailed }) {
            let failedActionSig = "\(failedStep.action.actionName):\(failedStep.action.targetResources.joined(separator: ","))"
            let previousFailures = history.filter { record in
                record.stepSignatures.contains(where: { $0 == failedActionSig })
            }
            if previousFailures.count >= 2 {
                return .denied(reason: "Repeated failure on action '\(failedStep.action.actionName)'. Halting execution.")
            }
        }

        // 6. Build Sanitized Replan Request
        let nextAttempt = currentAttempts + 1
        let failureDetail = evaluation.missingConditions.joined(separator: "; ")
        let evidenceDetail = evaluation.evidence.joined(separator: "; ")

        let prompt = """
        Goal: \(goal)
        Prior Attempt \(nextAttempt)/\(maxReplans) did not satisfy all conditions.
        Missing Conditions: \(failureDetail.isEmpty ? "Action verification could not be confirmed" : failureDetail)
        Completed Verified Evidence: \(evidenceDetail.isEmpty ? "None" : evidenceDetail)
        Generate a corrective multi-step plan to satisfy the remaining missing conditions.
        """

        let request = QReplanRequest(
            originalGoal: goal,
            attemptNumber: nextAttempt,
            maxAttempts: maxReplans,
            missingConditions: evaluation.missingConditions,
            completedEvidence: evaluation.evidence,
            priorFailureReason: failureDetail,
            sanitizedPrompt: prompt
        )

        // Audit replan request
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: currentPlan.sessionId,
                taskId: currentPlan.taskId,
                tool: "replan.requested",
                riskLevel: .level0ReadOnly,
                rawArguments: "attempt=\(nextAttempt)/\(maxReplans)",
                authorizationResult: "allow",
                provenance: "trusted:system",
                executionSummary: "Approved replan attempt \(nextAttempt)/\(maxReplans)"
            )
        )

        return .allow(request: request)
    }
}
