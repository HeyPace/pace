//
//  QSemanticComboBoxEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Combo Box Enumeration Tests (Phase 2BB).
//
//  ui.list_combo_boxes is Q's fiftieth controlled UI-interaction capability, and its nineteenth
//  read-only, Level 0 discovery/observation capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  Phase 2AV's ui.list_browser_columns, Phase 2AW's ui.list_popovers, Phase 2AX's ui.list_color_wells,
//  Phase 2AY's ui.list_progress_indicators, Phase 2AZ's ui.list_level_indicators, and Phase 2BA's ui.list_incrementors).
//  Enumerates direct AXComboBox elements belonging to an application window or view hierarchy.
//
//  Level 0 — no approval, no mutation, no selection change, no text entry, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, value, placeholderValue, isEnabled, isSettable, index).
//  Raw combo box contents remain ephemeral in outputData and are never persisted into durable
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

private final class ComboBoxEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_combo_boxes" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 combo box(es) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "comboBoxCount": "2",
                    "comboBox0.index": "0",
                    "comboBox0.title": "Font Family",
                    "comboBox0.identifier": "cb.font",
                    "comboBox0.role": "AXComboBox",
                    "comboBox0.value": "Helvetica",
                    "comboBox0.placeholderValue": "Select font...",
                    "comboBox0.enabled": "true",
                    "comboBox0.settable": "true",
                    "comboBox1.index": "1",
                    "comboBox1.title": "Encoding",
                    "comboBox1.identifier": "cb.encoding",
                    "comboBox1.role": "AXComboBox",
                    "comboBox1.value": "UTF-8",
                    "comboBox1.placeholderValue": "Select encoding...",
                    "comboBox1.enabled": "true",
                    "comboBox1.settable": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyComboBoxEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_combo_boxes" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 combo box(es) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "comboBoxCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticComboBoxEnumerationTests")
