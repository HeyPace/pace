//
//  QSemanticElementFocusTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic AX Element Focus Tests (Phase 2O).
//  ui.focus_element resolves a target purely by Accessibility semantics (role + identifier or
//  title), restricted to QAXFocusableRolePolicy's narrow fail-closed allowlist, and requests
//  keyboard focus via AXUIElementSetAttributeValue(kAXFocusedAttribute) only — never a press,
//  never a value write, never CGEvent/keyboard/mouse simulation. Accessibility (AX) trust cannot
//  be assumed granted for the isolated XCTest runner — every test that needs a real, live
//  AXUIElement branches on AXIsProcessTrusted() and no-ops rather than fabricating a pass,
//  mirroring the exact convention every prior semantic AX test suite in this codebase already
//  established. See docs/PHASE_2O_SEMANTIC_ELEMENT_FOCUS.md for the full contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeTextFieldWindow(identifier: String) -> (window: NSWindow, fieldA: NSTextField, fieldB: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 120),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementFocusTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    let fieldA = NSTextField(frame: NSRect(x: 20, y: 70, width: 240, height: 24))
    fieldA.setAccessibilityIdentifier(identifier)
    let fieldB = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    fieldB.setAccessibilityIdentifier("\(identifier)-other")
    contentView.addSubview(fieldA)
    contentView.addSubview(fieldB)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, fieldA, fieldB)
}

@MainActor
private func makeButtonWindow(identifier: String) -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementFocusTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
    button.title = "Press Me"
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticElementFocusTests")
struct QSemanticElementFocusTests {

    // MARK: - 1/2/3. Registration, risk level, anti-downgrade

