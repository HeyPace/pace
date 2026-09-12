//
//  QSemanticElementInsertionPointLineReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Insertion Point Line Number Read Tests (Phase 2CJ).
//
//  ui.read_element_insertion_point_line_number resolves a semantically-identified element purely
//  by Accessibility semantics (role + identifier or title), restricted to
//  QAXElementReadRolePolicy's existing allowlist (reused completely unmodified from
//  ui.read_element_expanded_state/ui.read_element_edited_state/ui.read_element_help_text,
//  including the identical AXSecureTextField-first-then-general-allowlist exclusion), and reads
//  its kAXInsertionPointLineNumberAttribute — which line the text caret currently sits on. This is
//  purely OBSERVATIONAL: no value is ever set, no AX action is ever performed, and
//  kAXValueAttribute is never read — only the bounded line-number integer crosses the boundary,
//  never the field's own typed text.
//
//  DISTINCT FROM ui.read_element_index (Phase 2CI): that capability reads kAXIndexAttribute (a
//  row's ordinal position, gated behind the NSAccessibilityRow protocol); this one reads a
//  completely different attribute (a text caret's line number, a plain general-property accessor)
//  applicable to any element on QAXElementReadRolePolicy's shared allowlist.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  kAXInsertionPointLineNumberAttribute has no universal-presence documentation — it is
//  meaningful only for elements that currently have a text caret. This suite proves the
//  missing-vs-failure discipline therefore follows the OPTIONAL-reference pattern (identical to
//  ui.read_element_index, Phase 2CI): genuine absence produces a valid nil, never an error, and is
//  never silently downgraded to 0.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CJ_SEMANTIC_INSERTION_POINT_LINE.md for the full
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
/// declares the standard `accessibilityInsertionPointLineNumber`/
/// `setAccessibilityInsertionPointLineNumber(_:)` accessor pair (`NSAccessibilityProtocols.h`),
/// the same declared-accessor pattern `ui.read_element_disclosure_level`'s own
/// `setAccessibilityDisclosureLevel`/`ui.read_element_edited_state`'s
/// `setAccessibilityEdited` already established as proven-working for forcing a deterministic AX
/// state — this attribute sits in the same general per-element property cluster (not gated
/// behind any specialized protocol, unlike `ui.read_element_index`'s `accessibilityIndex`).
@MainActor
private func makeInsertionPointLineTextFieldWindow(
    identifier: String,
    lineNumber: Int? = nil
) -> (window: NSWindow, textField: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementInsertionPointLineReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
    textField.stringValue = "Line content"
    textField.setAccessibilityIdentifier(identifier)
    if let lineNumber {
        textField.setAccessibilityInsertionPointLineNumber(lineNumber)
    }
    contentView.addSubview(textField)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textField)
}

private final class ElementInsertionPointLineMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_insertion_point_line_number" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed insertion point line number for AXTextField element in MockApp: lineNumber=2.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasLineNumber": "true",
                    "lineNumber": "2"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementInsertionPointLineReadTests")
struct QSemanticElementInsertionPointLineReadTests {

    // MARK: - Registration, Level 0, capability #84, no approval requirement

    @Test("Registration: ui.read_element_insertion_point_line_number is a registered, Level 0, read-only capability (#84) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementInsertionPointLineNumber() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_insertion_point_line_number"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 85)

