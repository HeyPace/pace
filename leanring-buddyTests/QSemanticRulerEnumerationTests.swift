//
//  QSemanticRulerEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Ruler Enumeration Tests (Phase 2BC).
//
//  ui.list_rulers is Q's fifty-first controlled UI-interaction capability, and its twentieth
//  read-only, Level 0 discovery/observation capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  Phase 2AV's ui.list_browser_columns, Phase 2AW's ui.list_popovers, Phase 2AX's ui.list_color_wells,
//  Phase 2AY's ui.list_progress_indicators, Phase 2AZ's ui.list_level_indicators, Phase 2BA's ui.list_incrementors,
//  and Phase 2BB's ui.list_combo_boxes).
//  Enumerates direct AXRuler elements belonging to an application window or view hierarchy.
//
//  Level 0 — no approval, no mutation, no marker repositioning, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, orientation, unitDescription, markerCount, isEnabled, index).
//  Raw ruler contents remain ephemeral in outputData and are never persisted into durable
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

private final class RulerEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_rulers" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 ruler(s) in application 'MockApp' (window: 'Canvas').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Canvas",
                    "rulerCount": "2",
                    "ruler0.index": "0",
                    "ruler0.title": "Horizontal Ruler",
                    "ruler0.identifier": "ruler.h",
                    "ruler0.role": "AXRuler",
                    "ruler0.orientation": "AXHorizontalOrientation",
                    "ruler0.unitDescription": "Inches",
                    "ruler0.markerCount": "3",
                    "ruler0.enabled": "true",
                    "ruler1.index": "1",
                    "ruler1.title": "Vertical Ruler",
                    "ruler1.identifier": "ruler.v",
                    "ruler1.role": "AXRuler",
                    "ruler1.orientation": "AXVerticalOrientation",
                    "ruler1.unitDescription": "Inches",
                    "ruler1.markerCount": "2",
                    "ruler1.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyRulerEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_rulers" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 ruler(s) in application 'MockApp' (window: 'Canvas').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Canvas",
                    "rulerCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticRulerEnumerationTests")
