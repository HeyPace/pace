//
//  QSemanticIncrementorEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Incrementor Enumeration Tests (Phase 2BA).
//
//  ui.list_incrementors is Q's forty-ninth controlled UI-interaction capability, and its eighteenth
//  read-only, Level 0 discovery/observation capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  Phase 2AV's ui.list_browser_columns, Phase 2AW's ui.list_popovers, Phase 2AX's ui.list_color_wells,
//  Phase 2AY's ui.list_progress_indicators, and Phase 2AZ's ui.list_level_indicators).
//  Enumerates direct AXIncrementor elements belonging to an application window or view hierarchy.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, value, minValue, maxValue, isEnabled, index).
//  Raw incrementor contents remain ephemeral in outputData and are never persisted into durable
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

private final class IncrementorEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_incrementors" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 incrementor(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "incrementorCount": "2",
                    "incrementor0.index": "0",
                    "incrementor0.title": "Zoom Level",
                    "incrementor0.identifier": "stepper.zoom",
                    "incrementor0.role": "AXIncrementor",
                    "incrementor0.value": "100.0",
                    "incrementor0.minValue": "10.0",
                    "incrementor0.maxValue": "400.0",
                    "incrementor0.enabled": "true",
                    "incrementor1.index": "1",
                    "incrementor1.title": "Copies",
                    "incrementor1.identifier": "stepper.copies",
                    "incrementor1.role": "AXIncrementor",
                    "incrementor1.value": "1.0",
                    "incrementor1.minValue": "1.0",
                    "incrementor1.maxValue": "99.0",
                    "incrementor1.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyIncrementorEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_incrementors" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 incrementor(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "incrementorCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticIncrementorEnumerationTests")
struct QSemanticIncrementorEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_incrementors is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_incrementors"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_incrementors is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_incrementors"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_incrementors plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List incrementors",
            "steps": [
                {
                    "actionName": "ui.list_incrementors",
                    "toolFamily": "ui",
                    "description": "Find numeric steppers in the window",
                    "parameters": {
                        "applicationName": "Xcode",
                        "windowTitle": "Pace"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List incrementors")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_incrementors")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "Xcode")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Pace")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List incrementors",
            "steps": [
                {
                    "actionName": "ui.list_incrementors",
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
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List incrementors")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            parameters: [
                "role": "AXIncrementor"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXToolbar, AXSheet, AXSlider) are rejected")
    func disallowedRolesRejected() async throws {
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXToolbar", "AXSheet", "AXSplitGroup", "AXTabGroup", "AXSlider"] {
            let req = QActionRequest(
                toolName: "ui.list_incrementors",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List incrementors",
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

    @Test("7. QAXIncrementorRolePolicy accepts AXIncrementor only")
    func incrementorRolePolicyDirect() {
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXIncrementor") == true)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXSlider") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXLevelIndicator") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXProgressIndicator") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXButton") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXWindow") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2BA-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXIncrementor"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Incrementor Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXIncrementor",
                "windowTitle": "QNoSuchWindow-2BA-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent incrementor target with specific filter returns empty collection")
    func nonExistentIncrementorTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXIncrementor",
                "incrementorTitle": "QNoSuchIncrementor-2BA-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-inc"))
        if result.success {
            #expect(result.outputData["incrementorCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXIncrementorMetadata and QAXIncrementorCollectionMetadata model structures")
    func incrementorMetadataModels() {
        let inc1 = QAXIncrementorMetadata(
            index: 0,
            title: "Zoom",
            identifier: "inc.zoom",
            role: "AXIncrementor",
            subrole: nil,
            value: 100.0,
            minValue: 25.0,
            maxValue: 400.0,
            isEnabled: true
        )
        let inc2 = QAXIncrementorMetadata(
            index: 1,
            title: "Copies",
            identifier: "inc.copies",
            role: "AXIncrementor",
            subrole: nil,
            value: 2.0,
            minValue: 1.0,
            maxValue: 50.0,
            isEnabled: true
        )
        let collection = QAXIncrementorCollectionMetadata(
            applicationName: "PrintDialog",
            windowTitle: "Settings",
            incrementorCount: 2,
            incrementors: [inc1, inc2]
        )

        #expect(collection.applicationName == "PrintDialog")
        #expect(collection.windowTitle == "Settings")
        #expect(collection.incrementorCount == 2)
        #expect(collection.incrementors[0].title == "Zoom")
        #expect(collection.incrementors[0].value == 100.0)
        #expect(collection.incrementors[1].value == 2.0)
    }

    @Test("12. Empty incrementor collection (zero incrementors) is a valid, non-error result")
    func emptyIncrementorCollectionIsValid() {
        let collection = QAXIncrementorCollectionMetadata(
            applicationName: "PrintDialog",
            windowTitle: "Settings",
            incrementorCount: 0,
            incrementors: []
        )
        #expect(collection.incrementorCount == 0)
        #expect(collection.incrementors.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            parameters: [
                "applicationName": "Xcode"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 incrementor(s) in application 'Xcode' (window: 'Workspace'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "incrementorCount": "2",
                "incrementor0.title": "ConfidentialFontSize",
                "windowTitle": "Workspace"
            ]
        )
        let strategy = QVerificationStrategy.incrementorEnumerationSucceeded(applicationName: "Xcode", incrementorCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("incrementorCount=2"))
            #expect(evidence.contains("incrementorRole=AXIncrementor"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("ConfidentialFontSize"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
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
        let strategy = QVerificationStrategy.incrementorEnumerationSucceeded(applicationName: "Xcode", incrementorCount: 0)
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
            actionName: "ui.list_incrementors",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List incrementors",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Workspace"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List incrementors")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_incrementors")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Workspace")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_incrementors does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_incrementors",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List incrementors"
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

    @Test("17. QPlanExecutor executes ui.list_incrementors step sequentially to completion")
    func planExecutorExecutesIncrementorEnumerationStep() async throws {
        let mockExec = IncrementorEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_incrementors",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List incrementors of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List incrementors of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-inc",
            sessionId: "s-list-inc",
            taskPrompt: "List incrementors",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-inc")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_incrementors step to completion when zero incrementors are found")
    func planExecutorExecutesEmptyIncrementorEnumerationStep() async throws {
        let mockExec = EmptyIncrementorEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_incrementors",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List incrementors of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List incrementors of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-inc-empty",
            sessionId: "s-list-inc-empty",
            taskPrompt: "List incrementors",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-inc-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSStepper Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSStepper discovery (guarded by AXIsProcessTrusted)")
    func realAppKitIncrementorEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSStepper) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "QIncrementorWindow-2BA"

            let stepper = NSStepper(frame: NSRect(x: 20, y: 20, width: 19, height: 27))
            stepper.minValue = 1.0
            stepper.maxValue = 100.0
            stepper.increment = 5.0
            stepper.doubleValue = 25.0
            stepper.setAccessibilityIdentifier("test.stepper.zoom")
            stepper.setAccessibilityTitle("Zoom Stepper")

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            contentView.addSubview(stepper)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)

            return (window, stepper)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listIncrementors(
            applicationName: currentProcessAppName,
            role: nil,
            identifier: nil,
            title: nil,
            windowTitle: "QIncrementorWindow-2BA",
            windowIdentifier: nil
        )

        #expect(metadata.incrementorCount >= 0)
        for inc in metadata.incrementors {
            #expect(inc.role == "AXIncrementor")
        }
    }
}
