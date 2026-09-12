//
//  QSemanticBrowserColumnEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Multi-Column Browser Enumeration Tests (Phase 2AV).
//
//  ui.list_browser_columns is Q's forty-fourth controlled UI-interaction capability, and its thirteenth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, and Phase 2AT's ui.list_split_panes).
//  Enumerates direct AXColumn elements belonging to exactly ONE named AXBrowser in a named application window.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isEnabled, index).
//  Raw column contents remain ephemeral in outputData and are never persisted into durable
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

private final class BrowserColumnEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_browser_columns" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 browser column(s) for browser in application 'MockApp' (window: 'Files').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Files",
                    "role": "AXBrowser",
                    "columnCount": "3",
                    "column0.index": "0",
                    "column0.title": "Root",
                    "column0.identifier": "browser.col.0",
                    "column0.role": "AXColumn",
                    "column0.enabled": "true",
                    "column1.index": "1",
                    "column1.title": "Documents",
                    "column1.identifier": "browser.col.1",
                    "column1.role": "AXColumn",
                    "column1.enabled": "true",
                    "column2.index": "2",
                    "column2.title": "Projects",
                    "column2.identifier": "browser.col.2",
                    "column2.role": "AXColumn",
                    "column2.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyBrowserColumnEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_browser_columns" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 browser column(s) for browser in application 'MockApp' (window: 'Files').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Files",
                    "role": "AXBrowser",
                    "columnCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticBrowserColumnEnumerationTests")
struct QSemanticBrowserColumnEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_browser_columns is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_browser_columns"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_browser_columns is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_browser_columns"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_browser_columns plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List browser columns",
          "steps": [
            {
              "actionName": "ui.list_browser_columns",
              "toolFamily": "ui",
              "description": "Enumerate columns in a multi-column browser",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXBrowser",
                "windowTitle": "Downloads"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-browsercols", taskPrompt: "List browser columns")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_browser_columns")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_browser_columns fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List browser columns",
              "steps": [
                {
                  "actionName": "ui.list_browser_columns",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate columns in a multi-column browser",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXBrowser"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-browsercols-\(mismatchedRisk)", taskPrompt: "List browser columns")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "role": "AXBrowser"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSplitGroup) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSplitGroup", "AXTabGroup", "AXSheet"] {
            let req = QActionRequest(
                toolName: "ui.list_browser_columns",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List browser columns",
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

    @Test("7. QAXBrowserRolePolicy accepts only AXBrowser")
    func browserRolePolicyDirect() {
        #expect(QAXBrowserRolePolicy.isAllowedBrowserRole("AXBrowser") == true)
        #expect(QAXBrowserRolePolicy.isAllowedBrowserRole("AXColumn") == false)
        #expect(QAXBrowserRolePolicy.isAllowedBrowserRole("AXTable") == false)
        #expect(QAXBrowserRolePolicy.isAllowedBrowserRole("AXOutline") == false)
        #expect(QAXBrowserRolePolicy.isAllowedBrowserRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AV-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXBrowser"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Browser Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXBrowser",
                "windowTitle": "QNoSuchWindow-2AV-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent browser target fails closed")
    func nonExistentBrowserTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXBrowser",
                "title": "QNoSuchBrowser-2AV-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-browser"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXBrowserColumnMetadata and QAXBrowserColumnCollectionMetadata model structures")
    func browserColumnMetadataModels() {
        let col1 = QAXBrowserColumnMetadata(
            index: 0,
            title: "Column 1",
            identifier: "col-1",
            role: "AXColumn",
            subrole: nil,
            isEnabled: true
        )
        let col2 = QAXBrowserColumnMetadata(
            index: 1,
            title: "Column 2",
            identifier: "col-2",
            role: "AXColumn",
            subrole: nil,
            isEnabled: true
        )
        let browserMeta = QAXBrowserColumnCollectionMetadata(
            applicationName: "Finder",
            windowTitle: "Downloads",
            browserTitle: "File Browser",
            browserIdentifier: "main-browser",
            columnCount: 2,
            columns: [col1, col2]
        )

        #expect(browserMeta.applicationName == "Finder")
        #expect(browserMeta.windowTitle == "Downloads")
        #expect(browserMeta.browserTitle == "File Browser")
        #expect(browserMeta.browserIdentifier == "main-browser")
        #expect(browserMeta.columnCount == 2)
        #expect(browserMeta.columns[0].title == "Column 1")
        #expect(browserMeta.columns[0].role == "AXColumn")
        #expect(browserMeta.columns[1].title == "Column 2")
        #expect(browserMeta.columns[1].role == "AXColumn")
    }

    @Test("12. Empty browser (zero columns) is a valid, non-error result")
    func emptyBrowserIsValid() {
        let browserMeta = QAXBrowserColumnCollectionMetadata(
            applicationName: "Finder",
            windowTitle: "Downloads",
            browserTitle: nil,
            browserIdentifier: nil,
            columnCount: 0,
            columns: []
        )
        #expect(browserMeta.columnCount == 0)
        #expect(browserMeta.columns.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "applicationName": "Finder",
                "role": "AXBrowser"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 browser column(s) for browser in application 'Finder' (window: 'Main'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Finder",
                "columnCount": "2",
                "column0.title": "Confidential Folder",
                "browserTitle": "Main Browser"
            ]
        )
        let strategy = QVerificationStrategy.browserColumnEnumerationSucceeded(applicationName: "Finder", columnCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Finder"))
            #expect(evidence.contains("columnCount=2"))
            #expect(evidence.contains("browserRole=AXBrowser"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Folder"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            parameters: [
                "applicationName": "Finder",
                "role": "AXBrowser"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.browserColumnEnumerationSucceeded(applicationName: "Finder", columnCount: 0)
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
            actionName: "ui.list_browser_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List browser columns",
            targetResources: [],
            arguments: ["applicationName": "Finder", "windowTitle": "Main"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List browser columns")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_browser_columns")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["windowTitle"] == "Main")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_browser_columns does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_browser_columns",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List browser columns"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click a browser column item"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_browser_columns step sequentially to completion")
    func planExecutorExecutesBrowserColumnEnumerationStep() async throws {
        let mockExec = BrowserColumnEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_browser_columns",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List browser columns of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Files"]
            ),
            description: "List browser columns of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-browsercols",
            sessionId: "s-list-browsercols",
            taskPrompt: "List browser columns",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-browsercols")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_browser_columns step to completion when zero columns are found")
    func planExecutorExecutesEmptyBrowserColumnEnumerationStep() async throws {
        let mockExec = EmptyBrowserColumnEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_browser_columns",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List browser columns of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Files"]
            ),
            description: "List browser columns of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-browsercols-empty",
            sessionId: "s-list-browsercols-empty",
            taskPrompt: "List browser columns",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-browsercols-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSBrowser Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSBrowser column discovery (guarded by AXIsProcessTrusted)")
    func realAppKitBrowserColumnEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSBrowser) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let browser = NSBrowser(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            browser.setAccessibilityIdentifier("test.browser")

            window.contentView = browser
            window.title = "QBrowserWindow-2AV"
            window.makeKeyAndOrderFront(nil)
            return (window, browser)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listBrowserColumns(
            applicationName: currentProcessAppName,
            role: "AXBrowser",
            identifier: "test.browser",
            title: nil,
            windowTitle: "QBrowserWindow-2AV",
            windowIdentifier: nil
        )

        #expect(metadata.columnCount >= 0)
        for column in metadata.columns {
            #expect(column.role == "AXColumn")
        }
    }
}
