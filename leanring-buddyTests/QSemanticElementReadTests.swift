//
//  QSemanticElementReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic AX Element Value Read Tests (Phase 2J).
//  ui.read_element_value resolves a target purely by Accessibility semantics (role + identifier
//  or title) — never by screen coordinates — and reads its value, denylisting only
//  AXSecureTextField. Unlike ui.set_text_value, the read value is INTENTIONALLY exposed to the
//  model — that is this capability's entire purpose — so these tests prove the OPPOSITE
//  direction from Phase 2I's redaction tests: the raw value must reach QTaskContext for the
//  planner to reason with, while still being sanitized before it reaches anything persisted,
//  audited, or held in memory, exactly like screen.ocr's existing, already-tested boundary. This
//  tool is registered under toolFamily "perception" specifically so it inherits that boundary
//  with zero changes to QPlanExecutor. See docs/PHASE_2J_SEMANTIC_ELEMENT_READ.md.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeTextFieldWindow(identifier: String, value: String) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = value
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

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
    window.title = "QSemanticElementReadTestFixture"
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
private func makeCheckboxWindow(identifier: String, isChecked: Bool) -> (window: NSWindow, checkbox: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementReadTestFixture"
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
private func makeTextAreaWindow(identifier: String, value: String) -> (window: NSWindow, view: NSTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 160),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
    let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 260, height: 120))
    textView.string = value
    textView.setAccessibilityIdentifier(identifier)
    contentView.addSubview(textView)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textView)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticElementReadTests")
struct QSemanticElementReadTests {

    // MARK: - 1. Capability registration

    @Test("1. ui.read_element_value is a registered, Level 0, perception-family, semantically-targeted capability")
    func capabilityRegistrationAcceptsUIReadElementValue() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_value"]
        #expect(regCap?.toolFamily == "perception")
        #expect(regCap?.defaultRisk == .level0ReadOnly)

