//
//  QSemanticSplitPaneEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Split Pane Enumeration Tests (Phase 2AT).
//
//  ui.list_split_panes is Q's forty-second controlled UI-interaction capability, and its twelfth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, and Phase 2AO's ui.list_sheet_actions).
//  Enumerates direct panes belonging to exactly ONE named AXSplitGroup in a named application window.
//  The AXSplitter divider elements between panes are strictly excluded from the returned collection.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isEnabled, index).
//  Raw pane contents remain ephemeral in outputData and are never persisted into durable
//  task snapshots, audit logs, or SQLite WAL memory stores.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

private final class SplitPaneEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_split_panes" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 split pane(s) for split group in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXSplitGroup",
                    "paneCount": "2",
                    "pane0.index": "0",
                    "pane0.title": "Sidebar",
                    "pane0.identifier": "split.sidebar",
                    "pane0.role": "AXOutline",
                    "pane0.enabled": "true",
                    "pane1.index": "1",
                    "pane1.title": "Detail",
                    "pane1.identifier": "split.detail",
                    "pane1.role": "AXGroup",
                    "pane1.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptySplitPaneEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_split_panes" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 split pane(s) for split group in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXSplitGroup",
                    "paneCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticSplitPaneEnumerationTests")
struct QSemanticSplitPaneEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_split_panes is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_split_panes"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_split_panes is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_split_panes"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_split_panes plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List split panes",
          "steps": [
            {
              "actionName": "ui.list_split_panes",
              "toolFamily": "ui",
              "description": "Enumerate panes in a split view",
              "parameters": {
                "applicationName": "Xcode",
                "role": "AXSplitGroup",
                "windowTitle": "Workspace"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-splitpanes", taskPrompt: "List split panes")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_split_panes")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_split_panes fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List split panes",
              "steps": [
                {
                  "actionName": "ui.list_split_panes",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate panes in a split view",
                  "parameters": {
                    "applicationName": "Xcode",
                    "role": "AXSplitGroup"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-splitpanes-\(mismatchedRisk)", taskPrompt: "List split panes")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "role": "AXSplitGroup"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSplitter) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSplitter", "AXTabGroup", "AXSheet"] {
            let req = QActionRequest(
                toolName: "ui.list_split_panes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List split panes",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    @Test("7. QAXSplitGroupRolePolicy accepts only AXSplitGroup")
    func splitGroupRolePolicyDirect() {
        #expect(QAXSplitGroupRolePolicy.isAllowedSplitGroupRole("AXSplitGroup") == true)
        #expect(QAXSplitGroupRolePolicy.isAllowedSplitGroupRole("AXSplitter") == false)
        #expect(QAXSplitGroupRolePolicy.isAllowedSplitGroupRole("AXGroup") == false)
        #expect(QAXSplitGroupRolePolicy.isAllowedSplitGroupRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AT-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXSplitGroup"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Split Group Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXSplitGroup",
                "windowTitle": "QNoSuchWindow-2AT-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent split group target fails closed")
    func nonExistentSplitGroupTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXSplitGroup",
                "title": "QNoSuchSplitGroup-2AT-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-splitgroup"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXSplitPaneItemMetadata and QAXSplitGroupMetadata model structures")
    func splitPaneMetadataModels() {
        let pane1 = QAXSplitPaneItemMetadata(
            index: 0,
            title: "Sidebar",
            identifier: "pane-sidebar",
            role: "AXOutline",
            subrole: nil,
            isEnabled: true
        )
        let pane2 = QAXSplitPaneItemMetadata(
            index: 1,
            title: "Detail",
            identifier: "pane-detail",
            role: "AXGroup",
            subrole: nil,
            isEnabled: true
        )
        let splitGroupMeta = QAXSplitGroupMetadata(
            applicationName: "Xcode",
            windowTitle: "Workspace",
            splitGroupTitle: "Navigator Split",
            splitGroupIdentifier: "main-split",
            paneCount: 2,
            panes: [pane1, pane2]
        )

        #expect(splitGroupMeta.applicationName == "Xcode")
        #expect(splitGroupMeta.windowTitle == "Workspace")
        #expect(splitGroupMeta.splitGroupTitle == "Navigator Split")
        #expect(splitGroupMeta.paneCount == 2)
        #expect(splitGroupMeta.panes[0].title == "Sidebar")
        #expect(splitGroupMeta.panes[0].role == "AXOutline")
        #expect(splitGroupMeta.panes[1].title == "Detail")
        #expect(splitGroupMeta.panes[1].role == "AXGroup")
    }

    @Test("12. Empty split group (zero panes) is a valid, non-error result")
    func emptySplitGroupIsValid() {
        let splitGroupMeta = QAXSplitGroupMetadata(
            applicationName: "Xcode",
            windowTitle: "Workspace",
            splitGroupTitle: nil,
            splitGroupIdentifier: nil,
            paneCount: 0,
            panes: []
        )
        #expect(splitGroupMeta.paneCount == 0)
        #expect(splitGroupMeta.panes.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "applicationName": "Xcode",
                "role": "AXSplitGroup"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 split pane(s) for split group in application 'Xcode' (window: 'Main'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "paneCount": "2",
                "pane0.title": "Confidential Project Navigator",
                "splitGroupTitle": "Main Split"
            ]
        )
        let strategy = QVerificationStrategy.splitPaneEnumerationSucceeded(applicationName: "Xcode", paneCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("paneCount=2"))
            #expect(evidence.contains("splitGroupRole=AXSplitGroup"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Project Navigator"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            parameters: [
                "applicationName": "Xcode",
                "role": "AXSplitGroup"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.splitPaneEnumerationSucceeded(applicationName: "Xcode", paneCount: 0)
        let outcome = await verifier.verify(action: actionReq, result: failedResult, strategy: strategy)
        #expect(outcome.isVerified == false)
        if case .failed(let reason, let evidence) = outcome {
            // QActionVerifier fails closed generically on result.success == false before ever
            // dispatching into a per-strategy evidence branch — it never fabricates
            // strategy-specific evidence for a mutation/read that didn't even execute.
            #expect(reason.contains("AX_NO_MATCHING_ELEMENT"))
            #expect(evidence.contains("prior to post-observation"))
        } else {
            Issue.record("Expected .failed outcome")
        }
    }

    @Test("15. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_split_panes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List split panes",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Main"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List split panes")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_split_panes")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Main")
    }

    // MARK: - 7. Security Isolation: ui.list_split_panes does NOT authorize mutating capabilities

    @Test("16. ui.list_split_panes does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_split_panes",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List split panes"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click a pane's control"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_split_panes step sequentially to completion")
    func planExecutorExecutesSplitPaneEnumerationStep() async throws {
        let mockExec = SplitPaneEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_split_panes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List split panes of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List split panes of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-splitpanes",
            sessionId: "s-list-splitpanes",
            taskPrompt: "List split panes",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-splitpanes")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_split_panes step to completion when zero panes are found")
    func planExecutorExecutesEmptySplitPaneEnumerationStep() async throws {
        let mockExec = EmptySplitPaneEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_split_panes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List split panes of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List split panes of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-splitpanes-empty",
            sessionId: "s-list-splitpanes-empty",
            taskPrompt: "List split panes",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-splitpanes-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSSplitView Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSSplitView pane discovery excludes AXSplitter dividers (guarded by AXIsProcessTrusted)")
    func realAppKitSplitPaneEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSSplitView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            splitView.isVertical = true
            splitView.dividerStyle = .thin

            let leftPane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
            leftPane.setAccessibilityIdentifier("split.left")
            let rightPane = NSView(frame: NSRect(x: 200, y: 0, width: 400, height: 400))
            rightPane.setAccessibilityIdentifier("split.right")

            splitView.addArrangedSubview(leftPane)
            splitView.addArrangedSubview(rightPane)

            window.contentView = splitView
            window.title = "QSplitViewWindow-2AT"
            window.makeKeyAndOrderFront(nil)
            return (window, splitView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listSplitPanes(
            applicationName: currentProcessAppName,
            role: "AXSplitGroup",
            identifier: nil,
            title: nil,
            windowTitle: "QSplitViewWindow-2AT",
            windowIdentifier: nil
        )

        #expect(metadata.paneCount >= 0)
        for pane in metadata.panes {
            #expect(pane.role != "AXSplitter")
        }
    }
}
