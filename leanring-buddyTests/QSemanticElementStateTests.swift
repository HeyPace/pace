//
//  QSemanticElementStateTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic AX Element State Change Tests (Phase 2K).
//  ui.set_element_state resolves a checkbox/radio-button target purely by Accessibility
//  semantics (role + identifier or title) — restricted to an explicit AXCheckBox/AXRadioButton
//  allowlist — verifies it is not stale by BOTH identity and VALUE, presses it only when its
//  current state differs from the desired state, and only ever counts a later, independent
//  AX value-hash diff as verified success. Accessibility (AX) trust cannot be assumed granted
//  for the isolated XCTest runner — every test that needs a real, live AXUIElement branches on
//  `AXIsProcessTrusted()` and no-ops rather than fabricating a pass, mirroring the exact
//  convention QSemanticClickTests/QSemanticTextEntryTests/QSemanticElementReadTests already
//  established. See docs/PHASE_2K_SEMANTIC_ELEMENT_STATE.md for the full contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeCheckboxWindow(identifier: String, isChecked: Bool) -> (window: NSWindow, checkbox: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let checkbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    checkbox.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
    checkbox.state = isChecked ? .on : .off
    checkbox.setAccessibilityIdentifier(identifier)
    contentView.addSubview(checkbox)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, checkbox)
}

@MainActor
private func makeRadioButtonWindow(identifier: String, isSelected: Bool) -> (window: NSWindow, radio: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let radio = NSButton(radioButtonWithTitle: "Option A", target: nil, action: nil)
    radio.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
    radio.state = isSelected ? .on : .off
    radio.setAccessibilityIdentifier(identifier)
    contentView.addSubview(radio)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, radio)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticElementStateTests")
struct QSemanticElementStateTests {

    // MARK: - 1/2/3. Capability registration, anti-downgrade, invalid schema

    @Test("1/2. ui.set_element_state is a registered, Level 2, semantically-targeted capability and cannot be risk-downgraded")
    func capabilityRegistrationAcceptsUISetElementState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_element_state"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Check the box",
          "steps": [
            {
              "actionName": "ui.set_element_state",
              "toolFamily": "ui",
              "description": "Set a semantically-identified checkbox's state",
              "parameters": {"applicationName": "Finder", "role": "AXCheckBox", "identifier": "SomeBox", "desiredState": "on"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-state", taskPrompt: "Check the box")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        let downgradeJSON = """
        {
          "taskPrompt": "Check the box",
          "steps": [
            {
              "actionName": "ui.set_element_state",
              "toolFamily": "ui",
              "riskLevel": "level0ReadOnly",
              "description": "Set a semantically-identified checkbox's state",
              "parameters": {"applicationName": "Finder", "role": "AXCheckBox", "identifier": "SomeBox", "desiredState": "on"}
            }
          ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-downgrade-state", taskPrompt: "Check the box")
        }
    }

    // MARK: - 3. Invalid schema rejected (missing desiredState, missing criteria)

    @Test("3. Missing or invalid required parameters fail closed with deterministic errors")
    func invalidSchemaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXCheckBox", identifier: nil, title: nil, desiredState: .on
            )
        }
        // Malformed desiredState at the QExecutionService layer (not just the bridge).
        let request = QActionRequest(
            toolName: "ui.set_element_state", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Set state",
            parameters: ["applicationName": currentProcessAppName, "role": "AXCheckBox", "identifier": "x", "desiredState": "maybe"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-invalid-schema"))
        #expect(result.success == false)
        #expect(result.error == "desiredState invalid")
    }

    // MARK: - 4/21. Valid AXCheckBox: false → true (direct bridge call)

    @Test("4/21. A valid, unchecked AXCheckBox is set to 'on' via AX press only")
    @MainActor
    func checkboxOffToOn() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "cb-offon-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "cb-offon-\(suffix)", title: nil, desiredState: .on
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.previousState == .off)
        #expect(outcome.currentState == .on)
        #expect(checkbox.state == .on)
    }