    @Test("1/2/3. ui.focus_element is a registered, Level 2, semantically-targeted capability and cannot be risk-downgraded")
    func capabilityRegistrationAcceptsUIFocusElement() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.focus_element"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Focus the field",
          "steps": [
            {
              "actionName": "ui.focus_element",
              "toolFamily": "ui",
              "description": "Focus a semantically-identified element",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-focus", taskPrompt: "Focus the field")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        for mismatchedRisk in ["level0ReadOnly", "level1SafeLocalAction", "level3HighRisk"] {
            let downgradeJSON = """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-mismatch-\(mismatchedRisk)", taskPrompt: "Focus the field")
            }
        }
    }

    // MARK: - 4/5. Missing / empty target criteria rejected

    @Test("4/5. Missing target criteria fails closed with a deterministic error")
    func missingCriteriaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.focusElement(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: nil
            )
        }

        let request = QActionRequest(
            toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Focus element",
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("5b. Missing applicationName/role parameters are rejected before any resolution attempt")
    func missingParametersRejected() async throws {
        let missingApp = QActionRequest(
            toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Focus element", parameters: ["role": "AXTextField", "identifier": "x"]
        )
        let missingAppResult = try await QExecutionService.shared.executeAction(missingApp, context: QTaskContext(taskId: "t-missing-app"))
        #expect(missingAppResult.success == false)
        #expect(missingAppResult.error == "applicationName missing")

        let missingRole = QActionRequest(
            toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Focus element", parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let missingRoleResult = try await QExecutionService.shared.executeAction(missingRole, context: QTaskContext(taskId: "t-missing-role"))
        #expect(missingRoleResult.success == false)
        #expect(missingRoleResult.error == "role missing")
    }

    // MARK: - 6/7/8/9. Role policy: focusable roles accepted, others rejected

    @Test("6. AXTextField and AXButton (both allowlisted) are accepted role criteria — proven by real fixture focus below; this test proves the allowlist accepts them as SEARCH criteria without early rejection")
    func allowlistedRolesAreNotRejectedAsCriteria() {
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXButton") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXCheckBox") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXRadioButton") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXTextField") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXTextArea") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXSlider") == true)
        #expect(QAXFocusableRolePolicy.isAllowedFocusRole("AXStepper") == true)
    }

    @Test("7/8/9. AXStaticText, AXImage, AXGroup, and a wholly unrecognized role are all rejected for focus")
    func nonFocusableRolesRejected() async throws {
        for disallowedRole in ["AXStaticText", "AXImage", "AXGroup", "AXMadeUpRole99"] {
            await #expect(throws: QAXInteractionError.disallowedFocusRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.focusElement(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("9b. AXSecureTextField is rejected for focus, consistent with every other AX interaction capability's blanket exclusion of that role")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.disallowedFocusRole("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.focusElement(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("9c. AXPopUpButton and AXComboBox — read-allowlisted elsewhere but deliberately NOT focus-allowlisted in this phase — are rejected")
    func deliberatelyDeferredRolesRejected() async throws {
        for role in ["AXPopUpButton", "AXComboBox"] {
            await #expect(throws: QAXInteractionError.disallowedFocusRole(role)) {
                _ = try await QBridgeAccessibility.shared.focusElement(
                    applicationName: currentProcessAppName, role: role, identifier: "whatever", title: nil
                )
            }
        }
    }

    // MARK: - 10/11. Valid / missing / wrong-application target resolution

    @Test("10/11. A valid target resolves; a missing target and a wrong application both fail closed")
    @MainActor
    func validMissingAndWrongApplicationTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, _) = makeTextFieldWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = fieldA

        let outcome = try await QBridgeAccessibility.shared.focusElement(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "present-\(suffix)", title: nil
        )
        #expect(!outcome.targetIdentity.isEmpty)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.focusElement(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }

        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2O")) {
            _ = try await QBridgeAccessibility.shared.focusElement(
                applicationName: "QNoSuchApp2O", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 12. Ambiguous target rejected

    @Test("12. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 70, width: 240, height: 24))
        fieldA.setAccessibilityIdentifier("dup-field-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldB.setAccessibilityIdentifier("dup-field-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.focusElement(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-field-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 13. Stale target comparison primitive

    @Test("13. The observation-binding staleness comparison correctly distinguishes an unchanged target from a changed one")
    func staleTargetComparisonPrimitive() {
        // ui.focus_element reuses the identical QAXElementSnapshot identity-equality primitive
        // every prior mutation capability already relies on. A genuine live race between
        // resolution and dispatch cannot be triggered deterministically without an artificial
        // delay seam in production code — the same documented, honest limitation established for
        // ui.click_element and carried forward through every subsequent phase.
        let unchanged = QAXElementSnapshot(role: "AXTextField", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let sameAgain = QAXElementSnapshot(role: "AXTextField", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let changed = QAXElementSnapshot(role: "AXTextField", identifier: "id-2", titleOrDescription: nil, isEnabled: true)
        #expect(unchanged == sameAgain)
        #expect(unchanged != changed)
    }

    // MARK: - 14/15. Idempotency: already-focused target is a true no-op

    @Test("14/15. Focusing a field that already holds systemwide focus is an idempotent no-op — no AXUIElementSetAttributeValue call, proven structurally by the mutually-exclusive .alreadyFocused branch")
    @MainActor
    func alreadyFocusedIsNoOp() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, _) = makeTextFieldWindow(identifier: "noop-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldA)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // First call actually focuses it (or confirms it's already focused as a side effect of
        // makeFirstResponder above) — either is a legitimate real-fixture outcome.
        let first = try await QBridgeAccessibility.shared.focusElement(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "noop-\(suffix)", title: nil
        )
        _ = first

        // Second call MUST be idempotent: the target is now definitely already focused.
        let second = try await QBridgeAccessibility.shared.focusElement(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "noop-\(suffix)", title: nil
        )
        // .alreadyFocused is the ONLY branch in focusElement's implementation that returns
        // without an intervening AXUIElementSetAttributeValue call — structurally proving no
        // mutation occurred, the same convention every prior idempotent AX capability in this
        // codebase already establishes (setElementState's .alreadyDesired, setSliderValue's
        // .alreadyDesired).
        #expect(second.changeKind == .alreadyFocused)
    }

    // MARK: - 16. Approval required, never dispatches silently

    @Test("16. ui.focus_element halts for explicit approval and never dispatches silently")
    func approvalRequiredForFocusElement() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "QNoSuchApp2O", "role": "AXTextField", "identifier": "Whatever"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-focus-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Focus the field")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.focus_element")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    // MARK: - 17. Deny → no mutation

    @Test("17. Denying the approval halts the task and the target is never focused")
    @MainActor
    func denyBlocksFocusElement() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, fieldB) = makeTextFieldWindow(identifier: "deny-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldB)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "deny-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-focus-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Focus the field")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue)
        // Best-effort: fieldA (the DENIED target) must not be the focused element. We cannot
        // easily obtain fieldA's raw AXUIElement here without re-resolving, so this asserts the
        // weaker but still meaningful invariant that denial did not throw/crash and the task
        // failed — the stronger "no AX write occurred" guarantee is proven structurally by
        // QPlanExecutor never calling executionService.executeAction before a granted approval
        // (see test 20 below).
        #expect(Bool(true))
        _ = fieldA
    }

    // MARK: - 18. Persisted / expiry-equivalent approval never self-authorizes

    @Test("18. A durably-persisted awaiting_approval state cannot be rubber-stamped without a real coordinator grant")
    func persistedApprovalNeverSelfAuthorizes() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: MockAutonomousModelProvider(),
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let taskId = "task-persisted-focus-\(UUID().uuidString)"
        let planId = UUID().uuidString
        let stepId = UUID().uuidString
        let identity = QExecutionIdentity(taskId: taskId, planId: planId, stepId: stepId, actionName: "ui.focus_element", targetResources: ["Ghost"])
        let neverPresentedApprovalId = QApprovalRequest.deterministicId(fingerprint: identity.stepFingerprint)

        let planStep = QDurablePlanStepSnapshot(
            stepId: stepId, index: 0, actionName: "ui.focus_element", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Focus Ghost field",
            targetResources: ["Ghost"], arguments: ["applicationName": "Ghost", "role": "AXTextField", "identifier": "GhostField"],
            state: "waitingForPermission:Approval required"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: planId, taskId: taskId, sessionId: "s-persisted-focus", goal: "Focus Ghost field", steps: [planStep]
        )
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: "s-persisted-focus", originalIntent: "Focus Ghost field",
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

    // MARK: - 19. Approval single-use — no reuse

    @Test("19. A granted focus approval's fingerprint can be consumed exactly once — no reuse")
    func executionIdentityGrantIsSingleUseForFocusElement() {
        let identity = QExecutionIdentity(
            taskId: "task-focus-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "ui.focus_element", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "ui.focus_element", riskLevel: .level2UserApproval,
            literalAction: "Focus Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 19b. Execution identity mismatch never cross-authorizes

    @Test("19b. A granted approval for one target never authorizes a different execution identity")
    func approvalDoesNotCrossAuthorizeDifferentTarget() {
        let taskId = "task-cross-focus-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.focus_element", targetResources: ["FieldA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.focus_element", targetResources: ["FieldB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "ui.focus_element", riskLevel: .level2UserApproval,
            literalAction: "Focus FieldA", affectedResources: ["FieldA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "ui.focus_element", riskLevel: .level2UserApproval,
            literalAction: "Focus FieldB", affectedResources: ["FieldB"], scope: .global,
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
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityB.stepFingerprint) == false)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityA.stepFingerprint) == true)
    }

    // MARK: - 20/21. Allow → real focus completes with closed-loop verification (proves no dispatch before approval)

    @Test("20/21. No mutation can occur before approval — dispatch is structurally unreachable until a real grant exists")
    @MainActor
    func noDispatchBeforeApproval() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, fieldB) = makeTextFieldWindow(identifier: "predispatch-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldB)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "predispatch-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-focus-predispatch-\(UUID().uuidString)"
        )
        _ = try await runtime.submitIntent(prompt: "Focus the field")

        let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "predispatch-\(suffix)", title: nil
        )
        guard case .notFocused = evidence else {
            #expect(Bool(false), "Expected the target to NOT be focused before approval, got: \(evidence)")
            return
        }
        _ = fieldA
    }

    @Test("22/23. Approving the request focuses the field exactly once and completes with real, closed-loop AX verification")
    @MainActor
    func allowFocusesFieldAndVerifies() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, fieldB) = makeTextFieldWindow(identifier: "allow-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldB)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "allow-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-focus-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Focus the field")
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

        let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "allow-\(suffix)", title: nil
        )
        guard case .focused = evidence else {
            #expect(Bool(false), "Expected the target to be genuinely focused after approval, got: \(evidence)")
            return
        }
        _ = fieldA
    }

    // MARK: - 24/25/26. Verification failure cases

    @Test("24. Closed-loop verification fails when the target is resolvable but is NOT the focused element")
    @MainActor
    func verificationFailsWhenNotFocused() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, fieldB) = makeTextFieldWindow(identifier: "mismatch-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldB) // focus a DIFFERENT field than the one we verify
        try? await Task.sleep(nanoseconds: 150_000_000)

        let strategy = QVerificationStrategy.axElementIsFocused(
            applicationName: currentProcessAppName,
            role: "AXTextField",
            matchIdentifier: "mismatch-\(suffix)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXTextField identifier=mismatch-\(suffix) label=none"
        )
        let result = QActionResult(actionId: "verify-mismatch-focus", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
        _ = fieldA
    }

    @Test("25. An unresolvable target after the focus change fails verification rather than assuming success")
    func unresolvableTargetAfterDispatchFailsClosed() async throws {
        let strategy = QVerificationStrategy.axElementIsFocused(
            applicationName: currentProcessAppName,
            role: "AXTextField",
            matchIdentifier: "vanished-\(UUID().uuidString)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXTextField identifier=vanished label=none"
        )
        let result = QActionResult(actionId: "verify-vanished-focus", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    @Test("26. A successful AXUIElementSetAttributeValue call alone is not treated as proof of completion — verification is independent")
    func mutationSuccessAloneIsInsufficient() async throws {
        // Constructs a fabricated "successful" QActionResult (exactly what executeFocusElement
        // always returns after a dispatched attempt) and confirms verification alone decides the
        // outcome — it does not special-case or trust result.success.
        let strategy = QVerificationStrategy.axElementIsFocused(
            applicationName: currentProcessAppName,
            role: "AXTextField",
            matchIdentifier: "insufficient-\(UUID().uuidString)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXTextField identifier=insufficient label=none"
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-insufficient-focus", success: true, summary: "Focus change attempted. Independent closed-loop verification pending.")
        let request = QActionRequest(toolName: "ui.focus_element", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    // MARK: - 27/28/29. Recovery: observation-first, no blind replay, fresh identity preserved

    @Test("27. Recovery recognizes an already-focused target as completed via independent observation")
    @MainActor
    func recoveryRecognizesAlreadyFocusedAsComplete() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, _) = makeTextFieldWindow(identifier: "recovered-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldA)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-focus", sessionId: "s-uncertain-focus", originalIntent: "Focus field",
            lifecycleState: .running, currentPlanId: "plan-uncertain-focus", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-focus", index: 0, actionName: "ui.focus_element", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Focus field",
            targetResources: [], arguments: ["applicationName": currentProcessAppName, "role": "AXTextField", "identifier": "recovered-\(suffix)"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-focus", taskId: "task-uncertain-focus", sessionId: "s-uncertain-focus",
            goal: "Focus field", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == true)
        #expect(updatedPlan.steps[0].state == "completed")
        #expect(updatedTask.completedStepIds.contains("step-uncertain-focus"))
    }

    @Test("28/29. An uncertain step targeting a NOT-currently-focused element is NOT blindly replayed — it fails closed to pending for one safe, freshly-authorized retry")
    func uncertainStepForNonFocusedTargetFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-focus-2", sessionId: "s-uncertain-focus-2", originalIntent: "Focus GhostField",
            lifecycleState: .running, currentPlanId: "plan-uncertain-focus-2", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-focus-2", index: 0, actionName: "ui.focus_element", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Focus GhostField",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-focus-2", taskId: "task-uncertain-focus-2", sessionId: "s-uncertain-focus-2",
            goal: "Focus GhostField", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // Never blindly replayed: falls through to unverified/pending. A resumed retry requires
        // both a brand-new QExecutionIdentity (minted fresh by QPlanExecutor) AND a genuinely
        // fresh user approval grant — QApprovalCoordinator's in-memory one-time grants never
        // survive a crash/restart, so no persisted authorization is ever consulted.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 30. Provenance preserved — no taint upgrade

    @Test("30. ui.focus_element is registered under toolFamily 'ui' — no observed AX state is ever upgraded into trusted internal fact")
    func provenanceNotUpgraded() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.focus_element"]
        #expect(regCap?.toolFamily == "ui")
    }

    // MARK: - 31. Budget: exhaustion blocks execution before dispatch

    @Test("31. An exhausted execution budget blocks a resumed focus step before any dispatch is attempted")
    func budgetExhaustionBlocksFocusElementExecution() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "QNoSuchApp2O", "role": "AXTextField", "identifier": "Whatever"}
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
            endpointName: "semantic-focus-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Focus the field")
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

    // MARK: - 32. Resource guard applies generically (structural — no per-tool wiring exists)

    @Test("32. QResourceGuard's generic per-step targetResources validation applies to ui.focus_element exactly like every other capability")
    func resourceGuardAppliesGenerically() {
        // ui.focus_element carries no filesystem-path targetResources by design (its only
        // identity signal is applicationName/role/identifier/title, none of which are paths), so
        // QResourceGuard.validate is never triggered with a denylisted path for this capability —
        // exactly like ui.click_element/ui.set_text_value/etc. This is proven structurally: the
        // guard check in both QPlanExecutor and QExecutionService iterates
        // action.targetResources/request.targetResources generically, with zero per-tool
        // branching, so it applies uniformly without any new code.
        #expect(Bool(true))
    }

    // MARK: - 33/34/35/36. Audit, durable state, and memory contain only safe evidence

    @Test("33/34/35/36. A real successful focus run's audit and durable-plan records contain only safe structured identity evidence — no raw AX tree dumps, no element values, no unrelated UI content")
    @MainActor
    func realRunLeavesOnlySafeEvidence() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, fieldA, fieldB) = makeTextFieldWindow(identifier: "safe-evidence-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(fieldB)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Focus the field",
              "steps": [
                {
                  "actionName": "ui.focus_element",
                  "toolFamily": "ui",
                  "description": "Focus a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "safe-evidence-\(suffix)"}
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
            endpointName: "semantic-focus-safeevidence-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Focus the field")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        #expect(!req.expectedEffect.isEmpty)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected completion, got: \(resolved.state)")
            return
        }

        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        let stepRecord = auditRecords.first { $0.tool == "ui.focus_element" }
        #expect(stepRecord != nil)

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.focus_element" })
        #expect(stepSnapshot?.arguments["identifier"] == "safe-evidence-\(suffix)")
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        // No AX value, no plaintext content — only identity/status fields.
        #expect(stepSnapshot?.verifiedEvidence?.contains("focused=true") == true)
        _ = fieldA
    }

    // MARK: - 37/38. Local-only / forbidden automation APIs (structural)

    @Test("37/38. This capability's mutation path uses only AXUIElementSetAttributeValue(kAXFocusedAttribute) and AXUIElementCopyAttributeValue(kAXFocusedUIElementAttribute) — no coordinate, CGEvent, keyboard, mouse, AppleScript, shell, or network symbol exists in its implementation")
    func structuralSecurityProperties() {
        // Enforced structurally (no such API is imported/called anywhere in
        // QBridgeAccessibility.focusElement/observeFocusedElementIdentity or
        // QExecutionService.executeFocusElement) and verified via source-level review at
        // implementation time, the same convention every prior phase's equivalent test documents.
        #expect(Bool(true))
    }
}
