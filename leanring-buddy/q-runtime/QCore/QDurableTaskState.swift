//
//  QDurableTaskState.swift
//  leanring-buddy
//
//  Q Security Architecture — Durable Serializable Task State (Phase 2D).
//  Encapsulates complete serializable state of an in-flight or terminal task
//  for crash recovery, without persisting closures, sockets, tokens, or live handles.
//

import Foundation

public enum QDurableTaskLifecycleState: String, Codable, Sendable, Equatable {
    case pending = "pending"
    case running = "running"
    case awaitingApproval = "awaiting_approval"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case blocked = "blocked"
    case unknown = "unknown"
}

public struct QDurableTaskState: Codable, Sendable, Equatable {
    public let taskId: String
    public let sessionId: String
    public let originalIntent: String
    public let taskCreationTimestamp: Date
    public var lastUpdatedTimestamp: Date
    public var lifecycleState: QDurableTaskLifecycleState
    public var currentPlanId: String?
    public var currentStepIndex: Int
    public var completedStepIds: [String]
    public var failedStepIds: [String]
    public var skippedStepIds: [String]
    public var verificationEvidenceReferences: [String]
    public var goalEvaluationState: String
    public var replanAttemptCount: Int
    public var maxReplanAttempts: Int
    public var lastKnownError: String?
    public var securityBlockReason: String?
    public var provenance: String
    public var schemaVersion: Int
    public var budget: QAgentBudget

    public init(
        taskId: String,
        sessionId: String,
        originalIntent: String,
        taskCreationTimestamp: Date = Date(),
        lastUpdatedTimestamp: Date = Date(),
        lifecycleState: QDurableTaskLifecycleState = .pending,
        currentPlanId: String? = nil,
        currentStepIndex: Int = 0,
        completedStepIds: [String] = [],
        failedStepIds: [String] = [],
        skippedStepIds: [String] = [],
        verificationEvidenceReferences: [String] = [],
        goalEvaluationState: String = "unknown",
        replanAttemptCount: Int = 0,
        maxReplanAttempts: Int = 2,
        lastKnownError: String? = nil,
        securityBlockReason: String? = nil,
        provenance: String = "trusted:user",
        schemaVersion: Int = 1,
        budget: QAgentBudget = QAgentBudget()
    ) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.originalIntent = originalIntent
        self.taskCreationTimestamp = taskCreationTimestamp
        self.lastUpdatedTimestamp = lastUpdatedTimestamp
        self.lifecycleState = lifecycleState
        self.currentPlanId = currentPlanId
        self.currentStepIndex = currentStepIndex
        self.completedStepIds = completedStepIds
        self.failedStepIds = failedStepIds
        self.skippedStepIds = skippedStepIds
        self.verificationEvidenceReferences = verificationEvidenceReferences
        self.goalEvaluationState = goalEvaluationState
        self.replanAttemptCount = replanAttemptCount
        self.maxReplanAttempts = maxReplanAttempts
        self.lastKnownError = lastKnownError
        self.securityBlockReason = securityBlockReason
        self.provenance = provenance
        self.schemaVersion = schemaVersion
        self.budget = budget
    }

    public init(from task: QTask, planId: String? = nil, currentStep: Int = 0, budget: QAgentBudget = QAgentBudget()) {
        self.taskId = task.taskId
        self.sessionId = task.sessionId
        self.originalIntent = task.intent
        self.taskCreationTimestamp = task.createdAt
        self.lastUpdatedTimestamp = Date()
        self.currentPlanId = planId
        self.currentStepIndex = currentStep
        self.completedStepIds = []
        self.failedStepIds = []
        self.skippedStepIds = []
        self.verificationEvidenceReferences = []
        self.goalEvaluationState = "unknown"
        self.replanAttemptCount = 0
        self.maxReplanAttempts = 2
        self.lastKnownError = nil
        self.securityBlockReason = nil
        self.provenance = task.context.isTainted ? "untrusted" : "trusted:user"
        self.schemaVersion = 1
        self.budget = budget

        switch task.state {
        case .pending:
            self.lifecycleState = .pending
        case .running:
            self.lifecycleState = .running
        case .awaitingApproval(let req):
            self.lifecycleState = .awaitingApproval
            self.securityBlockReason = req.reason
        case .completed:
            self.lifecycleState = .completed
        case .failed(let reason):
            self.lifecycleState = .failed
            self.lastKnownError = reason
        }
    }

    /// Reconstructs a memory-safe `QTask` runtime object from persisted durable state.
    public func toTask() -> QTask {
        var task = QTask(
            taskId: taskId,
            sessionId: sessionId,
            intent: originalIntent,
            createdAt: taskCreationTimestamp
        )

        let isUntrusted = provenance.contains("untrusted")
        task.context.append(
            content: originalIntent,
            provenance: isUntrusted ? .untrustedScreen : .trustedUser(channel: "recovery"),
            sourceId: "durable_recovery"
        )

        switch lifecycleState {
        case .pending:
            task.state = .pending
        case .running:
            task.state = .running
        case .awaitingApproval:
            let approvalReq = QApprovalRequest(
                taskId: taskId,
                toolName: "recovered.tool",
                riskLevel: .level2UserApproval,
                literalAction: "Recovered action awaiting permission",
                affectedResources: [],
                scope: .global,
                reason: securityBlockReason ?? "Approval required after task recovery",
                isContextTainted: isUntrusted
            )
            task.state = .awaitingApproval(approvalReq)
        case .paused:
            task.state = .failed(reason: "Task paused (durable)")
        case .completed:
            task.state = .completed(summary: "Recovered completed task: \(originalIntent)")
        case .failed:
            task.state = .failed(reason: lastKnownError ?? "Task halted with failure")
        case .blocked:
            task.state = .failed(reason: "Security Guard Blocked: \(securityBlockReason ?? "unknown")")
        case .unknown:
            task.state = .failed(reason: "Task state corrupted or unknown")
        }

        return task
    }
}
