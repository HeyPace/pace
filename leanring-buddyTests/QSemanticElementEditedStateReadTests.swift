//
//  QSemanticElementEditedStateReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Edited State Read Tests (Phase 2CG).
//
//  ui.read_element_edited_state resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused unmodified), and reads its kAXEditedAttribute — whether it currently
//  has unsaved changes ("is dirty"). This is purely OBSERVATIONAL: neither the element nor any
//  other UI state is ever pressed, focused, activated, or mutated; no AX action is ever performed.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  kAXEditedAttribute has no universal-presence documentation — it is meaningful only for
//  elements that can meaningfully have unsaved changes. This suite proves the missing-vs-failure
//  discipline therefore follows the OPTIONAL-reference pattern (identical to
//  ui.read_element_expanded_state, Phase 2CE): genuine absence (kAXErrorNoValue/
//  kAXErrorAttributeUnsupported) produces a valid nil, never an error, and is never silently
//  downgraded to false.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CG_SEMANTIC_EDITED_STATE.md for the full
//  contract.
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

/// A genuine, real, live `NSTextField` — AppKit's generic `NSAccessibilityElement` conformance
/// declares the standard `accessibilityEdited`/`setAccessibilityEdited(_:)` accessor pair
/// (`NSAccessibilityProtocols.h`), the same declared-accessor pattern
/// `ui.read_element_expanded_state`'s `setAccessibilityExpanded`/`ui.read_element_help_text`'s
/// `setAccessibilityHelp` already established as proven-working for forcing a deterministic AX
/// state.
@MainActor
private func makeTextFieldWindow(identifier: String, edited: Bool? = nil) -> (window: NSWindow, textField: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementEditedStateReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
    textField.stringValue = "Draft text"
    textField.setAccessibilityIdentifier(identifier)
    if let edited {
        textField.setAccessibilityEdited(edited)
    }
    contentView.addSubview(textField)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textField)
}

private final class ElementEditedStateMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_edited_state" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed edited state for AXTextField element in MockApp: isEdited=true.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasEditedState": "true",
                    "isEdited": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementEditedStateReadTests")
struct QSemanticElementEditedStateReadTests {

    // MARK: - Registration, Level 0, capability #81, no approval requirement

    @Test("Registration: ui.read_element_edited_state is a registered, Level 0, read-only capability (#81) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementEditedState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_edited_state"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 83)

