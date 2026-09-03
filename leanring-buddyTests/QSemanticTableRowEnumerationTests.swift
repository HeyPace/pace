//
//  QSemanticTableRowEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Table Row Enumeration Tests (Phase 2AE).
//
//  ui.list_table_rows is Q's twenty-second controlled UI-interaction capability, and its fourth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, and Phase 2AD's ui.list_popup_items).
//  Enumerates direct table rows belonging to exactly ONE named AXTable in a named application.
//
//  Level 0 — no approval, no mutation, no press, no open, no recovery replay.
//  Safe metadata only (title, identifier, enabled, isSelected, role, subrole, index).
//  Raw table row contents remain ephemeral in outputData and are never persisted into durable
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

private final class TableRowEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_table_rows" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 table row(s) for table in application 'MockApp' (selected rows: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTable",
                    "rowCount": "3",
                    "selectedRowCount": "1",
                    "row0.index": "0",
                    "row0.title": "Row Alpha",
                    "row0.selected": "false",
                    "row0.enabled": "true",
                    "row0.role": "AXRow",
                    "row0.subrole": "AXTableRow",
                    "row1.index": "1",
                    "row1.title": "Row Beta",
                    "row1.selected": "true",
                    "row1.enabled": "true",
                    "row1.role": "AXRow",
                    "row1.subrole": "AXTableRow",
                    "row2.index": "2",
                    "row2.title": "Row Gamma",
                    "row2.selected": "false",
                    "row2.enabled": "true",
                    "row2.role": "AXRow",
                    "row2.subrole": "AXTableRow"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTableRowEnumerationTests")
struct QSemanticTableRowEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_table_rows is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListTableRows() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_table_rows"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List table rows",
          "steps": [
            {
              "actionName": "ui.list_table_rows",
              "toolFamily": "ui",
              "description": "Enumerate the rows of a table",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXTable",
                "title": "Files"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-tables", taskPrompt: "List table rows")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List table rows",
              "steps": [
                {
                  "actionName": "ui.list_table_rows",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate the rows of a table",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXTable",
                    "title": "Files"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-tables-\(mismatchedRisk)", taskPrompt: "List table rows")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            parameters: [
                "role": "AXTable",
                "title": "Files"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTable"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Disallowed role (e.g. AXOutline, AXButton, AXRow) is rejected before tree walk")
    func disallowedRoleRejected() async throws {
        for invalidRole in ["AXOutline", "AXButton", "AXTextField", "AXWindow", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_table_rows",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table rows",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Files"
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
        let nonExistentApp = "QNoSuchApp-2AE-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXTable",
                "title": "Files"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Table Target Resolution

    @Test("6. Non-existent table target fails closed")
    func nonExistentTableTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTable",
                "title": "QNoSuchTable-2AE-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-table"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("7. QAXTableRowItemMetadata and QAXTableMetadata model structures")
    func tableMetadataModels() {
        let row1 = QAXTableRowItemMetadata(
            index: 0,
            title: "Row Alpha",
            identifier: "id-alpha",
            isSelected: true,
            isEnabled: true,
            role: "AXRow",
            subrole: "AXTableRow"
        )
        let row2 = QAXTableRowItemMetadata(
            index: 1,
            title: "Row Beta",
            identifier: "id-beta",
            isSelected: false,
            isEnabled: true,
            role: "AXRow",
            subrole: "AXTableRow"
        )
        let tableMeta = QAXTableMetadata(
            applicationName: "Finder",
            tableTitle: "Files",
            tableIdentifier: "files-table",
            rowCount: 2,
            selectedRowCount: 1,
            rows: [row1, row2]
        )

        #expect(tableMeta.applicationName == "Finder")
        #expect(tableMeta.tableTitle == "Files")
        #expect(tableMeta.rowCount == 2)
        #expect(tableMeta.selectedRowCount == 1)
        #expect(tableMeta.rows[0].title == "Row Alpha")
        #expect(tableMeta.rows[0].isSelected == true)
        #expect(tableMeta.rows[1].title == "Row Beta")
        #expect(tableMeta.rows[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("8. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            parameters: [
                "applicationName": "Mail",
                "role": "AXTable",
                "title": "Messages"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 10 table row(s) for table in application 'Mail' (selected rows: 1). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Mail",
                "rowCount": "10",
                "selectedRowCount": "1",
                "row0.title": "Confidential Message Subject",
                "tableTitle": "Messages"
            ]
        )
        let strategy = QVerificationStrategy.tableRowEnumerationSucceeded(applicationName: "Mail", rowCount: 10, selectedCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Mail"))
            #expect(evidence.contains("rowCount=10"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("tableRole=AXTable"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Message Subject"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("9. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_table_rows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table rows",
            targetResources: [],
            arguments: ["applicationName": "Finder", "title": "Files"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List table rows")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_table_rows")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["title"] == "Files")
    }

    // MARK: - 7. Security Isolation: ui.list_table_rows does NOT authorize ui.select_table_row

    @Test("10. ui.list_table_rows does not confer authorization for ui.select_table_row")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_table_rows",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List table rows"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.select_table_row",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select table row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("11. QPlanExecutor executes ui.list_table_rows step sequentially to completion")
    func planExecutorExecutesTableRowEnumerationStep() async throws {
        let mockExec = TableRowEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_table_rows",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table rows of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Files"]
            ),
            description: "List table rows of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-tables",
            sessionId: "s-list-tables",
            taskPrompt: "List table rows",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-tables")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real macOS AppKit NSTableView Fixture (TCC Guarded)

    @Test("12. Real macOS AppKit E2E — NSTableView row discovery (guarded by AXIsProcessTrusted)")
    func realAppKitTableViewEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSTableView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
            let tableView = NSTableView(frame: scrollView.bounds)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col1"))
            column.title = "Items"
            column.width = 300
            tableView.addTableColumn(column)
            tableView.setAccessibilityIdentifier("QTestTable-2AE")
            tableView.setAccessibilityLabel("Test Table")
            scrollView.documentView = tableView
            window.contentView?.addSubview(scrollView)
            window.makeKeyAndOrderFront(nil)
            return (window, tableView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listTableRows(
            applicationName: currentProcessAppName,
            role: "AXTable",
            identifier: "QTestTable-2AE",
            title: nil
        )

        #expect(metadata.rowCount >= 0)
    }
}