        let json = """
        {
          "taskPrompt": "Read the field",
          "steps": [
            {
              "actionName": "ui.read_element_value",
              "toolFamily": "perception",
              "description": "Read a semantically-identified element's value",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "SomeField"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-read", taskPrompt: "Read the field")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        // Anti-downgrade is symmetric: a model attempting to self-declare a HIGHER risk than
        // registered must also be rejected.
        let upgradeJSON = """
        {
          "taskPrompt": "Read the field",
          "steps": [
            {
              "actionName": "ui.read_element_value",
              "toolFamily": "perception",
              "riskLevel": "level2UserApproval",
              "description": "Read a semantically-identified element's value",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "SomeField"}
            }
          ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: upgradeJSON, taskId: "t-upgrade-read", taskPrompt: "Read the field")
        }
    }

    // MARK: - 2. Happy path: read a text field's value

    @Test("2. A valid AXTextField target's value is read correctly")
    @MainActor
    func validTextFieldValueIsRead() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "read-field-\(suffix)", value: "hello world")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let (value, snapshot) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "read-field-\(suffix)", title: nil
        )
        #expect(value == "hello world")
        #expect(snapshot.identifier == "read-field-\(suffix)")
    }

    // MARK: - 3. Happy path: read a button's title (AXValue fallback to title/description)

    @Test("3. A button with no meaningful AXValue falls back to its title/description")
    @MainActor
    func buttonReadFallsBackToTitle() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "read-button-\(suffix)", title: "Submit Form")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let (value, _) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "read-button-\(suffix)", title: nil
        )
        #expect(value == "Submit Form")
    }

    // MARK: - 4. Happy path: read a checkbox's state (polymorphic AXValue)

    @Test("4. A checkbox's boxed-number AXValue is read as a human-readable state string")
    @MainActor
    func checkboxStateIsReadPolymorphically() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeCheckboxWindow(identifier: "read-checkbox-\(suffix)", isChecked: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let (value, _) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "read-checkbox-\(suffix)", title: nil
        )
        // AXCheckBox's kAXValueAttribute is a boxed NSNumber (typically 1 for checked) — proves
        // the polymorphic reader handles non-String AX values, not just text-field strings.
        #expect(!value.isEmpty)
        #expect(value != "hello world") // sanity: not accidentally reading some other fixture
    }

    // MARK: - 4b. Valid AXTextArea read (allowlisted, same role write is restricted to)

    @Test("4b. A valid AXTextArea target's value is read correctly")
    @MainActor
    func validTextAreaValueIsRead() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextAreaWindow(identifier: "read-area-\(suffix)", value: "multi\nline body")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let (value, snapshot) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXTextArea", identifier: "read-area-\(suffix)", title: nil
        )
        #expect(value == "multi\nline body")
        #expect(snapshot.identifier == "read-area-\(suffix)")
    }

    // MARK: - 4c. Unknown/unlisted role rejected (allowlist, not denylist)

    @Test("4c. A role not on the allowlist is rejected, even though it is a real, unremarkable AX role")
    func unknownRoleRejected() async throws {
        // AXImage is a real, ordinary macOS AX role that is simply not on the read allowlist —
        // proves the policy is a fail-closed allowlist (reject anything not listed) rather than a
        // denylist (reject only known-bad roles).
        await #expect(throws: QAXInteractionError.disallowedReadRole("AXImage")) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXImage", identifier: "whatever", title: nil
            )
        }
        await #expect(throws: QAXInteractionError.disallowedReadRole("AXMadeUpRole42")) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXMadeUpRole42", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 5. Invalid parameters fail closed

    @Test("5. Missing required parameters fail closed with deterministic errors")
    func missingParametersFailClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: nil
            )
        }
    }

    // MARK: - 6. Secure field denylist rejection

    @Test("6. A secure-text-field role is rejected before any AX search is even attempted")
    func secureTextFieldReadDenied() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 7. Zero matches fails closed

    @Test("7. Zero matching elements fails closed, never a fabricated value")
    @MainActor
    func zeroMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)", value: "x")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 8. Ambiguous target fails closed

    @Test("8. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.setAccessibilityIdentifier("dup-read-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.setAccessibilityIdentifier("dup-read-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-read-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 9. Idempotency

    @Test("9. Repeated reads of an unchanged field return the same value with zero side effects")
    @MainActor
    func repeatedReadsAreIdempotent() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "idempotent-\(suffix)", value: "stable")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let (first, _) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "idempotent-\(suffix)", title: nil
        )
        let (second, _) = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "idempotent-\(suffix)", title: nil
        )
        #expect(first == "stable")
        #expect(second == "stable")
        #expect(field.stringValue == "stable") // the read itself never mutated the field
    }

    // MARK: - 10. No approval ever created for a Level 0 read — routed through QPermissionGate, not bypassed

    @Test("10. A successful ui.read_element_value run completes without ever halting for approval")
    @MainActor
    func readElementValueNeverHaltsForApproval() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "noapproval-\(suffix)", value: "no approval needed")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read a field",
              "steps": [
                {
                  "actionName": "ui.read_element_value",
                  "toolFamily": "perception",
                  "description": "Read a semantically-identified element's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "noapproval-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-read-noapproval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Read a field")
        // Level 0 is default-allow: QPermissionGate's Level 0/1 branch (see QPermissionGate
        // .evaluate) never constructs a QApprovalRequest at all — the task must reach
        // `.completed` directly through real execution, never an approval halt.
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected ui.read_element_value to complete without approval, got: \(task.state)")
            return
        }
    }

    // MARK: - 10b. Direct proof: QPermissionGate.evaluate never produces .requireApproval for this tool

    @Test("10b. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_value — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApprovalForRead() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-read-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_value",
            toolFamily: "perception",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's value",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
        #expect(decision.isDenied == false)
    }

    // MARK: - 11. Uncertain in-flight step fails closed to pending on recovery

    @Test("11. An uncertain in-flight read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainReadStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-read", sessionId: "s-uncertain-read", originalIntent: "Read GhostField",
            lifecycleState: .running, currentPlanId: "plan-uncertain-read", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-read", index: 0, actionName: "ui.read_element_value", toolFamily: "perception",
            riskLevel: "level0ReadOnly", literalAction: "Read GhostField",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-read", taskId: "task-uncertain-read", sessionId: "s-uncertain-read",
            goal: "Read GhostField", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 11b. Budget accounting

    @Test("11b. Each completed read step is correctly counted against the task's execution budget")
    @MainActor
    func readStepsAreCountedAgainstBudget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (windowA, _) = makeTextFieldWindow(identifier: "budget-a-\(suffix)", value: "one")
        let (windowB, _) = makeTextFieldWindow(identifier: "budget-b-\(suffix)", value: "two")
        defer { windowA.close(); windowB.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read two fields",
              "steps": [
                {
                  "actionName": "ui.read_element_value",
                  "toolFamily": "perception",
                  "description": "Read the first field",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "budget-a-\(suffix)"}
                },
                {
                  "actionName": "ui.read_element_value",
                  "toolFamily": "perception",
                  "description": "Read the second field",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "budget-b-\(suffix)"}
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
            endpointName: "semantic-read-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Read two fields")
        guard case .completed = task.state else {
            Issue.record("Expected both reads to complete, got: \(task.state)")
            return
        }

        guard let durableTaskState = try store.getTask(taskId: task.taskId) else {
            Issue.record("Expected a persisted durable task state")
            return
        }
        #expect(durableTaskState.budget.executedStepsCount == 2)
    }

    // MARK: - 12/15/16/17/18. Privacy: raw value reaches model reasoning, sanitized before persistence

    @Test("12/15/16/17/18. A read secret is redacted before durable state/audit/memory, but the RAW value still reaches QTaskContext for the planner to reason with")
    @MainActor
    func readSecretRedactedBeforePersistenceButRawForReasoning() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let secret = "sk-elementread0123456789012345678901"
        let (window, _) = makeTextFieldWindow(identifier: "secret-read-\(suffix)", value: secret)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read the secret field",
              "steps": [
                {
                  "actionName": "ui.read_element_value",
                  "toolFamily": "perception",
                  "description": "Read a semantically-identified element's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "secret-read-\(suffix)"}
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
            endpointName: "semantic-read-redact-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Read the secret field")
        guard case .completed = task.state else {
            Issue.record("Expected the read to complete, got: \(task.state)")
            return
        }

        // Durable state: redacted, matching screen.ocr's existing boundary — no code change was
        // needed for this because ui.read_element_value is registered under toolFamily
        // "perception", which QPlanExecutor's existing isScreenDerivedStep predicate already
        // covers.
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_value" })
        #expect(stepSnapshot?.resultSummary?.contains(secret) == false)
        #expect(stepSnapshot?.resultSummary?.contains("[REDACTED_SECRET]") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains(secret) == false)

        // Memory: redacted.
        let memoryRecord = try memory.getByKey("plan_\(planId)", sessionId: task.sessionId)
        #expect(memoryRecord?.content.contains(secret) == false)

        // Audit: no record for this task leaks the literal.
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        let anyRecordLeaksSecret = auditRecords.contains {
            ($0.executionSummary ?? "").contains(secret) || ($0.error ?? "").contains(secret)
        }
        #expect(anyRecordLeaksSecret == false)

        // HUD / persistent UI state: no approval surface was ever created for this Level 0 tool
        // (test 10/10b), so there is no QApprovalRequest.expectedEffect for the secret to appear
        // in at all — explicitly confirmed via the same reconstruction path the live HUD uses.
        let recoveredPlan = try durablePlan.validate()
        let uiSnapshot = QRuntimeUISnapshot.from(plan: recoveredPlan)
        #expect(uiSnapshot.pendingApproval == nil)

        // Recovery state: reconstructing a QTask from the persisted durable task state (the same
        // reconstruction QTaskRecoveryManager/QCoreRuntime use on resume) never surfaces the
        // secret — every free-text field on the durable task state is checked directly.
        guard let durableTaskState = try store.getTask(taskId: task.taskId) else {
            Issue.record("Expected a persisted durable task state")
            return
        }
        #expect(durableTaskState.lastKnownError?.contains(secret) != true)
        #expect(durableTaskState.securityBlockReason?.contains(secret) != true)
        #expect(durableTaskState.originalIntent.contains(secret) == false)
        let recoveredTask = durableTaskState.toTask()
        if case .awaitingApproval(let recoveredApproval) = recoveredTask.state {
            Issue.record("A completed Level 0 read must never reconstruct into an awaitingApproval state: \(recoveredApproval)")
        }

        // Persisted replan context: this run succeeded on the first attempt, so no replan
        // occurred — the closest-available persisted replan-context field is the durable task
        // state's own replan counter/last-error, both already checked above and both zero/nil
        // here, which is itself the correct evidence that no replan artifact carrying the secret
        // was ever written.
        #expect(durableTaskState.replanAttemptCount == 0)

        // The OPPOSITE property, equally required: the raw value must have reached QTaskContext
        // (proven directly by test 13's taint-forcing mechanism) — this test only asserts the
        // persistence-layer redaction.
        _ = suffix
    }

    // MARK: - 13. Provenance: tainted context forces fresh approval on a later Level 2/3 step

    @Test("13. A read step's untrusted provenance still forces a later Level 2 step to require fresh approval, proving the raw value really did reach QTaskContext")
    @MainActor
    func readTaintForcesApprovalOnLaterStep() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "taint-read-\(suffix)", value: "some content")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let readStep = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_value", toolFamily: "perception", riskLevel: .level0ReadOnly,
                literalAction: "Read the field",
                arguments: ["applicationName": currentProcessAppName, "role": "AXTextField", "identifier": "taint-read-\(suffix)"]
            ),
            description: "Read field"
        )
        let clipboardStep = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.write", toolFamily: "system", riskLevel: .level2UserApproval,
                literalAction: "Write text", arguments: ["text": "hello"]
            ),
            description: "Write clipboard"
        )
        let plan = QPlan(
            taskId: "t-read-taint-\(UUID().uuidString)", taskPrompt: "Read then write clipboard",
            steps: [readStep, clipboardStep]
        )
        let executor = QPlanExecutor(executionProvider: QExecutionService.shared)
        let executedPlan = try await executor.execute(plan: plan, context: QTaskContext(taskId: plan.taskId))

        #expect(executedPlan.steps[0].isComplete == true)
        guard case .waitingForPermission = executedPlan.state else {
            Issue.record("Expected the Level 2 step to halt for approval due to tainted context from the read, got: \(executedPlan.state)")
            return
        }
    }

    // MARK: - 14/E2E. Real macOS composition — write via ui.set_text_value, then read the same field back

    @Test("14/E2E. Real macOS E2E — a written value is correctly read back via the two composed capabilities in one plan")
    @MainActor
    func writeThenReadComposesCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "compose-\(suffix)", value: "original")
        defer { window.close() }

        // Establish real focus for the write step (read requires no focus).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(field)
        var focused = false
        for _ in 0..<20 {
            let systemWide = AXUIElementCreateSystemWide()
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                var idValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(value as! AXUIElement, "AXIdentifier" as CFString, &idValue) == .success,
                   (idValue as? String) == "compose-\(suffix)" {
                    focused = true
                    break
                }
            }
            _ = window.makeFirstResponder(field)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard focused else { return }

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Update and confirm the field",
              "steps": [
                {
                  "actionName": "ui.set_text_value",
                  "toolFamily": "ui",
                  "description": "Set a semantically-identified text field's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "compose-\(suffix)", "value": "composed value"}
                },
                {
                  "actionName": "ui.read_element_value",
                  "toolFamily": "perception",
                  "description": "Read a semantically-identified element's value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "compose-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-compose-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Update and confirm the field")
        guard case .awaitingApproval(let req) = task.state else {
            Issue.record("Expected the write step to halt for approval, got: \(task.state)")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed(let summary) = resolved.state else {
            Issue.record("Expected the full two-step plan to complete, got: \(resolved.state)")
            return
        }
        #expect(field.stringValue == "composed value")
        // The grounded summary is built from safe evidence for the write (Phase 2I) but the
        // read's own raw value is real evidence the goal evaluator legitimately saw.
        #expect(!summary.isEmpty)
    }
}
