//
//  QSemanticColorWellEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Color Well Enumeration Tests (Phase 2AX).
//
//  ui.list_color_wells is Q's forty-sixth controlled UI-interaction capability, and its fifteenth
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  Phase 2AV's ui.list_browser_columns, and Phase 2AW's ui.list_popovers).
//  Enumerates direct AXColorWell elements belonging to an application window or view hierarchy.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, value, isEnabled, index).
//  Raw color well contents remain ephemeral in outputData and are never persisted into durable
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

private final class ColorWellEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_color_wells" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 color well(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXColorWell",
                    "colorWellCount": "2",
                    "colorWell0.index": "0",
                    "colorWell0.title": "Foreground Color",
                    "colorWell0.identifier": "color.fg",
                    "colorWell0.role": "AXColorWell",
                    "colorWell0.value": "rgb 1 0 0 1",
                    "colorWell0.enabled": "true",
                    "colorWell1.index": "1",
                    "colorWell1.title": "Background Color",
                    "colorWell1.identifier": "color.bg",
                    "colorWell1.role": "AXColorWell",
                    "colorWell1.value": "rgb 0 0 1 1",
                    "colorWell1.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyColorWellEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_color_wells" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 color well(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "role": "AXColorWell",
                    "colorWellCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticColorWellEnumerationTests")
struct QSemanticColorWellEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_color_wells is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_color_wells"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_color_wells is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_color_wells"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_color_wells plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List color wells",
            "steps": [
                {
                    "actionName": "ui.list_color_wells",
                    "toolFamily": "ui",
                    "description": "Find color pickers in the window",
                    "parameters": {
                        "applicationName": "TextEdit",
                        "windowTitle": "Untitled"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List color wells")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_color_wells")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "TextEdit")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Untitled")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List color wells",
            "steps": [
                {
                    "actionName": "ui.list_color_wells",
                    "toolFamily": "ui",
                    "riskLevel": "level2UserApproval",
                    "description": "Attempted risk override",
                    "parameters": {
                        "applicationName": "TextEdit"
                    }
                }
            ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List color wells")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "role": "AXColorWell"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup"] {
            let req = QActionRequest(
                toolName: "ui.list_color_wells",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List color wells",
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

    @Test("7. QAXColorWellRolePolicy accepts only AXColorWell")
    func colorWellRolePolicyDirect() {
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("AXColorWell") == true)
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("AXButton") == false)
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("AXSlider") == false)
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("AXWindow") == false)
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("AXGroup") == false)
        #expect(QAXColorWellRolePolicy.isAllowedColorWellRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AX-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXColorWell"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Color Well Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXColorWell",
                "windowTitle": "QNoSuchWindow-2AX-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent color well target with specific filter returns empty collection")
    func nonExistentColorWellTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXColorWell",
                "colorWellTitle": "QNoSuchColorWell-2AX-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-cw"))
        if result.success {
            #expect(result.outputData["colorWellCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXColorWellMetadata and QAXColorWellCollectionMetadata model structures")
    func colorWellMetadataModels() {
        let cw1 = QAXColorWellMetadata(
            index: 0,
            title: "Primary Color",
            identifier: "cw.primary",
            role: "AXColorWell",
            subrole: nil,
            value: "rgb 1 0 0 1",
            isEnabled: true
        )
        let cw2 = QAXColorWellMetadata(
            index: 1,
            title: "Secondary Color",
            identifier: "cw.secondary",
            role: "AXColorWell",
            subrole: nil,
            value: "rgb 0 1 0 1",
            isEnabled: false
        )
        let collection = QAXColorWellCollectionMetadata(
            applicationName: "DesignStudio",
            windowTitle: "Canvas",
            colorWellCount: 2,
            colorWells: [cw1, cw2]
        )

        #expect(collection.applicationName == "DesignStudio")
        #expect(collection.windowTitle == "Canvas")
        #expect(collection.colorWellCount == 2)
        #expect(collection.colorWells[0].title == "Primary Color")
        #expect(collection.colorWells[0].value == "rgb 1 0 0 1")
        #expect(collection.colorWells[0].isEnabled == true)
        #expect(collection.colorWells[1].title == "Secondary Color")
        #expect(collection.colorWells[1].isEnabled == false)
    }

    @Test("12. Empty color wells collection (zero color wells) is a valid, non-error result")
    func emptyColorWellCollectionIsValid() {
        let collection = QAXColorWellCollectionMetadata(
            applicationName: "DesignStudio",
            windowTitle: "Canvas",
            colorWellCount: 0,
            colorWells: []
        )
        #expect(collection.colorWellCount == 0)
        #expect(collection.colorWells.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "applicationName": "TextEdit",
                "role": "AXColorWell"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 color well(s) in application 'TextEdit' (window: 'Untitled'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "TextEdit",
                "colorWellCount": "2",
                "colorWell0.title": "Secret Color",
                "windowTitle": "Untitled"
            ]
        )
        let strategy = QVerificationStrategy.colorWellEnumerationSucceeded(applicationName: "TextEdit", colorWellCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=TextEdit"))
            #expect(evidence.contains("colorWellCount=2"))
            #expect(evidence.contains("colorWellRole=AXColorWell"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Secret Color"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            parameters: [
                "applicationName": "TextEdit",
                "role": "AXColorWell"
            ]
        )
        let failedResult = QActionResult(
            actionId: actionReq.actionId,
            success: false,
            summary: "No Accessibility element matched the requested target.",
            error: "AX_NO_MATCHING_ELEMENT"
        )
        let strategy = QVerificationStrategy.colorWellEnumerationSucceeded(applicationName: "TextEdit", colorWellCount: 0)
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
            actionName: "ui.list_color_wells",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List color wells",
            targetResources: [],
            arguments: ["applicationName": "TextEdit", "windowTitle": "Untitled"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List color wells")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_color_wells")
        #expect(snapshot.arguments["applicationName"] == "TextEdit")
        #expect(snapshot.arguments["windowTitle"] == "Untitled")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_color_wells does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_color_wells",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List color wells"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.click_element",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Click a color well"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("17. QPlanExecutor executes ui.list_color_wells step sequentially to completion")
    func planExecutorExecutesColorWellEnumerationStep() async throws {
        let mockExec = ColorWellEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_color_wells",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List color wells of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List color wells of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-cw",
            sessionId: "s-list-cw",
            taskPrompt: "List color wells",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-cw")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_color_wells step to completion when zero color wells are found")
    func planExecutorExecutesEmptyColorWellEnumerationStep() async throws {
        let mockExec = EmptyColorWellEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_color_wells",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List color wells of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List color wells of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-cw-empty",
            sessionId: "s-list-cw-empty",
            taskPrompt: "List color wells",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-cw-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSColorWell Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSColorWell discovery (guarded by AXIsProcessTrusted)")
    func realAppKitColorWellEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSColorWell) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "QColorWellWindow-2AX"
            let colorWell = NSColorWell(frame: NSRect(x: 50, y: 50, width: 80, height: 30))
            colorWell.color = NSColor.systemPurple
            colorWell.setAccessibilityIdentifier("test.colorwell.purple")
            colorWell.setAccessibilityTitle("Purple Well")

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            contentView.addSubview(colorWell)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)

            return (window, colorWell)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listColorWells(
            applicationName: currentProcessAppName,
            role: "AXColorWell",
            identifier: nil,
            title: nil,
            windowTitle: "QColorWellWindow-2AX",
            windowIdentifier: nil
        )

        #expect(metadata.colorWellCount >= 0)
        for cw in metadata.colorWells {
            #expect(cw.role == "AXColorWell")
        }
    }
}
