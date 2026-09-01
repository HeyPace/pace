//
//  QTaskRecoveryManager.swift
//  leanring-buddy
//
//  Q Security Architecture — Task Recovery & Idempotent Resume Engine (Phase 2D).
//  Discovers incomplete tasks, validates persisted state, conducts observation-first
//  re-verification of uncertain steps, and safely resumes or fails closed.
//

import Foundation
import AppKit

public enum QRecoveryStatus: Sendable, Equatable {
    case notFound
    case recoverable(task: QDurableTaskState, plan: QDurablePlanSnapshot)
    case needsVerification(task: QDurableTaskState, plan: QDurablePlanSnapshot, stepIndex: Int, uncertainStep: QDurablePlanStepSnapshot)
    case needsPermission(task: QDurableTaskState, plan: QDurablePlanSnapshot, stepIndex: Int, reason: String)
    case securityBlocked(task: QDurableTaskState, reason: String)
    case corrupted(taskId: String, reason: String)
    case completed(task: QDurableTaskState)
    case failed(task: QDurableTaskState, reason: String)
}

public final class QTaskRecoveryManager: Sendable {
    public static let shared = QTaskRecoveryManager()

    private let store: QDurableTaskStoreProtocol
    private let verifier: QActionVerifier
    private let executionService: QExecutionService

    public init(
        store: QDurableTaskStoreProtocol = QDurableTaskStore.shared,
        verifier: QActionVerifier = QActionVerifier.shared,
        executionService: QExecutionService = QExecutionService.shared
    ) {
        self.store = store
        self.verifier = verifier
        self.executionService = executionService
    }

    /// Discovers all incomplete tasks in durable storage.
    public func discoverIncompleteTasks() throws -> [QDurableTaskState] {
        try store.listIncompleteTasks()
    }

    /// Analyzes the durable state and lifecycle events to produce a recovery decision.
    public func evaluateTaskRecovery(taskId: String) async throws -> QRecoveryStatus {
        guard let taskState = try store.getTask(taskId: taskId) else {
            return .notFound
        }

        // 1. Terminal task states require no resume
        if taskState.lifecycleState == .completed {
            return .completed(task: taskState)
        }

        if taskState.lifecycleState == .failed {
            return .failed(task: taskState, reason: taskState.lastKnownError ?? "Task marked failed")
        }

        if taskState.lifecycleState == .blocked {
            return .securityBlocked(task: taskState, reason: taskState.securityBlockReason ?? "Security guard blocked")
        }

        guard let planId = taskState.currentPlanId,
              let planSnapshot = try store.getPlan(planId: planId) else {
            return .corrupted(taskId: taskId, reason: "Missing or unreadable plan snapshot for task \(taskId)")
        }

        // Validate plan snapshot schema and capabilities
        do {
            _ = try planSnapshot.validate()
        } catch {
            return .corrupted(taskId: taskId, reason: "Plan snapshot failed validation: \(error.localizedDescription)")
        }

        // 2. Check for security blocks
        if let blockReason = taskState.securityBlockReason, !blockReason.isEmpty {
            return .securityBlocked(task: taskState, reason: blockReason)
        }

        // 3. Inspect events to identify last known step
        let events = try store.listEvents(taskId: taskId)
        let lastStepStartedEvent = events.last(where: { $0.eventType == .stepStarted })
        let lastStepCompletedEvent = events.last(where: { $0.eventType == .stepCompleted })

        let currentStepIdx = taskState.currentStepIndex
        guard currentStepIdx >= 0 && currentStepIdx < planSnapshot.steps.count else {
            return .recoverable(task: taskState, plan: planSnapshot)
        }

        let currentStep = planSnapshot.steps[currentStepIdx]

        // 4. Check if current step was in-flight (uncertain) during crash
        if currentStep.state == "running" || (lastStepStartedEvent != nil && lastStepCompletedEvent == nil) {
            return .needsVerification(
                task: taskState,
                plan: planSnapshot,
                stepIndex: currentStepIdx,
                uncertainStep: currentStep
            )
        }

        // 5. Check if awaiting permission
        if currentStep.state.hasPrefix("waitingForApproval") || taskState.lifecycleState == .awaitingApproval {
            return .needsPermission(
                task: taskState,
                plan: planSnapshot,
                stepIndex: currentStepIdx,
                reason: taskState.securityBlockReason ?? "Approval required"
            )
        }

        return .recoverable(task: taskState, plan: planSnapshot)
    }