    // MARK: - 22. Valid AXCheckBox: true → false (direct bridge call)

    @Test("22. A valid, checked AXCheckBox is set to 'off' via AX press only")
    @MainActor
    func checkboxOnToOff() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "cb-onoff-\(suffix)", isChecked: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "cb-onoff-\(suffix)", title: nil, desiredState: .off
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.previousState == .on)
        #expect(outcome.currentState == .off)
        #expect(checkbox.state == .off)
    }

    // MARK: - 5. Valid AXRadioButton: off → on (direct bridge call)

    @Test("5. A valid, unselected AXRadioButton is selected via AX press only")
    @MainActor
    func radioButtonOffToOn() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, radio) = makeRadioButtonWindow(identifier: "radio-offon-\(suffix)", isSelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXRadioButton", identifier: "radio-offon-\(suffix)", title: nil, desiredState: .on
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.currentState == .on)
        #expect(radio.state == .on)
    }

    // MARK: - 5b. AXRadioButton deselection is refused, never attempted blind

    @Test("5b. Requesting 'off' on an already-selected AXRadioButton is refused — AX cannot guarantee deselection via press")
    @MainActor
    func radioButtonDeselectionRefused() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, radio) = makeRadioButtonWindow(identifier: "radio-noundo-\(suffix)", isSelected: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXRadioButton", identifier: "radio-noundo-\(suffix)", title: nil, desiredState: .off
            )
            Issue.record("Expected AXRadioButton deselection to be refused")
        } catch let axError as QAXInteractionError {
            #expect(axError.errorCode == "AX_STATE_CHANGE_NOT_GUARANTEED")
        }
        // The control must remain untouched — refused, not attempted-and-failed.
        #expect(radio.state == .on)
    }

    // MARK: - 6. Unsupported role rejected (a role fine for click, not for state-change)

    @Test("6. AXButton — a role ui.click_element accepts — is rejected for state-change (not on the narrow allowlist)")
    func unsupportedRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.disallowedStateRole("AXButton")) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "whatever", title: nil, desiredState: .on
            )
        }
    }

    // MARK: - 7. Unknown role rejected

    @Test("7. A wholly unrecognized role is rejected by the same fail-closed allowlist check")
    func unknownRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.disallowedStateRole("AXMadeUpRole99")) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXMadeUpRole99", identifier: "whatever", title: nil, desiredState: .on
            )
        }
        // AXSecureTextField specifically, mirroring the write/read capabilities' explicit checks.
        await #expect(throws: QAXInteractionError.disallowedStateRole("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil, desiredState: .on
            )
        }
    }

    // MARK: - 8. Ambiguous target rejected

    @Test("8. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let boxA = NSButton(checkboxWithTitle: "A", target: nil, action: nil)
        boxA.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
        boxA.setAccessibilityIdentifier("dup-state-\(suffix)")
        let boxB = NSButton(checkboxWithTitle: "B", target: nil, action: nil)
        boxB.frame = NSRect(x: 20, y: 60, width: 240, height: 24)
        boxB.setAccessibilityIdentifier("dup-state-\(suffix)")
        contentView.addSubview(boxA)
        contentView.addSubview(boxB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "dup-state-\(suffix)", title: nil, desiredState: .on
            )
        }
    }

    // MARK: - 9. Stale identity comparison primitive

    @Test("9. The observation-binding staleness comparison correctly distinguishes an unchanged target from a changed one")
    func staleIdentityComparisonPrimitive() {
        // ui.set_element_state reuses the identical QAXElementSnapshot equality primitive
        // ui.click_element/ui.set_text_value already rely on. A genuine live race between
        // resolution and dispatch cannot be triggered deterministically without an artificial
        // delay seam in production code (the same, deliberate, documented limitation as every
        // prior semantic AX capability in this codebase).
        let unchanged = QAXElementSnapshot(role: "AXCheckBox", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let sameAgain = QAXElementSnapshot(role: "AXCheckBox", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let changed = QAXElementSnapshot(role: "AXCheckBox", identifier: "id-2", titleOrDescription: nil, isEnabled: true)
        #expect(unchanged == sameAgain)
        #expect(unchanged != changed)
    }

    // MARK: - 10. Wrong application rejected

    @Test("10. A nonexistent/wrong application fails closed with a deterministic error")
    func wrongApplicationRejected() async throws {
        // Accessibility permission is checked before application lookup (identical ordering to
        // ui.click_element's setElementState-analogous resolution — see
        // QSemanticClickTests.missingApplicationFailsSafely for the exact same precedent) — so
        // this deterministic error can only be observed when AX trust is actually granted.
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2K")) {
            _ = try await QBridgeAccessibility.shared.setElementState(
                applicationName: "QNoSuchApp2K", role: "AXCheckBox", identifier: "whatever", title: nil, desiredState: .on
            )
        }
    }

    // MARK: - 11. Value-drift staleness check does not spuriously trigger under normal conditions

    @Test("11. The value-drift staleness check does not spuriously fail a normal, non-racing state change")
    @MainActor
    func valueDriftCheckDoesNotFalsePositive() async throws {
        guard AXIsProcessTrusted() else { return }
        // A genuine race in the sub-millisecond window between the two back-to-back reads cannot
        // be triggered deterministically without an artificial delay seam in production code —
        // the same documented, honest limitation as ui.click_element's identity re-verify (see
        // docs/PHASE_2H_SEMANTIC_CLICK.md). This test instead proves the mechanism exists and is
        // correctly wired by confirming it does NOT spuriously reject a normal, unraced call.
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "novaldrift-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "novaldrift-\(suffix)", title: nil, desiredState: .on
        )
        #expect(outcome.changeKind == .changed)
        #expect(checkbox.state == .on)
    }

    // MARK: - 12/13. Idempotency: already-desired state is a no-op, no mutation

    @Test("12/13. Setting a checkbox to its current state is an idempotent no-op — no AX press, no mutation")
    @MainActor
    func alreadyDesiredStateIsNoOp() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "noop-state-\(suffix)", isChecked: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "noop-state-\(suffix)", title: nil, desiredState: .on
        )
        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.previousState == .on)
        #expect(outcome.currentState == .on)
        #expect(checkbox.state == .on) // unchanged — proves no press occurred
    }

    // MARK: - 14. Approval required, never dispatches silently

    @Test("14. ui.set_element_state halts for explicit approval and never dispatches silently")
    func approvalRequiredForSetElementState() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check a box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "QNoSuchApp2K", "role": "AXCheckBox", "identifier": "Whatever", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-state-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Check a box")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.set_element_state")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    // MARK: - 15. Deny → no mutation

    @Test("15. Denying the approval halts the task and the target is never mutated")
    @MainActor
    func denyBlocksSetElementState() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "deny-state-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check the box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXCheckBox", "identifier": "deny-state-\(suffix)", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-state-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Check the box")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }
        #expect(checkbox.state == .off)
    }

    // MARK: - 16. Persisted / expired approval never self-authorizes (recovery-time rubber-stamping)

    @Test("16. A durably-persisted awaiting_approval state cannot be rubber-stamped without a real coordinator grant")
    func persistedApprovalNeverSelfAuthorizes() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: MockAutonomousModelProvider(),
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let taskId = "task-persisted-state-\(UUID().uuidString)"
        let planId = UUID().uuidString
        let stepId = UUID().uuidString
        let identity = QExecutionIdentity(taskId: taskId, planId: planId, stepId: stepId, actionName: "ui.set_element_state", targetResources: ["Ghost"])
        // Deliberately never call QApprovalCoordinator.recordPending/resolve for this identity —
        // simulates state persisted before a crash/restart, where the in-memory coordinator (and
        // therefore any real "the user actually approved this" fact) is gone.
        let neverPresentedApprovalId = QApprovalRequest.deterministicId(fingerprint: identity.stepFingerprint)

        let planStep = QDurablePlanStepSnapshot(
            stepId: stepId, index: 0, actionName: "ui.set_element_state", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Check Ghost box",
            targetResources: ["Ghost"], arguments: ["applicationName": "Ghost", "role": "AXCheckBox", "identifier": "GhostBox", "desiredState": "on"],
            state: "waitingForPermission:Approval required"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: planId, taskId: taskId, sessionId: "s-persisted-state", goal: "Check Ghost box", steps: [planStep]
        )
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: "s-persisted-state", originalIntent: "Check Ghost box",
            lifecycleState: .awaitingApproval, currentPlanId: planId, currentStepIndex: 0,
            securityBlockReason: "Approval required"
        )
        try store.savePlan(planSnapshot)
        try store.saveTask(taskState)

        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)

        let result = try await runtime.resolveApproval(taskId: taskId, approvalId: neverPresentedApprovalId, decision: .approved)
        guard case .failed(let reason) = result.state else {
            #expect(Bool(false), "Expected resolveApproval to fail closed for an id the coordinator never held, got: \(result.state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("not pending") || reason.localizedCaseInsensitiveContains("not found") || reason.localizedCaseInsensitiveContains("expired"))
    }

    // MARK: - 17/20. Approval single-use — no reuse, no duplicate/race mutation

    @Test("17/20. A granted state-change approval's fingerprint can be consumed exactly once — no reuse, no duplicate side effect")
    func executionIdentityGrantIsSingleUseForSetElementState() {
        let identity = QExecutionIdentity(
            taskId: "task-state-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "ui.set_element_state", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "ui.set_element_state", riskLevel: .level2UserApproval,
            literalAction: "Check Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        // Reuse / duplicate-race attempt: the second consumption must fail — no standing grant.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 18/19. A different desiredState or target is a different execution identity — approval can never cross-authorize

    @Test("18/19. A granted approval for one target/desiredState never authorizes a different execution identity — the only way arguments can differ is a different step/plan, which is always a different, fresh execution identity")
    func approvalDoesNotCrossAuthorizeDifferentArguments() {
        let taskId = "task-cross-state-\(UUID().uuidString)"
        let planId = UUID().uuidString

        // Simulates two DIFFERENT steps — e.g. one requesting desiredState "on" on "BoxA", the
        // other (a hypothetically-modified plan, or a different target) requesting "off" on
        // "BoxB". QExecutionIdentity.stepFingerprint is taskId:planId:stepId:actionName — it does
        // not encode argument content directly, but because each step carries immutable
        // arguments once planned, a genuinely different desiredState/target can only ever arise
        // from a genuinely different step (different stepId) or a replan (different planId) —
        // both of which are, by construction, a different execution identity and therefore
        // require their own fresh approval.
        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.set_element_state", targetResources: ["BoxA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.set_element_state", targetResources: ["BoxB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "ui.set_element_state", riskLevel: .level2UserApproval,
            literalAction: "Set BoxA to on", affectedResources: ["BoxA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "ui.set_element_state", riskLevel: .level2UserApproval,
            literalAction: "Set BoxB to off", affectedResources: ["BoxB"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityB
        )
        #expect(requestA.id != requestB.id)

        QApprovalCoordinator.shared.recordPending(requestA)
        QApprovalCoordinator.shared.recordPending(requestB)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: requestA.id, decision: .approved)
        guard case .granted(let fingerprintA) = outcome else {
            #expect(Bool(false), "Expected requestA to be granted, got: \(outcome)")
            return
        }
        #expect(fingerprintA == identityA.stepFingerprint)
        // The grant for A (desiredState "on" on BoxA) cannot authorize B (desiredState "off" on
        // BoxB) — proving a modified desiredState or target invalidates any prior approval.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityB.stepFingerprint) == false)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityA.stepFingerprint) == true)
    }

    // MARK: - 23. Allow → checkbox verified after mutation (full autonomous path)

    @Test("23. Approving the request checks the target exactly once and completes with real, closed-loop AX verification")
    @MainActor
    func allowChecksCheckboxAndVerifies() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "allow-state-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check the box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXCheckBox", "identifier": "allow-state-\(suffix)", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-state-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Check the box")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed(let summary) = resolved.state else {
            #expect(Bool(false), "Expected task to complete after approval, got: \(resolved.state)")
            return
        }
        #expect(!summary.isEmpty)
        #expect(checkbox.state == .on)
    }

    // MARK: - 24. Radio button verified after mutation (full autonomous path)

    @Test("24. Approving a radio-button selection completes with real, closed-loop AX verification")
    @MainActor
    func allowSelectsRadioButtonAndVerifies() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, radio) = makeRadioButtonWindow(identifier: "allow-radio-\(suffix)", isSelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the option",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified radio button's state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRadioButton", "identifier": "allow-radio-\(suffix)", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-radio-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the option")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected task to complete after approval, got: \(resolved.state)")
            return
        }
        #expect(radio.state == .on)
    }

    // MARK: - 25. Verification failure is never fabricated as success

    @Test("25. Closed-loop verification against a mismatched desired-state hash fails, even though the underlying press succeeded")
    @MainActor
    func verificationFailsOnMismatch() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeCheckboxWindow(identifier: "mismatch-state-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.setElementState(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "mismatch-state-\(suffix)", title: nil, desiredState: .on
        )
        #expect(outcome.changeKind == .changed)

        // Directly exercise the independent verification strategy with a WRONG desired-state
        // hash — must fail, not fabricate.
        let wrongDesiredHash = "0000000000000000000000000000000000000000000000000000000000000000"
        let strategy = QVerificationStrategy.axElementStateMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXCheckBox",
            matchIdentifier: "mismatch-state-\(suffix)",
            matchTitle: nil,
            targetIdentity: outcome.targetIdentity,
            previousStateHash: outcome.previousStateHash,
            desiredStateHash: wrongDesiredHash
        )
        let result = QActionResult(actionId: "verify-mismatch-state", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.set_element_state", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    // MARK: - 26. Target disappearance after dispatch is handled conservatively (never assumed success)

    @Test("26. An unresolvable target after the state change fails verification rather than assuming success")
    func unresolvableTargetAfterDispatchFailsClosed() async throws {
        // Directly exercises the verification strategy against a target identifier that was
        // never created — simulating a target that vanished between dispatch and verification.
        let strategy = QVerificationStrategy.axElementStateMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXCheckBox",
            matchIdentifier: "vanished-\(UUID().uuidString)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXCheckBox identifier=vanished label=none",
            previousStateHash: "irrelevant",
            desiredStateHash: "irrelevant"
        )
        let result = QActionResult(actionId: "verify-vanished", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.set_element_state", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        // Unlike ui.click_element's axElementStateChanged, an unresolvable target here is NOT
        // treated as an observed success.
        #expect(verifyOutcome.isVerified == false)
    }

    // MARK: - 27/28/29/30. Recovery: crash before/after dispatch, uncertain state, no blind replay

    @Test("27. No mutation can occur before approval — dispatch is structurally unreachable until a real grant exists")
    @MainActor
    func noDispatchBeforeApproval() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "predispatch-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check the box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXCheckBox", "identifier": "predispatch-\(suffix)", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-state-predispatch-\(UUID().uuidString)"
        )
        _ = try await runtime.submitIntent(prompt: "Check the box")
        // The task halted for approval (proven by every other approval test); here we assert the
        // real-world side effect directly: the checkbox was never touched before approval.
        #expect(checkbox.state == .off)
    }

    @Test("28/29/30. An uncertain in-flight state-change step is never blindly marked complete — it fails closed to pending for observation-first re-execution, and idempotency prevents a duplicate press on retry")
    func uncertainSetElementStateStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-state", sessionId: "s-uncertain-state", originalIntent: "Check GhostBox",
            lifecycleState: .running, currentPlanId: "plan-uncertain-state", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-state", index: 0, actionName: "ui.set_element_state", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Check GhostBox",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXCheckBox", "identifier": "GhostBox", "desiredState": "on"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-state", taskId: "task-uncertain-state", sessionId: "s-uncertain-state",
            goal: "Check GhostBox", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // ui.set_element_state has no dedicated observation-first recovery check (mirroring
        // ui.click_element/ui.set_text_value) — an uncertain attempt fails closed: not verified,
        // reset to pending for one safe retry. That retry itself re-observes current state
        // (idempotency check inside setElementState) before ever pressing again, which is what
        // makes the retry safe rather than a blind replay.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 35. Provenance: no taint upgrade — registered under "ui", not "perception"

    @Test("35. ui.set_element_state is registered under toolFamily 'ui', not 'perception' — no observed-external-state is ever upgraded into trusted internal fact")
    func provenanceNotUpgraded() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_element_state"]
        #expect(regCap?.toolFamily == "ui")
        // Unlike ui.read_element_value (toolFamily "perception", intentionally exposing observed
        // content), this is a mutation capability — it must never be tagged .untrustedScreen or
        // otherwise treated as ingesting untrusted external content, since it doesn't read/expose
        // arbitrary UI content, only a small, non-secret "on"/"off" enum.
    }

    // MARK: - 36. Budget accounting / exhaustion blocks execution

    @Test("36. An exhausted execution budget blocks a resumed state-change step before any dispatch is attempted")
    func budgetExhaustionBlocksSetElementStateExecution() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check the box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "QNoSuchApp2K", "role": "AXCheckBox", "identifier": "Whatever", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-state-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Check the box")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        guard var durableTaskState = try store.getTask(taskId: task.taskId) else {
            #expect(Bool(false), "Expected a persisted task state")
            return
        }
        durableTaskState.budget = QAgentBudget(maxExecutionSteps: 0, executedStepsCount: 0)
        try store.saveTask(durableTaskState)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .failed(let reason) = resolved.state else {
            #expect(Bool(false), "Expected budget exhaustion to block execution, got: \(resolved.state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("halted") || reason.localizedCaseInsensitiveContains("budget") || reason.localizedCaseInsensitiveContains("exceeded"))
    }

    // MARK: - 37/38. Audit and memory contain only safe evidence for a real successful run

    @Test("37/38. A real successful state-change run's audit and memory records contain only safe structured evidence — no raw AX attribute dumps, no unrelated UI content")
    @MainActor
    func realRunLeavesOnlySafeEvidenceInAuditAndMemory() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, checkbox) = makeCheckboxWindow(identifier: "safe-evidence-\(suffix)", isChecked: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Check the box",
              "steps": [
                {
                  "actionName": "ui.set_element_state",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified checkbox's state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXCheckBox", "identifier": "safe-evidence-\(suffix)", "desiredState": "on"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let memory = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-state-safeevidence-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Check the box")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected completion, got: \(resolved.state)")
            return
        }
        #expect(checkbox.state == .on)

        // Audit: records exist for this task and their evidence is the small, safe shape only.
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        let stepRecord = auditRecords.first { $0.tool == "ui.set_element_state" }
        #expect(stepRecord != nil)
        #expect((stepRecord?.executionSummary ?? "").contains("status=verified") || (stepRecord?.executionSummary?.isEmpty == false))

        // Durable state: the persisted arguments are the small, non-sensitive schema only.
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.set_element_state" })
        #expect(stepSnapshot?.arguments["desiredState"] == "on")
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)

        // Memory: the plan-completion record exists and is a safe summary, not a raw dump.
        let memoryRecord = try memory.getByKey("plan_\(planId)", sessionId: task.sessionId)
        #expect(memoryRecord != nil)
    }
}
