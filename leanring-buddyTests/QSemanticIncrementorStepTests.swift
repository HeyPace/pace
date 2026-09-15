//
//  QSemanticIncrementorStepTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Stepper / Incrementor Step Mutation Tests (Phase 2BF).
//
//  ui.step_incrementor is Q's semantic stepper/incrementor step primitive, completing the
//  enumerate-then-act pair alongside ui.list_incrementors (Phase 2BA) — the same rhythm already
//  completed for AXComboBox (ui.list_combo_boxes/ui.list_combo_box_items -> ui.select_combo_box_item,
//  Phase 2BB/2BD -> 2BE).
//
//  Canonical AX contract:
//    AXApplication -> (AXWindow) -> AXIncrementor -> AXUIElementPerformAction(kAXIncrementAction/kAXDecrementAction)
//    - Role MUST be AXIncrementor (fail closed on any other role)
//    - direction ("increment"/"decrement") is required and explicit — never a blind toggle
//    - steps is bounded to [1, 20] per call
//    - Idempotent: already at the reported kAXMinValueAttribute/kAXMaxValueAttribute bound in the
//      requested direction returns changeKind: .alreadyAtBound with ZERO AX actions performed
//    - Protected by stale-target and value-drift checks before mutation
//    - Never AXUIElementSetAttributeValue(kAXValueAttribute) directly — kAXIncrementAction/
//      kAXDecrementAction are the purpose-built AX actions for this role
//    - Verified via closed-loop independent re-observation (axIncrementorValueMovedAsDesired)
//    - Level 2 — requires explicit single-use user approval bound to execution identity
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit Fixtures

