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

        case "ui.select_outline_row":
            // Observation-first (Phase 2T): re-check whether the requested outline row already
            // reports selected=true before ever considering a replay. Reuses the EXACT SAME
            // independent observation primitive
            // (QBridgeAccessibility.observeOutlineRowSelectionEvidence) QActionVerification's
            // .axOutlineRowSelectionMatchesDesired strategy uses — no parallel resolver. An
            // unresolvable/ambiguous/no-longer-subrole-or-outline-context-qualified target, an
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
            let outlineRowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let outlineRowRole = uncertainStep.arguments["role"] ?? ""
            let outlineRowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let outlineRowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let outlineRowDesiredSelectedRaw = uncertainStep.arguments["desiredSelected"] ?? ""
            if !outlineRowApplicationName.isEmpty, !outlineRowRole.isEmpty,
               let outlineRowDesiredSelected = Bool(outlineRowDesiredSelectedRaw), outlineRowDesiredSelected,
               (outlineRowIdentifier != nil || outlineRowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeOutlineRowSelectionEvidence(
                    applicationName: outlineRowApplicationName,
                    role: outlineRowRole,
                    identifier: outlineRowIdentifier,
                    title: outlineRowTitle
                )
                if case .resolved(let currentSelected) = evidence, currentSelected == outlineRowDesiredSelected {
                    verified = true
                    verifiedEvidence = "Observation verified: target outline row currentSelected='\(currentSelected)' desiredSelected='\(outlineRowDesiredSelected)' status=verified"
                }
            }

        case "ui.set_window_minimized":
            // Observation-first (Phase 2U): re-check whether the requested window already reports
            // the requested desired minimized state before ever considering a replay. Reuses the
            // EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeWindowMinimizedStateEvidence) QActionVerification's
            // .axWindowMinimizedStateMatchesDesired strategy uses — no parallel resolver. An
            // unresolvable/ambiguous target, an unreadable minimized state, or a resolvable-but-
            // wrong-state one, does NOT trigger a blind replay of the AX attribute-set here — it
            // falls through to `verified = false`, so a fresh execution requires both a brand-new
            // QExecutionIdentity (per QPlanExecutor) AND a genuinely fresh user approval grant,
            // since QApprovalCoordinator's in-memory one-time grants never survive a
            // crash/restart (no persisted authorization is ever consulted here). Unlike
            // ui.select_outline_row's one-way `desiredSelected=true` restriction, this
            // capability's `desiredMinimized` is genuinely bidirectional — both `true` and
            // `false` are valid, fully-resumable target states, so no directional filter is
            // applied here.
            let windowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let windowRole = uncertainStep.arguments["role"] ?? ""
            let windowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let windowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let windowDesiredMinimizedRaw = uncertainStep.arguments["desiredMinimized"] ?? ""
            if !windowApplicationName.isEmpty, !windowRole.isEmpty,
               let windowDesiredMinimized = Bool(windowDesiredMinimizedRaw),
               (windowIdentifier != nil || windowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeWindowMinimizedStateEvidence(
                    applicationName: windowApplicationName,
                    role: windowRole,
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                if case .resolved(let currentMinimized) = evidence, currentMinimized == windowDesiredMinimized {
                    verified = true
                    verifiedEvidence = "Observation verified: target window currentMinimized='\(currentMinimized)' desiredMinimized='\(windowDesiredMinimized)' status=verified"
                }
            }

        case "ui.set_window_full_screen":
            // Observation-first (Phase 2AS): re-check whether the requested window already reports
            // the requested desired full-screen state before ever considering a replay. Reuses the
            // EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeWindowFullScreenStateEvidence) QActionVerification's
            // .axWindowFullScreenMatchesDesired strategy uses — no parallel resolver. An
            // unresolvable/ambiguous target, an unreadable full-screen state, or a resolvable-but-
            // wrong-state one, does NOT trigger a blind replay of the AX attribute-set here — it
            // falls through to `verified = false`, so a fresh execution requires both a brand-new
            // QExecutionIdentity (per QPlanExecutor) AND a genuinely fresh user approval grant.
            let windowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let windowRole = uncertainStep.arguments["role"] ?? ""
            let windowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let windowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let windowDesiredFullScreenRaw = uncertainStep.arguments["desiredFullScreen"] ?? ""
            if !windowApplicationName.isEmpty, !windowRole.isEmpty,
               let windowDesiredFullScreen = Bool(windowDesiredFullScreenRaw),
               (windowIdentifier != nil || windowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeWindowFullScreenStateEvidence(
                    applicationName: windowApplicationName,
                    role: windowRole,
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                if case .resolved(let currentFullScreen) = evidence, currentFullScreen == windowDesiredFullScreen {
                    verified = true
                    verifiedEvidence = "Observation verified: target window currentFullScreen='\(currentFullScreen)' desiredFullScreen='\(windowDesiredFullScreen)' status=verified"
                }
            }

        case "ui.set_window_main":
            // Observation-first (Phase 2X): re-check whether the requested window already
            // reports kAXMainAttribute == true before ever considering a replay. Reuses the
            // EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeWindowMainEvidence) QActionVerification's
            // .windowMainStateMatchesDesired strategy uses — no parallel resolver. Unlike
            // ui.set_window_minimized's bidirectional recovery, this capability's contract
            // guarantees desiredMain is always `true` (false is rejected before any AX call and
            // never reaches persisted step arguments as a resumable state), so there is nothing
            // to compare against except `currentMain == true` itself — no directional filter
            // needed, but also no `false` branch to recognize as "already correct". An
            // unresolvable/ambiguous target or an unreadable main state does NOT trigger a blind
            // replay of the AX attribute-set here — it falls through to `verified = false`, so a
            // fresh execution requires both a brand-new QExecutionIdentity (per QPlanExecutor)
            // AND a genuinely fresh user approval grant, since QApprovalCoordinator's in-memory
            // one-time grants never survive a crash/restart (no persisted authorization is ever
            // consulted here). This recovery branch makes no attempt to observe or reason about
            // any other window's main state — it only re-resolves and re-reads the exact target
            // window, mirroring the capability's own exclusivity-agnostic contract.
            let mainWindowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let mainWindowRole = uncertainStep.arguments["role"] ?? ""
            let mainWindowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let mainWindowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            if !mainWindowApplicationName.isEmpty, !mainWindowRole.isEmpty,
               (mainWindowIdentifier != nil || mainWindowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeWindowMainEvidence(
                    applicationName: mainWindowApplicationName,
                    role: mainWindowRole,
                    identifier: mainWindowIdentifier,
                    title: mainWindowTitle
                )
                if case .resolved(let currentMain) = evidence, currentMain == true {
                    verified = true
                    verifiedEvidence = "Observation verified: target window currentMain='\(currentMain)' desiredMain='true' status=verified"
                }
            }

        case "ui.close_window":
            // Observation-first (Phase 2Y, Level 3): re-check whether the requested window is
            // already absent — with its owning application independently confirmed still
            // running — before ever considering a replay. Reuses the EXACT SAME independent
            // observation primitive (QBridgeAccessibility.observeWindowCloseEvidence)
            // QActionVerification's .windowCloseVerified strategy uses — no parallel resolver.
            // Absence-based recovery is a first for this codebase: `verified = true` ONLY on
            // `.windowAbsentApplicationRunning` — a still-resolvable window, an ambiguous match,
            // an unrunning application, or an unobservable (permission-denied) state ALL fall
            // through to `verified = false` here, per this capability's explicit contract that
            // application termination must never be credited as a successful window close and
            // that absence must never be assumed from an inability to observe. A still-resolvable
            // window is NEVER blindly re-pressed here — a resumed retry requires a brand-new
            // QExecutionIdentity (per QPlanExecutor), a genuinely fresh Level 3 approval grant
            // (QApprovalCoordinator's in-memory one-time grants never survive a crash/restart, so
            // no persisted authorization is ever consulted here), fresh target resolution, and
            // fresh close-button resolution.
            let closeWindowApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let closeWindowRole = uncertainStep.arguments["role"] ?? ""
            let closeWindowIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let closeWindowTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            if !closeWindowApplicationName.isEmpty, !closeWindowRole.isEmpty,
               (closeWindowIdentifier != nil || closeWindowTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeWindowCloseEvidence(
                    applicationName: closeWindowApplicationName,
                    role: closeWindowRole,
                    identifier: closeWindowIdentifier,
                    title: closeWindowTitle
                )
                if case .windowAbsentApplicationRunning = evidence {
                    verified = true
                    verifiedEvidence = "Observation verified: applicationRunning=true windowResolvable=false status=verified"
                }
            }

        case "ui.set_application_hidden":
            // Observation-first (Phase 2V): re-check whether the requested application already
            // reports the requested desired hidden state before ever considering a replay.
            // Mirrors ui.activate_application's (Phase 2N) own exact-match resolution contract
            // exactly — never substring/fuzzy — and, like that capability's recovery branch,
            // only recognizes completion when EXACTLY ONE running application exactly matches the
            // persisted name (a stable pid from resolution time is not available to reconstruct
            // here, since only the dispatch-time arguments — not QExecutionService's outputData —
            // survive into `uncertainStep.arguments`; a fresh, unambiguous name resolution is
            // required instead, identical to ui.activate_application's own recovery discipline).
            // An ambiguous, absent, or wrong-state target does NOT trigger a blind replay of
            // hide()/unhide() here — it falls through to `verified = false`, so a fresh execution
            // requires both a brand-new QExecutionIdentity (per QPlanExecutor) AND a genuinely
            // fresh user approval grant, since QApprovalCoordinator's in-memory one-time grants
            // never survive a crash/restart (no persisted authorization is ever consulted here).
            // Like ui.set_window_minimized's own recovery branch, `desiredHidden` is genuinely
            // bidirectional — both `true` and `false` are valid, fully-resumable target states,
            // so no directional filter is applied here.
            let hiddenAppName = uncertainStep.arguments["applicationName"] ?? ""
            let hiddenDesiredRaw = uncertainStep.arguments["desiredHidden"] ?? ""
            if !hiddenAppName.isEmpty, let hiddenDesired = Bool(hiddenDesiredRaw) {
                let exactMatches = NSWorkspace.shared.runningApplications.filter { $0.localizedName == hiddenAppName }
                if exactMatches.count == 1,
                   let target = exactMatches.first,
                   target.isHidden == hiddenDesired {
                    verified = true
                    verifiedEvidence = "Observation verified: Application '\(hiddenAppName)' currentHidden='\(target.isHidden)' desiredHidden='\(hiddenDesired)' status=verified (pid=\(target.processIdentifier))."
                }
            }

        case "ui.set_scroll_position":
            // Observation-first (Phase 2W): re-check whether the requested scroll bar already
            // reports the requested desired position before ever considering a replay. Reuses the
            // EXACT SAME independent observation primitive
            // (QBridgeAccessibility.observeScrollPositionEvidence) QActionVerification's
            // .scrollPositionMatchesDesired strategy uses — no parallel resolver — which itself
            // re-resolves the ENTIRE identity chain (scroll area -> orientation
            // convenience-reference -> scroll bar role) fresh, and compares using the identical
            // sliderValuesAreEqual tolerance rule ui.set_slider_value already established. An
            // unresolvable/misqualified target anywhere in the chain, an internally-inconsistent
            // range, or a resolvable-but-wrong-position one, does NOT trigger a blind replay of
            // the AX attribute-set here — it falls through to `verified = false`, so a fresh
            // execution requires both a brand-new QExecutionIdentity (per QPlanExecutor) AND a
            // genuinely fresh user approval grant, since QApprovalCoordinator's in-memory
            // one-time grants never survive a crash/restart (no persisted authorization is ever
            // consulted here).
            let scrollAppName = uncertainStep.arguments["applicationName"] ?? ""
            let scrollRole = uncertainStep.arguments["role"] ?? ""
            let scrollIdentifier = uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let scrollTitle = uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let scrollOrientation = uncertainStep.arguments["orientation"] ?? ""
            let scrollDesiredValueRaw = uncertainStep.arguments["desiredValue"] ?? ""
            if !scrollAppName.isEmpty, !scrollRole.isEmpty,
               !scrollOrientation.isEmpty, let scrollDesiredValue = Double(scrollDesiredValueRaw), scrollDesiredValue.isFinite,
               (scrollIdentifier != nil || scrollTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeScrollPositionEvidence(
                    applicationName: scrollAppName,
                    role: scrollRole,
                    identifier: scrollIdentifier,
                    title: scrollTitle,
                    orientation: scrollOrientation
                )
                if case .resolved(let currentValue) = evidence, QBridgeAccessibility.sliderValuesAreEqual(currentValue, scrollDesiredValue) {
                    verified = true
                    verifiedEvidence = "Observation verified: target scroll bar currentValue='\(currentValue)' desiredValue='\(scrollDesiredValue)' status=verified"
                }
            }

        case "ui.select_segmented_control_item":
            // Observation-first (Phase 2AQ): re-check whether the requested segmented control item already
            // reports selected=true before ever considering a replay. Reuses the EXACT SAME
            // independent observation primitive (QBridgeAccessibility.observeSegmentedControlSelectionEvidence).
            let segApplicationName = uncertainStep.arguments["applicationName"] ?? ""
            let segRole = uncertainStep.arguments["role"] ?? "AXSegmentedControl"
            let segControlId = uncertainStep.arguments["controlIdentifier"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["identifier"].flatMap { $0.isEmpty ? nil : $0 }
            let segControlTitle = uncertainStep.arguments["controlTitle"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
            let segWinTitle = uncertainStep.arguments["windowTitle"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["window"].flatMap { $0.isEmpty ? nil : $0 }
            let segWinId = uncertainStep.arguments["windowIdentifier"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["windowId"].flatMap { $0.isEmpty ? nil : $0 }
            let segItemIdentifier = uncertainStep.arguments["segmentIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
            let segItemTitle = uncertainStep.arguments["segmentTitle"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["segmentLabel"].flatMap { $0.isEmpty ? nil : $0 } ?? uncertainStep.arguments["segment"].flatMap { $0.isEmpty ? nil : $0 }
            let segDesiredSelectedRaw = uncertainStep.arguments["desiredSelected"] ?? "true"
            if !segApplicationName.isEmpty, !segRole.isEmpty,
               let segDesiredSelected = Bool(segDesiredSelectedRaw), segDesiredSelected,
               (segItemIdentifier != nil || segItemTitle != nil || segControlId != nil || segControlTitle != nil) {
                let evidence = await QBridgeAccessibility.shared.observeSegmentedControlSelectionEvidence(
                    applicationName: segApplicationName,
                    role: segRole,
                    controlIdentifier: segControlId,
                    controlTitle: segControlTitle,
                    windowTitle: segWinTitle,
                    windowIdentifier: segWinId,
                    segmentIdentifier: segItemIdentifier,
                    segmentTitle: segItemTitle
                )
                if case .resolved(let currentSelected) = evidence, currentSelected == segDesiredSelected {
                    verified = true
                    verifiedEvidence = "Observation verified: target segmented control item currentSelected='\(currentSelected)' desiredSelected='\(segDesiredSelected)' status=verified"
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
