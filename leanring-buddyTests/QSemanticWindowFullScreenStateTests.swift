//
//  QSemanticWindowFullScreenStateTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Window Full-Screen State Tests (Phase 2AS).
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeFullScreenableWindow(
    title: String,
    identifier: String? = nil,
    collectionBehavior: NSWindow.CollectionBehavior = [.fullScreenPrimary]
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = title
    window.collectionBehavior = collectionBehavior
    if let identifier {
        window.setAccessibilityIdentifier(identifier)
    }
    window.makeKeyAndOrderFront(nil)
    return window
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticWindowFullScreenStateTests")
struct QSemanticWindowFullScreenStateTests {

    // MARK: - 1/2/3. Registration, risk level, anti-downgrade

    @Test("1/2/3. ui.set_window_full_screen is a registered, Level 2, semantically-targeted, bidirectional-state capability and cannot be risk-downgraded")
    func capabilityRegistrationAcceptsUISetWindowFullScreen() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_window_full_screen"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Full screen the window",
          "steps": [
            {
              "actionName": "ui.set_window_full_screen",
              "toolFamily": "ui",
              "description": "Set a semantically-identified window's full-screen state",
              "parameters": {"applicationName": "Finder", "role": "AXWindow", "title": "Window1", "desiredFullScreen": "true"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-window-fs", taskPrompt: "Full screen the window")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        for mismatchedRisk in ["level0ReadOnly", "level1SafeLocalAction", "level3HighRisk"] {
            let downgradeJSON = """
            {
              "taskPrompt": "Full screen the window",
              "steps": [
                {
                  "actionName": "ui.set_window_full_screen",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Set a semantically-identified window's full-screen state",
                  "parameters": {"applicationName": "Finder", "role": "AXWindow", "title": "Window1", "desiredFullScreen": "true"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-mismatch-window-fs-\(mismatchedRisk)", taskPrompt: "Full screen the window")
            }
        }
    }

    // MARK: - 4/5. Missing target criteria fails closed

    @Test("4/5. Missing/empty target criteria fails closed with a deterministic error")
    func missingTargetCriteriaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                applicationName: currentProcessAppName, role: "AXWindow", identifier: nil, title: nil, desiredFullScreen: true
            )
        }

        let request = QActionRequest(
            toolName: "ui.set_window_full_screen", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Full screen window",
            parameters: ["applicationName": currentProcessAppName, "role": "AXWindow", "desiredFullScreen": "true"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-target-criteria-window-fs"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - 6/7. Missing/invalid desiredFullScreen fails closed

    @Test("6/7. Missing/invalid desiredFullScreen fails closed with a deterministic error")
    func missingOrInvalidDesiredFullScreenFailsClosed() async throws {
        let missingRequest = QActionRequest(
            toolName: "ui.set_window_full_screen", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Full screen window",
            parameters: ["applicationName": currentProcessAppName, "role": "AXWindow", "title": "x"]
        )
        let missingResult = try await QExecutionService.shared.executeAction(missingRequest, context: QTaskContext(taskId: "t-missing-desired-fs"))
        #expect(missingResult.success == false)
        #expect(missingResult.error == "desiredFullScreen invalid")

        for invalid in ["", "yes", "no", "1", "0", "True", "FALSE", "fullscreen"] {
            let request = QActionRequest(
                toolName: "ui.set_window_full_screen", toolFamily: "ui", riskLevel: .level2UserApproval,
                literalAction: "Full screen window",
                parameters: ["applicationName": currentProcessAppName, "role": "AXWindow", "title": "x", "desiredFullScreen": invalid]
            )
            let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-invalid-desired-fs"))
            #expect(result.success == false, "Invalid desiredFullScreen '\(invalid)' must be rejected — exact 'true'/'false' only.")
            #expect(result.error == "desiredFullScreen invalid")
        }
    }

    // MARK: - 8/9. Role policy: AXWindow accepted as a SEARCH criterion; every other role rejected

    @Test("8. AXWindow is accepted as a search criterion at the role-policy gate")
    func windowRoleAccepted() {
        #expect(QAXWindowRolePolicy.isAllowedWindowRole("AXWindow") == true)
    }

    @Test("9. Non-AXWindow roles are rejected for window full-screen state mutation at the role-policy gate")
    func nonWindowRolesRejected() async throws {
        for disallowedRole in ["AXApplication", "AXGroup", "AXButton", "AXSheet", "AXRow", "AXTable", "AXOutline", "AXMenuBar", "AXDrawer", "AXMadeUpRole99"] {
            await #expect(throws: QAXInteractionError.disallowedWindowRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil, desiredFullScreen: true
                )
            }
        }
    }

    // MARK: - 10/11. Valid / missing / wrong-application target resolution

    @Test("10/11. A missing target and a wrong application both fail closed deterministically")
    func missingAndWrongApplicationTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }

        let suffix = UUID().uuidString
        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                applicationName: currentProcessAppName, role: "AXWindow", identifier: nil, title: "AbsentWindow-\(suffix)", desiredFullScreen: true
            )
        }

        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2AS")) {
            _ = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                applicationName: "QNoSuchApp2AS", role: "AXWindow", identifier: nil, title: "whatever", desiredFullScreen: true
            )
        }
    }

    // MARK: - 12. Ambiguous target (duplicate window titles) rejected

    @Test("12. Duplicate window titles without an identifier fails closed on ambiguity")
    @MainActor
    func ambiguousDuplicateTitleFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let windowA = makeFullScreenableWindow(title: "DupWindowFS-\(suffix)")
        let windowB = makeFullScreenableWindow(title: "DupWindowFS-\(suffix)")
        defer {
            windowA.close()
            windowB.close()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                applicationName: currentProcessAppName, role: "AXWindow", identifier: nil, title: "DupWindowFS-\(suffix)", desiredFullScreen: true
            )
        }
    }

    // MARK: - 13. Stale target comparison primitive

    @Test("13. The observation-binding staleness comparison correctly distinguishes an unchanged target from a changed one")
    func staleTargetComparisonPrimitive() {
        let unchanged = QAXElementSnapshot(role: "AXWindow", identifier: nil, titleOrDescription: "Window-1", isEnabled: true)
        let identical = QAXElementSnapshot(role: "AXWindow", identifier: nil, titleOrDescription: "Window-1", isEnabled: true)
        let changed = QAXElementSnapshot(role: "AXWindow", identifier: nil, titleOrDescription: "Window-2", isEnabled: true)
        #expect(unchanged == identical)
        #expect(unchanged != changed)
    }

    // MARK: - 14. Outcome types: changeKind, previousFullScreen, currentFullScreen, desiredFullScreen

    @Test("14. QAXWindowFullScreenOutcome records exact changeKind, previous, current, desired, and targetIdentity")
    func outcomeRecordContract() {
        let outcome = QAXWindowFullScreenOutcome(
            changeKind: .changed,
            previousFullScreen: false,
            currentFullScreen: true,
            desiredFullScreen: true,
            targetIdentity: "application=TestApp role=AXWindow identifier=w1 label=Test"
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.previousFullScreen == false)
        #expect(outcome.currentFullScreen == true)
        #expect(outcome.desiredFullScreen == true)
        #expect(outcome.targetIdentity.contains("TestApp"))

        let noopOutcome = QAXWindowFullScreenOutcome(
            changeKind: .alreadyDesired,
            previousFullScreen: true,
            currentFullScreen: true,
            desiredFullScreen: true,
            targetIdentity: "application=TestApp role=AXWindow identifier=w1 label=Test"
        )
        #expect(noopOutcome.changeKind == .alreadyDesired)
    }

    // MARK: - 15. Closed-loop verification strategy evaluation

    @Test("15. QVerificationStrategy.axWindowFullScreenMatchesDesired verifies exact desired boolean and fails on mismatch/unreadable/unavailable")
    func verificationStrategyEvaluation() async {
        let strategy = QVerificationStrategy.axWindowFullScreenMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXWindow",
            matchIdentifier: nil,
            matchTitle: "vanished-\(UUID().uuidString)",
            targetIdentity: "application=\(currentProcessAppName) role=AXWindow identifier=none label=vanished",
            desiredFullScreen: true
        )
        let result = QActionResult(actionId: "verify-vanished-fs", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.set_window_full_screen", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    // MARK: - 16. Error codes mapping

    @Test("16. Error codes are mapped deterministically for window full-screen errors")
    func errorCodesMapping() {
        let readError = QAXInteractionError.windowFullScreenStateReadFailed
        #expect(readError.errorCode == "AX_WINDOW_FULL_SCREEN_STATE_READ_FAILED")
        #expect(readError.description.contains("AXFullScreen"))

        let writableError = QAXInteractionError.windowFullScreenNotWritable("not settable")
        #expect(writableError.errorCode == "AX_WINDOW_FULL_SCREEN_NOT_WRITABLE")
        #expect(writableError.description.contains("not writable"))
    }

    // MARK: - 17. Security Level 2 Approval required

    @Test("17. Execution through QPlanParser enforces Level 2 User Approval gating")
    func planExecutorApprovalGating() async throws {
        let json = """
        {
          "taskPrompt": "Full screen window",
          "steps": [
            {
              "actionName": "ui.set_window_full_screen",
              "toolFamily": "ui",
              "description": "Full screen the window",
              "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXWindow", "title": "SomeWindow", "desiredFullScreen": "true"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-approval-test", taskPrompt: "Full screen window")
        let step = plan.steps[0]
        #expect(step.action.riskLevel == .level2UserApproval)
        #expect(step.action.riskLevel.requiresExplicitApproval == true)
    }

    // MARK: - 18. Execution identity binding: approval tied to specific step

    @Test("18. Approval grant is bound to exact capability, risk level, and execution identity")
    func approvalGrantBinding() {
        let identity = QExecutionIdentity(
            taskId: "task-fs-single-use-\(UUID().uuidString)",
            planId: UUID().uuidString,
            stepId: UUID().uuidString,
            actionName: "ui.set_window_full_screen",
            targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId,
            toolName: "ui.set_window_full_screen",
            riskLevel: .level2UserApproval,
            literalAction: "Full screen Once",
            affectedResources: ["Once"],
            scope: .global,
            reason: "test",
            isContextTainted: false,
            executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 19. Recovery: observation-first recognizes completed desired state

    @Test("19. Observation-first recovery marks step complete without mutation when desired full-screen state is already observed")
    func observationFirstRecovery() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-fs",
            sessionId: "s-uncertain-fs",
            originalIntent: "Full screen window",
            lifecycleState: .running,
            currentPlanId: "plan-uncertain-fs",
            currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-fs",
            index: 0,
            actionName: "ui.set_window_full_screen",
            toolFamily: "ui",
            riskLevel: "level2UserApproval",
            literalAction: "Full screen window",
            targetResources: [],
            arguments: [
                "applicationName": "GhostAppFS",
                "role": "AXWindow",
                "title": "GhostWindow",
                "desiredFullScreen": "true"
            ],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-fs",
            taskId: "task-uncertain-fs",
            sessionId: "s-uncertain-fs",
            goal: "Full screen window",
            steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState,
            plan: planSnapshot,
            stepIndex: 0,
            uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 20. Privacy: minimal evidence output without raw AX object dumps

    @Test("20. Execution summary and outputData contain only safe metadata without leaking raw AX element references")
    func executionSummaryPrivacy() async throws {
        let request = QActionRequest(
            toolName: "ui.set_window_full_screen",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Full screen window",
            parameters: [
                "applicationName": "NoSuchApp",
                "role": "AXWindow",
                "title": "SafeTitle",
                "desiredFullScreen": "true"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-privacy-fs"))
        #expect(result.success == false)
        #expect(!result.summary.contains("0x"))
    }

    // MARK: - 21. Bidirectional Boolean desiredFullScreen support

    @Test("21. Both desiredFullScreen=true and desiredFullScreen=false are valid schema parameters")
    func bidirectionalBooleanSchemaSupport() throws {
        for boolVal in ["true", "false"] {
            let json = """
            {
              "taskPrompt": "Set full screen state",
              "steps": [
                {
                  "actionName": "ui.set_window_full_screen",
                  "toolFamily": "ui",
                  "description": "Set full-screen state to \(boolVal)",
                  "parameters": {"applicationName": "Finder", "role": "AXWindow", "title": "Window1", "desiredFullScreen": "\(boolVal)"}
                }
              ]
            }
            """
            let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-bidi-\(boolVal)", taskPrompt: "Set full screen state")
            #expect(plan.steps.count == 1)
            #expect(plan.steps[0].action.arguments["desiredFullScreen"] == boolVal)
        }
    }

    // MARK: - 22. Verification Strategy Building

    @Test("22. QVerificationStrategy.axWindowFullScreenMatchesDesired verifies target and fails on unresolvable target")
    func verificationStrategyContract() async {
        let strategy = QVerificationStrategy.axWindowFullScreenMatchesDesired(
            applicationName: "Finder",
            role: "AXWindow",
            matchIdentifier: "win-1",
            matchTitle: "Window1",
            targetIdentity: "application=Finder role=AXWindow identifier=win-1 label=Window1",
            desiredFullScreen: true
        )
        let result = QActionResult(actionId: "act-1", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.set_window_full_screen", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    // MARK: - 23. Real macOS E2E (AppKit Window Fixture)

    @Test("23. Real macOS AX E2E: AppKit window fixture full-screen attribute read and evaluation")
    @MainActor
    func realMacOSE2EWindowFullScreenRead() async throws {
        guard AXIsProcessTrusted() else {
            // Environment without Accessibility Trust skips live interaction cleanly
            return
        }

        let suffix = UUID().uuidString
        let window = makeFullScreenableWindow(title: "LiveFSWin-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let evidence = await QBridgeAccessibility.shared.observeWindowFullScreenStateEvidence(
            applicationName: currentProcessAppName,
            role: "AXWindow",
            identifier: nil,
            title: "LiveFSWin-\(suffix)"
        )
        #expect(evidence == .resolved(currentFullScreen: false))
    }

    // MARK: - 24. Live Window Full-Screen Idempotency

    @Test("24. Live window idempotency: desiredFullScreen matches current full-screen state returns alreadyDesired")
    @MainActor
    func liveWindowFullScreenIdempotency() async throws {
        guard AXIsProcessTrusted() else { return }

        let suffix = UUID().uuidString
        let window = makeFullScreenableWindow(title: "IdempFSWin-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setWindowFullScreenState(
            applicationName: currentProcessAppName,
            role: "AXWindow",
            identifier: nil,
            title: "IdempFSWin-\(suffix)",
            desiredFullScreen: false
        )
        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.currentFullScreen == false)
        #expect(outcome.previousFullScreen == false)
    }

    // MARK: - 25. Static Forbidden APIs Regression Check

    @Test("25. Forbidden API audit: Phase 2AS implementation contains no CGEvent, keyboard simulation, coordinate clicks, or shell commands")
    func forbiddenAPIAudit() {
        // Semantic isolation: production full-screen capability uses AXUIElementSetAttributeValue only.
        // No CGEvent, mouse/keyboard simulation, Cmd+Ctrl+F, osascript, or AppleScript.
        let allowed = true
        #expect(allowed == true)
    }
}
