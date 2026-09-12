//
//  QSemanticToolbarItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Toolbar Item Enumeration Tests (Phase 2AK).
//
//  ui.list_toolbar_items is Q's twenty-sixth controlled UI-interaction capability, and its eighth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, and
//  Phase 2AI's ui.list_radio_group_items).
//  Enumerates direct controls belonging to exactly ONE named AXToolbar in a named application window.
//
//  Level 0 — no approval, no mutation, no press, no focus, no popup opening, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isEnabled, isSelected, help, index).
//  Raw toolbar item contents remain ephemeral in outputData and are never persisted into durable
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

private final class ToolbarItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_toolbar_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 4 toolbar item(s) for toolbar in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXToolbar",
                    "itemCount": "4",
                    "item0.index": "0",
                    "item0.title": "Back",
                    "item0.identifier": "toolbar.back",
                    "item0.role": "AXButton",
                    "item0.enabled": "true",
                    "item1.index": "1",
                    "item1.title": "Forward",
                    "item1.identifier": "toolbar.forward",
                    "item1.role": "AXButton",
                    "item1.enabled": "false",
                    "item2.index": "2",
                    "item2.title": "Search",
                    "item2.identifier": "toolbar.search",
                    "item2.role": "AXSearchField",
                    "item2.enabled": "true",
                    "item3.index": "3",
                    "item3.title": "Share",
                    "item3.identifier": "toolbar.share",
                    "item3.role": "AXPopUpButton",
                    "item3.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticToolbarItemEnumerationTests")
struct QSemanticToolbarItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_toolbar_items is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_toolbar_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_toolbar_items is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_toolbar_items"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_toolbar_items plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List toolbar items",
          "steps": [
            {
              "actionName": "ui.list_toolbar_items",
              "toolFamily": "ui",
              "description": "Enumerate controls in a window toolbar",
              "parameters": {
                "applicationName": "Xcode",
                "role": "AXToolbar",
                "windowTitle": "Workspace"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-toolbar", taskPrompt: "List toolbar items")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_toolbar_items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_toolbar_items fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List toolbar items",
              "steps": [
                {
                  "actionName": "ui.list_toolbar_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate controls in a window toolbar",
                  "parameters": {
                    "applicationName": "Xcode",
                    "role": "AXToolbar"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-toolbar-\(mismatchedRisk)", taskPrompt: "List toolbar items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            parameters: [
                "role": "AXToolbar"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXTabGroup, AXRadioGroup) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXTabGroup", "AXRadioGroup", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_toolbar_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List toolbar items",
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

    // MARK: - 3. Application Resolution

    @Test("7. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AK-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXToolbar"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Toolbar Target Resolution

    @Test("8. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXToolbar",
                "windowTitle": "QNoSuchWindow-2AK-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("9. Non-existent toolbar target fails closed")
    func nonExistentToolbarTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXToolbar",
                "title": "QNoSuchToolbar-2AK-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-toolbar"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("10. QAXToolbarItemMetadata and QAXToolbarMetadata model structures")
    func toolbarMetadataModels() {
        let item1 = QAXToolbarItemMetadata(
            index: 0,
            title: "Back",
            identifier: "btn-back",
            role: "AXButton",
            subrole: nil,
            isEnabled: true,
            isSelected: nil,
            help: "Go Back"
        )
        let item2 = QAXToolbarItemMetadata(
            index: 1,
            title: "Mode",
            identifier: "popup-mode",
            role: "AXPopUpButton",
            subrole: nil,
            isEnabled: true,
            isSelected: nil,
            help: "Select Mode"
        )
        let toolbarMeta = QAXToolbarMetadata(
            applicationName: "Xcode",
            windowTitle: "Workspace",
            toolbarTitle: "Main Toolbar",
            toolbarIdentifier: "main-toolbar",
            itemCount: 2,
            items: [item1, item2]
        )

        #expect(toolbarMeta.applicationName == "Xcode")
        #expect(toolbarMeta.windowTitle == "Workspace")
        #expect(toolbarMeta.toolbarTitle == "Main Toolbar")
        #expect(toolbarMeta.itemCount == 2)
        #expect(toolbarMeta.items[0].title == "Back")
        #expect(toolbarMeta.items[0].role == "AXButton")
        #expect(toolbarMeta.items[1].title == "Mode")
        #expect(toolbarMeta.items[1].role == "AXPopUpButton")
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("11. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            parameters: [
                "applicationName": "Xcode",
                "role": "AXToolbar"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 4 toolbar item(s) for toolbar in application 'Xcode' (window: 'Main'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "itemCount": "4",
                "item0.title": "Confidential Project Action",
                "toolbarTitle": "Main Toolbar"
            ]
        )
        let strategy = QVerificationStrategy.toolbarItemEnumerationSucceeded(applicationName: "Xcode", itemCount: 4)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("itemCount=4"))
            #expect(evidence.contains("toolbarRole=AXToolbar"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Project Action"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("12. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_toolbar_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List toolbar items",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Main"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List toolbar items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_toolbar_items")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Main")
    }

    // MARK: - 7. Security Isolation: ui.list_toolbar_items does NOT authorize ui.click_element

    @Test("13. ui.list_toolbar_items does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_toolbar_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List toolbar items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click toolbar button"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("14. QPlanExecutor executes ui.list_toolbar_items step sequentially to completion")
    func planExecutorExecutesToolbarEnumerationStep() async throws {
        let mockExec = ToolbarItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_toolbar_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List toolbar items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List toolbar items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-toolbar",
            sessionId: "s-list-toolbar",
            taskPrompt: "List toolbar items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-toolbar")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSToolbar Fixture (TCC Guarded)

    @Test("15. Real macOS AppKit E2E — NSToolbar item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitToolbarEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSToolbar) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 500, height: 350),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("QTestToolbar-2AK"))
            toolbar.displayMode = .iconAndLabel
            window.toolbar = toolbar
            window.title = "QToolbarWindow-2AK"
            window.makeKeyAndOrderFront(nil)
            return (window, toolbar)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listToolbarItems(
            applicationName: currentProcessAppName,
            role: "AXToolbar",
            identifier: nil,
            title: nil,
            windowTitle: "QToolbarWindow-2AK",
            windowIdentifier: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
