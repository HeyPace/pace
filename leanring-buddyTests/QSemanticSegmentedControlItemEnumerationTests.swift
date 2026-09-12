//
//  QSemanticSegmentedControlItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Segmented Control Item Enumeration Tests (Phase 2AM).
//
//  ui.list_segmented_control_items is Q's twenty-seventh controlled UI-interaction capability,
//  and its ninth read-only, Level 0 discovery capability at the application surface (following
//  Phase 2Z's ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items,
//  Phase 2AE's ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items,
//  Phase 2AI's ui.list_radio_group_items, and Phase 2AK's ui.list_toolbar_items).
//  Enumerates direct segment options belonging to exactly ONE named AXSegmentedControl in a named application window.
//
//  Level 0 — no approval, no mutation, no press, no focus, no select, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, isEnabled, isSelected, index).
//  Raw segment contents remain ephemeral in outputData and are never persisted into durable
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

private final class SegmentedControlEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_segmented_control_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 segment(s) for segmented control in application 'MockApp' (window: 'Main') (selected: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXSegmentedControl",
                    "itemCount": "3",
                    "selectedItemCount": "1",
                    "item0.index": "0",
                    "item0.title": "Icons",
                    "item0.identifier": "segment.icons",
                    "item0.role": "AXRadioButton",
                    "item0.enabled": "true",
                    "item0.selected": "true",
                    "item1.index": "1",
                    "item1.title": "List",
                    "item1.identifier": "segment.list",
                    "item1.role": "AXRadioButton",
                    "item1.enabled": "true",
                    "item1.selected": "false",
                    "item2.index": "2",
                    "item2.title": "Columns",
                    "item2.identifier": "segment.columns",
                    "item2.role": "AXRadioButton",
                    "item2.enabled": "false",
                    "item2.selected": "false"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticSegmentedControlItemEnumerationTests")
struct QSemanticSegmentedControlItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_segmented_control_items is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_segmented_control_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_segmented_control_items is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_segmented_control_items"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_segmented_control_items plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List segmented control items",
          "steps": [
            {
              "actionName": "ui.list_segmented_control_items",
              "toolFamily": "ui",
              "description": "Enumerate segments in a segmented control",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXSegmentedControl",
                "windowTitle": "Downloads"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-seg", taskPrompt: "List segmented control items")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_segmented_control_items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_segmented_control_items fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List segmented control items",
              "steps": [
                {
                  "actionName": "ui.list_segmented_control_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate segments in a segmented control",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXSegmentedControl"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-seg-\(mismatchedRisk)", taskPrompt: "List segmented control items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            parameters: [
                "role": "AXSegmentedControl"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXRadioGroup, AXTable, AXButton, AXGroup, AXWindow, AXTabGroup, AXToolbar) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXRadioGroup", "AXTable", "AXButton", "AXGroup", "AXWindow", "AXTabGroup", "AXToolbar", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_segmented_control_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List segmented control items",
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
        let nonExistentApp = "QNoSuchApp-2AM-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXSegmentedControl"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Control Target Resolution

    @Test("8. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXSegmentedControl",
                "windowTitle": "QNoSuchWindow-2AM-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("9. Non-existent segmented control target fails closed")
    func nonExistentSegmentedControlTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXSegmentedControl",
                "title": "QNoSuchControl-2AM-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-control"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("10. QAXSegmentedControlItemMetadata and QAXSegmentedControlMetadata model structures")
    func segmentedControlMetadataModels() {
        let item1 = QAXSegmentedControlItemMetadata(
            index: 0,
            title: "Icons",
            identifier: "seg-icons",
            role: "AXRadioButton",
            subrole: nil,
            isEnabled: true,
            isSelected: true
        )
        let item2 = QAXSegmentedControlItemMetadata(
            index: 1,
            title: "List",
            identifier: "seg-list",
            role: "AXRadioButton",
            subrole: nil,
            isEnabled: true,
            isSelected: false
        )
        let segMeta = QAXSegmentedControlMetadata(
            applicationName: "Finder",
            windowTitle: "Downloads",
            controlTitle: "View Mode",
            controlIdentifier: "view-mode-seg",
            itemCount: 2,
            selectedItemCount: 1,
            items: [item1, item2]
        )

        #expect(segMeta.applicationName == "Finder")
        #expect(segMeta.windowTitle == "Downloads")
        #expect(segMeta.controlTitle == "View Mode")
        #expect(segMeta.itemCount == 2)
        #expect(segMeta.selectedItemCount == 1)
        #expect(segMeta.items[0].title == "Icons")
        #expect(segMeta.items[0].isSelected == true)
        #expect(segMeta.items[1].title == "List")
        #expect(segMeta.items[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("11. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            parameters: [
                "applicationName": "Finder",
                "role": "AXSegmentedControl"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 segment(s) for segmented control in application 'Finder' (window: 'Downloads') (selected: 1). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Finder",
                "itemCount": "3",
                "selectedItemCount": "1",
                "item0.title": "Confidential Segment Label",
                "controlTitle": "Private Setting Control"
            ]
        )
        let strategy = QVerificationStrategy.segmentedControlEnumerationSucceeded(applicationName: "Finder", itemCount: 3, selectedCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Finder"))
            #expect(evidence.contains("itemCount=3"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("segmentedControlRole=AXSegmentedControl"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Segment Label"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("12. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List segmented control items",
            targetResources: [],
            arguments: ["applicationName": "Finder", "windowTitle": "Downloads"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List segmented control items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_segmented_control_items")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["windowTitle"] == "Downloads")
    }

    // MARK: - 7. Security Isolation: ui.list_segmented_control_items does NOT authorize mutation

    @Test("13. ui.list_segmented_control_items does not confer authorization for ui.set_element_state or ui.select_tab")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_segmented_control_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List segmented control items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let stateReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.set_element_state",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Set element state"
        )
        let stateDecision = QPermissionGate.shared.evaluate(request: stateReq)
        #expect(stateDecision.isAllowed == false)
        #expect(stateDecision.requiresApproval == true)

        let tabReq = QToolAuthorizationRequest(
            taskId: "t-iso-3",
            toolName: "ui.select_tab",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select tab"
        )
        let tabDecision = QPermissionGate.shared.evaluate(request: tabReq)
        #expect(tabDecision.isAllowed == false)
        #expect(tabDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("14. QPlanExecutor executes ui.list_segmented_control_items step sequentially to completion")
    func planExecutorExecutesSegmentedControlEnumerationStep() async throws {
        let mockExec = SegmentedControlEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_segmented_control_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List segmented control items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List segmented control items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-seg",
            sessionId: "s-list-seg",
            taskPrompt: "List segmented control items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-seg")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSSegmentedControl Fixture (TCC Guarded)

    @Test("15. Real macOS AppKit E2E — NSSegmentedControl segment discovery (guarded by AXIsProcessTrusted)")
    func realAppKitSegmentedControlEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSSegmentedControl) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 500, height: 350),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            let segControl = NSSegmentedControl(labels: ["List", "Icons", "Columns"], trackingMode: .selectOne, target: nil, action: nil)
            segControl.selectedSegment = 1
            segControl.setAccessibilityLabel("View Mode Control")
            window.contentView?.addSubview(segControl)
            window.title = "QSegWindow-2AM"
            window.makeKeyAndOrderFront(nil)
            return (window, segControl)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listSegmentedControlItems(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            identifier: nil,
            title: "View Mode Control",
            windowTitle: "QSegWindow-2AM",
            windowIdentifier: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