    /// Performs observation-first re-verification of an uncertain step.
    /// If the physical effect already exists in system state, marks the step verified;
    /// otherwise marks it pending so it can safely execute once.
    public func resolveUncertainStep(
        task: QDurableTaskState,
        plan: QDurablePlanSnapshot,
        stepIndex: Int,
        uncertainStep: QDurablePlanStepSnapshot
    ) async throws -> (updatedTask: QDurableTaskState, updatedPlan: QDurablePlanSnapshot, isVerified: Bool) {
        var updatedTask = task
        var updatedPlanSteps = plan.steps

        // Empirical Observation Check based on action
        var verified = false
        var verifiedEvidence = ""

        switch uncertainStep.actionName {
        case "ui.open_app":
            let appName = uncertainStep.targetResources.first ?? uncertainStep.arguments["appName"] ?? ""
            if !appName.isEmpty {
                // Check if application is running in system state
                let isRunning = NSWorkspace.shared.runningApplications.contains { (app: NSRunningApplication) -> Bool in
                    if let name = app.localizedName, name.caseInsensitiveCompare(appName) == .orderedSame { return true }
                    if let bid = app.bundleIdentifier, bid.caseInsensitiveCompare(appName) == .orderedSame { return true }
                    return false
                }
                if isRunning {
                    verified = true
                    verifiedEvidence = "Observation verified: Application '\(appName)' is already running in macOS process space."
                } else {
                    let obsReq = QActionRequest(
                        actionId: UUID().uuidString,
                        toolName: "system.running_apps",
                        toolFamily: "system",
                        riskLevel: .level0ReadOnly,
                        literalAction: "Observation check running apps",
                        parameters: [:]
                    )
                    if let runningAppsRes = try? await executionService.executeAction(obsReq, context: QTaskContext(taskId: task.taskId)) {
                        let allApps = (runningAppsRes.outputData["apps"] ?? "") + "\n" + runningAppsRes.summary
                        if allApps.localizedCaseInsensitiveContains(appName) {
                            verified = true
                            verifiedEvidence = "Observation verified: Application '\(appName)' is already running in macOS process space."
                        }
                    }
                }
            }

        case "fs.write_sandbox":
            let path = uncertainStep.targetResources.first ?? uncertainStep.arguments["path"] ?? ""
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                verified = true
                verifiedEvidence = "Observation verified: Sandbox file '\(path)' exists on filesystem."
            }

        default:
            // Non-idempotent or pure read-only tool: not verified, must execute safely
            verified = false
        }

        if verified {
            // Update step as completed
            let completedStep = QDurablePlanStepSnapshot(
                stepId: uncertainStep.stepId,
                index: uncertainStep.index,
                actionName: uncertainStep.actionName,
                toolFamily: uncertainStep.toolFamily,
                riskLevel: uncertainStep.riskLevel,
                literalAction: uncertainStep.literalAction,
                targetResources: uncertainStep.targetResources,
                arguments: uncertainStep.arguments,
                expectedOutcomes: uncertainStep.expectedOutcomes,
                verificationStrategy: uncertainStep.verificationStrategy,
                state: "completed",
                resultSummary: "Recovered and verified existing system effect.",
                verifiedEvidence: verifiedEvidence
            )
            updatedPlanSteps[stepIndex] = completedStep

            if !updatedTask.completedStepIds.contains(uncertainStep.stepId) {
                updatedTask.completedStepIds.append(uncertainStep.stepId)
            }
            updatedTask.verificationEvidenceReferences.append(verifiedEvidence)
            updatedTask.currentStepIndex = stepIndex + 1

            // Record step verified event
            try store.recordEvent(
                QTaskLifecycleEvent(
                    taskId: task.taskId,
                    sessionId: task.sessionId,
                    eventType: .stepVerified,
                    payload: [
                        "stepIndex": "\(stepIndex)",
                        "actionName": uncertainStep.actionName,
                        "evidence": verifiedEvidence,
                        "recovery": "observation_first"
                    ]
                )
            )
        } else {
            // Mark step pending so it executes safely once
            let pendingStep = QDurablePlanStepSnapshot(
                stepId: uncertainStep.stepId,
                index: uncertainStep.index,
                actionName: uncertainStep.actionName,
                toolFamily: uncertainStep.toolFamily,
                riskLevel: uncertainStep.riskLevel,
                literalAction: uncertainStep.literalAction,
                targetResources: uncertainStep.targetResources,
                arguments: uncertainStep.arguments,
                expectedOutcomes: uncertainStep.expectedOutcomes,
                verificationStrategy: uncertainStep.verificationStrategy,
                state: "pending",
                resultSummary: nil,
                verifiedEvidence: nil
            )
            updatedPlanSteps[stepIndex] = pendingStep
        }

        let updatedPlan = QDurablePlanSnapshot(
            planId: plan.planId,
            taskId: plan.taskId,
            sessionId: plan.sessionId,
            goal: plan.goal,
            steps: updatedPlanSteps,
            state: plan.state,
            creationTimestamp: plan.creationTimestamp,
            schemaVersion: plan.schemaVersion
        )

        try store.saveTask(updatedTask)
        try store.savePlan(updatedPlan)

        return (updatedTask, updatedPlan, verified)
    }
}
