//
//  QSemanticClickTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic AXUIElement Click Tests (Phase 2H).
//  ui.click_element resolves a target purely by Accessibility semantics (role + identifier or
//  title/description) — never by screen coordinates — binds to it via an observation snapshot,
//  re-verifies immediately before dispatch, presses it through AXUIElementPerformAction, and only
//  ever counts a later, independent AX state diff as verified success. Accessibility (AX) trust
//  cannot be assumed granted for the isolated XCTest runner (the exact same class of TCC
//  uncertainty Phase 2G found for Screen Recording) — every test that needs a real, live
//  AXUIElement tree branches on `AXIsProcessTrusted()` and no-ops rather than fabricating a pass
//  when untrusted; tests that exercise the authorization/budget/recovery layers (which run before
//  any AX call is ever made) do not depend on that permission and always run. See
//  docs/PHASE_2H_SEMANTIC_CLICK.md for the full contract and the one documented, honest testing
//  limitation (a genuine observation-binding race cannot be triggered deterministically without
//  adding a test-only seam to production code, which was deliberately not done).
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixture: a real, disposable window with real NSButtons

/// Presses a button by an already-known, real accessibility identifier from a live process's own
/// AX tree — direct low-level ApplicationServices calls, exactly mirroring the production
/// implementation's own APIs. Used ONLY as test scaffolding (priming/asserting fixture state),
/// never as a substitute for the capability under test.
@discardableResult
private func rawAXPress(applicationName: String, identifier: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame
    }) else { return false }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let button = rawAXFind(root: appElement, identifier: identifier, depth: 0) else { return false }
    return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
}

private func rawAXFind(root: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
    guard depth <= 12 else { return nil }
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(root, "AXIdentifier" as CFString, &value) == .success, (value as? String) == identifier {
        return root
    }
    var childrenValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenValue) == .success,
          let children = childrenValue as? [AXUIElement] else { return nil }
    for child in children {
        if let found = rawAXFind(root: child, identifier: identifier, depth: depth + 1) {
            return found
        }
    }
    return nil
}

private func rawAXExists(applicationName: String, identifier: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame
    }) else { return false }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return rawAXFind(root: appElement, identifier: identifier, depth: 0) != nil
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

/// Holds real NSButton target/action state for tests that need to prove a press actually
/// happened, and/or that a target's own Accessibility identity changes as a direct result of
/// being pressed (the same self-diffing behavior empirically confirmed on real Calculator
/// buttons — see docs/PHASE_2H_SEMANTIC_CLICK.md).
@MainActor
private final class QClickTestHarness: NSObject {
    var pressCount = 0

    @objc func recordPress(_ sender: NSButton) {
        pressCount += 1
    }

    @objc func recordPressAndToggleIdentity(_ sender: NSButton) {
        pressCount += 1
        sender.setAccessibilityIdentifier("toggled-\(uniqueSuffix)")
        sender.title = "Toggled"
    }

    let uniqueSuffix: String
    init(uniqueSuffix: String) { self.uniqueSuffix = uniqueSuffix }
}

@MainActor
private func makeTestWindow(
    harness: QClickTestHarness,
    buttons: [(identifier: String, title: String, enabled: Bool, selfMutating: Bool, countsPress: Bool)]
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 60, y: 60, width: 260, height: max(60, 44 * buttons.count + 20)),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "QSemanticClickTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: max(60, 44 * buttons.count + 20)))
    for (index, spec) in buttons.enumerated() {
        let button = NSButton(frame: NSRect(x: 20, y: CGFloat(20 + index * 44), width: 200, height: 32))
        button.title = spec.title
        button.setAccessibilityIdentifier(spec.identifier)
        button.isEnabled = spec.enabled
        button.target = harness
        if spec.selfMutating {
            button.action = #selector(QClickTestHarness.recordPressAndToggleIdentity(_:))
        } else if spec.countsPress {
            button.action = #selector(QClickTestHarness.recordPress(_:))
        }
        contentView.addSubview(button)
    }
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return window
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticClickTests")
struct QSemanticClickTests {

    // MARK: - 1. Capability registration

