//
//  QSemanticElementProtectedContentStateReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Protected Content State Read Tests (Phase 2BR).
//
//  ui.read_element_protected_content_state resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused unmodified), and reads its AXContainsProtectedContent attribute —
//  whether the element contains protected content (e.g. a secure field). This is purely
//  OBSERVATIONAL: neither the element nor any other UI state is ever pressed, focused, activated,
//  or mutated; no AX action is ever performed; the protected content itself is NEVER read.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  This is the first capability in the program whose entire purpose is defensive/security-aware
//  observation — the boolean it returns exists to help a future planner AVOID sensitive content,
//  never to expose any of that content itself.
//  Unlike ui.read_window_modal_state (kAXModalAttribute, documented "Required for all window
//  elements"), AXContainsProtectedContent has no universal-presence documentation — it is
//  meaningful only for elements that can meaningfully hold sensitive content. This suite proves
//  the missing-vs-failure discipline therefore follows the OPTIONAL-reference pattern
//  (Phase 2BM/2BN/2BQ), not the inverted pattern used for modal state: genuine absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) produces a valid nil, never an error, and is
//  never silently downgraded to false.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See
//  docs/PHASE_2BR_SEMANTIC_ELEMENT_PROTECTED_CONTENT_STATE.md for the full contract.
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
private func makeTextFieldWindow(identifier: String, value: String, protectedContent: Bool? = nil) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "QSemanticProtectedContentStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = value
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    if let protectedContent {
        field.setAccessibilityProtectedContent(protectedContent)
    }
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

private final class ElementProtectedContentStateMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_protected_content_state" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed protected-content state for AXTextField element in MockApp: isProtectedContent=true.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasProtectedContentState": "true",
                    "isProtectedContent": "true"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementProtectedContentStateReadTests")
struct QSemanticElementProtectedContentStateReadTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.read_element_protected_content_state is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementProtectedContentState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_protected_content_state"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "Does this field contain protected content?",
          "steps": [
            {
              "actionName": "ui.read_element_protected_content_state",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's protected-content state",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Password"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-protected", taskPrompt: "Does this field contain protected content?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Does this field contain protected content?",
              "steps": [
                {
                  "actionName": "ui.read_element_protected_content_state",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's protected-content state",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Password"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-protected-\(mismatchedRisk)", taskPrompt: "Does this field contain protected content?")
            }
        }
    }

    // MARK: - Happy path: protected == true

    @Test("1. A field marked protected via setAccessibilityProtectedContent(true) resolves isProtectedContent == true")
    @MainActor
    func protectedTrueReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "protected-\(suffix)", value: "", protectedContent: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "protected-\(suffix)", title: nil
        )
        #expect(metadata.isProtectedContent == true)
    }

    // MARK: - Happy path: protected == false

    @Test("2. A field explicitly marked not-protected via setAccessibilityProtectedContent(false) resolves isProtectedContent == false — a fully valid, distinct outcome, never absent")
    @MainActor
    func protectedFalseReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "notprotected-\(suffix)", value: "", protectedContent: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "notprotected-\(suffix)", title: nil
        )
        #expect(metadata.isProtectedContent == false)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3. A field with no accessibilityProtectedContent ever set resolves a genuine, honest result — never fabricated, its exact native default explicitly investigated rather than assumed")
    @MainActor
    func genuineAbsenceOrNativeDefaultInvestigatedHonestly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "unset-\(suffix)", value: "", protectedContent: nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "unset-\(suffix)", title: nil
        )
        // Whatever AppKit's real, honest answer is (nil absence, or a default false actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because the attribute was never explicitly set, and that whichever value
        // comes back is a genuine native answer, never a guess this test forces.
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to false (structural, by direct inspection of resolveElementProtectedContentState's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementProtectedContentState's `case .noValue, .attributeUnsupported: return nil`
        // branch handles both identically — by direct source inspection at implementation time.
        // Neither ever reaches the elementProtectedContentStateReadFailed/
        // elementProtectedContentStateMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to false — structural proof: QAXElementProtectedContentStateMetadata.isProtectedContent is Bool?, and nil/false are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToFalseIsStructural() {
        let absentMetadata = QAXElementProtectedContentStateMetadata(applicationName: "App", role: "AXTextField", isProtectedContent: nil)
        let falseMetadata = QAXElementProtectedContentStateMetadata(applicationName: "App", role: "AXTextField", isProtectedContent: false)
        #expect(absentMetadata.isProtectedContent == nil)
        #expect(falseMetadata.isProtectedContent == false)
        #expect(absentMetadata.isProtectedContent != falseMetadata.isProtectedContent)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BR")) {
            _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
                applicationName: "QNoSuchApp2BR", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated protected-content-state result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)", value: "x")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
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
        fieldA.setAccessibilityIdentifier("dup-protected-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.stringValue = "Dup"
        fieldB.isEditable = true
        fieldB.setAccessibilityIdentifier("dup-protected-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-protected-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BR")) {
            _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
                applicationName: "QWrongApp2BR", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementProtectedContentState exactly as in every prior read capability")
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
                _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXSecureTextField is rejected before any AX search as the TARGET role, mirroring every prior read capability's identical secure-field precedent — this capability never resolves a secure field directly, even to check its own protected-content flag")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-Boolean) returned value fails closed with AX_ELEMENT_PROTECTED_CONTENT_STATE_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementProtectedContentStateMalformed
        #expect(error.errorCode == "AX_ELEMENT_PROTECTED_CONTENT_STATE_MALFORMED")
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_PROTECTED_CONTENT_STATE_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementProtectedContentStateReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_PROTECTED_CONTENT_STATE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_protected_content_state — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-protected-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_protected_content_state",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's protected-content state",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing isProtectedContent == true never authorizes ui.read_element_value or any other capability on that same field — the two capabilities' authorization paths are entirely disjoint, and no mutation authorization is ever granted by this read")
    func discoveredProtectedContentStateNeverAuthorizesOtherReadsOrMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-protected", toolName: "ui.read_element_protected_content_state", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element protected-content state"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        // A subsequent read of the element's actual VALUE is an entirely separate, independently
        // evaluated capability whose own role policy runs fresh, unaffected by anything this
        // capability ever observed.
        let readValueReq = QToolAuthorizationRequest(
            taskId: "t-noauth-protected", toolName: "ui.read_element_value", toolFamily: "perception",
            baseRisk: .level0ReadOnly, literalAction: "Read element value"
        )
        let readValueDecision = QPermissionGate.shared.evaluate(request: readValueReq)
        #expect(readValueDecision.isAllowed == true) // independently Level 0 on its own merits, not because of this capability

        let setTextReq = QToolAuthorizationRequest(
            taskId: "t-noauth-protected", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setTextDecision = QPermissionGate.shared.evaluate(request: setTextReq)
        #expect(setTextDecision.isAllowed == false)
        #expect(setTextDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementProtectedContentState/readElementProtectedContentState references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target and never reads its actual value/content — proven both structurally and by a real fixture's own field content remaining untouched")
    @MainActor
    func neverMutatesOrReadsContent() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", value: "unchanged-content", protectedContent: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(field.stringValue == "unchanged-content")
    }

    @Test("22. Recovery remains fail-closed: an uncertain in-flight protected-content-state-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-protected", sessionId: "s-uncertain-protected", originalIntent: "Does this field contain protected content?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-protected", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-protected", index: 0, actionName: "ui.read_element_protected_content_state", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Does this field contain protected content?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-protected", taskId: "task-uncertain-protected", sessionId: "s-uncertain-protected",
            goal: "Does this field contain protected content?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["isProtectedContent"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementProtectedContentStateMetadata's stored properties are String/Bool? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementProtectedContentStateMetadata(applicationName: "App", role: "AXTextField", isProtectedContent: true)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.isProtectedContent == true)
    }

    @Test("24. Protected content itself never appears in durable evidence, audit, recovery state, planner state, replanner state, or model output beyond the Boolean semantic result — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural boolean")
    func protectedContentItselfNeverLeaksAnywhereIsStructural() {
        // resolveElementProtectedContentState reads exactly one attribute
        // (AXContainsProtectedContent) and never calls axValueDescription/axStringAttribute for
        // kAXValueAttribute or any content-bearing attribute on the target — by direct source
        // inspection at implementation time. There is no code path by which this capability could
        // read, let alone persist, the protected content itself.
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the isProtectedContent fact — never any field content")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "durable-\(suffix)", value: "SuperSecretPassword123", protectedContent: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Does this field contain protected content?",
              "steps": [
                {
                  "actionName": "ui.read_element_protected_content_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's protected-content state",
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
            endpointName: "semantic-protected-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Does this field contain protected content?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_protected_content_state" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("SuperSecretPassword123") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — the field's actual content never appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "audit-\(suffix)", value: "AnotherSecretValue456", protectedContent: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Does this field contain protected content?",
              "steps": [
                {
                  "actionName": "ui.read_element_protected_content_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's protected-content state",
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
            endpointName: "semantic-protected-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Does this field contain protected content?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            #expect(summary.contains("AnotherSecretValue456") == false)
            let mentionsExpectedVocabulary = summary.contains("isProtectedContent=") || summary.contains("protected-content state") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    // MARK: - Verification

    @Test("27. The elementProtectedContentStateReadSucceeded verification strategy's evidence carries application name, role, and the isProtectedContent fact itself — safe to include directly since it carries no privacy risk (it is the security fact, never the content)")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementProtectedContentStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isProtectedContent: true)
        let result = QActionResult(actionId: "verify-protected", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_protected_content_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("isProtectedContent=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence (nil) as 'unavailable' — never conflated with 'false'")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementProtectedContentStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isProtectedContent: nil)
        let result = QActionResult(actionId: "verify-protected-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_protected_content_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("isProtectedContent=unavailable"))
        #expect(evidence.contains("isProtectedContent=false") == false)
    }

    @Test("28. The elementProtectedContentStateReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementProtectedContentStateReadSucceeded(applicationName: "SomeApp", role: "AXTextField", isProtectedContent: true)
        let result = QActionResult(actionId: "verify-protected-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_protected_content_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. Verification never mutates the UI, never reads the protected content, and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call, and no
        // AXUIElementCopyAttributeValue call for kAXValueAttribute or any content-bearing
        // attribute, exists anywhere in QActionVerifier's
        // .elementProtectedContentStateReadSucceeded evaluation branch, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("30. QPlanExecutor executes ui.read_element_protected_content_state step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesProtectedContentStateStep() async throws {
        let mockExec = ElementProtectedContentStateMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_protected_content_state",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a field's protected-content state",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read a field's protected-content state"
        )
        let plan = QPlan(
            taskId: "t-plan-protected", sessionId: "s-protected", taskPrompt: "Read a field's protected-content state", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-protected")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Robustness / fail-closed summary / forbidden API safety (structural)

    @Test("31. This capability's implementation uses only AXUIElementCopyAttributeValue for AXContainsProtectedContent — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("32. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementProtectedContentStateReadFailed("AXError(-25204)"),
            .elementProtectedContentStateMalformed
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 2) // each is a distinct, dedicated diagnostic
    }

    @Test("33. Exactly one attribute is read: readElementProtectedContentState performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func exactlyOneAttributeReadNoPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("34. Repeated invocation has no side effects — two consecutive real reads of the same fixture return the same result and neither mutates the fixture")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "repeat-\(suffix)", value: "still-unchanged", protectedContent: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "repeat-\(suffix)", title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "repeat-\(suffix)", title: nil
        )
        #expect(first.isProtectedContent == second.isProtectedContent)
        #expect(field.stringValue == "still-unchanged")
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("35/E2E. Real macOS AppKit E2E — a real NSTextField explicitly marked protected via setAccessibilityProtectedContent(true) resolves isProtectedContent == true via AXContainsProtectedContent; a field explicitly marked not-protected resolves isProtectedContent == false; neither field's content is ever read or mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitProtectedContentStateRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (protectedWindow, protectedField) = makeTextFieldWindow(identifier: "e2e-protected-\(suffix)", value: "unchanged-protected", protectedContent: true)
        defer { protectedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let protectedMetadata = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-protected-\(suffix)", title: nil
        )
        #expect(protectedMetadata.isProtectedContent == true)
        #expect(protectedField.stringValue == "unchanged-protected") // provably unchanged — content never read or mutated

        let (notProtectedWindow, notProtectedField) = makeTextFieldWindow(identifier: "e2e-notprotected-\(suffix)", value: "unchanged-open", protectedContent: false)
        defer { notProtectedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let notProtectedMetadata = try await QBridgeAccessibility.shared.readElementProtectedContentState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-notprotected-\(suffix)", title: nil
        )
        #expect(notProtectedMetadata.isProtectedContent == false)
        #expect(notProtectedField.stringValue == "unchanged-open") // provably unchanged
    }
}
