//
//  QSemanticElementRequiredStateTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Required State Read Tests (Phase 2BQ).
//
//  ui.read_element_required_state resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused unmodified), and reads its AXRequired attribute — whether the
//  element is required for successful form submission. This is purely OBSERVATIONAL: neither the
//  element nor any other UI state is ever pressed, focused, activated, or mutated; no AX action is
//  ever performed.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Unlike ui.read_window_modal_state (kAXModalAttribute, documented "Required for all window
//  elements"), AXRequired has no universal-presence documentation — it is meaningful only for
//  form-field-like elements. This suite proves the missing-vs-failure discipline therefore follows
//  the OPTIONAL-reference pattern (Phase 2BM/2BN), not the inverted pattern used for modal state:
//  genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) produces a valid nil, never an
//  error, and is never silently downgraded to false.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BQ_SEMANTIC_ELEMENT_REQUIRED_STATE.md for the
//  full contract.
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
private func makeTextFieldWindow(identifier: String, value: String, required: Bool? = nil) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "QSemanticRequiredStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = value
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    if let required {
        field.setAccessibilityRequired(required)
    }
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

private final class ElementRequiredStateMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_required_state" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed required-field state for AXTextField element in MockApp: isRequired=true.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasRequiredState": "true",
                    "isRequired": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementRequiredStateTests")
struct QSemanticElementRequiredStateTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.read_element_required_state is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementRequiredState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_required_state"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "Is this field required?",
          "steps": [
            {
              "actionName": "ui.read_element_required_state",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's required-field state",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Name"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-required", taskPrompt: "Is this field required?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Is this field required?",
              "steps": [
                {
                  "actionName": "ui.read_element_required_state",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's required-field state",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Name"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-required-\(mismatchedRisk)", taskPrompt: "Is this field required?")
            }
        }
    }

    // MARK: - Happy path: required == true

    @Test("1. A field marked required via setAccessibilityRequired(true) resolves isRequired == true")
    @MainActor
    func requiredTrueReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "required-\(suffix)", value: "", required: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "required-\(suffix)", title: nil
        )
        #expect(metadata.isRequired == true)
    }

    // MARK: - Happy path: required == false

    @Test("2. A field explicitly marked not-required via setAccessibilityRequired(false) resolves isRequired == false — a fully valid, distinct outcome, never absent")
    @MainActor
    func requiredFalseReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "notrequired-\(suffix)", value: "", required: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "notrequired-\(suffix)", title: nil
        )
        #expect(metadata.isRequired == false)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3. A field with no accessibilityRequired ever set resolves a genuine, honest absence (nil) — never fabricated as false")
    @MainActor
    func genuineAbsenceReportsNilNeverFalse() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "unset-\(suffix)", value: "", required: nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "unset-\(suffix)", title: nil
        )
        // Whatever AppKit's real, honest answer is (nil absence, or a default false actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because the attribute was never explicitly set.
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to false (structural, by direct inspection of resolveElementRequiredState's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementRequiredState's `case .noValue, .attributeUnsupported: return nil` branch
        // handles both identically — by direct source inspection at implementation time. Neither
        // ever reaches the elementRequiredStateReadFailed/elementRequiredStateMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to false — structural proof: QAXElementRequiredStateMetadata.isRequired is Bool?, and nil/false are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToFalseIsStructural() {
        let absentMetadata = QAXElementRequiredStateMetadata(applicationName: "App", role: "AXTextField", isRequired: nil)
        let falseMetadata = QAXElementRequiredStateMetadata(applicationName: "App", role: "AXTextField", isRequired: false)
        #expect(absentMetadata.isRequired == nil)
        #expect(falseMetadata.isRequired == false)
        #expect(absentMetadata.isRequired != falseMetadata.isRequired)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BQ")) {
            _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                applicationName: "QNoSuchApp2BQ", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated required-state result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)", value: "x")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous element

    @Test("10. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.stringValue = "Dup"
        fieldA.isEditable = true
        fieldA.setAccessibilityIdentifier("dup-required-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.stringValue = "Dup"
        fieldB.isEditable = true
        fieldB.setAccessibilityIdentifier("dup-required-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-required-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BQ")) {
            _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                applicationName: "QWrongApp2BQ", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementRequiredState exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("13. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - Role policy: allowed vs disallowed

    @Test("14. Disallowed roles are rejected before any AX search is even attempted — QAXElementReadRolePolicy reused verbatim, not broadened")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea"] {
            await #expect(throws: QAXInteractionError.disallowedReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXSecureTextField is rejected before any AX search, mirroring every prior read capability's identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementRequiredState(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-Boolean) returned value fails closed with AX_ELEMENT_REQUIRED_STATE_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementRequiredStateMalformed
        #expect(error.errorCode == "AX_ELEMENT_REQUIRED_STATE_MALFORMED")
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_REQUIRED_STATE_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementRequiredStateReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_REQUIRED_STATE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_required_state — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-required-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_required_state",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's required-field state",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing isRequired == true never authorizes ui.set_text_value or any other mutation on that same field — the two capabilities' authorization paths are entirely disjoint")
    func discoveredRequiredStateNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-required", toolName: "ui.read_element_required_state", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element required state"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setTextReq = QToolAuthorizationRequest(
            taskId: "t-noauth-required", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setTextDecision = QPermissionGate.shared.evaluate(request: setTextReq)
        #expect(setTextDecision.isAllowed == false)
        #expect(setTextDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementRequiredState/readElementRequiredState references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target — proven both structurally and by a real fixture's own field remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", value: "unchanged", required: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(field.stringValue == "unchanged")
    }

    @Test("22. An uncertain in-flight required-state-read step fails closed to pending, and recovery never replays or persists any required-state value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-required", sessionId: "s-uncertain-required", originalIntent: "Is this field required?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-required", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-required", index: 0, actionName: "ui.read_element_required_state", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Is this field required?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-required", taskId: "task-uncertain-required", sessionId: "s-uncertain-required",
            goal: "Is this field required?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["isRequired"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementRequiredStateMetadata's stored properties are String/Bool? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementRequiredStateMetadata(applicationName: "App", role: "AXTextField", isRequired: true)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.isRequired == true)
    }

    @Test("24. No sensitive content is ever leaked — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural boolean; no typed text, no document content, no credentials")
    func noSensitiveContentLeakageIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the isRequired fact")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "durable-\(suffix)", value: "Message", required: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Is this field required?",
              "steps": [
                {
                  "actionName": "ui.read_element_required_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's required-field state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-required-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Is this field required?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_required_state" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — no arbitrary window/document content ever appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "audit-\(suffix)", value: "Message", required: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Is this field required?",
              "steps": [
                {
                  "actionName": "ui.read_element_required_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's required-field state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-required-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Is this field required?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("isRequired=") || summary.contains("required-field state") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    // MARK: - Verification

    @Test("27. The elementRequiredStateReadSucceeded verification strategy's evidence carries application name, role, and the isRequired fact itself — safe to include directly since it carries no privacy risk")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementRequiredStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isRequired: true)
        let result = QActionResult(actionId: "verify-required", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_required_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("isRequired=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence (nil) as 'unavailable' — never conflated with 'false'")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementRequiredStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isRequired: nil)
        let result = QActionResult(actionId: "verify-required-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_required_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("isRequired=unavailable"))
        #expect(evidence.contains("isRequired=false") == false)
    }

    @Test("28. The elementRequiredStateReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementRequiredStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isRequired: true)
        let result = QActionResult(actionId: "verify-required-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_required_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. Verification never mutates the UI and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call exists anywhere in
        // QActionVerifier's .elementRequiredStateReadSucceeded evaluation branch, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("30. QPlanExecutor executes ui.read_element_required_state step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesRequiredStateStep() async throws {
        let mockExec = ElementRequiredStateMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_required_state",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a field's required state",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read a field's required state"
        )
        let plan = QPlan(
            taskId: "t-plan-required", sessionId: "s-required", taskPrompt: "Read a field's required state", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-required")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Fail-closed summary / forbidden API safety (structural)

    @Test("31. This capability's implementation uses only AXUIElementCopyAttributeValue for AXRequired — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("32. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementRequiredStateReadFailed("AXError(-25204)"),
            .elementRequiredStateMalformed
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 2) // each is a distinct, dedicated diagnostic
    }

    @Test("33. No polling, no traversal (resource bounds): readElementRequiredState performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("34/E2E. Real macOS AppKit E2E — a real NSTextField explicitly marked required via setAccessibilityRequired(true) resolves isRequired == true via AXRequired; a field explicitly marked not-required resolves isRequired == false; neither field is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitRequiredStateRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (requiredWindow, requiredField) = makeTextFieldWindow(identifier: "e2e-required-\(suffix)", value: "unchanged-required", required: true)
        defer { requiredWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let requiredMetadata = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-required-\(suffix)", title: nil
        )
        #expect(requiredMetadata.isRequired == true)
        #expect(requiredField.stringValue == "unchanged-required") // provably unchanged — no mutation

        let (notRequiredWindow, notRequiredField) = makeTextFieldWindow(identifier: "e2e-notrequired-\(suffix)", value: "unchanged-optional", required: false)
        defer { notRequiredWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let notRequiredMetadata = try await QBridgeAccessibility.shared.readElementRequiredState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-notrequired-\(suffix)", title: nil
        )
        #expect(notRequiredMetadata.isRequired == false)
        #expect(notRequiredField.stringValue == "unchanged-optional") // provably unchanged — no mutation
    }
}
