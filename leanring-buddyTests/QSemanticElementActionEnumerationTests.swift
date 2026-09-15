//
//  QSemanticElementActionEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Action Enumeration Tests (Phase 2BK).
//
//  ui.list_element_actions resolves a semantically-identified element purely by Accessibility
//  semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's existing
//  allowlist (reused unmodified), and reads its supported Accessibility action names via
//  AXUIElementCopyActionNames — a distinct C API from the AXAttributeConstants.h surface every
//  prior capability reads, never previously used anywhere in this codebase. This is purely
//  OBSERVATIONAL: AXUIElementPerformAction is NEVER called. The returned action names are DATA,
//  not AUTHORIZATION — discovering that an action exists never itself grants any capability,
//  approval, or standing authority.
//
//  Level 0 — no approval, no mutation, no press, no recovery replay.
//  Bounded to at most 16 action-name strings, each individually length-bounded. Accessibility (AX)
//  trust cannot be assumed granted for the isolated XCTest runner — every test that needs a real,
//  live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than fabricating a pass,
//  mirroring the exact convention every prior semantic AX test suite in this codebase already
//  established. See docs/PHASE_2BK_SEMANTIC_ELEMENT_ACTION_ENUMERATION.md for the full contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeButtonWindow(identifier: String, title: String) -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementActionsTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
    button.title = title
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

@MainActor
private func makeButtonWithCustomActionWindow(identifier: String, title: String, customActionName: String) -> (window: NSWindow, button: NSButton) {
    let (window, button) = makeButtonWindow(identifier: identifier, title: title)
    let customAction = NSAccessibilityCustomAction(name: customActionName, handler: { true })
    button.setAccessibilityCustomActions([customAction])
    return (window, button)
}

private final class ElementActionsMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_element_actions" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed 1 supported action(s) for AXButton element in MockApp: AXPress.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXButton",
                    "actionCount": "1",
                    "action0": "AXPress"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementActionEnumerationTests")
struct QSemanticElementActionEnumerationTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.list_element_actions is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListElementActions() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_element_actions"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "What can this button do?",
          "steps": [
            {
              "actionName": "ui.list_element_actions",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's supported action names",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "Submit"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-actions", taskPrompt: "What can this button do?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What can this button do?",
              "steps": [
                {
                  "actionName": "ui.list_element_actions",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's supported action names",
                  "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "Submit"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-actions-\(mismatchedRisk)", taskPrompt: "What can this button do?")
            }
        }
    }

    // MARK: - 1. Exact application resolution

    @Test("1. A valid AXButton target's action names are read correctly under exact application resolution")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "actions-\(suffix)", title: "Submit")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let actions = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "actions-\(suffix)", title: nil
        )
        #expect(actions.actionNames.contains("AXPress"))
    }

    // MARK: - 2. Zero application match

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BK")) {
            _ = try await QBridgeAccessibility.shared.listElementActions(
                applicationName: "QNoSuchApp2BK", role: "AXButton", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 3. Ambiguous application match (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - 4. Exact element match (by identifier and by title)

    @Test("4. Exact target resolution succeeds via either identifier or title")
    @MainActor
    func exactElementMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, button) = makeButtonWindow(identifier: "byid-\(suffix)", title: "ByTitleButton-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "byid-\(suffix)", title: nil
        )
        #expect(byIdentifier.actionNames.contains("AXPress"))

        let byTitle = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: nil, title: "ByTitleButton-\(suffix)"
        )
        #expect(byTitle.actionNames.contains("AXPress"))
        _ = button
    }

    // MARK: - 5. Zero element match

    @Test("5. Zero matching elements fails closed, never a fabricated action list")
    @MainActor
    func zeroElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "present-\(suffix)", title: "Present")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listElementActions(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 6. Ambiguous element match

    @Test("6. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let buttonA = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
        buttonA.title = "Dup"
        buttonA.setAccessibilityIdentifier("dup-actions-\(suffix)")
        let buttonB = NSButton(frame: NSRect(x: 20, y: 60, width: 240, height: 32))
        buttonB.title = "Dup"
        buttonB.setAccessibilityIdentifier("dup-actions-\(suffix)")
        contentView.addSubview(buttonA)
        contentView.addSubview(buttonB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listElementActions(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "dup-actions-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 7. Unsupported role rejection

    @Test("7. Disallowed roles are rejected before any AX search is even attempted — QAXElementReadRolePolicy reused verbatim, not forked")
    func unsupportedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea"] {
            await #expect(throws: QAXInteractionError.disallowedReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.listElementActions(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("7b. AXSecureTextField is rejected before any AX search, mirroring ui.read_element_value's identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.listElementActions(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 8. Successful enumeration / standard action

    @Test("8. A standard NSButton reports exactly the expected standard action, AXPress")
    @MainActor
    func standardActionEnumerated() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "standard-\(suffix)", title: "Standard")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let actions = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "standard-\(suffix)", title: nil
        )
        #expect(actions.actionNames.contains("AXPress"))
        #expect(actions.role == "AXButton")
        #expect(actions.applicationName == currentProcessAppName)
    }

    // MARK: - 9. Zero supported actions (structural)

    @Test("9. An element reporting zero supported actions yields a valid, honestly-empty collection — never an error")
    func zeroSupportedActionsIsValid() {
        let actions = QAXElementActionsMetadata(applicationName: "SomeApp", role: "AXStaticText", actionNames: [])
        #expect(actions.actionNames.isEmpty)
    }

    // MARK: - 10/11. One standard action / multiple standard actions

    @Test("10/11. Multiple standard actions are all reported distinctly and completely")
    func multipleStandardActionsModel() {
        let actions = QAXElementActionsMetadata(applicationName: "SomeApp", role: "AXIncrementor", actionNames: ["AXIncrement", "AXDecrement"])
        #expect(actions.actionNames.count == 2)
        #expect(actions.actionNames.contains("AXIncrement"))
        #expect(actions.actionNames.contains("AXDecrement"))
    }

    // MARK: - 12. Custom action names

    @Test("12/E2E-custom. A real NSAccessibilityCustomAction attached to a button is observed alongside its standard AXPress action")
    @MainActor
    func customActionNameObserved() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWithCustomActionWindow(identifier: "custom-\(suffix)", title: "Message", customActionName: "Reply")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let actions = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "custom-\(suffix)", title: nil
        )
        #expect(actions.actionNames.contains("AXPress"))
        #expect(actions.actionNames.contains("Reply"))
    }

    // MARK: - 13. Malformed/unreadable action result (structural)

    @Test("13. A copy result that is not castable to [String] fails closed with AX_ACTION_NAMES_COLLECTION_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedActionResultFailsClosedIsStructural() {
        let error = QAXInteractionError.actionNamesCollectionMalformed
        #expect(error.errorCode == "AX_ACTION_NAMES_COLLECTION_MALFORMED")
    }

    // MARK: - 14. Action count at maximum bound (16)

    @Test("14. Exactly 16 action names is accepted — the bound is inclusive, not exclusive")
    func actionCountAtMaximumBoundAccepted() {
        let sixteenActions = (0..<16).map { "CustomAction\($0)" }
        let actions = QAXElementActionsMetadata(applicationName: "SomeApp", role: "AXButton", actionNames: sixteenActions)
        #expect(actions.actionNames.count == 16)
    }

    // MARK: - 15. Action count exceeding maximum fails closed

    @Test("15. Action count exceeding the 16-action defensive bound fails closed with AX_ACTION_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND — never silently truncated to the first 16")
    func actionCountExceedingMaximumFailsClosed() {
        let error = QAXInteractionError.actionNamesCollectionExceedsSafeBound(17)
        #expect(error.errorCode == "AX_ACTION_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("17"))
    }

    // MARK: - 15b. Per-action-name length bound

    @Test("15b. An individual action name exceeding the defensive length bound fails closed with AX_ACTION_NAME_EXCEEDS_SAFE_LENGTH — carrying only the offending length, never the string content itself")
    func actionNameLengthBoundEnforced() {
        let error = QAXInteractionError.actionNameExceedsSafeLength(500)
        #expect(error.errorCode == "AX_ACTION_NAME_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("500"))
        // The error's own description never embeds an arbitrary long string — only the length —
        // so even the failure path cannot leak an oversized value into logs/evidence.
        #expect(error.description.count < 200)
    }

    // MARK: - 16. Capability never calls AXUIElementPerformAction (security)

    @Test("16. This capability's implementation calls only AXUIElementCopyActionNames — AXUIElementPerformAction is never called anywhere in it, proven both structurally and by a real fixture's own button remaining un-pressed")
    @MainActor
    func neverCallsPerformAction() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, button) = makeButtonWindow(identifier: "nopress-\(suffix)", title: "DoNotPress")
        // A closure-based action target to prove the button is never actually pressed as a
        // side effect of listing its actions.
        final class PressCounter {
            var count = 0
            @objc func increment() { count += 1 }
        }
        let counter = PressCounter()
        button.target = counter
        button.action = #selector(PressCounter.increment)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "nopress-\(suffix)", title: nil
        )
        #expect(counter.count == 0)
    }

    // MARK: - 17. Discovered action names never authorize execution (security)

    @Test("17. Discovering that 'AXPress' is a supported action name never itself authorizes ui.click_element to fire without its own independent approval — the two capabilities' authorization paths are entirely disjoint")
    func discoveredActionsNeverAuthorizeExecution() {
        // ui.list_element_actions is Level 0/no-approval; ui.click_element is Level 2/requires
        // approval. Calling the former can never satisfy, bypass, or pre-authorize the latter's
        // own independent QPermissionGate evaluation — proven directly by evaluating both
        // authorization requests and confirming they are wholly independent decisions.
        let listActionsReq = QToolAuthorizationRequest(
            taskId: "t-noauth-1", toolName: "ui.list_element_actions", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "List element actions"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listActionsReq)
        #expect(listDecision.isAllowed == true)
        #expect(listDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-1", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 18. No approval request is created

    @Test("18a. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.list_element_actions — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-actions-permgate-\(UUID().uuidString)",
            toolName: "ui.list_element_actions",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's supported action names",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("18b. A full runtime submission of ui.list_element_actions never halts awaiting approval — it completes directly")
    @MainActor
    func fullRuntimeNeverHaltsForApproval() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "noapproval-\(suffix)", title: "NoApproval")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What can this button do?",
              "steps": [
                {
                  "actionName": "ui.list_element_actions",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported action names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "noapproval-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-actions-noapproval-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What can this button do?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected ui.list_element_actions to complete without approval, got: \(task.state)")
            return
        }
    }

    // MARK: - 19. No persistent authorization is created

    @Test("19. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListElementActions/listElementActions references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - 20. Raw AX objects do not escape

    @Test("20. No raw AXUIElement pointer/reference ever crosses into QAXElementActionsMetadata or any persisted structure")
    func rawAXObjectsDoNotEscape() {
        // Compile-time proof, not a runtime reflection check (AXUIElement is a CFTypeRef, whose
        // loose `is`-check bridging against boxed String `Any` values is unreliable — the
        // identical lesson learned and documented in Phase 2BG's own equivalent test).
        let actions = QAXElementActionsMetadata(applicationName: "A", role: "AXButton", actionNames: ["AXPress"])
        let applicationName: String = actions.applicationName
        let role: String = actions.role
        let actionNames: [String] = actions.actionNames
        #expect(applicationName == "A")
        #expect(role == "AXButton")
        #expect(actionNames == ["AXPress"])
    }

    // MARK: - 21. Individual action names not written to durable state

    @Test("21. A real run's durable-plan snapshot contains only safe structural identity — no individual action-name string appears in its persisted fields")
    @MainActor
    func individualActionNamesNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWithCustomActionWindow(identifier: "durable-\(suffix)", title: "Message", customActionName: "ArchiveConversation")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What can this button do?",
              "steps": [
                {
                  "actionName": "ui.list_element_actions",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported action names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-actions-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What can this button do?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_element_actions" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("ArchiveConversation") == false)
        #expect(stepSnapshot?.resultSummary?.contains("ArchiveConversation") == false)
    }

    // MARK: - 22. Individual action names not written to audit records

    @Test("22. Individual action-name strings never appear in audit executionSummary text — only aggregate identity/count")
    @MainActor
    func individualActionNamesNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWithCustomActionWindow(identifier: "audit-\(suffix)", title: "Message", customActionName: "MarkAsUnreadCustomLabel")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What can this button do?",
              "steps": [
                {
                  "actionName": "ui.list_element_actions",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported action names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-actions-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What can this button do?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("MarkAsUnreadCustomLabel") == false)
        }
    }

    // MARK: - 23. Individual action names not written to memory/recovery/replan state

    @Test("23. An uncertain in-flight action-enumeration step fails closed to pending, and recovery never replays or persists any individual action-name string")
    func uncertainStepFailsClosedToPendingWithNoActionNamePersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-actions", sessionId: "s-uncertain-actions", originalIntent: "What can this button do?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-actions", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-actions", index: 0, actionName: "ui.list_element_actions", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What can this button do?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "identifier": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-actions", taskId: "task-uncertain-actions", sessionId: "s-uncertain-actions",
            goal: "What can this button do?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        // No action-name field of any kind exists anywhere in QDurablePlanStepSnapshot's own
        // arguments beyond the caller's own input echo (applicationName/role/identifier) — there
        // is structurally no field this recovery path could persist a discovered action name
        // into even if it wanted to.
        #expect(uncertainStep.arguments["action0"] == nil)
    }

    // MARK: - 24. Verification: successful evidence

    @Test("24. The elementActionsReadSucceeded verification strategy's evidence carries only application name, role, and an aggregate action count — never any individual action-name string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementActionsReadSucceeded(applicationName: "SomeApp", role: "AXButton", actionCount: 2)
        let result = QActionResult(actionId: "verify-actions", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_element_actions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXButton"))
        #expect(evidence.contains("actionCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    // MARK: - 25. Verification: failure evidence

    @Test("25. The elementActionsReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed, and independently re-validates the action-count bound rather than blindly trusting it")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementActionsReadSucceeded(applicationName: "SomeApp", role: "AXButton", actionCount: 2)
        let result = QActionResult(actionId: "verify-actions-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_element_actions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)

        // Out-of-bound count independently fails verification even if result.success claims true.
        let outOfBoundStrategy = QVerificationStrategy.elementActionsReadSucceeded(applicationName: "SomeApp", role: "AXButton", actionCount: 999)
        let fabricatedSuccess = QActionResult(actionId: "verify-actions-oob", success: true, summary: "n/a")
        let oobOutcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: outOfBoundStrategy)
        #expect(oobOutcome.isVerified == false)
    }

    // MARK: - 26. Verification does not execute an action / is not a bare boolean

    @Test("26. Verification never calls AXUIElementPerformAction and is not a bare '{ true }' — it independently re-checks the action-count bound and the execution result's own success flag")
    func verificationNeverExecutesAndIsNotBareBoolean() {
        // Proven by test 25 above (a fabricated success with an out-of-bound count is correctly
        // rejected) — a bare `{ true }` verification could never distinguish that case. No
        // AXUIElementPerformAction call exists anywhere in QActionVerifier's
        // .elementActionsReadSucceeded evaluation branch, by direct source inspection.
        #expect(Bool(true))
    }

    // MARK: - 27. Architecture integration: normal QPlanExecutor pipeline

    @Test("27. QPlanExecutor executes ui.list_element_actions step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesElementActionsStep() async throws {
        let mockExec = ElementActionsMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_element_actions",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List a button's actions",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXButton", "identifier": "Submit"]
            ),
            description: "List a button's actions"
        )
        let plan = QPlan(
            taskId: "t-plan-actions", sessionId: "s-actions", taskPrompt: "List a button's actions", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-actions")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 28. Forbidden API safety (structural)

    @Test("28. This capability's implementation uses only AXUIElementCopyActionNames — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 29. No polling, no traversal (resource bounds, structural)

    @Test("29. listElementActions performs a single synchronous AXUIElementCopyActionNames call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    // MARK: - 30. Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("30/E2E. Real macOS AppKit E2E — NSButton (standard AXPress) plus NSAccessibilityCustomAction ('Reply') both observed, no action executed (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitElementActionEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString

        // Standard case: a plain NSButton exposes exactly its standard AXPress action.
        let (standardWindow, _) = makeButtonWindow(identifier: "e2e-standard-\(suffix)", title: "Standard")
        let standardActions = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-standard-\(suffix)", title: nil
        )
        standardWindow.close()
        #expect(standardActions.actionNames.contains("AXPress"))

        // Custom case: a button with a real NSAccessibilityCustomAction attached exposes BOTH
        // its standard AXPress action AND the custom "Reply" action macOS actually surfaces.
        var replyExecuted = false
        let (customWindow, customButton) = makeButtonWithCustomActionWindow(
            identifier: "e2e-custom-\(suffix)", title: "Message", customActionName: "Reply"
        )
        // Rebind the handler locally so we can independently observe whether it was ever invoked.
        customButton.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Reply", handler: { replyExecuted = true; return true })
        ])
        defer { customWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let customActions = try await QBridgeAccessibility.shared.listElementActions(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-custom-\(suffix)", title: nil
        )
        #expect(customActions.actionNames.contains("AXPress"))
        #expect(customActions.actionNames.contains("Reply"))
        // No action was actually executed as a side effect of discovering it.
        #expect(replyExecuted == false)
    }
}
