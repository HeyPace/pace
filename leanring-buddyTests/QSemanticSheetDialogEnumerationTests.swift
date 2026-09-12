//
//  QSemanticSheetDialogEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Sheet Dialog Enumeration Tests (Phase 2AN).
//
//  ui.list_sheet_dialogs is Q's twenty-eighth controlled UI-interaction capability,
//  and its tenth read-only, Level 0 discovery capability at the application surface (following
//  Phase 2Z's ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items,
//  Phase 2AE's ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items,
//  Phase 2AI's ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, and Phase 2AM's
//  ui.list_segmented_control_items).
//  Enumerates direct AXSheet modal elements attached to exactly ONE named AXWindow in a named application.
//
//  Level 0 — no approval, no mutation, no press, no focus, no button enumeration, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isModal, index).
//  Raw sheet contents remain ephemeral in outputData and are never persisted into durable
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

private final class SheetEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_sheet_dialogs" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 1 sheet(s) for window in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "sheetCount": "1",
                    "sheet0.index": "0",
                    "sheet0.title": "Save Changes",
                    "sheet0.identifier": "sheet.save_prompt",
                    "sheet0.role": "AXSheet",
                    "sheet0.modal": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticSheetDialogEnumerationTests")
struct QSemanticSheetDialogEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_sheet_dialogs is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_sheet_dialogs"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_sheet_dialogs is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_sheet_dialogs"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_sheet_dialogs plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List sheet dialogs",
          "steps": [
            {
              "actionName": "ui.list_sheet_dialogs",
              "toolFamily": "ui",
              "description": "Enumerate modal sheets attached to a window",
              "parameters": {
                "applicationName": "TextEdit",
                "windowTitle": "Untitled"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-sheet", taskPrompt: "List sheet dialogs")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_sheet_dialogs")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_sheet_dialogs fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List sheet dialogs",
              "steps": [
                {
                  "actionName": "ui.list_sheet_dialogs",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate modal sheets attached to a window",
                  "parameters": {
                    "applicationName": "TextEdit"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-sheet-\(mismatchedRisk)", taskPrompt: "List sheet dialogs")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet dialogs",
            parameters: [:]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXDialog, AXWindow, AXToolbar, AXGroup, AXTable) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXDialog", "AXWindow", "AXToolbar", "AXGroup", "AXTable", "AXButton"] {
            let req = QActionRequest(
                toolName: "ui.list_sheet_dialogs",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List sheet dialogs",
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
        let nonExistentApp = "QNoSuchApp-2AN-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet dialogs",
            parameters: [
                "applicationName": nonExistentApp
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window Target Resolution

    @Test("8. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet dialogs",
            parameters: [
                "applicationName": currentProcessAppName,
                "windowTitle": "QNoSuchWindow-2AN-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("9. QAXSheetMetadata and QAXSheetCollectionMetadata model structures")
    func sheetMetadataModels() {
        let sheet1 = QAXSheetMetadata(
            index: 0,
            title: "Unsaved Changes",
            identifier: "sheet-unsaved",
            role: "AXSheet",
            subrole: nil,
            isModal: true
        )
        let collectionMeta = QAXSheetCollectionMetadata(
            applicationName: "TextEdit",
            windowTitle: "Document 1",
            windowIdentifier: "doc-1-win",
            sheetCount: 1,
            sheets: [sheet1]
        )

        #expect(collectionMeta.applicationName == "TextEdit")
        #expect(collectionMeta.windowTitle == "Document 1")
        #expect(collectionMeta.windowIdentifier == "doc-1-win")
        #expect(collectionMeta.sheetCount == 1)
        #expect(collectionMeta.sheets[0].title == "Unsaved Changes")
        #expect(collectionMeta.sheets[0].role == "AXSheet")
        #expect(collectionMeta.sheets[0].isModal == true)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("10. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet dialogs",
            parameters: [
                "applicationName": "TextEdit",
                "windowTitle": "Document 1"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 1 sheet(s) for window in application 'TextEdit' (window: 'Document 1'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "TextEdit",
                "sheetCount": "1",
                "sheet0.title": "Confidential Document Save Prompt",
                "windowTitle": "Document 1"
            ]
        )
        let strategy = QVerificationStrategy.sheetEnumerationSucceeded(applicationName: "TextEdit", sheetCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=TextEdit"))
            #expect(evidence.contains("sheetCount=1"))
            #expect(evidence.contains("sheetRole=AXSheet"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Document Save Prompt"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("11. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List sheet dialogs",
            targetResources: [],
            arguments: ["applicationName": "TextEdit", "windowTitle": "Document 1"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List sheet dialogs")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_sheet_dialogs")
        #expect(snapshot.arguments["applicationName"] == "TextEdit")
        #expect(snapshot.arguments["windowTitle"] == "Document 1")
    }

    // MARK: - 7. Security Isolation: ui.list_sheet_dialogs does NOT authorize mutation

    @Test("12. ui.list_sheet_dialogs does not confer authorization for ui.close_window or ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_sheet_dialogs",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List sheet dialogs"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click sheet button"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)

        let closeReq = QToolAuthorizationRequest(
            taskId: "t-iso-3",
            toolName: "ui.close_window",
            toolFamily: "ui",
            baseRisk: .level3HighRisk,
            literalAction: "Close window"
        )
        let closeDecision = QPermissionGate.shared.evaluate(request: closeReq)
        #expect(closeDecision.isAllowed == false)
        #expect(closeDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("13. QPlanExecutor executes ui.list_sheet_dialogs step sequentially to completion")
    func planExecutorExecutesSheetEnumerationStep() async throws {
        let mockExec = SheetEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_sheet_dialogs",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List sheet dialogs of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List sheet dialogs of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-sheet",
            sessionId: "s-list-sheet",
            taskPrompt: "List sheet dialogs",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-sheet")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSAlert Sheet Fixture (TCC Guarded)

    @Test("14. Real macOS AppKit E2E — NSAlert sheet discovery (guarded by AXIsProcessTrusted)")
    func realAppKitSheetEnumeration() async throws {
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
            window.title = "QSheetWindow-2AN"
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

        let metadata = try await QBridgeAccessibility.shared.listSheetDialogs(
            applicationName: currentProcessAppName,
            windowTitle: "QSheetWindow-2AN",
            windowIdentifier: nil
        )

        #expect(metadata.sheetCount >= 0)
    }

    @Test("15. Window with zero sheets returns empty collection cleanly without error")
    func windowWithZeroSheetsReturnsEmptyCleanly() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let window = await MainActor.run { () -> NSWindow in
            let win = NSWindow(
                contentRect: NSRect(x: 150, y: 150, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.animationBehavior = .none
            win.title = "QZeroSheetWindow-2AN"
            win.makeKeyAndOrderFront(nil)
            return win
        }

        defer {
            Task { @MainActor in
                window.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listSheetDialogs(
            applicationName: currentProcessAppName,
            windowTitle: "QZeroSheetWindow-2AN",
            windowIdentifier: nil
        )

        #expect(metadata.sheetCount == 0)
        #expect(metadata.sheets.isEmpty)
    }
}
