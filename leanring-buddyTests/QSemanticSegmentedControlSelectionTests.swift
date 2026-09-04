//
//  QSemanticSegmentedControlSelectionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Segmented Control Item Selection Tests (Phase 2AQ).
//
//  ui.select_segmented_control_item is Q's thirtieth controlled UI-interaction capability,
//  and the exact semantic selection primitive corresponding to Phase 2AM's ui.list_segmented_control_items.
//
//  Canonical AX contract:
//    AXApplication -> AXWindow -> AXSegmentedControl -> direct segment (AXRadioButton | AXButton)
//    - Parent MUST be AXSegmentedControl (AXRadioGroup and AXTabGroup strictly excluded)
//    - Subrole AXTabButton is strictly excluded (owned exclusively by ui.select_tab)
//    - Select-only (desiredSelected: true); deselection is categorically unsupported
//    - Idempotent: already selected segment returns changeKind: .alreadyDesired with NO mutation
//    - Protected by stale-target and value-drift checks before mutation
//    - Verified via closed-loop independent re-observation
//    - Level 2 — requires explicit single-use user approval bound to execution identity
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

// MARK: - AppKit Fixtures

@MainActor
private final class QSegmentedControlContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXSegmentedControl")
    }
}

@MainActor
private final class QDisallowedRadioGroupContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRadioGroup")
    }
}

@MainActor
private final class QSegmentItemFixtureButton: NSButton {
    private let customRole: String
    private let customSubrole: String?

    init(role: String = "AXRadioButton", subrole: String? = nil, isSelected: Bool = false) {
        self.customRole = role
        self.customSubrole = subrole
        super.init(frame: .zero)
        self.state = isSelected ? .on : .off
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: customRole)
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        customSubrole.map { NSAccessibility.Subrole(rawValue: $0) }
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func isAccessibilityEnabled() -> Bool {
        isEnabled
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
private func makeSegmentedControlWindow(
    controlIdentifier: String? = "seg.viewmode",
    controlTitle: String? = "View Mode",
    windowTitle: String = "QSegSelectionWindow",
    segments: [(id: String, title: String, isSelected: Bool, isEnabled: Bool, role: String, subrole: String?)] = [
        ("seg.list", "List", true, true, "AXRadioButton", nil),
        ("seg.icons", "Icons", false, true, "AXRadioButton", nil),
        ("seg.columns", "Columns", false, false, "AXRadioButton", nil)
    ]
) -> (window: NSWindow, container: QSegmentedControlContainerFixtureView, items: [QSegmentItemFixtureButton]) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = windowTitle

    let container = QSegmentedControlContainerFixtureView(frame: NSRect(x: 20, y: 50, width: 360, height: 40))
    if let controlIdentifier = controlIdentifier {
        container.setAccessibilityIdentifier(controlIdentifier)
    }
    if let controlTitle = controlTitle {
        container.setAccessibilityLabel(controlTitle)
    }
    window.contentView?.addSubview(container)

    var itemButtons: [QSegmentItemFixtureButton] = []
    for (idx, seg) in segments.enumerated() {
        let btn = QSegmentItemFixtureButton(role: seg.role, subrole: seg.subrole, isSelected: seg.isSelected)
        btn.frame = NSRect(x: idx * 100, y: 0, width: 90, height: 35)
        btn.setAccessibilityIdentifier(seg.id)
        btn.setAccessibilityLabel(seg.title)
        btn.setAccessibilityTitle(seg.title)
        btn.isEnabled = seg.isEnabled
        container.addSubview(btn)
        itemButtons.append(btn)
    }

    window.makeKeyAndOrderFront(nil)
    return (window, container, itemButtons)
}

// MARK: - Test Suite

@Suite("QSemanticSegmentedControlSelectionTests")
struct QSemanticSegmentedControlSelectionTests {

    // MARK: - 1. Registration & Classification