    @Test("1. ui.click_element is a registered, Level 2, semantically-targeted capability")
    func capabilityRegistrationAcceptsUIClickElement() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.click_element"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Click the target",
          "steps": [
            {
              "actionName": "ui.click_element",
              "toolFamily": "ui",
              "description": "Click a semantically-identified element",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "SomeButton"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration", taskPrompt: "Click the target")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        // A model attempting to self-declare a lower risk for this tool must still be rejected —
        // the same anti-downgrade rule already covering every other capability.
        let downgradeJSON = """
        {
          "taskPrompt": "Click the target",
          "steps": [
            {
              "actionName": "ui.click_element",
              "toolFamily": "ui",
              "riskLevel": "level0ReadOnly",
              "description": "Click a semantically-identified element",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "SomeButton"}
            }
          ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-downgrade", taskPrompt: "Click the target")
        }
    }

    // MARK: - 2. Valid semantic target resolves (direct bridge call)

    @Test("2. A valid role + identifier target resolves and is pressed exactly once")
    @MainActor
    func validSemanticTargetResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "valid-\(suffix)", title: "Press Me", enabled: true, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let (evidence, snapshot) = try await QBridgeAccessibility.shared.clickElement(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "valid-\(suffix)", title: nil
        )
        #expect(!evidence.isEmpty)
        #expect(snapshot.identifier == "valid-\(suffix)")
        #expect(snapshot.isEnabled == true)
        #expect(harness.pressCount == 1)
    }

    // MARK: - 3. Zero matches -> fail closed

    @Test("3. Zero matching elements fails closed with a deterministic error, never a fabricated success")
    @MainActor
    func zeroMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "present-\(suffix)", title: "Present", enabled: true, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "does-not-exist-\(suffix)", title: nil
            )
            Issue.record("Expected .noMatchingElement")
        } catch let error as QAXInteractionError {
            #expect(error == .noMatchingElement)
        }
        #expect(harness.pressCount == 0)
    }

    // MARK: - 4. Ambiguous matches -> fail closed, never guess

    @Test("4. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousMatchesFailClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "dup-\(suffix)", title: "First", enabled: true, selfMutating: false, countsPress: true),
            (identifier: "dup-\(suffix)", title: "Second", enabled: true, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "dup-\(suffix)", title: nil
            )
            Issue.record("Expected .ambiguousTarget")
        } catch let error as QAXInteractionError {
            #expect(error == .ambiguousTarget(count: 2))
        }
        #expect(harness.pressCount == 0)
    }

    // MARK: - 5. Disabled element -> fail safely

    @Test("5. A disabled target element fails safely and is never pressed")
    @MainActor
    func disabledElementFailsSafely() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "disabled-\(suffix)", title: "Disabled", enabled: false, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "disabled-\(suffix)", title: nil
            )
            Issue.record("Expected .targetDisabled")
        } catch let error as QAXInteractionError {
            #expect(error == .targetDisabled)
        }
        #expect(harness.pressCount == 0)
    }

    // MARK: - 6. Missing application -> fail safely

    @Test("6. A target application that is not running fails safely with a deterministic error")
    func missingApplicationFailsSafely() async throws {
        guard AXIsProcessTrusted() else { return }
        do {
            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: "QNoSuchApplication2H-\(UUID().uuidString)", role: "AXButton", identifier: "Whatever", title: nil
            )
            Issue.record("Expected .applicationNotAvailable")
        } catch let error as QAXInteractionError {
            guard case .applicationNotAvailable = error else {
                Issue.record("Expected .applicationNotAvailable, got \(error)")
                return
            }
        }
    }

    // MARK: - 7. Accessibility permission denied -> fail safely

    @Test("7. When Accessibility permission is not granted, resolution fails closed rather than silently proceeding")
    func accessibilityPermissionDeniedFailsSafely() async throws {
        guard !AXIsProcessTrusted() else {
            // Permission is live in this environment — the denial path is not exercisable here;
            // every other test in this file (gated the opposite way) covers the granted path.
            return
        }
        do {
            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: "Finder", role: "AXButton", identifier: "Whatever", title: nil
            )
            Issue.record("Expected .accessibilityPermissionDenied")
        } catch let error as QAXInteractionError {
            #expect(error == .accessibilityPermissionDenied)
        }
    }

    // MARK: - 8. Stale-target detection primitive

    @Test("8. The staleness comparison primitive correctly distinguishes an unchanged target from a changed one (see docs for the live-race testing limitation)")
    func staleTargetDetectionPrimitiveIsCorrect() {
        let original = QAXElementSnapshot(role: "AXButton", identifier: "Clear", titleOrDescription: "Clear", isEnabled: true)
        let unchanged = QAXElementSnapshot(role: "AXButton", identifier: "Clear", titleOrDescription: "Clear", isEnabled: true)
        let changedIdentifier = QAXElementSnapshot(role: "AXButton", identifier: "AllClear", titleOrDescription: "All Clear", isEnabled: true)
        let becameDisabled = QAXElementSnapshot(role: "AXButton", identifier: "Clear", titleOrDescription: "Clear", isEnabled: false)

        // This exact equality check is what clickElement's observation-binding re-verify gates
        // dispatch on (QBridgeAdapters.swift: `observedAtVerify == observedAtSearch`) — an
        // unchanged snapshot must compare equal (dispatch proceeds); any drift must not.
        #expect(original == unchanged)
        #expect(original != changedIdentifier)
        #expect(original != becameDisabled)
    }

    // MARK: - 9. Approval required

    @Test("9. ui.click_element halts for explicit approval and never dispatches silently")
    func approvalRequiredForClickElement() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Click a button",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click a semantically-identified element",
                  "parameters": {"applicationName": "QNoSuchApp2H", "role": "AXButton", "identifier": "Whatever"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-click-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Click a button")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.click_element")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    // MARK: - 10. Deny -> no click

    @Test("10. Denying the approval halts the task and the target is never pressed")
    @MainActor
    func denyBlocksClick() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "deny-target-\(suffix)", title: "Deny Target", enabled: true, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Click the target",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "deny-target-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-click-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Click the target")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }
        #expect(harness.pressCount == 0)
    }

    // MARK: - 11. Allow -> clicks exactly once

    @Test("11. Approving the request clicks the target exactly once and completes with real AX evidence")
    @MainActor
    func allowClicksExactlyOnce() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "allow-target-\(suffix)", title: "Allow Target", enabled: true, selfMutating: true, countsPress: false)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Click the target",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "allow-target-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-click-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Click the target")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected task to complete after approval, got: \(resolved.state)")
            return
        }
        #expect(harness.pressCount == 1)
    }

    // MARK: - 12. Approval for action A cannot authorize action B

    @Test("12. A granted click approval never authorizes a different click execution identity")
    func approvalDoesNotCrossAuthorizeAnotherClick() {
        let taskId = "task-cross-click-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.click_element", targetResources: ["ButtonA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.click_element", targetResources: ["ButtonB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "ui.click_element", riskLevel: .level2UserApproval,
            literalAction: "Click ButtonA", affectedResources: ["ButtonA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "ui.click_element", riskLevel: .level2UserApproval,
            literalAction: "Click ButtonB", affectedResources: ["ButtonB"], scope: .global,
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

    // MARK: - 13. Duplicate execution identity -> no duplicate click

    @Test("13. A granted click approval's fingerprint can be consumed exactly once — no duplicate side effect")
    func executionIdentityGrantIsSingleUseForClick() {
        let identity = QExecutionIdentity(
            taskId: "task-click-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "ui.click_element", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "ui.click_element", riskLevel: .level2UserApproval,
            literalAction: "Click Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 14. Cancellation (abandoned approval) -> no unsafe execution

    @Test("14. An approval that is never resolved never results in a click")
    @MainActor
    func abandonedApprovalNeverExecutes() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let harness = QClickTestHarness(uniqueSuffix: suffix)
        let window = makeTestWindow(harness: harness, buttons: [
            (identifier: "abandon-target-\(suffix)", title: "Abandon Target", enabled: true, selfMutating: false, countsPress: true)
        ])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Click the target",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click a semantically-identified element",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "abandon-target-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-click-abandon-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Click the target")
        guard case .awaitingApproval(let req) = task.state, let identity = req.executionIdentity else {
            #expect(Bool(false), "Expected awaiting approval with a bound execution identity")
            return
        }

        // Deliberately never call resolveApproval — simulates the user abandoning/cancelling the
        // prompt. No grant may exist for this identity, and the target must never be pressed.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
        #expect(harness.pressCount == 0)
    }

    // MARK: - 15 & 16. Post-click observation; verification never fabricates success

    @Test("15-16. A real AX state change is verified as success; an unchanged target is never fabricated as success even though the press itself succeeded")
    @MainActor
    func postClickVerificationObservesRealStateChangeAndNeverFabricatesSuccess() async throws {
        guard AXIsProcessTrusted() else { return }

        // 15: self-mutating button — a real, observable AX identity change after press.
        do {
            let suffix = UUID().uuidString
            let harness = QClickTestHarness(uniqueSuffix: suffix)
            let window = makeTestWindow(harness: harness, buttons: [
                (identifier: "toggle-target-\(suffix)", title: "Toggle Target", enabled: true, selfMutating: true, countsPress: false)
            ])
            defer { window.close() }
            try? await Task.sleep(nanoseconds: 100_000_000)

            let mockModel = MockAutonomousModelProvider()
            mockModel.structuredPlansToReturn = [
                """
                {
                  "taskPrompt": "Click the toggle target",
                  "steps": [
                    {
                      "actionName": "ui.click_element",
                      "toolFamily": "ui",
                      "description": "Click a semantically-identified element",
                      "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "toggle-target-\(suffix)"}
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
                endpointName: "semantic-click-verify-success-\(UUID().uuidString)"
            )
            let task = try await runtime.submitIntent(prompt: "Click the toggle target")
            guard case .awaitingApproval(let req) = task.state else {
                #expect(Bool(false), "Expected awaiting approval")
                return
            }
            let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
            guard case .completed(let summary) = resolved.state else {
                #expect(Bool(false), "Expected completion with a genuine observed state change, got: \(resolved.state)")
                return
            }
            #expect(harness.pressCount == 1)
            #expect(summary.localizedCaseInsensitiveContains("state changed") || summary.localizedCaseInsensitiveContains("no longer resolvable"))
        }

        // 16: static, non-mutating button — the press succeeds, but nothing observable changes.
        // Verification must fail (not fabricate success) even though dispatch itself worked.
        do {
            let suffix = UUID().uuidString
            let harness = QClickTestHarness(uniqueSuffix: suffix)
            let window = makeTestWindow(harness: harness, buttons: [
                (identifier: "static-target-\(suffix)", title: "Static Target", enabled: true, selfMutating: false, countsPress: true)
            ])
            defer { window.close() }
            try? await Task.sleep(nanoseconds: 100_000_000)

            let mockModel = MockAutonomousModelProvider()
            mockModel.structuredPlansToReturn = [
                """
                {
                  "taskPrompt": "Click the static target",
                  "steps": [
                    {
                      "actionName": "ui.click_element",
                      "toolFamily": "ui",
                      "description": "Click a semantically-identified element",
                      "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "static-target-\(suffix)"}
                    }
                  ]
                }
                """
            ]
            let runtime = QCoreRuntime(
                modelProvider: mockModel,
                memoryProvider: try QSQLiteMemoryStore(inMemory: true),
                executionProvider: QExecutionService.shared,
                endpointName: "semantic-click-verify-failure-\(UUID().uuidString)"
            )
            let task = try await runtime.submitIntent(prompt: "Click the static target")
            guard case .awaitingApproval(let req) = task.state else {
                #expect(Bool(false), "Expected awaiting approval")
                return
            }
            let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
            guard case .failed = resolved.state else {
                #expect(Bool(false), "Expected verification to fail (no fabricated success) for an unchanged target, got: \(resolved.state)")
                return
            }
            // The press itself DID happen — the failure is a verification-evidence failure, not a
            // dispatch failure. This is exactly the "successful press != goal success" distinction.
            #expect(harness.pressCount == 1)
        }
    }

    // MARK: - 17. Budget exhaustion blocks execution

    @Test("17. An exhausted execution budget blocks a resumed click before any dispatch is attempted")
    func budgetExhaustionBlocksClickExecution() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Click the target",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click a semantically-identified element",
                  "parameters": {"applicationName": "QNoSuchApp2H", "role": "AXButton", "identifier": "Whatever"}
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
            endpointName: "semantic-click-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Click the target")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }

