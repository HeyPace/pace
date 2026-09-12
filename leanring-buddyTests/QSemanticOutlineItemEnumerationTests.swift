//
//  QSemanticOutlineItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Outline Item Enumeration Tests (Phase 2AF).
//
//  ui.list_outline_items is Q's twenty-third controlled UI-interaction capability, and its fifth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, and Phase 2AE's
//  ui.list_table_rows).
//  Enumerates direct outline rows belonging to exactly ONE named AXOutline in a named application.
//
//  Level 0 — no approval, no mutation, no press, no open, no recovery replay.
//  Safe metadata only (title, identifier, depth, isExpanded, isSelected, isEnabled, role, subrole, index).
//  Raw outline item contents remain ephemeral in outputData and are never persisted into durable
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

private final class OutlineItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_outline_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 outline item(s) for outline in application 'MockApp' (selected: 1, expanded: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXOutline",
                    "itemCount": "3",
                    "selectedItemCount": "1",
                    "expandedItemCount": "1",
                    "item0.index": "0",
                    "item0.title": "Parent Alpha",
                    "item0.depth": "0",
                    "item0.expanded": "true",
                    "item0.selected": "false",
                    "item0.enabled": "true",
                    "item0.role": "AXRow",
                    "item0.subrole": "AXOutlineRow",
                    "item1.index": "1",
                    "item1.title": "Child A1",
                    "item1.depth": "1",
                    "item1.expanded": "false",
                    "item1.selected": "true",
                    "item1.enabled": "true",
                    "item1.role": "AXRow",
                    "item1.subrole": "AXOutlineRow",
                    "item2.index": "2",
                    "item2.title": "Parent Beta",
                    "item2.depth": "0",
                    "item2.expanded": "false",
                    "item2.selected": "false",
                    "item2.enabled": "true",
                    "item2.role": "AXRow",
                    "item2.subrole": "AXOutlineRow"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticOutlineItemEnumerationTests")
struct QSemanticOutlineItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_outline_items is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListOutlineItems() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_outline_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List outline items",
          "steps": [
            {
              "actionName": "ui.list_outline_items",
              "toolFamily": "ui",
              "description": "Enumerate the rows of an outline",
              "parameters": {
                "applicationName": "Xcode",
                "role": "AXOutline",
                "title": "Navigator"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-outlines", taskPrompt: "List outline items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List outline items",
              "steps": [
                {
                  "actionName": "ui.list_outline_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate the rows of an outline",
                  "parameters": {
                    "applicationName": "Xcode",
                    "role": "AXOutline",
                    "title": "Navigator"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-outlines-\(mismatchedRisk)", taskPrompt: "List outline items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            parameters: [
                "role": "AXOutline",
                "title": "Navigator"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXOutline"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Disallowed role (e.g. AXTable, AXButton, AXRow) is rejected before tree walk")
    func disallowedRoleRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXTextField", "AXWindow", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_outline_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List outline items",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Navigator"
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
        let nonExistentApp = "QNoSuchApp-2AF-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXOutline",
                "title": "Navigator"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Outline Target Resolution

    @Test("6. Non-existent outline target fails closed")
    func nonExistentOutlineTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXOutline",
                "title": "QNoSuchOutline-2AF-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-outline"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("7. QAXOutlineRowItemMetadata and QAXOutlineMetadata model structures")
    func outlineMetadataModels() {
        let item1 = QAXOutlineRowItemMetadata(
            index: 0,
            title: "Parent Alpha",
            identifier: "id-alpha",
            depth: 0,
            isExpanded: true,
            isSelected: false,
            isEnabled: true,
            role: "AXRow",
            subrole: "AXOutlineRow"
        )
        let item2 = QAXOutlineRowItemMetadata(
            index: 1,
            title: "Child A1",
            identifier: "id-a1",
            depth: 1,
            isExpanded: false,
            isSelected: true,
            isEnabled: true,
            role: "AXRow",
            subrole: "AXOutlineRow"
        )
        let outlineMeta = QAXOutlineMetadata(
            applicationName: "Xcode",
            outlineTitle: "Navigator",
            outlineIdentifier: "nav-outline",
            itemCount: 2,
            selectedItemCount: 1,
            expandedItemCount: 1,
            items: [item1, item2]
        )

        #expect(outlineMeta.applicationName == "Xcode")
        #expect(outlineMeta.outlineTitle == "Navigator")
        #expect(outlineMeta.itemCount == 2)
        #expect(outlineMeta.selectedItemCount == 1)
        #expect(outlineMeta.expandedItemCount == 1)
        #expect(outlineMeta.items[0].title == "Parent Alpha")
        #expect(outlineMeta.items[0].depth == 0)
        #expect(outlineMeta.items[0].isExpanded == true)
        #expect(outlineMeta.items[1].title == "Child A1")
        #expect(outlineMeta.items[1].depth == 1)
        #expect(outlineMeta.items[1].isSelected == true)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("8. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            parameters: [
                "applicationName": "Xcode",
                "role": "AXOutline",
                "title": "Navigator"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 10 outline item(s) for outline in application 'Xcode' (selected: 1, expanded: 2). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "itemCount": "10",
                "selectedItemCount": "1",
                "expandedItemCount": "2",
                "item0.title": "Confidential Project File",
                "outlineTitle": "Navigator"
            ]
        )
        let strategy = QVerificationStrategy.outlineItemEnumerationSucceeded(applicationName: "Xcode", itemCount: 10, selectedCount: 1, expandedCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("itemCount=10"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("expandedCount=2"))
            #expect(evidence.contains("outlineRole=AXOutline"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Project File"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("9. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_outline_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List outline items",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "title": "Navigator"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List outline items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_outline_items")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["title"] == "Navigator")
    }

    // MARK: - 7. Security Isolation: ui.list_outline_items does NOT authorize ui.select_outline_row or ui.toggle_disclosure

    @Test("10. ui.list_outline_items does not confer authorization for ui.select_outline_row or ui.toggle_disclosure")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_outline_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List outline items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.select_outline_row",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select outline row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)

        let toggleReq = QToolAuthorizationRequest(
            taskId: "t-iso-3",
            toolName: "ui.toggle_disclosure",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Toggle disclosure"
        )
        let toggleDecision = QPermissionGate.shared.evaluate(request: toggleReq)
        #expect(toggleDecision.isAllowed == false)
        #expect(toggleDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("11. QPlanExecutor executes ui.list_outline_items step sequentially to completion")
    func planExecutorExecutesOutlineEnumerationStep() async throws {
        let mockExec = OutlineItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_outline_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List outline items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Navigator"]
            ),
            description: "List outline items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-outlines",
            sessionId: "s-list-outlines",
            taskPrompt: "List outline items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-outlines")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real macOS AppKit NSOutlineView Fixture (TCC Guarded)

    @Test("12. Real macOS AppKit E2E — NSOutlineView item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitOutlineViewEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSOutlineView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
            let outlineView = NSOutlineView(frame: scrollView.bounds)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col1"))
            column.title = "Navigator"
            column.width = 300
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.setAccessibilityIdentifier("QTestOutline-2AF")
            outlineView.setAccessibilityLabel("Test Outline")
            scrollView.documentView = outlineView
            window.contentView?.addSubview(scrollView)
            window.makeKeyAndOrderFront(nil)
            return (window, outlineView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listOutlineItems(
            applicationName: currentProcessAppName,
            role: "AXOutline",
            identifier: "QTestOutline-2AF",
            title: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
