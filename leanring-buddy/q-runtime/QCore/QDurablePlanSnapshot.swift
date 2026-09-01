//
//  QDurablePlanSnapshot.swift
//  leanring-buddy
//
//  Q Security Architecture — Validated Durable Plan Snapshot (Phase 2D).
//  Provides serialization and decoding validation for persisted execution plans,
//  strictly preventing unvalidated or corrupted plan deserialization.
//

import Foundation

public enum QDurablePlanError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidStepIndex(expected: Int, actual: Int)
    case unallowlistedCapability(String)
    case malformedArguments(String)
    case invalidRiskLevel(String)
    case emptyPlan

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let v):
            return "Unsupported durable plan schema version: \(v)"
        case .invalidStepIndex(let expected, let actual):
            return "Durable plan step index mismatch (expected \(expected), got \(actual))"
        case .unallowlistedCapability(let cap):
            return "Durable plan contains forbidden or unallowlisted capability: '\(cap)'"
        case .malformedArguments(let msg):
            return "Durable plan contains malformed arguments: \(msg)"
        case .invalidRiskLevel(let lvl):
            return "Durable plan contains invalid risk level: '\(lvl)'"
        case .emptyPlan:
            return "Durable plan contains zero execution steps"
        }
    }
}

public struct QDurablePlanStepSnapshot: Codable, Sendable, Equatable {
    public let stepId: String
    public let index: Int
    public let actionName: String
    public let toolFamily: String
    public let riskLevel: String
    public let literalAction: String
    public let targetResources: [String]
    public let arguments: [String: String]
    public let expectedOutcomes: [String]
    public let verificationStrategy: String
    public let state: String
    public let resultSummary: String?
    public let verifiedEvidence: String?

    public init(
        stepId: String = UUID().uuidString,
        index: Int,
        actionName: String,
        toolFamily: String,
        riskLevel: String,
        literalAction: String,
        targetResources: [String] = [],
        arguments: [String: String] = [:],
        expectedOutcomes: [String] = [],
        verificationStrategy: String = "empirical",
        state: String = "pending",
        resultSummary: String? = nil,
        verifiedEvidence: String? = nil
    ) {
        self.stepId = stepId
        self.index = index
        self.actionName = actionName
        self.toolFamily = toolFamily
        self.riskLevel = riskLevel
        self.literalAction = literalAction
        self.targetResources = targetResources
        self.arguments = arguments
        self.expectedOutcomes = expectedOutcomes
        self.verificationStrategy = verificationStrategy
        self.state = state
        self.resultSummary = resultSummary
        self.verifiedEvidence = verifiedEvidence
    }

    public init(from step: QPlanStep) {
        self.stepId = step.id.uuidString
        self.index = step.index
        self.actionName = step.action.actionName
        self.toolFamily = step.action.toolFamily
        self.riskLevel = "\(step.action.riskLevel.rawValue)"
        self.literalAction = step.action.literalAction
        self.targetResources = step.action.targetResources
        self.arguments = step.action.arguments
        self.expectedOutcomes = []
        self.verificationStrategy = "empirical"

        switch step.state {
        case .pending:
            self.state = "pending"
        case .executing:
            self.state = "executing"
        case .verifying:
            self.state = "verifying"
        case .completed:
            self.state = "completed"
        case .failed(let reason):
            self.state = "failed:\(reason)"
        case .blocked(let reason):
            self.state = "blocked:\(reason)"
        case .waitingForPermission(let reason):
            self.state = "waitingForPermission:\(reason)"
        case .skipped(let reason):
            self.state = "skipped:\(reason)"
        }

        self.resultSummary = step.result?.summary
        self.verifiedEvidence = step.result?.verifiedEvidence
    }
}

public struct QDurablePlanSnapshot: Codable, Sendable, Equatable {
    public let planId: String
    public let taskId: String
    public let sessionId: String
    public let goal: String
    public let steps: [QDurablePlanStepSnapshot]
    public let state: String
    public let creationTimestamp: Date
    public let schemaVersion: Int

    public init(
        planId: String = UUID().uuidString,
        taskId: String,
        sessionId: String,
        goal: String,
        steps: [QDurablePlanStepSnapshot],
        state: String = "pending",
        creationTimestamp: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.planId = planId
        self.taskId = taskId
        self.sessionId = sessionId
        self.goal = goal
        self.steps = steps
        self.state = state
        self.creationTimestamp = creationTimestamp
        self.schemaVersion = schemaVersion
    }

    public init(from plan: QPlan) {
        self.planId = plan.id.uuidString
        self.taskId = plan.taskId
        self.sessionId = plan.sessionId
        self.goal = plan.taskPrompt
        self.steps = plan.steps.map { QDurablePlanStepSnapshot(from: $0) }
        self.creationTimestamp = plan.createdAt
        self.schemaVersion = 1

        switch plan.state {
        case .pending:
            self.state = "pending"
        case .running:
            self.state = "running"
        case .executing(let idx):
            self.state = "executing:\(idx)"
        case .verifying(let idx):
            self.state = "verifying:\(idx)"
        case .completed(let sum):
            self.state = "completed:\(sum)"
        case .failed(let reason, let stepIdx):
            self.state = "failed:\(stepIdx ?? -1):\(reason)"
        case .blocked(let reason, let stepIdx):
            self.state = "blocked:\(stepIdx ?? -1):\(reason)"
        case .waitingForPermission(let stepIdx, let reason):
            self.state = "waitingForPermission:\(stepIdx):\(reason)"
        case .cancelled(let reason):
            self.state = "cancelled:\(reason)"
        }
    }

