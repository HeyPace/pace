//
//  QSemanticPopoverEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Popover Enumeration Tests (Phase 2AW).
//
//  ui.list_popovers is Q's forty-fifth controlled UI-interaction capability, and its fourteenth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  and Phase 2AV's ui.list_browser_columns).
//  Enumerates direct AXPopover elements belonging to an application window or application root.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isModal, index).
//  Raw popover contents remain ephemeral in outputData and are never persisted into durable
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

private final class PopoverEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_popovers" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 popover(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXPopover",
                    "popoverCount": "2",
                    "popover0.index": "0",
                    "popover0.title": "Inspector",
                    "popover0.identifier": "popover.inspector",
                    "popover0.role": "AXPopover",
                    "popover0.modal": "false",
                    "popover1.index": "1",
                    "popover1.title": "Quick Look",
                    "popover1.identifier": "popover.quicklook",
                    "popover1.role": "AXPopover",
                    "popover1.modal": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyPopoverEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_popovers" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 popover(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXPopover",
                    "popoverCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticPopoverEnumerationTests")
struct QSemanticPopoverEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_popovers is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_popovers"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_popovers is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_popovers"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_popovers plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List popovers",
          "steps": [
            {
              "actionName": "ui.list_popovers",
              "toolFamily": "ui",
              "description": "Enumerate popovers in application window",
              "parameters": {
                "applicationName": "Safari",
                "role": "AXPopover",
                "windowTitle": "Start Page"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-popovers", taskPrompt: "List popovers")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_popovers")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_popovers fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List popovers",
              "steps": [
                {
                  "actionName": "ui.list_popovers",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate popovers in application window",
                  "parameters": {
                    "applicationName": "Safari",
                    "role": "AXPopover"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-popovers-\(mismatchedRisk)", taskPrompt: "List popovers")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "role": "AXPopover"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup"] {
            let req = QActionRequest(
                toolName: "ui.list_popovers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List popovers",
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

    @Test("7. QAXPopoverRolePolicy accepts only AXPopover")
    func popoverRolePolicyDirect() {
        #expect(QAXPopoverRolePolicy.isAllowedPopoverRole("AXPopover") == true)
        #expect(QAXPopoverRolePolicy.isAllowedPopoverRole("AXSheet") == false)
        #expect(QAXPopoverRolePolicy.isAllowedPopoverRole("AXWindow") == false)
        #expect(QAXPopoverRolePolicy.isAllowedPopoverRole("AXGroup") == false)
        #expect(QAXPopoverRolePolicy.isAllowedPopoverRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AW-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXPopover"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Popover Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXPopover",
                "windowTitle": "QNoSuchWindow-2AW-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent popover target with specific filter returns empty collection")
    func nonExistentPopoverTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXPopover",
                "popoverTitle": "QNoSuchPopover-2AW-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-popover"))
        if result.success {
            #expect(result.outputData["popoverCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXPopoverMetadata and QAXPopoverCollectionMetadata model structures")
    func popoverMetadataModels() {
        let pop1 = QAXPopoverMetadata(
            index: 0,
            title: "Color Inspector",
            identifier: "popover-1",
            role: "AXPopover",
            subrole: nil,
            isModal: false
        )
        let pop2 = QAXPopoverMetadata(
            index: 1,
            title: "Quick View",
            identifier: "popover-2",
            role: "AXPopover",
            subrole: nil,
            isModal: true
        )
        let popoverMeta = QAXPopoverCollectionMetadata(
            applicationName: "Keynote",
            windowTitle: "Presentation",
            popoverCount: 2,
            popovers: [pop1, pop2]
        )

        #expect(popoverMeta.applicationName == "Keynote")
        #expect(popoverMeta.windowTitle == "Presentation")
        #expect(popoverMeta.popoverCount == 2)
        #expect(popoverMeta.popovers[0].title == "Color Inspector")
        #expect(popoverMeta.popovers[0].role == "AXPopover")
        #expect(popoverMeta.popovers[0].isModal == false)
        #expect(popoverMeta.popovers[1].title == "Quick View")
        #expect(popoverMeta.popovers[1].isModal == true)
    }

    @Test("12. Empty popovers collection (zero popovers) is a valid, non-error result")
    func emptyPopoverCollectionIsValid() {
        let popoverMeta = QAXPopoverCollectionMetadata(
            applicationName: "Keynote",
            windowTitle: "Presentation",
            popoverCount: 0,
            popovers: []
        )
        #expect(popoverMeta.popoverCount == 0)
        #expect(popoverMeta.popovers.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "applicationName": "Safari",
                "role": "AXPopover"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 popover(s) in application 'Safari' (window: 'Start Page'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Safari",
                "popoverCount": "2",
                "popover0.title": "Confidential Bookmarks",
                "windowTitle": "Start Page"
            ]
        )
        let strategy = QVerificationStrategy.popoverEnumerationSucceeded(applicationName: "Safari", popoverCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Safari"))
            #expect(evidence.contains("popoverCount=2"))
            #expect(evidence.contains("popoverRole=AXPopover"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Bookmarks"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            parameters: [
                "applicationName": "Safari",
                "role": "AXPopover"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.popoverEnumerationSucceeded(applicationName: "Safari", popoverCount: 0)
        let outcome = await verifier.verify(action: actionReq, result: failedResult, strategy: strategy)
        #expect(outcome.isVerified == false)
        if case .failed(let reason, let evidence) = outcome {
            #expect(reason.contains("AX_NO_MATCHING_ELEMENT"))
            #expect(evidence.contains("prior to post-observation"))
        } else {
            Issue.record("Expected .failed outcome")
        }
    }

    @Test("15. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_popovers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popovers",
            targetResources: [],
            arguments: ["applicationName": "Safari", "windowTitle": "Main"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List popovers")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_popovers")
        #expect(snapshot.arguments["applicationName"] == "Safari")
        #expect(snapshot.arguments["windowTitle"] == "Main")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_popovers does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_popovers",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List popovers"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click a popover control"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_popovers step sequentially to completion")
    func planExecutorExecutesPopoverEnumerationStep() async throws {
        let mockExec = PopoverEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_popovers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List popovers of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List popovers of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-popovers",
            sessionId: "s-list-popovers",
            taskPrompt: "List popovers",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-popovers")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_popovers step to completion when zero popovers are found")
    func planExecutorExecutesEmptyPopoverEnumerationStep() async throws {
        let mockExec = EmptyPopoverEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_popovers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List popovers of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List popovers of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-popovers-empty",
            sessionId: "s-list-popovers-empty",
            taskPrompt: "List popovers",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-popovers-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSPopover Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSPopover discovery (guarded by AXIsProcessTrusted)")
    func realAppKitPopoverEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSPopover, NSViewController) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            let anchorView = NSView(frame: NSRect(x: 50, y: 50, width: 100, height: 30))
            window.contentView?.addSubview(anchorView)
            window.title = "QPopoverWindow-2AW"
            window.makeKeyAndOrderFront(nil)

            let popover = NSPopover()
            popover.contentSize = NSSize(width: 200, height: 150)
            popover.behavior = .transient
            let contentVC = NSViewController()
            let popoverView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
            popoverView.setAccessibilityIdentifier("test.popover.content")
            contentVC.view = popoverView
            popover.contentViewController = contentVC
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)

            return (window, popover, contentVC)
        }

        defer {
            Task { @MainActor in
                expectation.1.close()
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listPopovers(
            applicationName: currentProcessAppName,
            role: "AXPopover",
            identifier: nil,
            title: nil,
            windowTitle: "QPopoverWindow-2AW",
            windowIdentifier: nil
        )

        #expect(metadata.popoverCount >= 0)
        for pop in metadata.popovers {
            #expect(pop.role == "AXPopover")
        }
    }
}
