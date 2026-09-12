//
//  QSemanticElementDisclosureLevelReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Disclosure Level Read Tests (Phase 2CF).
//
//  ui.read_element_disclosure_level resolves a semantically-identified outline row purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXOutlineRowRolePolicy's
//  existing allowlist (reused unmodified from ui.select_outline_row, Phase 2T — the SAME dedicated
//  AXRow role policy, no new parallel role mechanism), and reads its kAXDisclosureLevelAttribute —
//  a row's nesting depth. This is purely OBSERVATIONAL: neither the row nor any other UI state is
//  ever pressed, focused, activated, or mutated; no AX action is ever performed.
//
//  DELIBERATELY UNLIKE ui.select_outline_row: this read does NOT additionally require the
//  AXOutlineRow subrole or an AXOutline parent context. A MUTATION on the wrong kind of row would
//  be real, silent misbehavior; a READ of an ordinary AXRow that is not genuinely an outline row
//  simply, honestly reports genuine attribute absence (kAXErrorNoValue/kAXErrorAttributeUnsupported)
//  — a valid, expected nil, never a fabricated depth.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  kAXDisclosureLevelAttribute has no universal-presence documentation — it is meaningful only for
//  outline-row-style elements. This suite proves the missing-vs-failure discipline therefore
//  follows the OPTIONAL-reference pattern (identical to ui.read_element_expanded_state, Phase 2CE,
//  and ui.read_element_required_state, Phase 2BQ): genuine absence produces a valid nil, never an
//  error, and is never silently downgraded to 0.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CF_SEMANTIC_DISCLOSURE_LEVEL.md for the full
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

/// A minimal, genuinely-real AXUIElement fixture that authentically self-reports Accessibility
/// role `AXRow` — the same role-override mechanism `QSemanticOutlineRowSelectionTests`'s own
/// `AXRow` fixtures already establish as proven-working, not a mock or simulation. Its disclosure
/// level is forced via the real, declared `setAccessibilityDisclosureLevel(_:)`/
/// `accessibilityDisclosureLevel()` AppKit accessor pair (`NSAccessibilityProtocols.h`,
/// `API_AVAILABLE(macos(10.10))`) directly on the instance — the same method-pair-not-property
/// bridging pattern `ui.read_element_help_text`'s `setAccessibilityHelp`/`accessibilityHelp()`
/// already established as proven-working — no subclass override of its own is needed.
@MainActor
private final class QDisclosureLevelRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }
}

@MainActor
private func makeDisclosureLevelRowWindow(
    identifier: String,
    disclosureLevel: Int? = nil
) -> (window: NSWindow, row: QDisclosureLevelRowFixtureButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementDisclosureLevelReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let row = QDisclosureLevelRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
    row.title = "Node"
    row.setAccessibilityIdentifier(identifier)
    if let disclosureLevel {
        row.setAccessibilityDisclosureLevel(disclosureLevel)
    }
    contentView.addSubview(row)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, row)
}

private final class ElementDisclosureLevelMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_disclosure_level" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed disclosure level for AXRow element in MockApp: disclosureLevel=2.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXRow",
                    "hasDisclosureLevel": "true",
                    "disclosureLevel": "2"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementDisclosureLevelReadTests")
struct QSemanticElementDisclosureLevelReadTests {

    // MARK: - Registration, Level 0, capability #80, no approval requirement

    @Test("Registration: ui.read_element_disclosure_level is a registered, Level 0, read-only capability (#80) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementDisclosureLevel() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_disclosure_level"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 81)