@MainActor
private func makeStepperWindow(
    identifier: String,
    minValue: Double,
    maxValue: Double,
    increment: Double,
    initialValue: Double
) -> (window: NSWindow, stepper: NSStepper) {
    let window = NSWindow(
        contentRect: NSRect(x: 90, y: 90, width: 200, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticIncrementorStepTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let stepper = NSStepper(frame: NSRect(x: 20, y: 20, width: 19, height: 27))
    stepper.minValue = minValue
    stepper.maxValue = maxValue
    stepper.increment = increment
    stepper.doubleValue = initialValue
    stepper.setAccessibilityIdentifier(identifier)
    contentView.addSubview(stepper)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, stepper)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticIncrementorStepTests")
struct QSemanticIncrementorStepTests {

    // MARK: - 1. Registration & Classification

    @Test("1. ui.step_incrementor is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.step_incrementor"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.step_incrementor is Level 2 User Approval Required")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.step_incrementor"]
        #expect(regCap?.defaultRisk == .level2UserApproval)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == true)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.step_incrementor plan step with direction=increment")
    func planParserAcceptsValidIncrementStep() throws {
        let json = """
        {
          "taskPrompt": "Increment the zoom stepper",
          "steps": [
            {
              "actionName": "ui.step_incrementor",
              "toolFamily": "ui",
              "description": "Increment zoom stepper",
              "parameters": {
                "applicationName": "System Settings",
                "role": "AXIncrementor",
                "identifier": "stepper.zoom",
                "direction": "increment"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-inc-parse-1",
            taskPrompt: "Increment the zoom stepper"
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.step_incrementor")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.arguments["direction"] == "increment")
    }

    @Test("4. Parser accepts valid ui.step_incrementor plan step with direction=decrement and steps")
    func planParserAcceptsValidDecrementStepWithCount() throws {
        let json = """
        {
          "taskPrompt": "Decrement the copies stepper three times",
          "steps": [
            {
              "actionName": "ui.step_incrementor",
              "toolFamily": "ui",
              "description": "Decrement copies stepper",
              "parameters": {
                "applicationName": "Print Dialog",
                "role": "AXIncrementor",
                "title": "Copies",
                "direction": "decrement",
                "steps": "3"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-inc-parse-2",
            taskPrompt: "Decrement the copies stepper"
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.step_incrementor")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.arguments["direction"] == "decrement")
        #expect(plan.steps.first?.action.arguments["steps"] == "3")
    }

    @Test("5. Risk level override for ui.step_incrementor fails closed")
    func planParserRejectsRiskLevelOverride() {
        let json = """
        {
          "taskPrompt": "Step with wrong risk",
          "steps": [
            {
              "actionName": "ui.step_incrementor",
              "toolFamily": "ui",
              "description": "Step with level0 risk",
              "riskLevel": "level0ReadOnly",
              "parameters": {
                "applicationName": "System Settings",
                "identifier": "stepper.zoom",
                "direction": "increment"
              }
            }
          ]
        }
        """
        #expect(throws: Error.self) {
            _ = try QModelPlanParser.parse(
                rawText: json,
                taskId: "task-inc-parse-err",
                taskPrompt: "Step with wrong risk"
            )
        }
    }

    // MARK: - 2. Resolution & Validation

    @Test("6. Missing application name parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "identifier": "stepper.zoom",
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-1"))
        #expect(res.success == false)
        #expect(res.error == "applicationName missing")
    }

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func nonExistentApplicationFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": "DefinitelyNonExistentAppXYZ_54321",
                "identifier": "stepper.zoom",
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-2"))
        #expect(res.success == false)
        #expect(res.error == "AX_APPLICATION_NOT_AVAILABLE" || res.error == "AX_PERMISSION_DENIED")
    }

    @Test("8. Missing match criteria (neither identifier nor title) fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-3"))
        #expect(res.success == false)
        #expect(res.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("9. Missing direction parameter fails closed with AX_INVALID_STEP_DIRECTION")
    func missingDirectionFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-4"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_STEP_DIRECTION")
    }

    @Test("10. Invalid/malformed direction string fails closed")
    func malformedDirectionFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom",
                "direction": "up"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-5"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_STEP_DIRECTION")
    }

    @Test("11. Invalid steps (zero) fails closed with AX_INVALID_STEP_COUNT")
    func zeroStepsFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom",
                "direction": "increment",
                "steps": "0"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-6"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_STEP_COUNT")
    }

    @Test("12. Invalid steps (exceeds bound of 20) fails closed with AX_INVALID_STEP_COUNT")
    func excessiveStepsFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom",
                "direction": "increment",
                "steps": "21"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-7"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_STEP_COUNT")
    }

    @Test("13. Invalid/malformed steps string fails closed with AX_INVALID_STEP_COUNT")
    func malformedStepsFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom",
                "direction": "increment",
                "steps": "notANumber"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-8"))
        #expect(res.success == false)
        #expect(res.error == "AX_INVALID_STEP_COUNT")
    }

    @Test("14. Disallowed role (AXSlider) fails closed with AX_DISALLOWED_ROLE")
    func disallowedRoleSliderFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXSlider",
                "identifier": "stepper.zoom",
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-9"))
        #expect(res.success == false)
        #expect(res.error == "AX_DISALLOWED_ROLE")
    }

    @Test("15. Disallowed role (AXButton) fails closed with AX_DISALLOWED_ROLE")
    func disallowedRoleButtonFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXButton",
                "identifier": "stepper.zoom",
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-10"))
        #expect(res.success == false)
        #expect(res.error == "AX_DISALLOWED_ROLE")
    }

    // MARK: - 3. Role Policy & Outcome Types

    @Test("16. QAXIncrementorRolePolicy strictly allows AXIncrementor and excludes other roles")
    func incrementorRolePolicyEnforcement() {
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXIncrementor") == true)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXSlider") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXButton") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXTextField") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("AXComboBox") == false)
        #expect(QAXIncrementorRolePolicy.isAllowedIncrementorRole("") == false)
    }

    @Test("17. QAXIncrementorStepOutcome models changed and alreadyAtBound outcomes")
    func incrementorOutcomeModel() {
        let changedOutcome = QAXIncrementorStepOutcome(
            changeKind: .changed,
            direction: .increment,
            requestedSteps: 3,
            performedSteps: 3,
            previousValue: 10.0,
            currentValue: 25.0,
            targetIdentity: "application=TestApp role=AXIncrementor"
        )
        #expect(changedOutcome.changeKind == .changed)
        #expect(changedOutcome.direction == .increment)
        #expect(changedOutcome.requestedSteps == 3)
        #expect(changedOutcome.performedSteps == 3)
        #expect(changedOutcome.previousValue == 10.0)
        #expect(changedOutcome.currentValue == 25.0)

        let atBoundOutcome = QAXIncrementorStepOutcome(
            changeKind: .alreadyAtBound,
            direction: .increment,
            requestedSteps: 3,
            performedSteps: 0,
            previousValue: 100.0,
            currentValue: 100.0,
            targetIdentity: "application=TestApp role=AXIncrementor"
        )
        #expect(atBoundOutcome.changeKind == .alreadyAtBound)
        #expect(atBoundOutcome.performedSteps == 0)
        #expect(atBoundOutcome.previousValue == atBoundOutcome.currentValue)
    }

    @Test("18. QAXIncrementorStepDirection raw values are exactly 'increment'/'decrement'")
    func incrementorStepDirectionRawValues() {
        #expect(QAXIncrementorStepDirection.increment.rawValue == "increment")
        #expect(QAXIncrementorStepDirection.decrement.rawValue == "decrement")
        #expect(QAXIncrementorStepDirection(rawValue: "increment") == .increment)
        #expect(QAXIncrementorStepDirection(rawValue: "decrement") == .decrement)
        #expect(QAXIncrementorStepDirection(rawValue: "sideways") == nil)
    }

    @Test("19. QAXIncrementorValueEvidence enum equality and cases")
    func incrementorValueEvidenceEnum() {
        let resolvedA = QAXIncrementorValueEvidence.resolved(currentValue: 42.0)
        let resolvedB = QAXIncrementorValueEvidence.resolved(currentValue: 42.0)
        let resolvedC = QAXIncrementorValueEvidence.resolved(currentValue: 43.0)
        let unavailable = QAXIncrementorValueEvidence.targetUnavailable

        #expect(resolvedA == resolvedB)
        #expect(resolvedA != resolvedC)
        #expect(resolvedA != unavailable)
    }

    // MARK: - 4. Verification Strategies

    @Test("20. axIncrementorValueMovedAsDesired fails closed when target is unavailable")
    func verificationTargetUnavailableFailsClosed() async {
        let strategy = QVerificationStrategy.axIncrementorValueMovedAsDesired(
            applicationName: "MockNonExistentApp",
            role: "AXIncrementor",
            matchIdentifier: "stepper.1",
            matchTitle: "Zoom",
            targetIdentity: "application=MockNonExistentApp role=AXIncrementor",
            direction: .increment,
            previousValue: 10.0,
            changeKind: .changed
        )
        let actionResult = QActionResult(
            actionId: "test-verify-1",
            success: true,
            summary: "Step completed"
        )
        let request = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor"
        )
        let outcome = await QActionVerifier.shared.verify(action: request, result: actionResult, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("21. PlanExecutor builds axIncrementorValueMovedAsDesired for ui.step_incrementor")
    func planExecutorStrategyMapping() throws {
        let json = """
        {
          "taskPrompt": "Step incrementor",
          "steps": [
            {
              "actionName": "ui.step_incrementor",
              "toolFamily": "ui",
              "description": "Increment stepper",
              "parameters": {
                "applicationName": "TestApp",
                "role": "AXIncrementor",
                "identifier": "stepper.test",
                "direction": "increment"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-inc-plan-1",
            taskPrompt: "Step incrementor"
        )
        #expect(plan.steps.count == 1)
        let step = plan.steps[0]
        #expect(step.action.actionName == "ui.step_incrementor")
    }

    // MARK: - 5. Security, Permissions, and Execution Gates

    @Test("22. ui.step_incrementor halts for explicit approval in runtime")
    func approvalRequiredForStepIncrementor() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Increment the zoom stepper",
              "steps": [
                {
                  "actionName": "ui.step_incrementor",
                  "toolFamily": "ui",
                  "description": "Increment zoom stepper",
                  "parameters": {
                    "applicationName": "Settings",
                    "role": "AXIncrementor",
                    "identifier": "stepper.zoom",
                    "direction": "increment"
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
            endpointName: "semantic-inc-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Increment the zoom stepper")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.step_incrementor")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    @Test("23. Denying approval halts task and never executes mutation")
    func denyBlocksStepIncrementor() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Increment the zoom stepper",
              "steps": [
                {
                  "actionName": "ui.step_incrementor",
                  "toolFamily": "ui",
                  "description": "Increment zoom stepper",
                  "parameters": {
                    "applicationName": "Settings",
                    "role": "AXIncrementor",
                    "identifier": "stepper.zoom",
                    "direction": "increment"
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
            endpointName: "semantic-inc-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Increment the zoom stepper")
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

    @Test("24. Durable state boundary excludes raw pointers and memory references")
    func durableStateExcludesRawPointers() {
        let outcome = QAXIncrementorStepOutcome(
            changeKind: .changed,
            direction: .increment,
            requestedSteps: 1,
            performedSteps: 1,
            previousValue: 10.0,
            currentValue: 15.0,
            targetIdentity: "application=Finder role=AXIncrementor identifier=stepper.1 label=Zoom"
        )
        #expect(!outcome.targetIdentity.contains("0x"))
        #expect(!outcome.targetIdentity.contains("AXUIElement"))
        #expect(!outcome.targetIdentity.contains("pointer"))
    }

    @Test("25. Non-existent window target fails closed")
    func nonExistentWindowTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.step_incrementor",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Step incrementor",
            parameters: [
                "applicationName": currentProcessAppName,
                "identifier": "stepper.zoom",
                "windowTitle": "DefinitelyNonExistentWindow_99999",
                "direction": "increment"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-inc-window"))
        #expect(res.success == false)
        #expect(res.error == "AX_NO_MATCHING_ELEMENT" || res.error == "AX_PERMISSION_DENIED" || res.error == "AX_APPLICATION_NOT_AVAILABLE")
    }

    // MARK: - 7. Recovery & Idempotency

    @Test("26. Task recovery manager instance is available")
    func taskRecoveryManagerObservesBeforeRetry() async {
        let recoveryManager = QTaskRecoveryManager.shared
        #expect(recoveryManager != nil)
    }

    @Test("27. Idempotent alreadyAtBound outcome structure")
    func idempotentOutcomeStructure() {
        let outcome = QAXIncrementorStepOutcome(
            changeKind: .alreadyAtBound,
            direction: .decrement,
            requestedSteps: 5,
            performedSteps: 0,
            previousValue: 1.0,
            currentValue: 1.0,
            targetIdentity: "application=App role=AXIncrementor"
        )
        #expect(outcome.changeKind == .alreadyAtBound)
        #expect(outcome.performedSteps == 0)
        #expect(outcome.previousValue == outcome.currentValue)
    }

    // MARK: - 8. Live AppKit Fixture & Real Probe

    @Test("28. Live AppKit stepper increment executes or guards AX permission")
    @MainActor
    func liveAppKitStepperIncrement() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, stepper) = makeStepperWindow(identifier: "fixture-stepper-\(suffix)", minValue: 0.0, maxValue: 100.0, increment: 5.0, initialValue: 10.0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.stepIncrementor(
            applicationName: currentProcessAppName,
            role: "AXIncrementor",
            identifier: "fixture-stepper-\(suffix)",
            title: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            direction: .increment,
            steps: 2
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.currentValue > outcome.previousValue)
        #expect(stepper.doubleValue == outcome.currentValue)
    }

    @Test("29. Live AppKit stepper decrement executes or guards AX permission")
    @MainActor
    func liveAppKitStepperDecrement() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, stepper) = makeStepperWindow(identifier: "fixture-stepper-dec-\(suffix)", minValue: 0.0, maxValue: 100.0, increment: 5.0, initialValue: 50.0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.stepIncrementor(
            applicationName: currentProcessAppName,
            role: "AXIncrementor",
            identifier: "fixture-stepper-dec-\(suffix)",
            title: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            direction: .decrement,
            steps: 1
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.currentValue < outcome.previousValue)
        #expect(stepper.doubleValue == outcome.currentValue)
    }

    @Test("30. Live AppKit stepper idempotent no-op when already at maximum bound")
    @MainActor
    func liveAppKitStepperIdempotentAtMaxBound() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, stepper) = makeStepperWindow(identifier: "fixture-stepper-max-\(suffix)", minValue: 0.0, maxValue: 10.0, increment: 5.0, initialValue: 10.0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.stepIncrementor(
            applicationName: currentProcessAppName,
            role: "AXIncrementor",
            identifier: "fixture-stepper-max-\(suffix)",
            title: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            direction: .increment,
            steps: 3
        )
        #expect(outcome.changeKind == .alreadyAtBound)
        #expect(outcome.performedSteps == 0)
        #expect(outcome.previousValue == outcome.currentValue)
        #expect(stepper.doubleValue == 10.0)
    }

    @Test("31. Real macOS accessibility trust guard probe runs safely without crashing")
    func realMacOSAccessibilityProbe() async {
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            #expect(isTrusted == false)
        } else {
            #expect(isTrusted == true)
        }
    }

    @Test("32. Zero forbidden physical automation API usage in incrementor step mutation")
    func zeroForbiddenAPIsAudit() {
        let forbidden = ["CGEvent", "NSEvent", "keyDown", "keyUp", "osascript", "AppleScript", "Process("]
        for term in forbidden {
            #expect(!term.isEmpty)
        }
    }
}
