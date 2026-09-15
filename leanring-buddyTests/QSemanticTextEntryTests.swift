//
//  QSemanticTextEntryTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic AX Text-Entry Tests (Phase 2I).
//  ui.set_text_value resolves a target purely by Accessibility semantics (role + identifier or
//  title), restricted to an explicit AXTextField/AXTextArea allowlist, verifies the target is
//  genuinely focused before ever mutating it, writes via AXUIElementSetAttributeValue
//  (kAXValueAttribute) only, and only ever counts a later, independent AX value-hash diff as
//  verified success. Accessibility (AX) trust and real keyboard focus cannot be assumed granted
//  in an isolated XCTest runner — every test that needs a real, live, focused AXUIElement
//  branches on `AXIsProcessTrusted()`/focus establishment and no-ops rather than fabricating a
//  pass, mirroring the exact convention QSemanticClickTests already established for Phase 2H.
//  See docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md for the full privacy contract this
//  capability implements.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures: real, disposable windows with real text controls

private func rawAXFocusedIdentifier() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = value as! AXUIElement
    var idValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &idValue) == .success else { return nil }
    return idValue as? String
}

/// Best-effort real focus establishment for a test fixture control — activates the test host
/// app, makes the window key, and makes the control the first responder, then polls the REAL
/// system-wide AX focused element (not just `NSWindow.firstResponder`) until it reports the
/// expected identifier. Environments without a genuine window-server focus session (e.g. some CI
/// runners) may never converge; callers must treat a `false` return as "cannot establish real
/// focus here" and no-op rather than fail, exactly like the existing `AXIsProcessTrusted()` gate.
@MainActor
@discardableResult
private func establishRealAXFocus(window: NSWindow, responder: NSResponder, identifier: String, timeout: TimeInterval = 3.0) async -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    _ = window.makeFirstResponder(responder)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if rawAXFocusedIdentifier() == identifier { return true }
        _ = window.makeFirstResponder(responder)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    return rawAXFocusedIdentifier() == identifier
}

@MainActor
private func makeTextFieldWindow(identifier: String, initialValue: String) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticTextEntryTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = initialValue
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

@MainActor
private func makeTextAreaWindow(identifier: String, initialValue: String) -> (window: NSWindow, view: NSTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 160),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticTextEntryTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
    let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 260, height: 120))
    textView.string = initialValue
    textView.isEditable = true
    textView.setAccessibilityIdentifier(identifier)
    contentView.addSubview(textView)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textView)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@discardableResult
private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

@Suite("QSemanticTextEntryTests")
struct QSemanticTextEntryTests {

    // MARK: - 1. Capability registration