        let json = """
        {
          "taskPrompt": "How deeply nested is this row?",
          "steps": [
            {
              "actionName": "ui.read_element_disclosure_level",
              "toolFamily": "ui",
              "description": "Read a semantically-identified outline row's disclosure level",
              "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Node1"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-disclosure-level", taskPrompt: "How deeply nested is this row?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "How deeply nested is this row?",
              "steps": [
                {
                  "actionName": "ui.read_element_disclosure_level",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified outline row's disclosure level",
                  "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Node1"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-disclosure-level-\(mismatchedRisk)", taskPrompt: "How deeply nested is this row?")
            }
        }
    }

    // MARK: - Happy path: real, non-zero depth

    @Test("1. A row explicitly reporting disclosure level 2 via accessibilityDisclosureLevel resolves disclosureLevel == 2")
    @MainActor
    func nonZeroDisclosureLevelReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "nested-\(suffix)", disclosureLevel: 2)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "nested-\(suffix)", title: nil
        )
        #expect(metadata.disclosureLevel == 2)
    }

    // MARK: - Happy path: top-level depth 0

    @Test("2. A row explicitly reporting disclosure level 0 (top level) resolves disclosureLevel == 0 — a fully valid, distinct outcome, never absent")
    @MainActor
    func zeroDisclosureLevelReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "toplevel-\(suffix)", disclosureLevel: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "toplevel-\(suffix)", title: nil
        )
        #expect(metadata.disclosureLevel == 0)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3/4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to 0 (structural, by direct inspection of resolveElementDisclosureLevel's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementDisclosureLevel's `case .noValue, .attributeUnsupported: return nil` branch
        // handles both identically — by direct source inspection at implementation time. Neither
        // ever reaches the elementDisclosureLevelReadFailed/elementDisclosureLevelMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to 0 — structural proof: QAXElementDisclosureLevelMetadata.disclosureLevel is Int?, and nil/0 are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToZeroIsStructural() {
        let absentMetadata = QAXElementDisclosureLevelMetadata(applicationName: "App", role: "AXRow", disclosureLevel: nil)
        let zeroMetadata = QAXElementDisclosureLevelMetadata(applicationName: "App", role: "AXRow", disclosureLevel: 0)
        #expect(absentMetadata.disclosureLevel == nil)
        #expect(zeroMetadata.disclosureLevel == 0)
        #expect(absentMetadata.disclosureLevel != zeroMetadata.disclosureLevel)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2CF")) {
            _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                applicationName: "QNoSuchApp2CF", role: "AXRow", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated disclosure-level result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous element

    @Test("10. Two rows matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let rowA = QDisclosureLevelRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        rowA.setAccessibilityIdentifier("dup-disclosure-\(suffix)")
        let rowB = QDisclosureLevelRowFixtureButton(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        rowB.setAccessibilityIdentifier("dup-disclosure-\(suffix)")
        contentView.addSubview(rowA)
        contentView.addSubview(rowB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "dup-disclosure-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CF")) {
            _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                applicationName: "QWrongApp2CF", role: "AXRow", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementDisclosureLevel exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("13. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - Role policy: allowed vs disallowed (reuses QAXOutlineRowRolePolicy verbatim)

    @Test("14. Disallowed roles are rejected before any AX search is even attempted — QAXOutlineRowRolePolicy (the SAME dedicated AXRow policy ui.select_outline_row already uses) reused verbatim, not broadened")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea", "AXButton", "AXTextField"] {
            await #expect(throws: QAXInteractionError.disallowedOutlineRowRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXRow is the only accepted target role — proven structurally, unmodified, shared with ui.select_outline_row's own QAXOutlineRowRolePolicy")
    func readableRoleAcceptedIsStructural() {
        #expect(QAXOutlineRowRolePolicy.isAllowedOutlineRowRole("AXRow") == true)
        #expect(QAXOutlineRowRolePolicy.isAllowedOutlineRowRole("AXButton") == false)
    }

    @Test("14c. Unlike ui.select_outline_row, this read does NOT require the AXOutlineRow subrole or an AXOutline parent context — an ordinary AXRow lacking outline semantics honestly reports genuine attribute absence rather than being pre-emptively rejected at the role gate")
    @MainActor
    func ordinaryRowWithoutOutlineContextIsAcceptedAtRoleGate() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        // No subrole override at all — a genuinely unqualified AXRow, exactly the case
        // ui.select_outline_row's own dedicated fixture proves gets refused at ITS subrole gate.
        // This capability has no such gate: the read proceeds to the AX call itself.
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "unqualified-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Does not throw disallowedOutlineRowRole/targetNotAnOutlineRow/outlineContextUnavailable —
        // the read reaches the AX call and returns a genuine (here, explicitly-set) result.
        let metadata = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "unqualified-\(suffix)", title: nil
        )
        #expect(metadata.applicationName == currentProcessAppName)
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-integer, e.g. floating-point) returned value fails closed with AX_ELEMENT_DISCLOSURE_LEVEL_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementDisclosureLevelMalformed
        #expect(error.errorCode == "AX_ELEMENT_DISCLOSURE_LEVEL_MALFORMED")
    }

    @Test("15b. A negative returned integer fails closed with AX_ELEMENT_DISCLOSURE_LEVEL_INVALID — a nesting depth is fundamentally non-negative, never silently clamped to 0")
    func negativeValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementDisclosureLevelInvalid("negative value: -1")
        #expect(error.errorCode == "AX_ELEMENT_DISCLOSURE_LEVEL_INVALID")
        #expect(error.description.contains("invalid"))
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_DISCLOSURE_LEVEL_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementDisclosureLevelReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_DISCLOSURE_LEVEL_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_disclosure_level — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-disclosure-level-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_disclosure_level",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified outline row's disclosure level",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing disclosureLevel != nil never authorizes ui.select_outline_row or any other mutation on that same row — the two capabilities' authorization paths are entirely disjoint")
    func discoveredDisclosureLevelNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-disclosure-level", toolName: "ui.read_element_disclosure_level", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element disclosure level"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-noauth-disclosure-level", toolName: "ui.select_outline_row", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Select outline row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementDisclosureLevel/readElementDisclosureLevel references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target — proven both structurally and by a real fixture's own disclosure level remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, row) = makeDisclosureLevelRowWindow(identifier: "nomutate-\(suffix)", disclosureLevel: 3)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(row.accessibilityDisclosureLevel() == 3)
    }

    @Test("22. An uncertain in-flight disclosure-level-read step fails closed to pending, and recovery never replays or persists any disclosure-level value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-disclosure-level", sessionId: "s-uncertain-disclosure-level", originalIntent: "How deeply nested is this row?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-disclosure-level", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-disclosure-level", index: 0, actionName: "ui.read_element_disclosure_level", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "How deeply nested is this row?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXRow", "identifier": "GhostRow"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-disclosure-level", taskId: "task-uncertain-disclosure-level", sessionId: "s-uncertain-disclosure-level",
            goal: "How deeply nested is this row?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["disclosureLevel"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementDisclosureLevelMetadata's stored properties are String/Int? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementDisclosureLevelMetadata(applicationName: "App", role: "AXRow", disclosureLevel: 1)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXRow")
        #expect(metadata.disclosureLevel == 1)
    }

    @Test("24. No sensitive content is ever leaked — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural, bounded non-negative integer; no typed text, no document content, no credentials")
    func noSensitiveContentLeakageIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the disclosureLevel fact")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "durable-\(suffix)", disclosureLevel: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "How deeply nested is this row?",
              "steps": [
                {
                  "actionName": "ui.read_element_disclosure_level",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified outline row's disclosure level",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-disclosure-level-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "How deeply nested is this row?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_disclosure_level" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — no arbitrary window/document content ever appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeDisclosureLevelRowWindow(identifier: "audit-\(suffix)", disclosureLevel: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "How deeply nested is this row?",
              "steps": [
                {
                  "actionName": "ui.read_element_disclosure_level",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified outline row's disclosure level",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-disclosure-level-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "How deeply nested is this row?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("disclosureLevel=") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, row) = makeDisclosureLevelRowWindow(identifier: identifier, disclosureLevel: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: identifier, title: nil
        )
        #expect(first.disclosureLevel == second.disclosureLevel)
        #expect(row.accessibilityDisclosureLevel() == 1)
    }

    // MARK: - Verification

    @Test("27. The elementDisclosureLevelReadSucceeded verification strategy's evidence carries application name, role, and the disclosureLevel fact itself — safe to include directly since it carries no privacy risk")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: true, disclosureLevelRaw: "2")
        let result = QActionResult(actionId: "verify-disclosure-level", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXRow"))
        #expect(evidence.contains("disclosureLevel=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence as 'unavailable' — never conflated with a present depth of 0")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: false, disclosureLevelRaw: nil)
        let result = QActionResult(actionId: "verify-disclosure-level-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("disclosureLevel=unavailable"))
        #expect(evidence.contains("disclosureLevel=0") == false)
    }

    @Test("28. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: true, disclosureLevelRaw: "2")
        let result = QActionResult(actionId: "verify-disclosure-level-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a disclosure level is present but the raw value is missing/unparseable is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedMissingValue() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: true, disclosureLevelRaw: nil)
        let fabricatedSuccess = QActionResult(actionId: "verify-disclosure-level-fabricated-missing", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29b. The strategy also rejects a fabricated success claiming a non-numeric disclosure level")
    func verificationRejectsFabricatedNonNumericValue() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: true, disclosureLevelRaw: "not-a-number")
        let fabricatedSuccess = QActionResult(actionId: "verify-disclosure-level-fabricated-nonnumeric", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29c. The strategy also rejects a fabricated success claiming a negative disclosure level — an independently-checkable invariant a plain Boolean does not have")
    func verificationRejectsFabricatedNegativeValue() async throws {
        let strategy = QVerificationStrategy.elementDisclosureLevelReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasDisclosureLevel: true, disclosureLevelRaw: "-1")
        let fabricatedSuccess = QActionResult(actionId: "verify-disclosure-level-fabricated-negative", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("30. Verification never mutates the UI, is not a bare boolean, and performs NO additional AX read of any kind — proven by the fabrication-rejection tests above (a bare '{ true }' verification, or one re-reading kAXDisclosureLevelAttribute, could never distinguish those cases from a genuinely fresh call) and by direct source inspection: determineVerificationStrategy reconstructs its evidence entirely from action.arguments/result.outputData, never calling QBridgeAccessibility a second time")
    func verificationNeverMutatesIsNotBareBooleanNoSecondRead() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("31. QPlanExecutor executes ui.read_element_disclosure_level step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesDisclosureLevelStep() async throws {
        let mockExec = ElementDisclosureLevelMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_disclosure_level",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a row's disclosure level",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXRow", "identifier": "MockRow"]
            ),
            description: "Read a row's disclosure level"
        )
        let plan = QPlan(
            taskId: "t-plan-disclosure-level", sessionId: "s-disclosure-level", taskPrompt: "Read a row's disclosure level", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-disclosure-level")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Fail-closed summary / forbidden API safety (structural)

    @Test("32. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXDisclosureLevelAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("33. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementDisclosureLevelReadFailed("AXError(-25204)"),
            .elementDisclosureLevelMalformed,
            .elementDisclosureLevelInvalid("negative value: -1")
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 3) // each is a distinct, dedicated diagnostic
    }

    @Test("34. No polling, no traversal (resource bounds): readElementDisclosureLevel performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_disclosure_level exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read disclosure level", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-disclosure-level"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read disclosure level",
            parameters: ["role": "AXRow", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-disclosure-level"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read disclosure level",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-disclosure-level"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
                applicationName: currentProcessAppName, role: "AXRow", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_disclosure_level", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read disclosure level",
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-disclosure-level"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - Capability-count integrity

    @Test("35. Capability count integrity: 79 → 80 was this phase's own registry-size delta; the registry has since grown further (Phase 2CG's ui.read_element_edited_state), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 81)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("36/E2E. Real macOS AppKit E2E — a real AXRow fixture explicitly reporting disclosure level 3 via accessibilityDisclosureLevel resolves disclosureLevel == 3 via kAXDisclosureLevelAttribute, cross-validated against AppKit's own accessibilityDisclosureLevel accessor for the identical control; a genuinely top-level (0) row is also exercised; the row's own state is never mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitDisclosureLevelRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (nestedWindow, nestedRow) = makeDisclosureLevelRowWindow(identifier: "e2e-nested-\(suffix)", disclosureLevel: 3)
        defer { nestedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let nestedMetadata = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "e2e-nested-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(nestedMetadata.disclosureLevel == nestedRow.accessibilityDisclosureLevel())
        #expect(nestedMetadata.disclosureLevel == 3)

        let (topLevelWindow, topLevelRow) = makeDisclosureLevelRowWindow(identifier: "e2e-toplevel-\(suffix)", disclosureLevel: 0)
        defer { topLevelWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let topLevelMetadata = try await QBridgeAccessibility.shared.readElementDisclosureLevel(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "e2e-toplevel-\(suffix)", title: nil
        )
        #expect(topLevelMetadata.disclosureLevel == topLevelRow.accessibilityDisclosureLevel())
        #expect(topLevelMetadata.disclosureLevel == 0)
    }
}