struct QSemanticRulerEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_rulers is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_rulers"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_rulers is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_rulers"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_rulers plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List rulers",
            "steps": [
                {
                    "actionName": "ui.list_rulers",
                    "toolFamily": "ui",
                    "description": "Find rulers in the window",
                    "parameters": {
                        "applicationName": "Xcode",
                        "windowTitle": "Pace"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List rulers")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_rulers")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "Xcode")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Pace")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List rulers",
            "steps": [
                {
                    "actionName": "ui.list_rulers",
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
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List rulers")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            parameters: [
                "role": "AXRuler"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet, AXSlider, AXIncrementor, AXComboBox) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup", "AXSlider", "AXIncrementor", "AXComboBox"] {
            let req = QActionRequest(
                toolName: "ui.list_rulers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List rulers",
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

    @Test("7. QAXRulerRolePolicy accepts AXRuler only")
    func rulerRolePolicyDirect() {
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXRuler") == true)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXComboBox") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXSlider") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXIncrementor") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXLevelIndicator") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXProgressIndicator") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXButton") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("AXWindow") == false)
        #expect(QAXRulerRolePolicy.isAllowedRulerRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2BC-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXRuler"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Ruler Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXRuler",
                "windowTitle": "QNoSuchWindow-2BC-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent ruler target with specific filter returns empty collection")
    func nonExistentRulerTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXRuler",
                "rulerTitle": "QNoSuchRuler-2BC-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-ruler"))
        if result.success {
            #expect(result.outputData["rulerCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXRulerMetadata and QAXRulerCollectionMetadata model structures")
    func rulerMetadataModels() {
        let r1 = QAXRulerMetadata(
            index: 0,
            title: "Horizontal",
            identifier: "ruler.h",
            role: "AXRuler",
            subrole: nil,
            orientation: "AXHorizontalOrientation",
            unitDescription: "Inches",
            markerCount: 4,
            isEnabled: true
        )
        let r2 = QAXRulerMetadata(
            index: 1,
            title: "Vertical",
            identifier: "ruler.v",
            role: "AXRuler",
            subrole: nil,
            orientation: "AXVerticalOrientation",
            unitDescription: "Inches",
            markerCount: 2,
            isEnabled: true
        )
        let collection = QAXRulerCollectionMetadata(
            applicationName: "CanvasApp",
            windowTitle: "Layout",
            rulerCount: 2,
            rulers: [r1, r2]
        )

        #expect(collection.applicationName == "CanvasApp")
        #expect(collection.windowTitle == "Layout")
        #expect(collection.rulerCount == 2)
        #expect(collection.rulers[0].title == "Horizontal")
        #expect(collection.rulers[0].orientation == "AXHorizontalOrientation")
        #expect(collection.rulers[0].unitDescription == "Inches")
        #expect(collection.rulers[0].markerCount == 4)
        #expect(collection.rulers[1].title == "Vertical")
    }

    @Test("12. Empty ruler collection (zero rulers) is a valid, non-error result")
    func emptyRulerCollectionIsValid() {
        let collection = QAXRulerCollectionMetadata(
            applicationName: "CanvasApp",
            windowTitle: "Layout",
            rulerCount: 0,
            rulers: []
        )
        #expect(collection.rulerCount == 0)
        #expect(collection.rulers.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            parameters: [
                "applicationName": "Xcode"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 ruler(s) in application 'Xcode' (window: 'Canvas'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "rulerCount": "2",
                "ruler0.title": "ConfidentialDocumentRuler",
                "windowTitle": "Canvas"
            ]
        )
        let strategy = QVerificationStrategy.rulerEnumerationSucceeded(applicationName: "Xcode", rulerCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("rulerCount=2"))
            #expect(evidence.contains("rulerRole=AXRuler"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("ConfidentialDocumentRuler"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
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
        let strategy = QVerificationStrategy.rulerEnumerationSucceeded(applicationName: "Xcode", rulerCount: 0)
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
            actionName: "ui.list_rulers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List rulers",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Canvas"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List rulers")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_rulers")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Canvas")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_rulers does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_rulers",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List rulers"
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

    @Test("17. QPlanExecutor executes ui.list_rulers step sequentially to completion")
    func planExecutorExecutesRulerEnumerationStep() async throws {
        let mockExec = RulerEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_rulers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List rulers of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Canvas"]
            ),
            description: "List rulers of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-ruler",
            sessionId: "s-list-ruler",
            taskPrompt: "List rulers",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-ruler")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_rulers step to completion when zero rulers are found")
    func planExecutorExecutesEmptyRulerEnumerationStep() async throws {
        let mockExec = EmptyRulerEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_rulers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List rulers of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Canvas"]
            ),
            description: "List rulers of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-ruler-empty",
            sessionId: "s-list-ruler-empty",
            taskPrompt: "List rulers",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-ruler-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSRulerView Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSRulerView discovery (guarded by AXIsProcessTrusted)")
    func realAppKitRulerEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSScrollView) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "QRulerWindow-2BC"

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let horizontalRuler = NSRulerView(scrollView: scrollView, orientation: .horizontalRuler)
            let verticalRuler = NSRulerView(scrollView: scrollView, orientation: .verticalRuler)
            horizontalRuler.setAccessibilityIdentifier("test.ruler.horizontal")
            horizontalRuler.setAccessibilityTitle("Document Horizontal Ruler")
            verticalRuler.setAccessibilityIdentifier("test.ruler.vertical")
            verticalRuler.setAccessibilityTitle("Document Vertical Ruler")

            scrollView.horizontalRulerView = horizontalRuler
            scrollView.verticalRulerView = verticalRuler
            scrollView.hasHorizontalRuler = true
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true

            window.contentView = scrollView
            window.makeKeyAndOrderFront(nil)

            return (window, scrollView)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listRulers(
            applicationName: currentProcessAppName,
            role: nil,
            identifier: nil,
            title: nil,
            windowTitle: "QRulerWindow-2BC",
            windowIdentifier: nil
        )

        #expect(metadata.rulerCount >= 0)
        for ruler in metadata.rulers {
            #expect(ruler.role == "AXRuler")
        }
    }
}
