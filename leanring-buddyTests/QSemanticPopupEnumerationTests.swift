//
//  QSemanticPopupEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Pop-Up Menu Item Enumeration Tests (Phase 2AD).
//
//  ui.list_popup_items is Q's twenty-first controlled UI-interaction capability, and its third
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows and Phase 2AA's ui.list_menu_items).
//  Enumerates direct menu items belonging to exactly ONE named AXPopUpButton in a named application.
//
//  Level 0 — no approval, no mutation, no press, no open, no recovery replay.
//  Safe metadata only (title, identifier, enabled, isSelected, role).
//  Raw popup contents remain ephemeral in outputData and are never persisted into durable
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

private final class PopupEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_popup_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 popup item(s) (current value: 'Item Beta') for application 'MockApp'.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXPopUpButton",
                    "selectedValue": "Item Beta",
                    "itemCount": "3",
                    "item0.title": "Item Alpha",
                    "item0.selected": "false",
                    "item0.enabled": "true",
                    "item0.role": "AXMenuItem",
                    "item1.title": "Item Beta",
                    "item1.selected": "true",
                    "item1.enabled": "true",
                    "item1.role": "AXMenuItem",
                    "item2.title": "Item Gamma",
                    "item2.selected": "false",
                    "item2.enabled": "true",
                    "item2.role": "AXMenuItem"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticPopupEnumerationTests")
struct QSemanticPopupEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_popup_items is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListPopupItems() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_popup_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List popup items",
          "steps": [
            {
              "actionName": "ui.list_popup_items",
              "toolFamily": "ui",
              "description": "Enumerate the popup items of a popup button",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXPopUpButton",
                "title": "Format"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-popups", taskPrompt: "List popup items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List popup items",
              "steps": [
                {
                  "actionName": "ui.list_popup_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate the popup items of a popup button",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXPopUpButton",
                    "title": "Format"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-popups-\(mismatchedRisk)", taskPrompt: "List popup items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            parameters: [
                "role": "AXPopUpButton",
                "title": "Format"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXPopUpButton"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Disallowed role (e.g. AXComboBox, AXButton) is rejected before tree walk")
    func disallowedRoleRejected() async throws {
        for invalidRole in ["AXComboBox", "AXButton", "AXTextField", "AXWindow", "AXMenu"] {
            let req = QActionRequest(
                toolName: "ui.list_popup_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List popup items",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Format"
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
        let nonExistentApp = "QNoSuchApp-2AD-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXPopUpButton",
                "title": "Format"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Popup Target Resolution

    @Test("6. Non-existent popup button target fails closed")
    func nonExistentPopupTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXPopUpButton",
                "title": "QNoSuchPopup-2AD-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-popup"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("7. QAXPopupItemMetadata and QAXPopupMenuMetadata model structures")
    func popupMetadataModels() {
        let item1 = QAXPopupItemMetadata(
            title: "Option 1",
            identifier: "id-opt-1",
            isEnabled: true,
            isSelected: true,
            role: "AXMenuItem"
        )
        let item2 = QAXPopupItemMetadata(
            title: "Option 2",
            identifier: "id-opt-2",
            isEnabled: false,
            isSelected: false,
            role: "AXMenuItem"
        )
        let popupMenu = QAXPopupMenuMetadata(selectedValue: "Option 1", items: [item1, item2])

        #expect(popupMenu.selectedValue == "Option 1")
        #expect(popupMenu.items.count == 2)
        #expect(popupMenu.items[0].title == "Option 1")
        #expect(popupMenu.items[0].isSelected == true)
        #expect(popupMenu.items[1].title == "Option 2")
        #expect(popupMenu.items[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("8. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            parameters: [
                "applicationName": "Calculator",
                "role": "AXPopUpButton",
                "title": "Mode"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 5 popup item(s) (current value: 'Degrees') for application 'Calculator'. This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Calculator",
                "itemCount": "5",
                "item0.title": "Secret Item Label",
                "selectedValue": "Degrees"
            ]
        )
        let strategy = QVerificationStrategy.popupEnumerationSucceeded(applicationName: "Calculator", itemCount: 5)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Calculator"))
            #expect(evidence.contains("itemCount=5"))
            #expect(evidence.contains("popupRole=AXPopUpButton"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Secret Item Label"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("9. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_popup_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List popup items",
            targetResources: [],
            arguments: ["applicationName": "Finder", "title": "Format"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List popup items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_popup_items")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["title"] == "Format")
    }

    // MARK: - 7. Security Isolation: ui.list_popup_items does NOT authorize ui.select_popup_item

    @Test("10. ui.list_popup_items does not confer authorization for ui.select_popup_item")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_popup_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List popup items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.select_popup_item",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select popup item"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("11. QPlanExecutor executes ui.list_popup_items step sequentially to completion")
    func planExecutorExecutesPopupEnumerationStep() async throws {
        let mockExec = PopupEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_popup_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List popup items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Format"]
            ),
            description: "List popup items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-popups",
            sessionId: "s-list-popups",
            taskPrompt: "List popup items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-popups")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real macOS AppKit NSPopUpButton Fixture (TCC Guarded)

    @Test("12. Real macOS AppKit E2E — NSPopUpButton item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitPopUpButtonEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSPopUpButton) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let popUp = NSPopUpButton(frame: NSRect(x: 20, y: 50, width: 200, height: 30), pullsDown: false)
            popUp.addItems(withTitles: ["Item Alpha", "Item Beta", "Item Gamma"])
            popUp.selectItem(withTitle: "Item Beta")
            popUp.setAccessibilityIdentifier("QTestPopUp-2AD")
            popUp.setAccessibilityLabel("Test PopUp Button")
            window.contentView?.addSubview(popUp)
            window.makeKeyAndOrderFront(nil)
            return (window, popUp)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listPopupItems(
            applicationName: currentProcessAppName,
            role: "AXPopUpButton",
            identifier: "QTestPopUp-2AD",
            title: nil
        )

        #expect(metadata.items.count == 3)
        #expect(metadata.selectedValue == "Item Beta")
        #expect(metadata.items.contains { $0.title == "Item Alpha" && $0.isSelected == false })
        #expect(metadata.items.contains { $0.title == "Item Beta" && $0.isSelected == true })
        #expect(metadata.items.contains { $0.title == "Item Gamma" && $0.isSelected == false })
    }
}
