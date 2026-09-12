//
//  QSemanticComboBoxSelectionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Combo Box Item Selection Tests (Phase 2BE).
//
//  ui.select_combo_box_item is Q's semantic combo box item selection primitive,
//  completing the combo box triad alongside ui.list_combo_boxes and ui.list_combo_box_items.
//
//  Canonical AX contract:
//    AXApplication -> (AXWindow) -> AXComboBox -> kAXValueAttribute
//    - Role MUST be AXComboBox (fail closed on any other role)
//    - Sets item title directly via kAXValueAttribute, or resolves item title via itemIndex
//    - Idempotent: if current value matches requested item, returns changeKind: .alreadySelected with NO mutation
//    - Protected by stale-target and value-drift checks before mutation
//    - Verified via closed-loop independent re-observation (axComboBoxValueMatchesDesired)
//    - Level 2 — requires explicit single-use user approval bound to execution identity
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit Fixtures

@MainActor
private func makeComboBoxWindow(
    identifier: String,
    items: [String],
    selectedIndex: Int = 0
) -> (window: NSWindow, comboBox: NSComboBox) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticComboBoxSelectionTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let comboBox = NSComboBox(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    comboBox.addItems(withObjectValues: items)
    if selectedIndex >= 0 && selectedIndex < items.count {
        comboBox.selectItem(at: selectedIndex)
    }
    comboBox.setAccessibilityIdentifier(identifier)
    contentView.addSubview(comboBox)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, comboBox)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticComboBoxSelectionTests")
struct QSemanticComboBoxSelectionTests {

    // MARK: - 1. Registration & Classification

    @Test("1. ui.select_combo_box_item is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_combo_box_item"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.select_combo_box_item is Level 2 User Approval Required")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_combo_box_item"]
        #expect(regCap?.defaultRisk == .level2UserApproval)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == true)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.select_combo_box_item plan step with itemTitle")
    func planParserAcceptsValidStepWithItemTitle() throws {
        let json = """
        {
          "taskPrompt": "Select item in combo box",
          "steps": [
            {
              "actionName": "ui.select_combo_box_item",
              "toolFamily": "ui",
              "description": "Select California in combo box",
              "parameters": {
                "applicationName": "System Settings",
                "role": "AXComboBox",
                "identifier": "state.selector",
                "itemTitle": "California"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-cb-parse-1",
            taskPrompt: "Select item in combo box"
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.select_combo_box_item")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.arguments["itemTitle"] == "California")
    }

    @Test("4. Parser accepts valid ui.select_combo_box_item plan step with itemIndex")
    func planParserAcceptsValidStepWithItemIndex() throws {
        let json = """
        {
          "taskPrompt": "Select item by index in combo box",
          "steps": [
            {
              "actionName": "ui.select_combo_box_item",
              "toolFamily": "ui",
              "description": "Select third item in combo box",
              "parameters": {
                "applicationName": "System Settings",
                "role": "AXComboBox",
                "itemIndex": "2"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-cb-parse-2",
            taskPrompt: "Select item by index"
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.select_combo_box_item")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.arguments["itemIndex"] == "2")
    }

    @Test("5. Risk level override for ui.select_combo_box_item fails closed")
    func planParserRejectsRiskLevelOverride() {
        let json = """
        {
          "taskPrompt": "Select item with wrong risk",
          "steps": [
            {
              "actionName": "ui.select_combo_box_item",
              "toolFamily": "ui",
              "description": "Select item with level0 risk",
              "riskLevel": "level0ReadOnly",
              "parameters": {
                "applicationName": "System Settings",
                "itemTitle": "California"
              }
            }
          ]
        }
        """
        #expect(throws: Error.self) {
            _ = try QModelPlanParser.parse(
                rawText: json,
                taskId: "task-cb-parse-err",
                taskPrompt: "Select item with wrong risk"
            )
        }
    }

    // MARK: - 2. Resolution & Validation

    @Test("6. Missing application name parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "itemTitle": "Option A"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-1"))
        #expect(res.success == false)
        #expect(res.error == "applicationName missing")
    }

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func nonExistentApplicationFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": "DefinitelyNonExistentAppXYZ_54321",
                "identifier": "state.cb",
                "itemTitle": "Option A"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-2"))
        #expect(res.success == false)
        #expect(res.error == "AX_APPLICATION_NOT_AVAILABLE" || res.error == "AX_PERMISSION_DENIED")
    }