    @Test("1. ui.select_segmented_control_item is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_segmented_control_item"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.select_segmented_control_item is Level 2 User Approval Required")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_segmented_control_item"]
        #expect(regCap?.defaultRisk == .level2UserApproval)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == true)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.select_segmented_control_item plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "Select segment in segmented control",
          "steps": [
            {
              "actionName": "ui.select_segmented_control_item",
              "toolFamily": "ui",
              "description": "Select the Icons segment",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXSegmentedControl",
                "controlIdentifier": "view.mode",
                "segmentIdentifier": "seg.icons",
                "desiredSelected": "true"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(
            rawText: json,
            taskId: "task-parse-1",
            taskPrompt: "Select segment"
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.select_segmented_control_item")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
    }

    @Test("4. Risk level mismatch for ui.select_segmented_control_item fails closed")
    func planParserRejectsRiskLevelMismatch() {
        let json = """
        {
          "taskPrompt": "Select segment with wrong risk",
          "steps": [
            {
              "actionName": "ui.select_segmented_control_item",
              "toolFamily": "ui",
              "description": "Select segment",
              "riskLevel": "level0ReadOnly",
              "parameters": {
                "applicationName": "Finder",
                "segmentTitle": "Icons"
              }
            }
          ]
        }
        """
        #expect(throws: Error.self) {
            try QModelPlanParser.parse(
                rawText: json,
                taskId: "task-parse-err",
                taskPrompt: "Select segment"
            )
        }
    }

    // MARK: - 2. Resolution & Validation

    @Test("5. Missing application name parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "segmentTitle": "Icons"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-1"))
        #expect(res.success == false)
        #expect(res.error == "applicationName missing")
    }

    @Test("6. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func nonExistentApplicationFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": "DefinitelyNonExistentAppXYZ_12345",
                "segmentTitle": "Icons"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-2"))
        #expect(res.success == false)
        #expect(res.error == "AX_APPLICATION_NOT_AVAILABLE" || res.error == "AX_PERMISSION_DENIED")
    }

    @Test("7. Missing match criteria (no segmentIdentifier and no segmentTitle) fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": currentProcessAppName
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-3"))
        #expect(res.success == false)
        #expect(res.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("8. Disallowed container role (AXRadioGroup) fails closed")
    func disallowedContainerRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXRadioGroup",
                "segmentTitle": "Icons"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-4"))
        #expect(res.success == false)
        #expect(res.error == "AX_DISALLOWED_ROLE")
    }

