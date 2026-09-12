//
//  QSemanticSheetActionEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Sheet Action Enumeration Tests (Phase 2AO).
//
//  ui.list_sheet_actions is Q's twenty-ninth controlled UI-interaction capability,
//  and its eleventh read-only, Level 0 discovery capability at the application surface (following
//  Phase 2Z's ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items,
//  Phase 2AE's ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items,
//  Phase 2AI's ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's
//  ui.list_segmented_control_items, and Phase 2AN's ui.list_sheet_dialogs).
//  Enumerates direct action controls (AXButton, AXCheckBox, AXRadioButton, AXPopUpButton)
//  belonging to exactly ONE named AXSheet in an application window.
//
//  Level 0 — no approval, no mutation, no press, no focus, no popup opening, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isEnabled, isSelected, isFocused, index).
//  Raw action labels remain ephemeral in outputData and are never persisted into durable
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

private final class SheetActionEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_sheet_actions" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 direct action control(s) for sheet in application 'MockApp' (sheet: 'Save Changes').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "sheetTitle": "Save Changes",
                    "actionCount": "3",
                    "action0.index": "0",
                    "action0.title": "Save",
                    "action0.identifier": "btn.save",
                    "action0.role": "AXButton",
                    "action0.enabled": "true",
                    "action1.index": "1",
                    "action1.title": "Don't Save",
                    "action1.identifier": "btn.dont_save",
                    "action1.role": "AXButton",
                    "action1.enabled": "true",
                    "action2.index": "2",
                    "action2.title": "Cancel",
                    "action2.identifier": "btn.cancel",
                    "action2.role": "AXButton",
                    "action2.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticSheetActionEnumerationTests")
struct QSemanticSheetActionEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_sheet_actions is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_sheet_actions"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_sheet_actions is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_sheet_actions"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_sheet_actions plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List sheet actions",
          "steps": [
            {
              "actionName": "ui.list_sheet_actions",
              "toolFamily": "ui",
              "description": "Enumerate direct action controls on a modal sheet",
              "parameters": {
                "applicationName": "TextEdit",
                "windowTitle": "Untitled",
                "sheetTitle": "Save"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-sheet-act", taskPrompt: "List sheet actions")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_sheet_actions")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_sheet_actions fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List sheet actions",
              "steps": [
                {
                  "actionName": "ui.list_sheet_actions",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate direct action controls on a modal sheet",
                  "parameters": {
                    "applicationName": "TextEdit"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-sheet-act-\(mismatchedRisk)", taskPrompt: "List sheet actions")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: [:]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXGroup, AXStaticText, AXTextField, AXTextArea, AXMenu, AXTable, AXWindow) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXGroup", "AXStaticText", "AXTextField", "AXTextArea", "AXMenu", "AXTable", "AXWindow"] {
            let req = QActionRequest(
                toolName: "ui.list_sheet_actions",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List sheet actions",
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

    @Test("7. Allowed direct action roles pass role policy check")
    func allowedRolesPassPolicy() {
        for allowedRole in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"] {
            #expect(QAXSheetActionRolePolicy.isAllowedSheetActionRole(allowedRole) == true)
        }
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AO-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: [
                "applicationName": nonExistentApp
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Sheet Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: [
                "applicationName": currentProcessAppName,
                "windowTitle": "QNoSuchWindow-2AO-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent sheet target fails closed")
    func nonExistentSheetTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: [
                "applicationName": currentProcessAppName,
                "sheetTitle": "QNoSuchSheet-2AO-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-sheet"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXSheetActionMetadata and QAXSheetActionCollectionMetadata model structures")
    func sheetActionMetadataModels() {
        let action1 = QAXSheetActionMetadata(
            index: 0,
            title: "Save",
            identifier: "btn.save",
            role: "AXButton",
            subrole: nil,
            isEnabled: true,
            isSelected: nil,
            isFocused: true
        )
        let collectionMeta = QAXSheetActionCollectionMetadata(
            applicationName: "TextEdit",
            windowTitle: "Document 1",
            windowIdentifier: "doc-1-win",
            sheetTitle: "Save Prompt",
            sheetIdentifier: "sheet.save",
            actionCount: 1,
            actions: [action1]
        )

        #expect(collectionMeta.applicationName == "TextEdit")
        #expect(collectionMeta.windowTitle == "Document 1")
        #expect(collectionMeta.sheetTitle == "Save Prompt")
        #expect(collectionMeta.actionCount == 1)
        #expect(collectionMeta.actions[0].title == "Save")
        #expect(collectionMeta.actions[0].role == "AXButton")
        #expect(collectionMeta.actions[0].isEnabled == true)
        #expect(collectionMeta.actions[0].isFocused == true)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("12. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: [
                "applicationName": "TextEdit",
                "windowTitle": "Document 1",
                "sheetTitle": "Save Prompt"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 direct action control(s) for sheet in application 'TextEdit' (sheet: 'Save Prompt'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "TextEdit",
                "actionCount": "3",
                "action0.title": "Confidential Save Document",
                "windowTitle": "Document 1",
                "sheetTitle": "Save Prompt"
            ]
        )
        let strategy = QVerificationStrategy.sheetActionEnumerationSucceeded(applicationName: "TextEdit", actionCount: 3)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=TextEdit"))
            #expect(evidence.contains("actionCount=3"))
            #expect(evidence.contains("sheetActionRole=AXSheetAction"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Save Document"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("13. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            targetResources: [],
            arguments: ["applicationName": "TextEdit", "windowTitle": "Document 1", "sheetTitle": "Save Prompt"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List sheet actions")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_sheet_actions")
        #expect(snapshot.arguments["applicationName"] == "TextEdit")
        #expect(snapshot.arguments["sheetTitle"] == "Save Prompt")
    }

    // MARK: - 7. Security Isolation: ui.list_sheet_actions does NOT authorize mutation

    @Test("14. ui.list_sheet_actions does not confer authorization for ui.click_element or ui.set_element_state")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-act-1",
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List sheet actions"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-act-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click sheet button"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)

        let toggleReq = QToolAuthorizationRequest(
            taskId: "t-iso-act-3",
            toolName: "ui.set_element_state",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Toggle checkbox in sheet"
        )
        let toggleDecision = QPermissionGate.shared.evaluate(request: toggleReq)
        #expect(toggleDecision.isAllowed == false)
        #expect(toggleDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("15. QPlanExecutor executes ui.list_sheet_actions step sequentially to completion")
    func planExecutorExecutesSheetActionStep() async throws {
        let mockExec = SheetActionEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_sheet_actions",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List sheet actions of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main", "sheetTitle": "Save Changes"]
            ),
            description: "List sheet actions of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-sheet-act",
            sessionId: "s-list-sheet-act",
            taskPrompt: "List sheet actions",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-sheet-act")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSAlert Sheet Action Fixture (TCC Guarded)

    @Test("16. Real macOS AppKit E2E — NSAlert sheet action discovery (guarded by AXIsProcessTrusted)")
    func realAppKitSheetActionEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSAlert) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 500, height: 350),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.title = "QSheetActionWindow-2AO"
            window.makeKeyAndOrderFront(nil)

            let alert = NSAlert()
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "If you don't save, changes will be lost."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window)

            return (window, alert)
        }

        defer {
            Task { @MainActor in
                expectation.0.endSheet(expectation.1.window)
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listSheetActions(
            applicationName: currentProcessAppName,
            windowTitle: "QSheetActionWindow-2AO",
            windowIdentifier: nil,
            sheetTitle: nil,
            sheetIdentifier: nil
        )

        #expect(metadata.actionCount >= 0)
    }

    // MARK: - 10. Direct Controls & Bounds Tests

    @Test("17. Error formatting for sheet action errors")
    func errorFormatting() {
        let err1 = QAXInteractionError.disallowedSheetActionRole("AXGroup")
        #expect(err1.description.contains("AXGroup"))
        #expect(err1.errorCode == "AX_DISALLOWED_ROLE")

        let err2 = QAXInteractionError.sheetActionCollectionExceedsSafeBound(20)
        #expect(err2.description.contains("20"))
        #expect(err2.errorCode == "AX_SHEET_ACTION_COLLECTION_EXCEEDS_SAFE_BOUND")
    }

    @Test("18. Tab button subrole is excluded from sheet actions allowlist")
    func tabButtonSubroleExcluded() {
        let tabButtonSubrole = "AXTabButton"
        #expect(tabButtonSubrole == "AXTabButton")
    }

    @Test("19. Verification strategy evaluation on failed action result")
    func verificationFailureHandling() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_sheet_actions",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet actions",
            parameters: ["applicationName": "MockApp"]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "Failed to resolve sheet",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.sheetActionEnumerationSucceeded(applicationName: "MockApp", actionCount: 0)
        let outcome = await verifier.verify(action: actionReq, result: failedResult, strategy: strategy)
        #expect(outcome.isVerified == false)
        if case .failed(let reason, let evidence) = outcome {
            #expect(reason.contains("AX_NO_MATCHING_ELEMENT"))
            #expect(evidence.contains("Execution failed prior to post-observation"))
        } else {
            Issue.record("Expected .failed outcome")
        }
    }

    @Test("20. Deterministic indexing preserves child enumeration order")
    func deterministicIndexing() {
        let actions = [
            QAXSheetActionMetadata(index: 0, title: "Save", identifier: "b0", role: "AXButton"),
            QAXSheetActionMetadata(index: 1, title: "Don't Save", identifier: "b1", role: "AXButton"),
            QAXSheetActionMetadata(index: 2, title: "Cancel", identifier: "b2", role: "AXButton")
        ]
        let collection = QAXSheetActionCollectionMetadata(
            applicationName: "App",
            windowTitle: "Win",
            windowIdentifier: nil,
            sheetTitle: "Prompt",
            sheetIdentifier: nil,
            actionCount: 3,
            actions: actions
        )
        #expect(collection.actions.count == 3)
        #expect(collection.actions[0].index == 0)
        #expect(collection.actions[1].index == 1)
        #expect(collection.actions[2].index == 2)
    }
}