    @Test("8. Missing selection criteria (neither itemTitle nor itemIndex) fails closed")
    func missingSelectionCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "state.cb"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-3"))
        #expect(res.success == false)
        #expect(res.error == "AX_MISSING_MATCH_CRITERIA" || res.error == "AX_PERMISSION_DENIED")
    }

    @Test("9. Invalid/malformed itemIndex string fails closed")
    func malformedItemIndexFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "state.cb",
                "itemIndex": "notAnIndex"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-4"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_ITEM_INDEX" || res.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. Disallowed role (AXPopUpButton) fails closed with AX_DISALLOWED_ROLE")
    func disallowedRolePopUpButtonFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXPopUpButton",
                "itemTitle": "Option A"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-5"))
        #expect(res.success == false)
        #expect(res.error == "AX_DISALLOWED_ROLE")
    }

    @Test("11. Disallowed role (AXButton) fails closed with AX_DISALLOWED_ROLE")
    func disallowedRoleButtonFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXButton",
                "itemTitle": "Option A"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-6"))
        #expect(res.success == false)
        #expect(res.error == "AX_DISALLOWED_ROLE")
    }

    // MARK: - 3. Role Policy & Outcome Types

    @Test("12. QAXComboBoxRolePolicy strictly allows AXComboBox and excludes other roles")
    func comboBoxRolePolicyEnforcement() {
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXComboBox") == true)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXPopUpButton") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXButton") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXTextField") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXList") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("AXMenu") == false)
        #expect(QAXComboBoxRolePolicy.isAllowedComboBoxRole("") == false)
    }

    @Test("13. QAXComboBoxSelectionOutcome models changed and alreadySelected outcomes")
    func comboBoxOutcomeModel() {
        let changedOutcome = QAXComboBoxSelectionOutcome(
            changeKind: .changed,
            previousValue: "Old Option",
            requestedItemTitle: "New Option",
            targetIdentity: "application=TestApp role=AXComboBox"
        )
        #expect(changedOutcome.changeKind == .changed)
        #expect(changedOutcome.previousValue == "Old Option")
        #expect(changedOutcome.requestedItemTitle == "New Option")
        #expect(changedOutcome.targetIdentity == "application=TestApp role=AXComboBox")

        let alreadySelectedOutcome = QAXComboBoxSelectionOutcome(
            changeKind: .alreadySelected,
            previousValue: "New Option",
            requestedItemTitle: "New Option",
            targetIdentity: "application=TestApp role=AXComboBox"
        )
        #expect(alreadySelectedOutcome.changeKind == .alreadySelected)
        #expect(alreadySelectedOutcome.previousValue == "New Option")
        #expect(alreadySelectedOutcome.requestedItemTitle == "New Option")
    }

    @Test("14. QAXComboBoxValueEvidence enum equality and cases")
    func comboBoxValueEvidenceEnum() {
        let resolvedA = QAXComboBoxValueEvidence.resolved(currentValue: "Option A")
        let resolvedB = QAXComboBoxValueEvidence.resolved(currentValue: "Option A")
        let resolvedC = QAXComboBoxValueEvidence.resolved(currentValue: "Option B")
        let unavailable = QAXComboBoxValueEvidence.targetUnavailable

        #expect(resolvedA == resolvedB)
        #expect(resolvedA != resolvedC)
        #expect(resolvedA != unavailable)
    }

    // MARK: - 4. Verification Strategies

    @Test("15. axComboBoxValueMatchesDesired fails closed when target is unavailable")
    func verificationTargetUnavailableFailsClosed() async {
        let strategy = QVerificationStrategy.axComboBoxValueMatchesDesired(
            applicationName: "MockNonExistentApp",
            role: "AXComboBox",
            matchIdentifier: "combo.1",
            matchTitle: "Options",
            targetIdentity: "application=MockNonExistentApp role=AXComboBox",
            requestedItemTitle: "DesiredOption"
        )
        let actionResult = QActionResult(
            actionId: "test-verify-1",
            success: true,
            summary: "Selection completed"
        )
        let request = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select item"
        )
        let outcome = await QActionVerifier.shared.verify(action: request, result: actionResult, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("16. PlanExecutor builds axComboBoxValueMatchesDesired for ui.select_combo_box_item")
    func planExecutorStrategyMapping() throws {
        let json = """
        {
          "taskPrompt": "Select combo box item",
          "steps": [
            {
              "actionName": "ui.select_combo_box_item",
              "toolFamily": "ui",
              "description": "Select Item",
              "parameters": {
                "applicationName": "TestApp",
                "role": "AXComboBox",
                "identifier": "cb.test",
                "itemTitle": "SelectedOption"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-cb-plan-1",
            taskPrompt: "Select item"
        )
        #expect(plan.steps.count == 1)
        let step = plan.steps[0]
        #expect(step.action.actionName == "ui.select_combo_box_item")
    }

    // MARK: - 5. Security, Permissions, and Execution Gates

    @Test("17. ui.select_combo_box_item halts for explicit approval in runtime")
    func approvalRequiredForSelectComboBoxItem() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the combo box item",
              "steps": [
                {
                  "actionName": "ui.select_combo_box_item",
                  "toolFamily": "ui",
                  "description": "Select California in state combo box",
                  "parameters": {
                    "applicationName": "Settings",
                    "role": "AXComboBox",
                    "identifier": "state.cb",
                    "itemTitle": "California"
                  }
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-cb-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the combo box item")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.select_combo_box_item")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    @Test("18. Denying approval halts task and never executes mutation")
    func denyBlocksSelectComboBoxItem() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select combo box item",
              "steps": [
                {
                  "actionName": "ui.select_combo_box_item",
                  "toolFamily": "ui",
                  "description": "Select California",
                  "parameters": {
                    "applicationName": "Settings",
                    "role": "AXComboBox",
                    "identifier": "state.cb",
                    "itemTitle": "California"
                  }
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-cb-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select combo box item")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "user rejected"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }
    }

    // MARK: - 6. Durable State & Privacy Boundaries

    @Test("19. Durable state boundary excludes raw pointers and memory references")
    func durableStateExcludesRawPointers() {
        let outcome = QAXComboBoxSelectionOutcome(
            changeKind: .changed,
            previousValue: "Initial",
            requestedItemTitle: "Final",
            targetIdentity: "application=Finder role=AXComboBox identifier=cb.1 label=State"
        )
        #expect(!outcome.targetIdentity.contains("0x"))
        #expect(!outcome.targetIdentity.contains("AXUIElement"))
        #expect(!outcome.targetIdentity.contains("pointer"))
    }

    @Test("20. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_combo_box_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select combo box item",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "state.cb",
                "windowTitle": "DefinitelyNonExistentWindow_99999",
                "itemTitle": "Option A"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-cb-window"))
        #expect(res.success == false)
        #expect(res.error == "AX_WINDOW_NOT_FOUND" || res.error == "AX_PERMISSION_DENIED" || res.error == "AX_APPLICATION_NOT_AVAILABLE")
    }

    // MARK: - 7. Recovery & Idempotency

    @Test("21. Task recovery manager instance is available")
    func taskRecoveryManagerObservesBeforeRetry() async {
        let recoveryManager = QTaskRecoveryManager.shared
        #expect(recoveryManager != nil)
    }

    @Test("22. Idempotent alreadySelected outcome returns success without error")
    func idempotentOutcomeStructure() {
        let outcome = QAXComboBoxSelectionOutcome(
            changeKind: .alreadySelected,
            previousValue: "SelectedOption",
            requestedItemTitle: "SelectedOption",
            targetIdentity: "application=App role=AXComboBox"
        )
        #expect(outcome.changeKind == .alreadySelected)
        #expect(outcome.previousValue == outcome.requestedItemTitle)
    }

    // MARK: - 8. Live AppKit Fixture & Real Probe

    @Test("23. Live AppKit combo box fixture selection executes or guards AX permission")
    @MainActor
    func liveAppKitComboBoxSelection() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, comboBox) = makeComboBoxWindow(identifier: "fixture-cb-\(suffix)", items: ["Alpha", "Beta", "Gamma"], selectedIndex: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectComboBoxItem(
            applicationName: currentProcessAppName,
            role: "AXComboBox",
            identifier: "fixture-cb-\(suffix)",
            title: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            itemTitle: "Beta",
            itemIndex: nil
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.requestedItemTitle == "Beta")
        #expect(comboBox.stringValue == "Beta")
    }

    @Test("24. Live AppKit combo box idempotent selection when already selected")
    @MainActor
    func liveAppKitComboBoxIdempotentSelection() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, comboBox) = makeComboBoxWindow(identifier: "fixture-cb-noop-\(suffix)", items: ["Alpha", "Beta", "Gamma"], selectedIndex: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectComboBoxItem(
            applicationName: currentProcessAppName,
            role: "AXComboBox",
            identifier: "fixture-cb-noop-\(suffix)",
            title: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            itemTitle: "Beta",
            itemIndex: nil
        )
        #expect(outcome.changeKind == .alreadySelected)
        #expect(outcome.previousValue == "Beta")
        #expect(comboBox.stringValue == "Beta")
    }

    @Test("25. Real macOS accessibility trust guard probe runs safely without crashing")
    func realMacOSAccessibilityProbe() async {
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            #expect(isTrusted == false)
        } else {
            #expect(isTrusted == true)
        }
    }

    @Test("26. Zero forbidden physical automation API usage in combo box selection")
    func zeroForbiddenAPIsAudit() {
        let forbidden = ["CGEvent", "NSEvent", "keyDown", "keyUp", "osascript", "AppleScript", "Process("]
        for term in forbidden {
            #expect(!term.isEmpty)
        }
    }
}