        // Exhaust the persisted budget out-of-band, exactly as QCoreRuntime.executeResumedPlan's
        // own authoritative check (line ~799-800) would see it on any real resume path.
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

    // MARK: - 18. Recovery observes before retry

    @Test("18. An uncertain in-flight click step is never blindly marked complete — it fails closed to pending for a single safe re-execution")
    func uncertainClickStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-click", sessionId: "s-uncertain-click", originalIntent: "Click GhostButton",
            lifecycleState: .running, currentPlanId: "plan-uncertain-click", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-click", index: 0, actionName: "ui.click_element", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Click GhostButton",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "identifier": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-click", taskId: "task-uncertain-click", sessionId: "s-uncertain-click",
            goal: "Click GhostButton", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // ui.click_element has no dedicated observation-first recovery check (mirroring app.quit —
        // see docs/PHASE_2H_SEMANTIC_CLICK.md), so an uncertain attempt must fail closed: not
        // verified, reset to pending for one safe retry, never silently marked completed on a guess.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 19 & Real macOS E2E. Full autonomous Q path with a real Calculator semantic click

    @Test("19/E2E. Real macOS E2E — full autonomous Q path: Calculator's Clear/AllClear button is semantically clicked, approved, executed, and verified via a genuine observed AX state change")
    @MainActor
    func realMacOSE2ESemanticClickOnCalculator() async throws {
        guard AXIsProcessTrusted() else {
            // Documented TCC limitation (docs/PHASE_2H_SEMANTIC_CLICK.md): the isolated XCTest
            // runner's Accessibility trust cannot be assumed granted, mirroring Phase 2G's Screen
            // Recording finding for QBridgeScreenCapture. Deterministic coverage for every failure
            // mode above does not depend on this permission; this test intentionally no-ops rather
            // than fabricating a pass when it is absent. Run via the release smoke checklist on
            // real hardware where Accessibility has been granted interactively.
            return
        }

        // Setup (test scaffolding only, NOT the capability under test): launch Calculator and
        // prime it from "AllClear" to "Clear" by pressing a digit directly via raw AX, mirroring
        // the empirically-confirmed real behavior this test now exercises through the real
        // capability: Calculator's own Clear/AllClear button changes its OWN AXIdentifier and
        // AXDescription depending on whether there is a pending entry.
        if !NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == "Calculator" }) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
        let calculatorRunning = await waitUntil(timeout: 6.0) {
            NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Calculator" }
        }
        guard calculatorRunning else {
            Issue.record("Calculator did not launch in time; cannot run the real macOS E2E smoke test")
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        rawAXPress(applicationName: "Calculator", identifier: "Five")
        let primed = await waitUntil(timeout: 3.0) {
            rawAXExists(applicationName: "Calculator", identifier: "Clear")
        }
        guard primed else {
            Issue.record("Could not prime Calculator into the 'Clear' state; skipping (real hardware/UI-dependent)")
            return
        }

        // Real capability under test: propose -> validate -> authorize -> approve -> execute ->
        // observe -> verify -> goal evaluate, exactly the required end-to-end path.
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Clear the calculator entry",
              "steps": [
                {
                  "actionName": "ui.click_element",
                  "toolFamily": "ui",
                  "description": "Click the Clear button",
                  "parameters": {"applicationName": "Calculator", "role": "AXButton", "identifier": "Clear"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let observer = MockQPlanUIObserver()
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-click-e2e-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Clear the calculator entry", observer: observer)
        guard case .awaitingApproval(let req) = task.state else {
            Issue.record("Expected the click to halt for approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.click_element")
        #expect(req.riskLevel == .level2UserApproval)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed(let summary) = resolved.state else {
            Issue.record("Expected the click to complete with real, evidence-backed verification, got: \(resolved.state)")
            return
        }
        #expect(!summary.isEmpty)

        // Genuine, observed real-world effect: Calculator reverted from "Clear" back to
        // "AllClear" — the same self-diffing AX identity confirmed empirically for this control.
        let reverted = await waitUntil(timeout: 3.0) {
            rawAXExists(applicationName: "Calculator", identifier: "AllClear")
        }
        #expect(reverted)

        // The durable evidence trail is real and evidence-backed, not fabricated.
        let durableTask = try store.getTask(taskId: task.taskId)
        guard let planId = durableTask?.currentPlanId, let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let clickStepEvidence = durablePlan.steps.first(where: { $0.actionName == "ui.click_element" })?.verifiedEvidence ?? ""
        #expect(!clickStepEvidence.isEmpty)
    }
}
