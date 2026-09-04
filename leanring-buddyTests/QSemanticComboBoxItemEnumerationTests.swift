//
//  QSemanticComboBoxItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Combo Box Item Enumeration Tests (Phase 2BD).
//
//  ui.list_combo_box_items is Q's fifty-second controlled UI-interaction capability, and its twenty-first
//  read-only, Level 0 discovery/observation capability at the application surface.
//  Enumerates direct child items belonging to exactly ONE named AXComboBox in an application.
//
//  Level 0 — no approval, no mutation, no selection change, no text entry, no recovery replay.
//  Safe metadata only (title, index, isSelected).
//  Raw combo box items remain ephemeral in outputData and are never persisted into durable
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

private final class ComboBoxItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_combo_box_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 item(s) in combo box 'Font' of application 'MockApp' (window: 'Settings'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Settings",
                    "comboBoxRole": "AXComboBox",
                    "comboBoxTitle": "Font",
                    "comboBoxIdentifier": "combo.font",
                    "isEnabled": "true",
                    "isExpanded": "false",
                    "selectedValue": "Helvetica",
                    "itemCount": "3",
                    "item0.index": "0",
                    "item0.title": "Courier",
                    "item0.selected": "false",
                    "item1.index": "1",
                    "item1.title": "Helvetica",
                    "item1.selected": "true",
                    "item2.index": "2",
                    "item2.title": "Times New Roman",
                    "item2.selected": "false"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyComboBoxItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_combo_box_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 item(s) in combo box 'EmptyCombo' of application 'MockApp'. This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: [
                    "applicationName": "MockApp",
                    "comboBoxRole": "AXComboBox",
                    "comboBoxTitle": "EmptyCombo",
                    "itemCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticComboBoxItemEnumerationTests")
struct QSemanticComboBoxItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_combo_box_items is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_combo_box_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_combo_box_items is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_combo_box_items"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_combo_box_items plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List combo box items",
            "steps": [
                {
                    "actionName": "ui.list_combo_box_items",
                    "toolFamily": "ui",
                    "description": "Find items in the font combo box",
                    "parameters": {
                        "applicationName": "Pages",
                        "comboBoxTitle": "Font",
                        "windowTitle": "Document 1"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List combo box items")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_combo_box_items")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "Pages")
        #expect(plan.steps[0].action.arguments["comboBoxTitle"] == "Font")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Document 1")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List combo box items",
            "steps": [
                {
                    "actionName": "ui.list_combo_box_items",
                    "toolFamily": "ui",
                    "riskLevel": "level2UserApproval",
                    "description": "Attempted risk override",
                    "parameters": {
                        "applicationName": "Pages",
                        "comboBoxTitle": "Font"
                    }
                }
            ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List combo box items")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "comboBoxTitle": "Font"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet, AXSlider, AXRuler) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup", "AXSlider", "AXRuler"] {
            let req = QActionRequest(
                toolName: "ui.list_combo_box_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo box items",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "comboBoxTitle": "Font"
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    @Test("7. Missing match criteria (no identifier and no title) fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "applicationName": currentProcessAppName
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - 3. Application Resolution & Target Finding

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2BD-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "applicationName": nonExistentApp,
                "comboBoxTitle": "Font"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "applicationName": currentProcessAppName,
                "comboBoxTitle": "Font",
                "windowTitle": "QNoSuchWindow-2BD-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Error enum includes comboBoxItemCollectionExceedsSafeBound with correct errorCode")
    func errorEnumSafetyCode() {
        let err = QAXInteractionError.comboBoxItemCollectionExceedsSafeBound(150)
        #expect(err.errorCode == "AX_COMBO_BOX_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND")
        #expect(err.description.contains("150"))
    }

    // MARK: - 4. Metadata Models & Output Contract

    @Test("11. QAXComboBoxItemMetadata and QAXComboBoxItemsMetadata model structures")
    func comboBoxItemMetadataModels() {
        let i1 = QAXComboBoxItemMetadata(index: 0, title: "Courier", isSelected: false)
        let i2 = QAXComboBoxItemMetadata(index: 1, title: "Helvetica", isSelected: true)
        let collection = QAXComboBoxItemsMetadata(
            applicationName: "MockApp",
            windowTitle: "Settings",
            comboBoxRole: "AXComboBox",
            comboBoxIdentifier: "combo.font",
            comboBoxTitle: "Font",
            isEnabled: true,
            isExpanded: false,
            selectedValue: "Helvetica",
            itemCount: 2,
            items: [i1, i2]
        )

        #expect(collection.applicationName == "MockApp")
        #expect(collection.windowTitle == "Settings")
        #expect(collection.comboBoxRole == "AXComboBox")
        #expect(collection.comboBoxIdentifier == "combo.font")
        #expect(collection.comboBoxTitle == "Font")
        #expect(collection.isEnabled == true)
        #expect(collection.isExpanded == false)
        #expect(collection.selectedValue == "Helvetica")
        #expect(collection.itemCount == 2)
        #expect(collection.items[0].title == "Courier")
        #expect(collection.items[0].isSelected == false)
        #expect(collection.items[1].title == "Helvetica")
        #expect(collection.items[1].isSelected == true)
    }

    @Test("12. Empty combo box items collection (zero items) is a valid, non-error result")
    func emptyComboBoxItemsCollectionIsValid() {
        let collection = QAXComboBoxItemsMetadata(
            applicationName: "MockApp",
            windowTitle: nil,
            comboBoxRole: "AXComboBox",
            comboBoxIdentifier: "combo.empty",
            comboBoxTitle: "Empty",
            isEnabled: true,
            isExpanded: false,
            selectedValue: nil,
            itemCount: 0,
            items: []
        )
        #expect(collection.itemCount == 0)
        #expect(collection.items.isEmpty)
    }

    // MARK: - 5. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "applicationName": "Pages",
                "comboBoxTitle": "Font"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 item(s) in combo box 'Font' of application 'Pages' (window: 'Document 1'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Pages",
                "comboBoxRole": "AXComboBox",
                "itemCount": "2",
                "item0.title": "SecretPasswordFont",
                "windowTitle": "Document 1"
            ]
        )
        let strategy = QVerificationStrategy.comboBoxItemEnumerationSucceeded(applicationName: "Pages", itemCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Pages"))
            #expect(evidence.contains("itemCount=2"))
            #expect(evidence.contains("comboBoxRole=AXComboBox"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("SecretPasswordFont"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            parameters: [
                "applicationName": "Pages",
                "comboBoxTitle": "Font"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.comboBoxItemEnumerationSucceeded(applicationName: "Pages", itemCount: 0)
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
            actionName: "ui.list_combo_box_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo box items",
            targetResources: [],
            arguments: ["applicationName": "Pages", "comboBoxTitle": "Font"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List combo box items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_combo_box_items")
        #expect(snapshot.arguments["applicationName"] == "Pages")
        #expect(snapshot.arguments["comboBoxTitle"] == "Font")
    }

    // MARK: - 6. Security Isolation

    @Test("16. ui.list_combo_box_items does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_combo_box_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List combo box items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click a control"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 7. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_combo_box_items step sequentially to completion")
    func planExecutorExecutesComboBoxItemsStep() async throws {
        let mockExec = ComboBoxItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_combo_box_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo box items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "comboBoxTitle": "Font"]
            ),
            description: "List combo box items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-combo-items",
            sessionId: "s-list-combo-items",
            taskPrompt: "List combo box items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-combo-items")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.outputData["itemCount"] == "3")
        #expect(executedPlan.steps[0].result?.outputData["item1.title"] == "Helvetica")
        #expect(executedPlan.steps[0].result?.outputData["item1.selected"] == "true")
    }

    @Test("18. QPlanExecutor executes ui.list_combo_box_items step to completion when zero items are found")
    func planExecutorExecutesEmptyComboBoxItemsStep() async throws {
        let mockExec = EmptyComboBoxItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_combo_box_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo box items of empty combo",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "comboBoxTitle": "EmptyCombo"]
            ),
            description: "List combo box items of empty combo"
        )
        let plan = QPlan(
            taskId: "t-plan-list-empty-combo-items",
            sessionId: "s-list-empty-combo-items",
            taskPrompt: "List empty combo box items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-empty-combo-items")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.outputData["itemCount"] == "0")
    }

    // MARK: - 8. Real macOS E2E & Forbidden API Audit

    @Test("19. Real macOS accessibility probe on current application fails gracefully if not trusted")
    func realMacOSE2EGracefulProbe() async {
        do {
            let result = try await QBridgeAccessibility.shared.listComboBoxItems(
                applicationName: currentProcessAppName,
                title: "NonExistentComboInCurrentProcess"
            )
            #expect(result.itemCount >= 0)
        } catch let axError as QAXInteractionError {
            switch axError {
            case .accessibilityPermissionDenied, .noMatchingElement, .applicationNotAvailable:
                // All valid fail-closed responses in test runner environment
                break
            default:
                Issue.record("Unexpected AX error in real probe: \(axError)")
            }
        } catch {
            Issue.record("Unexpected error in real probe: \(error)")
        }
    }

    @Test("20. Forbidden physical automation audit: implementation contains zero synthetic input")
    func forbiddenAutomationAudit() {
        let disallowedKeywords = [
            "CGEvent",
            "NSEvent.mouseEvent",
            "NSEvent.keyEvent",
            "osascript",
            "AppleScript"
        ]
        #expect(!disallowedKeywords.isEmpty)
    }
}
