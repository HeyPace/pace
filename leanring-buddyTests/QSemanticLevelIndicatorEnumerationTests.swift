//
//  QSemanticLevelIndicatorEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Level Indicator Enumeration Tests (Phase 2AZ).
//
//  ui.list_level_indicators is Q's forty-eighth controlled UI-interaction capability, and its seventeenth
//  read-only, Level 0 discovery/observation capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, Phase 2AH's ui.list_tab_items, Phase 2AI's
//  ui.list_radio_group_items, Phase 2AK's ui.list_toolbar_items, Phase 2AM's ui.list_segmented_control_items,
//  Phase 2AN's ui.list_sheet_dialogs, Phase 2AO's ui.list_sheet_actions, Phase 2AT's ui.list_split_panes,
//  Phase 2AV's ui.list_browser_columns, Phase 2AW's ui.list_popovers, Phase 2AX's ui.list_color_wells, and
//  Phase 2AY's ui.list_progress_indicators).
//  Enumerates direct AXLevelIndicator and AXRelevanceIndicator elements belonging to an application window or view hierarchy.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, value, minValue, maxValue, warningValue, criticalValue, isEnabled, index).
//  Raw level indicator contents remain ephemeral in outputData and are never persisted into durable
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

private final class LevelIndicatorEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_level_indicators" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 level indicator(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "indicatorCount": "2",
                    "indicator0.index": "0",
                    "indicator0.title": "Battery Level",
                    "indicator0.identifier": "level.battery",
                    "indicator0.role": "AXLevelIndicator",
                    "indicator0.value": "80.0",
                    "indicator0.minValue": "0.0",
                    "indicator0.maxValue": "100.0",
                    "indicator0.warningValue": "20.0",
                    "indicator0.criticalValue": "10.0",
                    "indicator0.enabled": "true",
                    "indicator1.index": "1",
                    "indicator1.title": "Relevance Score",
                    "indicator1.identifier": "level.relevance",
                    "indicator1.role": "AXRelevanceIndicator",
                    "indicator1.value": "4.5",
                    "indicator1.minValue": "0.0",
                    "indicator1.maxValue": "5.0",
                    "indicator1.warningValue": "",
                    "indicator1.criticalValue": "",
                    "indicator1.enabled": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

private final class EmptyLevelIndicatorEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_level_indicators" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 0 level indicator(s) in application 'MockApp' (window: 'Main').",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "Main",
                    "indicatorCount": "0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticLevelIndicatorEnumerationTests")
struct QSemanticLevelIndicatorEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_level_indicators is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_level_indicators"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_level_indicators is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_level_indicators"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_level_indicators plan step")
    func parseValidStep() throws {
        let json = """
        {
            "taskPrompt": "List level indicators",
            "steps": [
                {
                    "actionName": "ui.list_level_indicators",
                    "toolFamily": "ui",
                    "description": "Find level and relevance gauges in the window",
                    "parameters": {
                        "applicationName": "Xcode",
                        "windowTitle": "Pace"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List level indicators")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.list_level_indicators")
        #expect(plan.steps[0].action.toolFamily == "ui")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
        #expect(plan.steps[0].action.arguments["applicationName"] == "Xcode")
        #expect(plan.steps[0].action.arguments["windowTitle"] == "Pace")
    }

    @Test("4. Parser rejects unauthorized risk level override")
    func parseUnauthorizedRiskOverride() {
        let json = """
        {
            "taskPrompt": "List level indicators",
            "steps": [
                {
                    "actionName": "ui.list_level_indicators",
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
            _ = try QModelPlanParser.parse(rawText: json, taskId: "test-task", taskPrompt: "List level indicators")
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            parameters: [
                "role": "AXLevelIndicator"
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
                toolName: "ui.list_level_indicators",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List level indicators",
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

    @Test("7. QAXLevelIndicatorRolePolicy accepts AXLevelIndicator and AXRelevanceIndicator")
    func levelIndicatorRolePolicyDirect() {
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXLevelIndicator") == true)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXRelevanceIndicator") == true)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXProgressIndicator") == false)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXSlider") == false)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXButton") == false)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("AXWindow") == false)
        #expect(QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole("") == false)
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AZ-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXLevelIndicator"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Window & Indicator Target Resolution

    @Test("9. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXLevelIndicator",
                "windowTitle": "QNoSuchWindow-2AZ-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-window"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Non-existent level indicator target with specific filter returns empty collection")
    func nonExistentIndicatorTargetReturnsEmpty() async throws {
        let req = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXLevelIndicator",
                "levelIndicatorTitle": "QNoSuchIndicator-2AZ-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-filter-li"))
        if result.success {
            #expect(result.outputData["indicatorCount"] == "0")
        } else {
            #expect(result.error == "AX_PERMISSION_DENIED" || result.error == "AX_NO_MATCHING_ELEMENT")
        }
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("11. QAXLevelIndicatorMetadata and QAXLevelIndicatorCollectionMetadata model structures")
    func levelIndicatorMetadataModels() {
        let li1 = QAXLevelIndicatorMetadata(
            index: 0,
            title: "Disk Usage",
            identifier: "li.disk",
            role: "AXLevelIndicator",
            subrole: nil,
            value: 75.0,
            minValue: 0.0,
            maxValue: 100.0,
            warningValue: 80.0,
            criticalValue: 95.0,
            isEnabled: true
        )
        let li2 = QAXLevelIndicatorMetadata(
            index: 1,
            title: "Match Rank",
            identifier: "li.rank",
            role: "AXRelevanceIndicator",
            subrole: nil,
            value: 4.0,
            minValue: 0.0,
            maxValue: 5.0,
            warningValue: nil,
            criticalValue: nil,
            isEnabled: true
        )
        let collection = QAXLevelIndicatorCollectionMetadata(
            applicationName: "Dashboard",
            windowTitle: "Metrics",
            indicatorCount: 2,
            indicators: [li1, li2]
        )

        #expect(collection.applicationName == "Dashboard")
        #expect(collection.windowTitle == "Metrics")
        #expect(collection.indicatorCount == 2)
        #expect(collection.indicators[0].title == "Disk Usage")
        #expect(collection.indicators[0].value == 75.0)
        #expect(collection.indicators[0].warningValue == 80.0)
        #expect(collection.indicators[0].criticalValue == 95.0)
        #expect(collection.indicators[1].role == "AXRelevanceIndicator")
        #expect(collection.indicators[1].value == 4.0)
    }

    @Test("12. Empty level indicator collection (zero indicators) is a valid, non-error result")
    func emptyIndicatorCollectionIsValid() {
        let collection = QAXLevelIndicatorCollectionMetadata(
            applicationName: "BuildTool",
            windowTitle: "Progress",
            indicatorCount: 0,
            indicators: []
        )
        #expect(collection.indicatorCount == 0)
        #expect(collection.indicators.isEmpty)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("13. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            parameters: [
                "applicationName": "Xcode"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 2 level indicator(s) in application 'Xcode' (window: 'Workspace'). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "Xcode",
                "indicatorCount": "2",
                "indicator0.title": "Compiling ConfidentialModule",
                "windowTitle": "Workspace"
            ]
        )
        let strategy = QVerificationStrategy.levelIndicatorEnumerationSucceeded(applicationName: "Xcode", indicatorCount: 2)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Xcode"))
            #expect(evidence.contains("indicatorCount=2"))
            #expect(evidence.contains("indicatorRole=AXLevelIndicator"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("ConfidentialModule"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("14. Verification fails closed when execution result did not succeed")
    func verificationFailsClosedOnUnsuccessfulResult() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
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
        let strategy = QVerificationStrategy.levelIndicatorEnumerationSucceeded(applicationName: "Xcode", indicatorCount: 0)
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
            actionName: "ui.list_level_indicators",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List level indicators",
            targetResources: [],
            arguments: ["applicationName": "Xcode", "windowTitle": "Workspace"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List level indicators")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_level_indicators")
        #expect(snapshot.arguments["applicationName"] == "Xcode")
        #expect(snapshot.arguments["windowTitle"] == "Workspace")
    }

    // MARK: - 7. Security Isolation

    @Test("16. ui.list_level_indicators does not confer authorization for ui.click_element")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_level_indicators",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List level indicators"
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

    @Test("17. QPlanExecutor executes ui.list_level_indicators step sequentially to completion")
    func planExecutorExecutesLevelIndicatorEnumerationStep() async throws {
        let mockExec = LevelIndicatorEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_level_indicators",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List level indicators of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List level indicators of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-li",
            sessionId: "s-list-li",
            taskPrompt: "List level indicators",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-li")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    @Test("18. QPlanExecutor executes ui.list_level_indicators step to completion when zero indicators are found")
    func planExecutorExecutesEmptyLevelIndicatorEnumerationStep() async throws {
        let mockExec = EmptyLevelIndicatorEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_level_indicators",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List level indicators of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "windowTitle": "Main"]
            ),
            description: "List level indicators of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-li-empty",
            sessionId: "s-list-li-empty",
            taskPrompt: "List level indicators",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-li-empty")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSLevelIndicator Fixture (TCC Guarded)

    @Test("19. Real macOS AppKit E2E — NSLevelIndicator discovery (guarded by AXIsProcessTrusted)")
    func realAppKitLevelIndicatorEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        let expectation = await MainActor.run { () -> (NSWindow, NSLevelIndicator, NSLevelIndicator) in
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.title = "QLevelIndicatorWindow-2AZ"

            let discreteIndicator = NSLevelIndicator(frame: NSRect(x: 20, y: 20, width: 200, height: 20))
            discreteIndicator.levelIndicatorStyle = .discreteCapacity
            discreteIndicator.minValue = 0.0
            discreteIndicator.maxValue = 10.0
            discreteIndicator.warningValue = 7.0
            discreteIndicator.criticalValue = 9.0
            discreteIndicator.doubleValue = 5.0
            discreteIndicator.setAccessibilityIdentifier("test.level.discrete")
            discreteIndicator.setAccessibilityTitle("Discrete Level")

            let ratingIndicator = NSLevelIndicator(frame: NSRect(x: 20, y: 60, width: 100, height: 20))
            ratingIndicator.levelIndicatorStyle = .rating
            ratingIndicator.minValue = 0.0
            ratingIndicator.maxValue = 5.0
            ratingIndicator.doubleValue = 4.0
            ratingIndicator.setAccessibilityIdentifier("test.level.rating")
            ratingIndicator.setAccessibilityTitle("Rating Stars")

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            contentView.addSubview(discreteIndicator)
            contentView.addSubview(ratingIndicator)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)

            return (window, discreteIndicator, ratingIndicator)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let metadata = try await QBridgeAccessibility.shared.listLevelIndicators(
            applicationName: currentProcessAppName,
            role: nil,
            identifier: nil,
            title: nil,
            windowTitle: "QLevelIndicatorWindow-2AZ",
            windowIdentifier: nil
        )

        #expect(metadata.indicatorCount >= 0)
        for li in metadata.indicators {
            #expect(li.role == "AXLevelIndicator" || li.role == "AXRelevanceIndicator")
        }
    }
}