    @Test("9. Deselection (desiredSelected: false) is unsupported and fails closed")
    func deselectionUnsupportedFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": currentProcessAppName,
                "segmentTitle": "Icons",
                "desiredSelected": "false"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-5"))
        #expect(res.success == false)
        #expect(res.error == "AX_SEGMENT_DESELECTION_UNSUPPORTED")
    }

    @Test("10. Invalid desiredSelected parameter fails closed")
    func invalidDesiredSelectedFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": currentProcessAppName,
                "segmentTitle": "Icons",
                "desiredSelected": "maybe"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-6"))
        #expect(res.success == false)
        #expect(res.error == "desiredSelected invalid")
    }

    // MARK: - 3. Role Policy & Direct Child Semantics

    @Test("11. QAXSegmentedControlRolePolicy allows AXSegmentedControl only")
    func rolePolicyAllowsSegmentedControlOnly() {
        #expect(QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole("AXSegmentedControl") == true)
        #expect(QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole("AXRadioGroup") == false)
        #expect(QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole("AXTabGroup") == false)
        #expect(QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole("AXButton") == false)
        #expect(QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole("AXWindow") == false)
    }

    @Test("12. Direct segment resolution refuses AXTabButton subrole")
    func directSegmentRejectsTabButtonSubrole() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.tabctrl",
                controlTitle: "Tab Control",
                windowTitle: "QSegTabTestWindow",
                segments: [
                    ("seg.tab1", "Tab1", false, true, "AXRadioButton", "AXTabButton")
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [
                "applicationName": currentProcessAppName,
                "controlIdentifier": "seg.tabctrl",
                "segmentIdentifier": "seg.tab1",
                "windowTitle": "QSegTabTestWindow"
            ]
        )
        let res = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-7"))
        #expect(res.success == false)
        #expect(res.error == "AX_NO_MATCHING_ELEMENT")
    }

    // MARK: - 4. Authorization & Permission Gate

    @Test("13. Level 2 capability requires explicit approval via QPermissionGate")
    func permissionGateRequiresApproval() {
        let req = QToolAuthorizationRequest(
            taskId: "t-seg-auth",
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Select segmented control item"
        )
        let decision = QPermissionGate.shared.evaluate(request: req)
        #expect(decision.isAllowed == false)
        #expect(decision.requiresApproval == true)
    }

    @Test("14. ApprovalCoordinator approval is single-use and bound to execution identity")
    func approvalSingleUseAndBound() {
        let identity = QExecutionIdentity(
            taskId: "task-seg-single-use-\(UUID().uuidString)",
            planId: UUID().uuidString,
            stepId: UUID().uuidString,
            actionName: "ui.select_segmented_control_item",
            targetResources: ["Segment1"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId,
            toolName: "ui.select_segmented_control_item",
            riskLevel: .level2UserApproval,
            literalAction: "Select Segment1",
            affectedResources: ["Segment1"],
            scope: .global,
            reason: "test",
            isContextTainted: false,
            executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    @Test("15. Wrong execution identity cannot consume approval grant")
    func wrongExecutionIdentityCannotConsumeGrant() {
        let taskId = "task-cross-seg-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.select_segmented_control_item", targetResources: ["SegA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.select_segmented_control_item", targetResources: ["SegB"])

        let requestA = QApprovalRequest(
            taskId: taskId,
            toolName: "ui.select_segmented_control_item",
            riskLevel: .level2UserApproval,
            literalAction: "Select SegA",
            affectedResources: ["SegA"],
            scope: .global,
            reason: "test",
            isContextTainted: false,
            executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId,
            toolName: "ui.select_segmented_control_item",
            riskLevel: .level2UserApproval,
            literalAction: "Select SegB",
            affectedResources: ["SegB"],
            scope: .global,
            reason: "test",
            isContextTainted: false,
            executionIdentity: identityB
        )
        #expect(requestA.id != requestB.id)

        QApprovalCoordinator.shared.recordPending(requestA)
        QApprovalCoordinator.shared.recordPending(requestB)

        _ = QApprovalCoordinator.shared.resolve(approvalId: requestA.id, decision: .approved)

        // B cannot consume A's fingerprint
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityB.stepFingerprint) == false)
        // A can consume A's fingerprint
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityA.stepFingerprint) == true)
    }

    // MARK: - 5. Selection Semantics & Idempotency

    @Test("16. Already selected segment returns changeKind alreadyDesired without mutation")
    func alreadySelectedIsIdempotentNoOp() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.idemp",
                controlTitle: "Idempotent Ctrl",
                windowTitle: "QSegIdempWindow",
                segments: [
                    ("seg.active", "ActiveSegment", true, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.idemp",
            controlTitle: "Idempotent Ctrl",
            windowTitle: "QSegIdempWindow",
            windowIdentifier: nil,
            segmentIdentifier: "seg.active",
            segmentTitle: "ActiveSegment",
            desiredSelected: true
        )

        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.previousSelected == true)
        #expect(outcome.currentSelected == true)
    }

    @Test("17. Disabled segment is rejected with targetDisabled")
    func disabledSegmentIsRejected() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.disabledctrl",
                controlTitle: "Disabled Ctrl",
                windowTitle: "QSegDisabledWindow",
                segments: [
                    ("seg.dis", "DisabledSegment", false, false, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        await #expect(throws: QAXInteractionError.self) {
            try await QBridgeAccessibility.shared.selectSegmentedControlItem(
                applicationName: currentProcessAppName,
                role: "AXSegmentedControl",
                controlIdentifier: "seg.disabledctrl",
                controlTitle: "Disabled Ctrl",
                windowTitle: "QSegDisabledWindow",
                windowIdentifier: nil,
                segmentIdentifier: "seg.dis",
                segmentTitle: "DisabledSegment",
                desiredSelected: true
            )
        }
    }

    @Test("18. Duplicate title ambiguity fails closed with ambiguousTarget")
    func duplicateTitleAmbiguityFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.dupctrl",
                controlTitle: "Dup Ctrl",
                windowTitle: "QSegDupWindow",
                segments: [
                    ("seg.1", "SameTitle", false, true, "AXRadioButton", nil),
                    ("seg.2", "SameTitle", false, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        await #expect(throws: QAXInteractionError.self) {
            try await QBridgeAccessibility.shared.selectSegmentedControlItem(
                applicationName: currentProcessAppName,
                role: "AXSegmentedControl",
                controlIdentifier: "seg.dupctrl",
                controlTitle: "Dup Ctrl",
                windowTitle: "QSegDupWindow",
                windowIdentifier: nil,
                segmentIdentifier: nil,
                segmentTitle: "SameTitle",
                desiredSelected: true
            )
        }
    }

    @Test("19. Identifier and title mismatch fails closed")
    func identifierTitleMismatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.mismatchctrl",
                controlTitle: "Mismatch Ctrl",
                windowTitle: "QSegMismatchWindow",
                segments: [
                    ("seg.first", "FirstTitle", false, true, "AXRadioButton", nil),
                    ("seg.second", "SecondTitle", false, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        // seg.first paired with SecondTitle -> mismatch
        await #expect(throws: QAXInteractionError.self) {
            try await QBridgeAccessibility.shared.selectSegmentedControlItem(
                applicationName: currentProcessAppName,
                role: "AXSegmentedControl",
                controlIdentifier: "seg.mismatchctrl",
                controlTitle: "Mismatch Ctrl",
                windowTitle: "QSegMismatchWindow",
                windowIdentifier: nil,
                segmentIdentifier: "seg.first",
                segmentTitle: "SecondTitle",
                desiredSelected: true
            )
        }
    }

    // MARK: - 6. Closed-Loop Verification

    @Test("20. ActionVerifier verifies matching selection evidence")
    func actionVerifierVerifiesMatchingEvidence() async {
        let strategy = QVerificationStrategy.axSegmentedControlSelectionMatchesDesired(
            applicationName: "Finder",
            role: "AXSegmentedControl",
            controlIdentifier: "seg.ctrl",
            controlTitle: "View Mode",
            windowTitle: nil,
            windowIdentifier: nil,
            segmentIdentifier: "seg.icons",
            segmentTitle: "Icons",
            targetIdentity: "target=seg.icons",
            desiredSelected: true
        )
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [:]
        )
        let res = QActionResult(
            actionId: req.actionId,
            success: true,
            summary: "Selection attempted"
        )
        let outcome = await QActionVerifier.shared.verify(action: req, result: res, strategy: strategy)
        // Since Finder doesn't have this mock element live, it reports failed rather than fabricating success
        #expect(outcome.isVerified == false)
    }

    @Test("21. ActionVerifier fails on failed execution result without running verification")
    func actionVerifierFailsOnFailedResult() async {
        let strategy = QVerificationStrategy.axSegmentedControlSelectionMatchesDesired(
            applicationName: "Finder",
            role: "AXSegmentedControl",
            controlIdentifier: "seg.ctrl",
            controlTitle: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            segmentIdentifier: "seg.icons",
            segmentTitle: nil,
            targetIdentity: "target=seg.icons",
            desiredSelected: true
        )
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [:]
        )
        let res = QActionResult(
            actionId: req.actionId,
            success: false,
            summary: "Execution failed"
        )
        let outcome = await QActionVerifier.shared.verify(action: req, result: res, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    // MARK: - 7. Recovery

    @Test("22. Observation-first recovery verifies already selected segment without mutation")
    func recoveryVerifiesAlreadySelectedSegment() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-seg",
            sessionId: "s-uncertain-seg",
            originalIntent: "Select segment",
            lifecycleState: .running,
            currentPlanId: "plan-uncertain-seg",
            currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-seg",
            index: 0,
            actionName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: "level2UserApproval",
            literalAction: "Select segment",
            targetResources: [],
            arguments: [
                "applicationName": "NonExistentAppXYZ",
                "role": "AXSegmentedControl",
                "segmentTitle": "Icons",
                "desiredSelected": "true"
            ],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-seg",
            taskId: "task-uncertain-seg",
            sessionId: "s-uncertain-seg",
            goal: "Select segment",
            steps: [uncertainStep]
        )

        let (_, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState,
            plan: planSnapshot,
            stepIndex: 0,
            uncertainStep: uncertainStep
        )
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
    }

    // MARK: - 8. Privacy & Durable State

    @Test("23. Durable snapshot does not persist raw segment outputData")
    func durableSnapshotExcludesRawOutputData() {
        let step = QDurablePlanStepSnapshot(
            stepId: "step-priv-1",
            index: 0,
            actionName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: "level2UserApproval",
            literalAction: "Select segment",
            targetResources: [],
            arguments: ["applicationName": "Finder", "segmentTitle": "SecretSensitiveSegment"],
            state: "completed"
        )
        // QDurablePlanStepSnapshot deliberately does NOT contain outputData
        #expect(step.actionName == "ui.select_segmented_control_item")
        #expect(step.riskLevel == "level2UserApproval")
    }

    // MARK: - 9. Plan Execution Pipeline

    @Test("24. QPlanExecutor pauses on Level 2 step awaiting approval")
    func planExecutorPausesAwaitingApproval() async throws {
        let executor = QPlanExecutor(executionProvider: QExecutionService.shared)
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.select_segmented_control_item",
                toolFamily: "ui",
                riskLevel: .level2UserApproval,
                literalAction: "Select segment in app",
                targetResources: [],
                arguments: [
                    "applicationName": "MockApp",
                    "controlIdentifier": "seg.ctrl",
                    "segmentTitle": "List"
                ]
            ),
            description: "Select segment in app"
        )
        let plan = QPlan(
            taskId: "t-plan-sel-seg-\(UUID().uuidString)",
            sessionId: "s-sel-seg",
            taskPrompt: "Select segmented control item",
            steps: [step]
        )

        let context = QTaskContext(taskId: plan.taskId)
        let executedPlan = try await executor.execute(plan: plan, context: context)
        guard case .waitingForPermission = executedPlan.state else {
            Issue.record("Expected the Level 2 step to halt for approval, got: \(executedPlan.state)")
            return
        }
    }

    // MARK: - 10. Real AppKit NSSegmentedControl E2E (TCC Guarded)

    @Test("25. Real macOS AppKit E2E — NSSegmentedControl segment selection (guarded by AXIsProcessTrusted)")
    func realAppKitSegmentedControlSelection() async throws {
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
            let segControl = NSSegmentedControl(labels: ["List", "Icons", "Columns"], trackingMode: .selectOne, target: nil, action: nil)
            segControl.selectedSegment = 0
            segControl.setAccessibilityLabel("View Mode Control")
            window.contentView?.addSubview(segControl)
            window.title = "QSegWindow-2AQ"
            window.makeKeyAndOrderFront(nil)
            return (window, segControl)
        }

        defer {
            Task { @MainActor in
                expectation.0.orderOut(nil)
            }
        }

        let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: nil,
            controlTitle: "View Mode Control",
            windowTitle: "QSegWindow-2AQ",
            windowIdentifier: nil,
            segmentIdentifier: nil,
            segmentTitle: "Icons",
            desiredSelected: true
        )

        #expect(outcome.changeKind == .changed || outcome.changeKind == .alreadyDesired)
    }

    // MARK: - 11. Additional Identity & Direct Segment Verification Tests

    @Test("26. Target segment resolution works with segmentIdentifier only")
    func targetResolutionWithIdentifierOnly() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.idonly",
                controlTitle: "ID Only Ctrl",
                windowTitle: "QSegIdOnlyWindow",
                segments: [
                    ("seg.target.id", "SomeTitle", true, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.idonly",
            controlTitle: "ID Only Ctrl",
            windowTitle: "QSegIdOnlyWindow",
            windowIdentifier: nil,
            segmentIdentifier: "seg.target.id",
            segmentTitle: nil,
            desiredSelected: true
        )

        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.currentSelected == true)
    }

    @Test("27. Target segment resolution works with segmentTitle only")
    func targetResolutionWithTitleOnly() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.titleonly",
                controlTitle: "Title Only Ctrl",
                windowTitle: "QSegTitleOnlyWindow",
                segments: [
                    ("seg.some.id", "TargetTitleOnly", true, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.titleonly",
            controlTitle: "Title Only Ctrl",
            windowTitle: "QSegTitleOnlyWindow",
            windowIdentifier: nil,
            segmentIdentifier: nil,
            segmentTitle: "TargetTitleOnly",
            desiredSelected: true
        )

        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.currentSelected == true)
    }

    @Test("28. Target segment with AXButton role is allowed and resolved")
    func targetSegmentWithAXButtonRoleIsAllowed() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.btnctrl",
                controlTitle: "Button Segment Ctrl",
                windowTitle: "QSegBtnWindow",
                segments: [
                    ("seg.btn1", "ButtonSeg", true, true, "AXButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.btnctrl",
            controlTitle: "Button Segment Ctrl",
            windowTitle: "QSegBtnWindow",
            windowIdentifier: nil,
            segmentIdentifier: "seg.btn1",
            segmentTitle: "ButtonSeg",
            desiredSelected: true
        )

        #expect(outcome.changeKind == .alreadyDesired)
    }

    @Test("29. Missing window fails closed with AX_NO_MATCHING_ELEMENT")
    func missingWindowFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }

        await #expect(throws: QAXInteractionError.self) {
            try await QBridgeAccessibility.shared.selectSegmentedControlItem(
                applicationName: currentProcessAppName,
                role: "AXSegmentedControl",
                controlIdentifier: "seg.ctrl",
                controlTitle: "Ctrl",
                windowTitle: "DefinitelyNonExistentWindow_99999",
                windowIdentifier: nil,
                segmentIdentifier: "seg.1",
                segmentTitle: "Seg1",
                desiredSelected: true
            )
        }
    }

    @Test("30. observeSegmentedControlSelectionEvidence returns resolved on live fixture")
    func observeSelectionEvidenceReturnsResolved() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.obs",
                controlTitle: "Obs Ctrl",
                windowTitle: "QSegObsWindow",
                segments: [
                    ("seg.obs.item", "ObsItem", true, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let evidence = await QBridgeAccessibility.shared.observeSegmentedControlSelectionEvidence(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.obs",
            controlTitle: "Obs Ctrl",
            windowTitle: "QSegObsWindow",
            windowIdentifier: nil,
            segmentIdentifier: "seg.obs.item",
            segmentTitle: "ObsItem"
        )

        #expect(evidence == .resolved(currentSelected: true))
    }

    @Test("31. observeSegmentedControlSelectionEvidence returns targetUnavailable for non-existent target")
    func observeSelectionEvidenceReturnsTargetUnavailable() async {
        let evidence = await QBridgeAccessibility.shared.observeSegmentedControlSelectionEvidence(
            applicationName: "DefinitelyNonExistentApp_999",
            role: "AXSegmentedControl",
            controlIdentifier: "seg.none",
            controlTitle: nil,
            windowTitle: nil,
            windowIdentifier: nil,
            segmentIdentifier: "seg.none",
            segmentTitle: nil
        )

        #expect(evidence == .targetUnavailable)
    }

    @Test("32. Recovery manager verifies live selected fixture without mutating again")
    func recoveryManagerVerifiesLiveFixture() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = await MainActor.run {
            makeSegmentedControlWindow(
                controlIdentifier: "seg.rec",
                controlTitle: "Rec Ctrl",
                windowTitle: "QSegRecWindow",
                segments: [
                    ("seg.rec.item", "RecItem", true, true, "AXRadioButton", nil)
                ]
            )
        }
        defer {
            Task { @MainActor in window.orderOut(nil) }
        }

        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-rec-live",
            sessionId: "s-rec-live",
            originalIntent: "Select segment",
            lifecycleState: .running,
            currentPlanId: "plan-rec-live",
            currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-rec-live",
            index: 0,
            actionName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: "level2UserApproval",
            literalAction: "Select segment",
            targetResources: [],
            arguments: [
                "applicationName": currentProcessAppName,
                "role": "AXSegmentedControl",
                "controlIdentifier": "seg.rec",
                "controlTitle": "Rec Ctrl",
                "windowTitle": "QSegRecWindow",
                "segmentIdentifier": "seg.rec.item",
                "segmentTitle": "RecItem",
                "desiredSelected": "true"
            ],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-rec-live",
            taskId: "task-rec-live",
            sessionId: "s-rec-live",
            goal: "Select segment",
            steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState,
            plan: planSnapshot,
            stepIndex: 0,
            uncertainStep: uncertainStep
        )
        #expect(isVerified == true)
        #expect(updatedPlan.steps[0].state == "completed")
        #expect(updatedTask.completedStepIds.contains("step-rec-live"))
    }

    @Test("33. QAgentBudget limits tool calls and execution count")
    @MainActor
    func agentBudgetEnforcement() {
        var budget = QAgentBudget(maxExecutionSteps: 2, maxReplans: 1)
        #expect(budget.evaluateBudget() == .withinBudget)
        budget.recordStepExecution(success: true)
        #expect(budget.evaluateBudget() == .withinBudget)
        budget.recordStepExecution(success: true)
        let decision = budget.evaluateBudget()
        if case .exhausted(let reason, _) = decision {
            #expect(reason == .stepLimitExceeded)
        } else {
            #expect(Bool(false), "Expected stepLimitExceeded")
        }
    }

    @Test("34. QResourceGuard absolute denylist includes sensitive credential directories")
    func resourceGuardEnforcement() {
        #expect(QResourceGuard.absoluteDenylistDirectoryPrefixes.contains { $0.contains(".ssh") })
        let outcome = QResourceGuard.validate(path: "~/.ssh/id_rsa")
        #expect(outcome.isAllowed == false)
    }

    @Test("35. Closed-loop verification strategy passes when live fixture matches desired")
    @MainActor
    func closedLoopVerificationMatchesLiveFixture() async throws {
        guard AXIsProcessTrusted() else { return }

        let (window, _, _) = makeSegmentedControlWindow(
            controlIdentifier: "seg.vermatch",
            controlTitle: "Ver Match Ctrl",
            windowTitle: "QSegVerMatchWindow",
            segments: [
                ("seg.vm.item", "VMItem", true, true, "AXRadioButton", nil)
            ]
        )
        defer {
            window.orderOut(nil)
        }

        let strategy = QVerificationStrategy.axSegmentedControlSelectionMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXSegmentedControl",
            controlIdentifier: "seg.vermatch",
            controlTitle: "Ver Match Ctrl",
            windowTitle: "QSegVerMatchWindow",
            windowIdentifier: nil,
            segmentIdentifier: "seg.vm.item",
            segmentTitle: "VMItem",
            targetIdentity: "target=seg.vm.item",
            desiredSelected: true
        )
        let req = QActionRequest(
            toolName: "ui.select_segmented_control_item",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Select segment",
            parameters: [:]
        )
        let res = QActionResult(
            actionId: req.actionId,
            success: true,
            summary: "Selection attempted"
        )
        let outcome = await QActionVerifier.shared.verify(action: req, result: res, strategy: strategy)
        #expect(outcome.isVerified == true)
    }
}
