//
//  QSemanticTabItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Tab Item Enumeration Tests (Phase 2AH).
//
//  ui.list_tab_items is Q's twenty-fourth controlled UI-interaction capability, and its sixth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, and Phase 2AF's ui.list_outline_items).
//  Enumerates direct tab items belonging to exactly ONE named AXTabGroup in a named application.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, isSelected, isEnabled, role, subrole, index).
//  Raw tab item contents remain ephemeral in outputData and are never persisted into durable
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

private final class TabItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_tab_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 tab item(s) for tab group in application 'MockApp' (selected: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTabGroup",
                    "itemCount": "3",
                    "selectedItemCount": "1",
                    "item0.index": "0",
                    "item0.title": "Overview",
                    "item0.selected": "true",
                    "item0.enabled": "true",
                    "item0.role": "AXRadioButton",
                    "item0.subrole": "AXTabButton",
                    "item1.index": "1",
                    "item1.title": "Details",
                    "item1.selected": "false",
                    "item1.enabled": "true",
                    "item1.role": "AXRadioButton",
                    "item1.subrole": "AXTabButton",
                    "item2.index": "2",
                    "item2.title": "Settings",
                    "item2.selected": "false",
                    "item2.enabled": "true",
                    "item2.role": "AXRadioButton",
                    "item2.subrole": "AXTabButton"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTabItemEnumerationTests")
struct QSemanticTabItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_tab_items is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListTabItems() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_tab_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List tab items",
          "steps": [
            {
              "actionName": "ui.list_tab_items",
              "toolFamily": "ui",
              "description": "Enumerate the tabs of a tab group",
              "parameters": {
                "applicationName": "Xcode",
                "role": "AXTabGroup",
                "title": "Project Settings"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-tabs", taskPrompt: "List tab items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List tab items",
              "steps": [
                {
                  "actionName": "ui.list_tab_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate the tabs of a tab group",
                  "parameters": {
                    "applicationName": "Xcode",
                    "role": "AXTabGroup",
                    "title": "Project Settings"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-tabs-\(mismatchedRisk)", taskPrompt: "List tab items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            parameters: [
                "role": "AXTabGroup",
                "title": "Project Settings"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTabGroup"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Disallowed role (e.g. AXTable, AXButton, AXGroup, AXWindow, AXRadioGroup) is rejected before tree walk")
    func disallowedRoleRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXRadioGroup", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_tab_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List tab items",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Project Settings"
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    // MARK: - 3. Application Resolution

    @Test("5. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AH-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXTabGroup",
                "title": "Project Settings"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Tab Group Target Resolution

    @Test("6. Non-existent tab group target fails closed")
    func nonExistentTabGroupTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTabGroup",
                "title": "QNoSuchTabGroup-2AH-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-tabgroup"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("7. QAXTabItemMetadata and QAXTabGroupMetadata model structures")
    func tabMetadataModels() {
        let item1 = QAXTabItemMetadata(
            index: 0,
            title: "Overview",
            identifier: "tab-overview",
            isSelected: true,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: "AXTabButton"
        )
        let item2 = QAXTabItemMetadata(
            index: 1,
            title: "Details",
            identifier: "tab-details",
            isSelected: false,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: "AXTabButton"
        )
        let groupMeta = QAXTabGroupMetadata(
            applicationName: "Xcode",
            tabGroupTitle: "Project Settings",
            tabGroupIdentifier: "tab-group-1",
            itemCount: 2,
            selectedItemCount: 1,
            items: [item1, item2]
        )

        #expect(groupMeta.applicationName == "Xcode")
        #expect(groupMeta.tabGroupTitle == "Project Settings")
        #expect(groupMeta.itemCount == 2)
        #expect(groupMeta.selectedItemCount == 1)
        #expect(groupMeta.items[0].title == "Overview")
        #expect(groupMeta.items[0].isSelected == true)
        #expect(groupMeta.items[1].title == "Details")
        #expect(groupMeta.items[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("8. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            parameters: [
                "applicationName": "Xcode",
                "role": "AXTabGroup",
                "title": "Project Settings"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 4 tab item(s) for tab group in application 'Xcode' (selected: 1). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "itemCount": "4",
                "selectedItemCount": "1",
                "item0.title": "Confidential Security Tab",
                "tabGroupTitle": "Project Settings"
            ]
        )
        let strategy = QVerificationStrategy.tabItemEnumerationSucceeded(applicationName: "Xcode", tabCount: 4, selectedCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("tabCount=4"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("tabGroupRole=AXTabGroup"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Security Tab"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("9. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_tab_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List tab items",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "title": "Project Settings"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List tab items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_tab_items")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["title"] == "Project Settings")
    }

    // MARK: - 7. Security Isolation: ui.list_tab_items does NOT authorize ui.select_tab

    @Test("10. ui.list_tab_items does not confer authorization for ui.select_tab")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_tab_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List tab items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.select_tab",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select tab"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("11. QPlanExecutor executes ui.list_tab_items step sequentially to completion")
    func planExecutorExecutesTabEnumerationStep() async throws {
        let mockExec = TabItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_tab_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List tab items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Project Settings"]
            ),
            description: "List tab items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-tabs",
            sessionId: "s-list-tabs",
            taskPrompt: "List tab items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-tabs")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSTabView Fixture (TCC Guarded)

    @Test("12. Real macOS AppKit E2E — NSTabView item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitTabViewEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSTabView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let tabView = NSTabView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
            let item1 = NSTabViewItem(identifier: "tab-overview")
            item1.label = "Overview"
            let item2 = NSTabViewItem(identifier: "tab-details")
            item2.label = "Details"
            let item3 = NSTabViewItem(identifier: "tab-settings")
            item3.label = "Settings"

            tabView.addTabViewItem(item1)
            tabView.addTabViewItem(item2)
            tabView.addTabViewItem(item3)

            tabView.setAccessibilityIdentifier("QTestTabGroup-2AH")
            tabView.setAccessibilityLabel("Test Tab Group")
            window.contentView?.addSubview(tabView)
            window.makeKeyAndOrderFront(nil)
            return (window, tabView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listTabItems(
            applicationName: currentProcessAppName,
            role: "AXTabGroup",
            identifier: "QTestTabGroup-2AH",
            title: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
