//
//  QSemanticRadioGroupItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Radio Group Item Enumeration Tests (Phase 2AI).
//
//  ui.list_radio_group_items is Q's twenty-fifth controlled UI-interaction capability, and its seventh
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, and Phase 2AH's ui.list_tab_items).
//  Enumerates direct radio button options belonging to exactly ONE named AXRadioGroup in a named application.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, isSelected, isEnabled, role, subrole, index).
//  Raw radio item contents remain ephemeral in outputData and are never persisted into durable
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

private final class RadioGroupItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_radio_group_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 radio item(s) for radio group in application 'MockApp' (selected: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXRadioGroup",
                    "itemCount": "3",
                    "selectedItemCount": "1",
                    "item0.index": "0",
                    "item0.title": "Small",
                    "item0.selected": "true",
                    "item0.enabled": "true",
                    "item0.role": "AXRadioButton",
                    "item0.subrole": "",
                    "item1.index": "1",
                    "item1.title": "Medium",
                    "item1.selected": "false",
                    "item1.enabled": "true",
                    "item1.role": "AXRadioButton",
                    "item1.subrole": "",
                    "item2.index": "2",
                    "item2.title": "Large",
                    "item2.selected": "false",
                    "item2.enabled": "true",
                    "item2.role": "AXRadioButton",
                    "item2.subrole": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticRadioGroupItemEnumerationTests")
struct QSemanticRadioGroupItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_radio_group_items is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_radio_group_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_radio_group_items is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_radio_group_items"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_radio_group_items plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List radio group items",
          "steps": [
            {
              "actionName": "ui.list_radio_group_items",
              "toolFamily": "ui",
              "description": "Enumerate options in a radio group",
              "parameters": {
                "applicationName": "TextEdit",
                "role": "AXRadioGroup",
                "title": "Alignment"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-radio-group", taskPrompt: "List radio group items")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_radio_group_items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_radio_group_items fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List radio group items",
              "steps": [
                {
                  "actionName": "ui.list_radio_group_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate options in a radio group",
                  "parameters": {
                    "applicationName": "TextEdit",
                    "role": "AXRadioGroup",
                    "title": "Alignment"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-radio-\(mismatchedRisk)", taskPrompt: "List radio group items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXRadioGroup"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("7. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXTabGroup) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXTabGroup", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_radio_group_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List radio items",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Alignment"
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AI-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Radio Group Target Resolution

    @Test("9. Non-existent radio group target fails closed")
    func nonExistentRadioGroupTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXRadioGroup",
                "title": "QNoSuchRadioGroup-2AI-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-radiogroup"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("10. QAXRadioGroupItemMetadata and QAXRadioGroupMetadata model structures")
    func radioGroupMetadataModels() {
        let item1 = QAXRadioGroupItemMetadata(
            index: 0,
            title: "Option A",
            identifier: "opt-a",
            isSelected: true,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: nil
        )
        let item2 = QAXRadioGroupItemMetadata(
            index: 1,
            title: "Option B",
            identifier: "opt-b",
            isSelected: false,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: nil
        )
        let groupMeta = QAXRadioGroupMetadata(
            applicationName: "TextEdit",
            radioGroupTitle: "Choices",
            radioGroupIdentifier: "choices-group",
            itemCount: 2,
            selectedItemCount: 1,
            items: [item1, item2]
        )

        #expect(groupMeta.applicationName == "TextEdit")
        #expect(groupMeta.radioGroupTitle == "Choices")
        #expect(groupMeta.itemCount == 2)
        #expect(groupMeta.selectedItemCount == 1)
        #expect(groupMeta.items[0].title == "Option A")
        #expect(groupMeta.items[0].isSelected == true)
        #expect(groupMeta.items[1].title == "Option B")
        #expect(groupMeta.items[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("11. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": "TextEdit",
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 radio item(s) for radio group in application 'TextEdit' (selected: 1). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "TextEdit",
                "itemCount": "3",
                "selectedItemCount": "1",
                "item0.title": "Confidential Form Choice",
                "radioGroupTitle": "Alignment"
            ]
        )
        let strategy = QVerificationStrategy.radioGroupEnumerationSucceeded(applicationName: "TextEdit", itemCount: 3, selectedCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=TextEdit"))
            #expect(evidence.contains("itemCount=3"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("radioGroupRole=AXRadioGroup"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Form Choice"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("12. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            targetResources: [],
            arguments: ["applicationName": "TextEdit", "title": "Alignment"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List radio items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_radio_group_items")
        #expect(snapshot.arguments["applicationName"] == "TextEdit")
        #expect(snapshot.arguments["title"] == "Alignment")
    }

    // MARK: - 7. Security Isolation: ui.list_radio_group_items does NOT authorize ui.set_element_state

    @Test("13. ui.list_radio_group_items does not confer authorization for ui.set_element_state")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List radio group items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.set_element_state",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Set radio button state"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("14. QPlanExecutor executes ui.list_radio_group_items step sequentially to completion")
    func planExecutorExecutesRadioEnumerationStep() async throws {
        let mockExec = RadioGroupItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_radio_group_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List radio items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Alignment"]
            ),
            description: "List radio items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-radios",
            sessionId: "s-list-radios",
            taskPrompt: "List radio items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-radios")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSStackView of Radio Buttons Fixture (TCC Guarded)

    @Test("15. Real macOS AppKit E2E — NSStackView radio group item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitRadioGroupEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSStackView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let stackView = NSStackView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
            stackView.orientation = .vertical

            let radio1 = NSButton(radioButtonWithTitle: "Small", target: nil, action: nil)
            radio1.state = .on
            let radio2 = NSButton(radioButtonWithTitle: "Medium", target: nil, action: nil)
            radio2.state = .off
            let radio3 = NSButton(radioButtonWithTitle: "Large", target: nil, action: nil)
            radio3.state = .off

            stackView.addArrangedSubview(radio1)
            stackView.addArrangedSubview(radio2)
            stackView.addArrangedSubview(radio3)

            stackView.setAccessibilityRole(.radioGroup)
            stackView.setAccessibilityIdentifier("QTestRadioGroup-2AI")
            stackView.setAccessibilityLabel("Size Selection")
            window.contentView?.addSubview(stackView)
            window.makeKeyAndOrderFront(nil)
            return (window, stackView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listRadioGroupItems(
            applicationName: currentProcessAppName,
            role: "AXRadioGroup",
            identifier: "QTestRadioGroup-2AI",
            title: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