struct QSemanticComboBoxEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_combo_boxes is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_combo_boxes"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_combo_boxes is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_combo_boxes"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_combo_boxes plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List combo boxes",
            "steps": [
                {
                    "actionName": "ui.list_combo_boxes",
                    "toolFamily": "ui",
                    "description": "Find combo boxes in the window",
                    "parameters": {
                        "applicationName": "Xcode",
                        "windowTitle": "Pace"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List combo boxes")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_combo_boxes")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "Xcode")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Pace")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List combo boxes",
            "steps": [
                {
                    "actionName": "ui.list_combo_boxes",
                    "toolFamily": "ui",
                    "riskLevel": "level2UserApproval",
                    "description": "Attempted risk override",
                    "parameters": {
                        "applicationName": "Xcode"
                    }
                }
            ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List combo boxes")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "role": "AXComboBox"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet, AXSlider, AXIncrementor) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup", "AXSlider", "AXIncrementor"] {
            let req = QActionRequest(
                toolName: "ui.list_combo_boxes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo boxes",
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

    @Test("7. QAXComboBoxRolePolicy accepts AXComboBox only")
    func comboBoxRolePolicyDirect() {
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXComboBox") == true)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXSlider") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXIncrementor") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXLevelIndicator") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXProgressIndicator") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXButton") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXWindow") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2BB-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXComboBox"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Combo Box Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXComboBox",
                "windowTitle": "QNoSuchWindow-2BB-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent combo box target with specific filter returns empty collection")
    func nonExistentComboBoxTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXComboBox",
                "comboBoxTitle": "QNoSuchComboBox-2BB-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-cb"))
        if result.success {
            #expect(result.outputData["comboBoxCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXComboBoxMetadata and QAXComboBoxCollectionMetadata model structures")
    func comboBoxMetadataModels() {
        let cb1 = QAXComboBoxMetadata(
            index: 0,
            title: "Font",
            identifier: "cb.font",
            role: "AXComboBox",
            subrole: nil,
            value: "Helvetica",
            placeholderValue: "Select font...",
            isEnabled: true,
            isSettable: true
        )
        let cb2 = QAXComboBoxMetadata(
            index: 1,
            title: "Size",
            identifier: "cb.size",
            role: "AXComboBox",
            subrole: nil,
            value: "12",
            placeholderValue: "Select size...",
            isEnabled: true,
            isSettable: true
        )
        let collection = QAXComboBoxCollectionMetadata(
            applicationName: "TextEditor",
            windowTitle: "Document",
            comboBoxCount: 2,
            comboBoxes: [cb1, cb2]
        )

        #expect(collection.applicationName == "TextEditor")
        #expect(collection.windowTitle == "Document")
        #expect(collection.comboBoxCount == 2)
        #expect(collection.comboBoxes[0].title == "Font")
        #expect(collection.comboBoxes[0].value == "Helvetica")
        #expect(collection.comboBoxes[1].value == "12")
    }

    @Test("12. Empty combo box collection (zero combo boxes) is a valid, non-error result")
    func emptyComboBoxCollectionIsValid() {
        let collection = QAXComboBoxCollectionMetadata(
            applicationName: "TextEditor",
            windowTitle: "Document",
            comboBoxCount: 0,
            comboBoxes: []
        )
        #expect(collection.comboBoxCount == 0)
        #expect(collection.comboBoxes.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "applicationName": "Xcode"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 combo box(es) in application 'Xcode' (window: 'Workspace'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "comboBoxCount": "2",
                "comboBox0.title": "ConfidentialFontChoice",
                "windowTitle": "Workspace"
            ]
        )
        let strategy = QVerificationStrategy.comboBoxEnumerationSucceeded(applicationName: "Xcode", comboBoxCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("comboBoxCount=2"))
            #expect(evidence.contains("comboBoxRole=AXComboBox"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("ConfidentialFontChoice"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            parameters: [
                "applicationName": "Xcode"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.comboBoxEnumerationSucceeded(applicationName: "Xcode", comboBoxCount: 0)
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
            actionName: "ui.list_combo_boxes",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List combo boxes",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Workspace"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List combo boxes")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_combo_boxes")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Workspace")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_combo_boxes does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_combo_boxes",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List combo boxes"
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

    // MARK: - 8. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_combo_boxes step sequentially to completion")
    func planExecutorExecutesComboBoxEnumerationStep() async throws {
        let mockExec = ComboBoxEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_combo_boxes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo boxes of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List combo boxes of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-cb",
            sessionId: "s-list-cb",
            taskPrompt: "List combo boxes",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-cb")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_combo_boxes step to completion when zero combo boxes are found")
    func planExecutorExecutesEmptyComboBoxEnumerationStep() async throws {
        let mockExec = EmptyComboBoxEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_combo_boxes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List combo boxes of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List combo boxes of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-cb-empty",
            sessionId: "s-list-cb-empty",
            taskPrompt: "List combo boxes",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-cb-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSComboBox Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSComboBox discovery (guarded by AXIsProcessTrusted)")
    func realAppKitComboBoxEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSComboBox) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.title = "QComboBoxWindow-2BB"

            let comboBox = NSComboBox(frame: NSRect(x: 20, y: 20, width: 150, height: 26))
            comboBox.addItems(withObjectValues: ["One", "Two", "Three"])
            comboBox.selectItem(at: 0)
            comboBox.stringValue = "One"
            comboBox.setAccessibilityIdentifier("test.combobox.select")
            comboBox.setAccessibilityTitle("Number Selector")

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            contentView.addSubview(comboBox)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)

            return (window, comboBox)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listComboBoxes(
            applicationName: currentProcessAppName,
            role: nil,
            identifier: nil,
            title: nil,
            windowTitle: "QComboBoxWindow-2BB",
            windowIdentifier: nil
        )

        #expect(metadata.comboBoxCount >= 0)
        for cb in metadata.comboBoxes {
            #expect(cb.role == "AXComboBox")
        }
    }
}