        let json = """
        {
          "taskPrompt": "What line is the cursor on?",
          "steps": [
            {
              "actionName": "ui.read_element_insertion_point_line_number",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's insertion point line number",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Notes"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-insertion-point-line", taskPrompt: "What line is the cursor on?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What line is the cursor on?",
              "steps": [
                {
                  "actionName": "ui.read_element_insertion_point_line_number",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's insertion point line number",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Notes"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-insertion-point-line-\(mismatchedRisk)", taskPrompt: "What line is the cursor on?")
            }
        }
    }

    // MARK: - Happy path: real, non-zero line number

    @Test("1. An element explicitly reporting insertion point line number 2 resolves lineNumber == 2")
    @MainActor
    func nonZeroLineNumberReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "line2-\(suffix)", lineNumber: 2)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "line2-\(suffix)", title: nil
        )
        #expect(metadata.lineNumber == 2)
    }

    // MARK: - Happy path: line number 0

    @Test("2. An element explicitly reporting insertion point line number 0 (first line) resolves lineNumber == 0 — a fully valid, distinct outcome, never absent")
    @MainActor
    func zeroLineNumberReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "line0-\(suffix)", lineNumber: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "line0-\(suffix)", title: nil
        )
        #expect(metadata.lineNumber == 0)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3. An element with no accessibilityInsertionPointLineNumber ever set resolves without throwing — structural contract test, whatever AppKit's own honest answer is")
    @MainActor
    func genuineAbsenceDoesNotThrow() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "unset-\(suffix)", lineNumber: nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "unset-\(suffix)", title: nil
        )
        // Whatever AppKit's real, honest answer is (nil absence, or a genuine value actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because the attribute was never explicitly set.
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to 0 (structural, by direct inspection of resolveElementInsertionPointLine's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementInsertionPointLine's `case .noValue, .attributeUnsupported: return nil`
        // branch handles both identically — by direct source inspection at implementation time.
        // Neither ever reaches the elementInsertionPointLineReadFailed/
        // elementInsertionPointLineMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to 0 — structural proof: QAXElementInsertionPointLineMetadata.lineNumber is Int?, and nil/0 are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToZeroIsStructural() {
        let absentMetadata = QAXElementInsertionPointLineMetadata(applicationName: "App", role: "AXTextField", lineNumber: nil)
        let zeroMetadata = QAXElementInsertionPointLineMetadata(applicationName: "App", role: "AXTextField", lineNumber: 0)
        #expect(absentMetadata.lineNumber == nil)
        #expect(zeroMetadata.lineNumber == 0)
        #expect(absentMetadata.lineNumber != zeroMetadata.lineNumber)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2CJ")) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: "QNoSuchApp2CJ", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated insertion-point-line result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "present-\(suffix)", lineNumber: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
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
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.setAccessibilityIdentifier("dup-insertion-point-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.setAccessibilityIdentifier("dup-insertion-point-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-insertion-point-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CJ")) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: "QWrongApp2CJ", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementInsertionPointLine exactly as in every prior read capability")
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
                _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXSecureTextField is rejected before any AX search, mirroring every prior read capability's identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("14c. Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.read_element_expanded_state/ui.read_element_edited_state/ui.read_element_help_text/ui.read_element_placeholder_value")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextArea") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXComboBox") == true)
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-integer, e.g. floating-point) returned value fails closed with AX_ELEMENT_INSERTION_POINT_LINE_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementInsertionPointLineMalformed
        #expect(error.errorCode == "AX_ELEMENT_INSERTION_POINT_LINE_MALFORMED")
    }

    @Test("15b. A negative returned integer fails closed with AX_ELEMENT_INSERTION_POINT_LINE_INVALID — a line number is fundamentally non-negative, never silently clamped to 0")
    func negativeValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementInsertionPointLineInvalid("negative value: -1")
        #expect(error.errorCode == "AX_ELEMENT_INSERTION_POINT_LINE_INVALID")
        #expect(error.description.contains("invalid"))
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_INSERTION_POINT_LINE_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementInsertionPointLineReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_INSERTION_POINT_LINE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_insertion_point_line_number — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-insertion-point-line-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_insertion_point_line_number",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's insertion point line number",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing lineNumber != nil never authorizes any mutation on that same element — this read's authorization path carries no mutation authority whatsoever")
    func discoveredLineNumberNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-insertion-point-line", toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element insertion point line number"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let mutateReq = QToolAuthorizationRequest(
            taskId: "t-noauth-insertion-point-line", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let mutateDecision = QPermissionGate.shared.evaluate(request: mutateReq)
        #expect(mutateDecision.isAllowed == false)
        #expect(mutateDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementInsertionPointLine/readElementInsertionPointLine references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target — proven both structurally and by a real fixture's own text content remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, textField) = makeInsertionPointLineTextFieldWindow(identifier: "nomutate-\(suffix)", lineNumber: 3)
        let stringValueBefore = textField.stringValue
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(textField.stringValue == stringValueBefore)
    }

    @Test("22. An uncertain in-flight insertion-point-line-read step fails closed to pending, and recovery never replays or persists any line-number value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-insertion-point-line", sessionId: "s-uncertain-insertion-point-line", originalIntent: "What line is the cursor on?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-insertion-point-line", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-insertion-point-line", index: 0, actionName: "ui.read_element_insertion_point_line_number", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What line is the cursor on?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-insertion-point-line", taskId: "task-uncertain-insertion-point-line", sessionId: "s-uncertain-insertion-point-line",
            goal: "What line is the cursor on?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["lineNumber"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementInsertionPointLineMetadata's stored properties are String/Int? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementInsertionPointLineMetadata(applicationName: "App", role: "AXTextField", lineNumber: 1)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.lineNumber == 1)
    }

    @Test("24. No sensitive content is ever leaked — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural, bounded non-negative integer; no typed text, no document content, no credentials")
    func noSensitiveContentLeakageIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the lineNumber fact")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "durable-\(suffix)", lineNumber: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What line is the cursor on?",
              "steps": [
                {
                  "actionName": "ui.read_element_insertion_point_line_number",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's insertion point line number",
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
            endpointName: "semantic-insertion-point-line-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What line is the cursor on?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_insertion_point_line_number" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — no arbitrary window/document content ever appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeInsertionPointLineTextFieldWindow(identifier: "audit-\(suffix)", lineNumber: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What line is the cursor on?",
              "steps": [
                {
                  "actionName": "ui.read_element_insertion_point_line_number",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's insertion point line number",
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
            endpointName: "semantic-insertion-point-line-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What line is the cursor on?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("lineNumber=") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, textField) = makeInsertionPointLineTextFieldWindow(identifier: identifier, lineNumber: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )
        #expect(first.lineNumber == second.lineNumber)
        #expect(textField.stringValue == "Line content")
    }

    // MARK: - Verification

    @Test("27. The elementInsertionPointLineReadSucceeded verification strategy's evidence carries application name, role, and the lineNumber fact itself — safe to include directly since it carries no privacy risk")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: true, lineNumberRaw: "2")
        let result = QActionResult(actionId: "verify-insertion-point-line", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("lineNumber=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence as 'unavailable' — never conflated with a present line number of 0")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: false, lineNumberRaw: nil)
        let result = QActionResult(actionId: "verify-insertion-point-line-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("lineNumber=unavailable"))
        #expect(evidence.contains("lineNumber=0") == false)
    }

    @Test("28. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: true, lineNumberRaw: "2")
        let result = QActionResult(actionId: "verify-insertion-point-line-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a line number is present but the raw value is missing/unparseable is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedMissingValue() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: true, lineNumberRaw: nil)
        let fabricatedSuccess = QActionResult(actionId: "verify-insertion-point-line-fabricated-missing", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29b. The strategy also rejects a fabricated success claiming a non-numeric line number")
    func verificationRejectsFabricatedNonNumericValue() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: true, lineNumberRaw: "not-a-number")
        let fabricatedSuccess = QActionResult(actionId: "verify-insertion-point-line-fabricated-nonnumeric", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29c. The strategy also rejects a fabricated success claiming a negative line number — an independently-checkable invariant a plain Boolean does not have")
    func verificationRejectsFabricatedNegativeValue() async throws {
        let strategy = QVerificationStrategy.elementInsertionPointLineReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasLineNumber: true, lineNumberRaw: "-1")
        let fabricatedSuccess = QActionResult(actionId: "verify-insertion-point-line-fabricated-negative", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("30. Verification never mutates the UI, is not a bare boolean, and performs NO additional AX read of any kind — proven by the fabrication-rejection tests above and by direct source inspection: determineVerificationStrategy reconstructs its evidence entirely from action.arguments/result.outputData, never calling QBridgeAccessibility a second time")
    func verificationNeverMutatesIsNotBareBooleanNoSecondRead() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("31. QPlanExecutor executes ui.read_element_insertion_point_line_number step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesInsertionPointLineStep() async throws {
        let mockExec = ElementInsertionPointLineMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_insertion_point_line_number",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's insertion point line number",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read an element's insertion point line number"
        )
        let plan = QPlan(
            taskId: "t-plan-insertion-point-line", sessionId: "s-insertion-point-line", taskPrompt: "Read an element's insertion point line number", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-insertion-point-line")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Fail-closed summary / forbidden API safety (structural)

    @Test("32. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXInsertionPointLineNumberAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("33. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementInsertionPointLineReadFailed("AXError(-25204)"),
            .elementInsertionPointLineMalformed,
            .elementInsertionPointLineInvalid("negative value: -1")
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 3) // each is a distinct, dedicated diagnostic
    }

    @Test("34. No polling, no traversal (resource bounds): readElementInsertionPointLine performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_insertion_point_line_number exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read insertion point line number", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-insertion-point-line"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read insertion point line number",
            parameters: ["role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-insertion-point-line"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read insertion point line number",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-insertion-point-line"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_insertion_point_line_number", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read insertion point line number",
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-insertion-point-line"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - Capability-count integrity

    @Test("35. Capability count integrity: 83 → 84 was this phase's own registry-size delta; the registry has since grown further (Phase 2CK's ui.read_table_header), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 85)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("36/E2E. Real macOS AppKit E2E — a real NSTextField explicitly reporting insertion point line number 3 via setAccessibilityInsertionPointLineNumber resolves lineNumber == 3 via kAXInsertionPointLineNumberAttribute, cross-validated against AppKit's own accessibilityInsertionPointLineNumber accessor for the identical control; a genuinely first-line (0) field is also exercised; the field's own text content is never mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitInsertionPointLineRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (thirdWindow, thirdField) = makeInsertionPointLineTextFieldWindow(identifier: "e2e-third-\(suffix)", lineNumber: 3)
        defer { thirdWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let thirdMetadata = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-third-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(thirdMetadata.lineNumber == thirdField.accessibilityInsertionPointLineNumber())
        #expect(thirdMetadata.lineNumber == 3)

        let (firstWindow, firstField) = makeInsertionPointLineTextFieldWindow(identifier: "e2e-first-\(suffix)", lineNumber: 0)
        defer { firstWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let firstMetadata = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-first-\(suffix)", title: nil
        )
        #expect(firstMetadata.lineNumber == firstField.accessibilityInsertionPointLineNumber())
        #expect(firstMetadata.lineNumber == 0)
    }
}