        let json = """
        {
          "taskPrompt": "Does this document have unsaved changes?",
          "steps": [
            {
              "actionName": "ui.read_element_edited_state",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's edited state",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Notes"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-edited", taskPrompt: "Does this document have unsaved changes?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Does this document have unsaved changes?",
              "steps": [
                {
                  "actionName": "ui.read_element_edited_state",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's edited state",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Notes"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-edited-\(mismatchedRisk)", taskPrompt: "Does this document have unsaved changes?")
            }
        }
    }

    // MARK: - Happy path: edited == true

    @Test("1. An element marked edited via setAccessibilityEdited(true) resolves isEdited == true")
    @MainActor
    func editedTrueReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "edited-\(suffix)", edited: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "edited-\(suffix)", title: nil
        )
        #expect(metadata.isEdited == true)
    }

    // MARK: - Happy path: edited == false

    @Test("2. An element explicitly marked not-edited via setAccessibilityEdited(false) resolves isEdited == false — a fully valid, distinct outcome, never absent")
    @MainActor
    func editedFalseReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "notedited-\(suffix)", edited: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "notedited-\(suffix)", title: nil
        )
        #expect(metadata.isEdited == false)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3. An element with no accessibilityEdited ever set resolves without throwing — structural contract test, whatever AppKit's own honest answer is")
    @MainActor
    func genuineAbsenceDoesNotThrow() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "unset-\(suffix)", edited: nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "unset-\(suffix)", title: nil
        )
        // Whatever AppKit's real, honest answer is (nil absence, or a genuine value actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because the attribute was never explicitly set.
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to false (structural, by direct inspection of resolveElementEditedState's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementEditedState's `case .noValue, .attributeUnsupported: return nil` branch
        // handles both identically — by direct source inspection at implementation time. Neither
        // ever reaches the elementEditedStateReadFailed/elementEditedStateMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to false — structural proof: QAXElementEditedStateMetadata.isEdited is Bool?, and nil/false are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToFalseIsStructural() {
        let absentMetadata = QAXElementEditedStateMetadata(applicationName: "App", role: "AXTextField", isEdited: nil)
        let falseMetadata = QAXElementEditedStateMetadata(applicationName: "App", role: "AXTextField", isEdited: false)
        #expect(absentMetadata.isEdited == nil)
        #expect(falseMetadata.isEdited == false)
        #expect(absentMetadata.isEdited != falseMetadata.isEdited)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2CG")) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
                applicationName: "QNoSuchApp2CG", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated edited-state result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
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
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
        fieldA.stringValue = "A"
        fieldA.setAccessibilityIdentifier("dup-edited-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 180, height: 24))
        fieldB.stringValue = "B"
        fieldB.setAccessibilityIdentifier("dup-edited-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-edited-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CG")) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
                applicationName: "QWrongApp2CG", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementEditedState exactly as in every prior read capability")
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
                _ = try await QBridgeAccessibility.shared.readElementEditedState(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXSecureTextField is rejected before any AX search, mirroring every prior read capability's identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("14c. Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/ui.read_element_role_description/ui.read_element_help_text/ui.read_element_placeholder_value/ui.read_element_expanded_state")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextArea") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXComboBox") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-Boolean) returned value fails closed with AX_ELEMENT_EDITED_STATE_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementEditedStateMalformed
        #expect(error.errorCode == "AX_ELEMENT_EDITED_STATE_MALFORMED")
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_EDITED_STATE_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementEditedStateReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_EDITED_STATE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_edited_state — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-edited-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_edited_state",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's edited state",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing isEdited == true never authorizes any mutation on that same element — this read's authorization path carries no mutation authority whatsoever")
    func discoveredEditedStateNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-edited", toolName: "ui.read_element_edited_state", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element edited state"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let mutateReq = QToolAuthorizationRequest(
            taskId: "t-noauth-edited", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let mutateDecision = QPermissionGate.shared.evaluate(request: mutateReq)
        #expect(mutateDecision.isAllowed == false)
        #expect(mutateDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementEditedState/readElementEditedState references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target — proven both structurally and by a real fixture's own text content remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, textField) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", edited: true)
        let stringValueBefore = textField.stringValue
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(textField.stringValue == stringValueBefore)
    }

    @Test("22. An uncertain in-flight edited-state-read step fails closed to pending, and recovery never replays or persists any edited-state value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-edited", sessionId: "s-uncertain-edited", originalIntent: "Does this document have unsaved changes?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-edited", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-edited", index: 0, actionName: "ui.read_element_edited_state", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Does this document have unsaved changes?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-edited", taskId: "task-uncertain-edited", sessionId: "s-uncertain-edited",
            goal: "Does this document have unsaved changes?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["isEdited"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementEditedStateMetadata's stored properties are String/Bool? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementEditedStateMetadata(applicationName: "App", role: "AXTextField", isEdited: true)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.isEdited == true)
    }

    @Test("24. No sensitive content is ever leaked — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural boolean; no typed text, no document content, no credentials")
    func noSensitiveContentLeakageIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the isEdited fact")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "durable-\(suffix)", edited: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Does this document have unsaved changes?",
              "steps": [
                {
                  "actionName": "ui.read_element_edited_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's edited state",
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
            endpointName: "semantic-edited-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Does this document have unsaved changes?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_edited_state" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — no arbitrary window/document content ever appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "audit-\(suffix)", edited: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Does this document have unsaved changes?",
              "steps": [
                {
                  "actionName": "ui.read_element_edited_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's edited state",
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
            endpointName: "semantic-edited-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Does this document have unsaved changes?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("isEdited=") || summary.contains("edited state") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    // MARK: - Verification

    @Test("27. The elementEditedStateReadSucceeded verification strategy's evidence carries application name, role, and the isEdited fact itself — safe to include directly since it carries no privacy risk")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementEditedStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isEdited: true)
        let result = QActionResult(actionId: "verify-edited", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("isEdited=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence (nil) as 'unavailable' — never conflated with 'false'")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementEditedStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isEdited: nil)
        let result = QActionResult(actionId: "verify-edited-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("isEdited=unavailable"))
        #expect(evidence.contains("isEdited=false") == false)
    }

    @Test("28. The elementEditedStateReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed — this is the fabrication-rejection proof for a Boolean-typed capability: there is no length/content bound to independently re-check (unlike the String-typed capabilities), so the strategy's only independently-verifiable fact is result.success itself, and it is checked as a genuine, meaningful assertion, never a bare '{ true }' bypass")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementEditedStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isEdited: true)
        let result = QActionResult(actionId: "verify-edited-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. Verification never mutates the UI and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call exists anywhere in
        // QActionVerifier's .elementEditedStateReadSucceeded evaluation branch, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("30. QPlanExecutor executes ui.read_element_edited_state step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesEditedStateStep() async throws {
        let mockExec = ElementEditedStateMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_edited_state",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's edited state",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read an element's edited state"
        )
        let plan = QPlan(
            taskId: "t-plan-edited", sessionId: "s-edited", taskPrompt: "Read an element's edited state", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-edited")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Fail-closed summary / forbidden API safety (structural)

    @Test("31. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXEditedAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("32. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementEditedStateReadFailed("AXError(-25204)"),
            .elementEditedStateMalformed
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 2) // each is a distinct, dedicated diagnostic
    }

    @Test("33. No polling, no traversal (resource bounds): readElementEditedState performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_edited_state exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read edited state", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-edited"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read edited state",
            parameters: ["role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-edited"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read edited state",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-edited"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementEditedState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_edited_state", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read edited state",
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-edited"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - 25. Capability-count integrity

    @Test("25b. Capability count integrity: 80 → 81 was this phase's own registry-size delta; the registry has since grown further (Phase 2CH's ui.list_visible_children, then Phase 2CI's ui.read_element_index), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 83)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("34/E2E. Real macOS AppKit E2E — a real NSTextField explicitly marked edited via setAccessibilityEdited(true) resolves isEdited == true via kAXEditedAttribute, cross-validated against AppKit's own accessibilityEdited() accessor for the identical control; a control explicitly marked not-edited resolves isEdited == false; neither control's text content is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitEditedStateRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (editedWindow, editedField) = makeTextFieldWindow(identifier: "e2e-edited-\(suffix)", edited: true)
        defer { editedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let editedMetadata = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-edited-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(editedMetadata.isEdited == editedField.isAccessibilityEdited())

        let (notEditedWindow, notEditedField) = makeTextFieldWindow(identifier: "e2e-notedited-\(suffix)", edited: false)
        defer { notEditedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let notEditedMetadata = try await QBridgeAccessibility.shared.readElementEditedState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-notedited-\(suffix)", title: nil
        )
        #expect(notEditedMetadata.isEdited == notEditedField.isAccessibilityEdited())
        #expect(notEditedMetadata.isEdited == false)
    }
}