    @Test("1. ui.set_text_value is a registered, Level 2, semantically-targeted capability")
    func capabilityRegistrationAcceptsUISetTextValue() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_text_value"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Set the field value",
          "steps": [
            {
              "actionName": "ui.set_text_value",
              "toolFamily": "ui",
              "description": "Set a semantically-identified text field's value",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "SomeField", "value": "hello"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-text", taskPrompt: "Set the field value")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        // Anti-downgrade: a model attempting to self-declare a lower risk must be rejected.
        let downgradeJSON = """
        {
          "taskPrompt": "Set the field value",
          "steps": [
            {
              "actionName": "ui.set_text_value",
              "toolFamily": "ui",
              "riskLevel": "level0ReadOnly",
              "description": "Set a semantically-identified text field's value",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "SomeField", "value": "hello"}
            }
          ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-downgrade-text", taskPrompt: "Set the field value")
        }
    }

    // MARK: - 2. Valid AXTextField resolves, focus verified, value written

    @Test("2. A valid, focused AXTextField target is written exactly once via AX only")
    @MainActor
    func validTextFieldTargetIsWritten() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "field-\(suffix)", initialValue: "before")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "field-\(suffix)") else { return }

        let outcome = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "field-\(suffix)", title: nil, newValue: "after"
        )
        #expect(outcome.valueChanged == true)
        #expect(outcome.previousLength == "before".count)
        #expect(outcome.currentLength == "after".count)
        #expect(field.stringValue == "after")
    }

    // MARK: - 3. Valid AXTextArea resolves and is written

    @Test("3. A valid, focused AXTextArea target is written exactly once via AX only")
    @MainActor
    func validTextAreaTargetIsWritten() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, view) = makeTextAreaWindow(identifier: "area-\(suffix)", initialValue: "old body")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: view, identifier: "area-\(suffix)") else { return }

        let outcome = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: currentProcessAppName, role: "AXTextArea", identifier: "area-\(suffix)", title: nil, newValue: "new body text"
        )
        #expect(outcome.valueChanged == true)
        #expect(view.string == "new body text")
    }

    // MARK: - 4. Disallowed role (AXSecureTextField) rejected before any search

    @Test("4. A secure-text-field role is rejected before any AX search is even attempted")
    func secureTextFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.disallowedTargetRole("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil, newValue: "x"
            )
        }
    }

    // MARK: - 4b. Unknown/unlisted role rejected

    @Test("4b. An unrecognized role is rejected by the same fail-closed allowlist check")
    func unknownRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.disallowedTargetRole("AXCustomWidgetRole")) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXCustomWidgetRole", identifier: "whatever", title: nil, newValue: "x"
            )
        }
        // AXStaticText specifically, since it is a real, common AX role (unlike a made-up one).
        await #expect(throws: QAXInteractionError.disallowedTargetRole("AXStaticText")) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXStaticText", identifier: "whatever", title: nil, newValue: "x"
            )
        }
    }

    // MARK: - 5. Zero matches fails closed

    @Test("5. Zero matching elements fails closed with a deterministic error, never a fabricated success")
    @MainActor
    func zeroMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)", initialValue: "x")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil, newValue: "y"
            )
        }
    }

    // MARK: - 6. Ambiguous target fails closed

    @Test("6. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.isEditable = true
        fieldA.setAccessibilityIdentifier("dup-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.isEditable = true
        fieldB.setAccessibilityIdentifier("dup-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-\(suffix)", title: nil, newValue: "z"
            )
        }
    }

    // MARK: - 7. Wrong focus fails closed — and no keyboard/CGEvent fallback occurs

    @Test("7. A valid, resolvable target that is NOT focused fails closed and is never mutated by any fallback path")
    @MainActor
    func wrongFocusFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "unfocused-\(suffix)", initialValue: "unchanged")
        defer { window.close() }
        // Deliberately do NOT call makeFirstResponder / establish focus.
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "unfocused-\(suffix)", title: nil, newValue: "hacked"
            )
            // If the real environment happens to have already focused this field for some
            // window-server reason outside this test's control, that's not this test's concern —
            // but if we get here on a genuinely unfocused field, that's the bug this test exists
            // to catch, so only assert the negative when we can independently confirm non-focus.
            if rawAXFocusedIdentifier() != "unfocused-\(suffix)" {
                Issue.record("setTextValue succeeded against a target that was not the focused AX element")
            }
        } catch let axError as QAXInteractionError {
            #expect(axError.errorCode == "AX_TARGET_NOT_FOCUSED")
        }
        // Regardless of outcome, the field's content must be untouched — no CGEvent/keyboard
        // fallback, no coordinate click, ever mutated it behind the focus check.
        #expect(field.stringValue == "unchanged")
    }

    // MARK: - 8. Already-equal value is an idempotent no-op

    @Test("8. Setting a value equal to the current value is a no-op — no AX write, no unnecessary mutation")
    @MainActor
    func alreadyEqualValueIsNoOp() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "noop-\(suffix)", initialValue: "same value")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "noop-\(suffix)") else { return }

        let outcome = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "noop-\(suffix)", title: nil, newValue: "same value"
        )
        #expect(outcome.valueChanged == false)
        #expect(outcome.previousLength == outcome.currentLength)
        #expect(field.stringValue == "same value")
    }

    // MARK: - 8b. Stale target comparison primitive

    @Test("8b. The observation-binding staleness comparison correctly distinguishes an unchanged target from a changed one")
    @MainActor
    func staleTargetComparisonPrimitive() async throws {
        // setTextValue reuses the identical QAXElementSnapshot equality primitive
        // ui.click_element's observation-binding re-verify already relies on (same
        // snapshotIfMatches/staleTarget discipline) — this proves it holds for the text-entry
        // case too. A genuine live race between resolution and dispatch cannot be triggered
        // deterministically without an artificial delay seam in production code (the same,
        // deliberate limitation documented for ui.click_element in
        // docs/PHASE_2H_SEMANTIC_CLICK.md), so this tests the comparison primitive directly.
        let unchanged = QAXElementSnapshot(role: "AXTextField", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let sameAgain = QAXElementSnapshot(role: "AXTextField", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let changedEnabled = QAXElementSnapshot(role: "AXTextField", identifier: "id-1", titleOrDescription: nil, isEnabled: false)
        let changedIdentifier = QAXElementSnapshot(role: "AXTextField", identifier: "id-2", titleOrDescription: nil, isEnabled: true)

        #expect(unchanged == sameAgain)
        #expect(unchanged != changedEnabled)
        #expect(unchanged != changedIdentifier)
    }

    // MARK: - 9. Approval required, never dispatches silently

    @Test("9. ui.set_text_value halts for explicit approval and never dispatches silently")
    func approvalRequiredForSetTextValue() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set a field",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "QNoSuchApp2I", "role": "AXTextField", "identifier": "Whatever", "value": "SECRET_TEST_VALUE"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-text-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set a field")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.set_text_value")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
        // Approval HUD privacy (Phase 2I remediation): the literal value never appears in the
        // pre-approval display text.
        #expect(req.expectedEffect.contains("SECRET_TEST_VALUE") == false)
        #expect(req.literalAction.contains("SECRET_TEST_VALUE") == false)
    }

    // MARK: - 10. Deny -> no mutation

    @Test("10. Denying the approval halts the task and the target is never mutated")
    @MainActor
    func denyBlocksSetTextValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "deny-target-\(suffix)", initialValue: "untouched")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "deny-target-\(suffix)") else { return }

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set the target",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "deny-target-\(suffix)", "value": "denied value"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-text-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set the target")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }
        #expect(field.stringValue == "untouched")
    }

    // MARK: - 11. Allow -> writes exactly once, closed-loop verified

    @Test("11. Approving the request writes the target exactly once and completes with real, closed-loop AX verification")
    @MainActor
    func allowWritesExactlyOnceAndVerifies() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "allow-target-\(suffix)", initialValue: "start")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "allow-target-\(suffix)") else { return }

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set the target",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "allow-target-\(suffix)", "value": "finished"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-text-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set the target")
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
        #expect(field.stringValue == "finished")
        // Redaction across model/replan/goal-evaluation context (Phase 2I remediation): the
        // final grounded summary text is built from verified evidence, never the literal.
        #expect(summary.contains("finished") == false)
    }

    // MARK: - 12. Approval for target A cannot authorize target B

    @Test("12. A granted text-entry approval never authorizes a different execution identity")
    func approvalDoesNotCrossAuthorizeAnotherTarget() {
        let taskId = "task-cross-text-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.set_text_value", targetResources: ["FieldA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.set_text_value", targetResources: ["FieldB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "ui.set_text_value", riskLevel: .level2UserApproval,
            literalAction: "Set FieldA", affectedResources: ["FieldA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "ui.set_text_value", riskLevel: .level2UserApproval,
            literalAction: "Set FieldB", affectedResources: ["FieldB"], scope: .global,
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

    // MARK: - 13. Single-use grant / no duplicate execution / no approval reuse

    @Test("13. A granted text-entry approval's fingerprint can be consumed exactly once — no reuse, no duplicate side effect")
    func executionIdentityGrantIsSingleUseForSetTextValue() {
        let identity = QExecutionIdentity(
            taskId: "task-text-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "ui.set_text_value", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "ui.set_text_value", riskLevel: .level2UserApproval,
            literalAction: "Set Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        // Reuse / duplicate-race attempt: the second consumption must fail — no standing grant,
        // no replay.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 14. Abandoned approval never executes

    @Test("14. An approval that is never resolved never results in a mutation")
    @MainActor
    func abandonedApprovalNeverExecutes() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "abandon-target-\(suffix)", initialValue: "untouched")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "abandon-target-\(suffix)") else { return }

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set the target",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "abandon-target-\(suffix)", "value": "abandoned"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-text-abandon-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set the target")
        guard case .awaitingApproval(let req) = task.state, let identity = req.executionIdentity else {
            #expect(Bool(false), "Expected awaiting approval with a bound execution identity")
            return
        }
        // Deliberately never call resolveApproval.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
        #expect(field.stringValue == "untouched")
    }

    // MARK: - 15. Closed-loop verification fails (never fabricates success) when the value does not match

    @Test("15. Verification against a mismatched intended value fails, even though the underlying write succeeded")
    @MainActor
    func verificationFailsOnMismatch() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "mismatch-\(suffix)", initialValue: "start")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "mismatch-\(suffix)") else { return }

        // Real write via the actual capability.
        let outcome = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "mismatch-\(suffix)", title: nil, newValue: "actual"
        )
        #expect(outcome.valueChanged == true)

        // Directly exercise the independent verification strategy with a WRONG intended-value
        // hash (simulating what would happen if the field were changed by something else, or the
        // model's declared intent didn't match what actually landed) — must fail, not fabricate.
        let wrongIntendedHash = "0000000000000000000000000000000000000000000000000000000000000000"
        let strategy = QVerificationStrategy.axTextValueChanged(
            applicationName: currentProcessAppName,
            role: "AXTextField",
            matchIdentifier: "mismatch-\(suffix)",
            matchTitle: nil,
            targetIdentity: outcome.targetIdentity,
            previousLength: outcome.previousLength,
            previousValueHash: outcome.previousValueHash,
            intendedValueHash: wrongIntendedHash
        )
        let result = QActionResult(actionId: "verify-mismatch", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.set_text_value", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let outcomeVerify = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcomeVerify.isVerified == false)
        if case .failed(_, let evidence) = outcomeVerify {
            #expect(evidence.contains("actual") == false)
        }
    }

    // MARK: - 16. Budget exhaustion blocks execution before any dispatch

    @Test("16. An exhausted execution budget blocks a resumed text-entry step before any dispatch is attempted")
    func budgetExhaustionBlocksSetTextValueExecution() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set the target",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "QNoSuchApp2I", "role": "AXTextField", "identifier": "Whatever", "value": "x"}
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
            endpointName: "semantic-text-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set the target")
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

    // MARK: - 17. Recovery observes before retry — uncertain step fails closed to pending

    @Test("17. An uncertain in-flight text-entry step is never blindly marked complete — it fails closed to pending, and idempotency prevents a duplicate write on retry")
    func uncertainSetTextValueStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-text", sessionId: "s-uncertain-text", originalIntent: "Set GhostField",
            lifecycleState: .running, currentPlanId: "plan-uncertain-text", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-text", index: 0, actionName: "ui.set_text_value", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Set GhostField",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField", "value": "[REDACTED_SENSITIVE_ARGUMENT:length=5]"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-text", taskId: "task-uncertain-text", sessionId: "s-uncertain-text",
            goal: "Set GhostField", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // ui.set_text_value has no dedicated observation-first recovery check (mirroring
        // ui.click_element/app.quit) — an uncertain attempt fails closed: not verified, reset to
        // pending for one safe retry. That retry itself re-observes current state and treats an
        // already-equal value as a no-op (test 8), which is what makes the retry safe rather than
        // duplicating a write.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 18. Redaction across durable state, memory, and audit for a real successful run

    @Test("18. A real successful text-entry run leaves no literal value in durable state, memory, or audit")
    @MainActor
    func realRunLeavesNoLiteralInPersistedSurfaces() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let secret = "SECRET_TEST_VALUE_\(suffix)"
        let (window, field) = makeTextFieldWindow(identifier: "redact-\(suffix)", initialValue: "before")
        defer { window.close() }
        guard await establishRealAXFocus(window: window, responder: field, identifier: "redact-\(suffix)") else { return }

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Set the target",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "redact-\(suffix)", "value": "\(secret)"}
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
            endpointName: "semantic-text-redact-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Set the target")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected completion, got: \(resolved.state)")
            return
        }
        #expect(field.stringValue == secret)

        // Durable state: arguments["value"] must be masked, never the literal.
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.set_text_value" })
        #expect(stepSnapshot?.arguments["value"]?.contains(secret) == false)
        #expect(stepSnapshot?.arguments["value"]?.hasPrefix("[REDACTED_SENSITIVE_ARGUMENT:") == true)
        #expect(stepSnapshot?.resultSummary?.contains(secret) == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains(secret) == false)

        // Memory: no plan-completion record contains the literal.
        let memoryRecord = try memory.getByKey("plan_\(planId)", sessionId: task.sessionId)
        #expect(memoryRecord?.content.contains(secret) == false)

        // Audit: no record for this task contains the literal.
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        let anyRecordLeaksSecret = auditRecords.contains {
            ($0.executionSummary ?? "").contains(secret) || ($0.error ?? "").contains(secret)
        }
        #expect(anyRecordLeaksSecret == false)
    }
}
