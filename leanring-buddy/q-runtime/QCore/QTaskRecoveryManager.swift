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

        case "ui.activate_application":
            // Observation-first (Phase 2N): re-check whether the requested target is already
            // frontmost before ever considering a replay. Mirrors the capability's own exact-
            // match resolution contract exactly — never substring/fuzzy — and, like the live
            // capability itself, only recognizes completion when EXACTLY ONE running application
            // exactly matches the requested name and it is currently frontmost (matched by stable
            // `processIdentifier`, not `localizedName`). An ambiguous, absent, or not-yet-frontmost
            // target does NOT trigger a blind replay of activate() here — it falls through to
            // `verified = false`, so a fresh execution (with a fresh QExecutionIdentity, per
            // QPlanExecutor) goes through the normal plan-executor path exactly once, safely.
            let appName = uncertainStep.arguments["applicationName"] ?? uncertainStep.targetResources.first ?? ""
            if !appName.isEmpty {
                let exactMatches = NSWorkspace.shared.runningApplications.filter { $0.localizedName == appName }
                if exactMatches.count == 1,
                   let target = exactMatches.first,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    verified = true
                    verifiedEvidence = "Observation verified: Application '\(appName)' is already the frontmost application (pid=\(target.processIdentifier))."
                }
            }

        case "ui.focus_element":
            // Observation-first (Phase 2O): re-check whether the requested target is already the
            // systemwide focused Accessibility element before ever considering a replay. Reuses
            // the EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeFocusedElementIdentity) QActionVerification's
            // .axElementIsFocused strategy uses — no parallel resolver. An unresolvable target,
            // or a resolvable-but-not-focused one, does NOT trigger a blind replay of the AX
            // focus write here — it falls through to `verified = false`, so a fresh execution
            // requires both a brand-new QExecutionIdentity (per QPlanExecutor) AND a genuinely
            // fresh user approval grant, since QApprovalCoordinator's in-memory one-time grants
            // never survive a crash/restart (no persisted authorization is ever consulted here).
            let applicationName = uncertainStep.arguments["applicationName"] ?? ""
            let role = uncertainStep.arguments["role"] ?? ""
            let identifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let title = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            if !applicationName.isEmpty, !role.isEmpty, (identifier != nil || title != nil) {
                let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
                    applicationName: applicationName,
                    role: role,
                    identifier: identifier,
                    title: title
                )
                if case .focused(let identity) = evidence {
                    verified = true
                    verifiedEvidence = "Observation verified: target=\(identity) status=verified focused=true"
                }
            }

        case "ui.select_popup_item":
            // Observation-first (Phase 2P): re-check whether the requested popup already shows
            // the requested item before ever considering a replay. Reuses the EXACT SAME
            // independent observation primitive (QBridgeAccessibility.observePopupValueEvidence)
            // QActionVerification's .axPopupValueMatchesDesired strategy uses — no parallel
            // resolver. An unresolvable target, or a resolvable-but-wrong-value one, does NOT
            // trigger a blind replay of the AX open+select press sequence here — it falls through
            // to `verified = false`, so a fresh execution requires both a brand-new
            // QExecutionIdentity (per QPlanExecutor) AND a genuinely fresh user approval grant,
            // since QApprovalCoordinator's in-memory one-time grants never survive a
            // crash/restart (no persisted authorization is ever consulted here).
            let popupApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let popupRole = uncertainStep.arguments["role"] ?? ""
            let popupIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let popupTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let requestedItemTitle = uncertainStep.arguments["itemTitle"] ?? ""
            if !popupApplicationName.isEmpty, !popupRole.isEmpty, !requestedItemTitle.isEmpty,
               (popupIdentifier != nil || popupTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observePopupValueEvidence(
                    applicationName: popupApplicationName,
                    role: popupRole,
                    identifier: popupIdentifier,
                    title: popupTitle
                )
                if case .resolved(let currentValue) = evidence, currentValue == requestedItemTitle {
                    verified = true
                    verifiedEvidence = "Observation verified: target popup currentValue='\(currentValue)' requestedItemTitle='\(requestedItemTitle)' status=verified"
                }
            }

        case "ui.toggle_disclosure":
            // Observation-first (Phase 2Q): re-check whether the requested disclosure triangle
            // already reports the requested desired state before ever considering a replay.
            // Reuses the EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeDisclosureStateEvidence)
            // QActionVerification's .axDisclosureStateMatchesDesired strategy uses — no parallel
            // resolver. An unresolvable target, an unreadable/indeterminate state, or a
            // resolvable-but-wrong-state one, does NOT trigger a blind replay of the AX press
            // here — it falls through to `verified = false`, so a fresh execution requires both a
            // brand-new QExecutionIdentity (per QPlanExecutor) AND a genuinely fresh user approval
            // grant, since QApprovalCoordinator's in-memory one-time grants never survive a
            // crash/restart (no persisted authorization is ever consulted here). A toggle without
            // this explicit desired-state re-verification would be unsafe to resume — this branch
            // is exactly what makes it safe.
            let disclosureApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let disclosureRole = uncertainStep.arguments["role"] ?? ""
            let disclosureIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let disclosureTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let disclosureDesiredStateRaw = uncertainStep.arguments["desiredState"] ?? ""
            if !disclosureApplicationName.isEmpty, !disclosureRole.isEmpty,
               let disclosureDesiredState = QAXDisclosureState(rawValue: disclosureDesiredStateRaw),
               (disclosureIdentifier != nil || disclosureTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeDisclosureStateEvidence(
                    applicationName: disclosureApplicationName,
                    role: disclosureRole,
                    identifier: disclosureIdentifier,
                    title: disclosureTitle
                )
                if case .resolved(let currentState) = evidence, currentState == disclosureDesiredState {
                    verified = true
                    verifiedEvidence = "Observation verified: target disclosure currentState='\(currentState.rawValue)' desiredState='\(disclosureDesiredState.rawValue)' status=verified"
                }
            }

        case "ui.select_tab":
            // Observation-first (Phase 2R): re-check whether the requested tab already reports
            // the requested desired selection state before ever considering a replay. Reuses the
            // EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeTabSelectionEvidence) QActionVerification's
            // .axTabSelectionMatchesDesired strategy uses — no parallel resolver. An unresolvable/
            // ambiguous/no-longer-subrole-qualified target, an unreadable selection state, or a
            // resolvable-but-wrong-state one, does NOT trigger a blind replay of the AX press
            // here — it falls through to `verified = false`, so a fresh execution requires both a
            // brand-new QExecutionIdentity (per QPlanExecutor) AND a genuinely fresh user approval
            // grant, since QApprovalCoordinator's in-memory one-time grants never survive a
            // crash/restart (no persisted authorization is ever consulted here). A selection
            // without this explicit desired-state re-verification would be unsafe to resume —
            // this branch is exactly what makes it safe.
            let tabApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let tabRole = uncertainStep.arguments["role"] ?? ""
            let tabIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let tabTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let tabDesiredSelectedRaw = uncertainStep.arguments["desiredSelected"] ?? ""
            if !tabApplicationName.isEmpty, !tabRole.isEmpty,
               let tabDesiredSelected = Bool(tabDesiredSelectedRaw),
               (tabIdentifier != nil || tabTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeTabSelectionEvidence(
                    applicationName: tabApplicationName,
                    role: tabRole,
                    identifier: tabIdentifier,
                    title: tabTitle
                )
                if case .resolved(let currentSelected) = evidence, currentSelected == tabDesiredSelected {
                    verified = true
                    verifiedEvidence = "Observation verified: target tab currentSelected='\(currentSelected)' desiredSelected='\(tabDesiredSelected)' status=verified"
                }
            }

        case "ui.select_table_row":
            // Observation-first (Phase 2S): re-check whether the requested table row already
            // reports selected=true before ever considering a replay. Reuses the EXACT SAME
            // independent observation primitive
            // (QBridgeAccessibility.observeTableRowSelectionEvidence) QActionVerification's
            // .axTableRowSelectionMatchesDesired strategy uses — no parallel resolver. An
            // unresolvable/ambiguous/no-longer-subrole-or-table-context-qualified target, an
            // unreadable selection state, or a resolvable-but-not-selected one, does NOT trigger
            // a blind replay of the AX press here — it falls through to `verified = false`, so a
            // fresh execution requires both a brand-new QExecutionIdentity (per QPlanExecutor)
            // AND a genuinely fresh user approval grant, since QApprovalCoordinator's in-memory
            // one-time grants never survive a crash/restart (no persisted authorization is ever
            // consulted here). A selection without this explicit desired-state re-verification
            // would be unsafe to resume — this branch is exactly what makes it safe. Note: since
            // this capability only ever supports `desiredSelected=true` (deselection is
            // categorically out of scope, refused before dispatch), a persisted step is only ever
            // resumed toward `true` — there is no `desiredSelected=false` case to reconstruct.
            let rowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let rowRole = uncertainStep.arguments["role"] ?? ""
            let rowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let rowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let rowDesiredSelectedRaw = uncertainStep.arguments["desiredSelected"] ?? ""
            if !rowApplicationName.isEmpty, !rowRole.isEmpty,
               let rowDesiredSelected = Bool(rowDesiredSelectedRaw), rowDesiredSelected,
               (rowIdentifier != nil || rowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeTableRowSelectionEvidence(
                    applicationName: rowApplicationName,
                    role: rowRole,
                    identifier: rowIdentifier,
                    title: rowTitle
                )
                if case .resolved(let currentSelected) = evidence, currentSelected == rowDesiredSelected {
                    verified = true
                    verifiedEvidence = "Observation verified: target table row currentSelected='\(currentSelected)' desiredSelected='\(rowDesiredSelected)' status=verified"
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