    /// Validates the persisted plan snapshot against schema rules, capability allowlists, and step ordering.
    public func validate(
        allowedCapabilities: Set<String> = [
            "system.running_apps",
            "system.clipboard.read",
            "screen.ocr",
            "ui.open_app",
            "fs.read",
            "fs.write_sandbox",
            "accessibility.read",
            "test.noop"
        ]
    ) throws -> QPlan {
        guard schemaVersion == 1 else {
            throw QDurablePlanError.unsupportedSchemaVersion(schemaVersion)
        }

        guard !steps.isEmpty else {
            throw QDurablePlanError.emptyPlan
        }

        var reconstructedSteps: [QPlanStep] = []

        for (expectedIdx, stepSnapshot) in steps.enumerated() {
            guard stepSnapshot.index == expectedIdx else {
                throw QDurablePlanError.invalidStepIndex(expected: expectedIdx, actual: stepSnapshot.index)
            }

            guard allowedCapabilities.contains(stepSnapshot.actionName) else {
                throw QDurablePlanError.unallowlistedCapability(stepSnapshot.actionName)
            }

            guard let riskLevel = parseCapabilityLevel(stepSnapshot.riskLevel) else {
                throw QDurablePlanError.invalidRiskLevel(stepSnapshot.riskLevel)
            }

            // Capability cannot declare Level 4
            guard riskLevel != .level4Blocked else {
                throw QDurablePlanError.unallowlistedCapability("Level 4 Blocked capability cannot be reconstructed: \(stepSnapshot.actionName)")
            }

            let plannedAction = QPlannedAction(
                actionName: stepSnapshot.actionName,
                toolFamily: stepSnapshot.toolFamily,
                riskLevel: riskLevel,
                literalAction: stepSnapshot.literalAction,
                targetResources: stepSnapshot.targetResources,
                arguments: stepSnapshot.arguments
            )

            let stepUUID = UUID(uuidString: stepSnapshot.stepId) ?? UUID()
            var step = QPlanStep(
                id: stepUUID,
                index: stepSnapshot.index,
                action: plannedAction,
                description: stepSnapshot.literalAction
            )

            // Reconstruct step state
            if stepSnapshot.state.hasPrefix("completed") {
                step.state = .completed
                step.result = QPlanStepResult(
                    stepId: step.id,
                    success: true,
                    summary: stepSnapshot.resultSummary ?? "Step completed",
                    verifiedEvidence: stepSnapshot.verifiedEvidence
                )
            } else if stepSnapshot.state.hasPrefix("failed") {
                step.state = .failed(reason: stepSnapshot.state)
            } else if stepSnapshot.state.hasPrefix("blocked") {
                step.state = .blocked(reason: stepSnapshot.state)
            } else if stepSnapshot.state.hasPrefix("waitingForPermission") {
                step.state = .waitingForPermission(reason: stepSnapshot.state)
            } else if stepSnapshot.state.hasPrefix("executing") || stepSnapshot.state.hasPrefix("running") {
                step.state = .executing
            } else if stepSnapshot.state.hasPrefix("verifying") {
                step.state = .verifying
            } else {
                step.state = .pending
            }

            reconstructedSteps.append(step)
        }

        var reconstructedPlanState: QPlanState = .pending
        if state.hasPrefix("completed") {
            reconstructedPlanState = .completed(summary: state)
        } else if state.hasPrefix("failed") {
            reconstructedPlanState = .failed(reason: state, failedStepIndex: nil)
        } else if state.hasPrefix("blocked") {
            reconstructedPlanState = .blocked(reason: state, blockedStepIndex: nil)
        } else {
            reconstructedPlanState = .pending
        }

        let planUUID = UUID(uuidString: planId) ?? UUID()
        let plan = QPlan(
            id: planUUID,
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: goal,
            createdAt: creationTimestamp,
            state: reconstructedPlanState,
            steps: reconstructedSteps
        )

        return plan
    }

    private func parseCapabilityLevel(_ str: String) -> QCapabilityLevel? {
        if str.contains("0") || str.localizedCaseInsensitiveContains("ReadOnly") { return .level0ReadOnly }
        if str.contains("1") || str.localizedCaseInsensitiveContains("SafeLocal") { return .level1SafeLocalAction }
        if str.contains("2") || str.localizedCaseInsensitiveContains("UserApproval") { return .level2UserApproval }
        if str.contains("3") || str.localizedCaseInsensitiveContains("HighRisk") { return .level3HighRisk }
        if str.contains("4") || str.localizedCaseInsensitiveContains("Blocked") { return .level4Blocked }
        return nil
    }
}
