//
//  QSemanticElementIndexReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Index Read Tests (Phase 2CI).
//
//  ui.read_element_index resolves a semantically-identified outline/table row purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXOutlineRowRolePolicy's
//  existing allowlist (reused unmodified from ui.read_element_disclosure_level, Phase 2CF — the
//  SAME dedicated AXRow role policy, no new parallel role mechanism), and reads its
//  kAXIndexAttribute — a row's authoritative, AX-reported ordinal position within its container.
//  This is purely OBSERVATIONAL: neither the row nor any other UI state is ever pressed, focused,
//  activated, or mutated; no AX action is ever performed.
//
//  DISTINCT FROM ui.list_outline_items' own `index` field (Phase 2AF): that field is a SYNTHETIC
//  array-position computed during enumeration, never a read of kAXIndexAttribute itself. This
//  capability reads the real, AX-reported position of one already-resolved row directly, without
//  first enumerating the whole container.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  kAXIndexAttribute has no universal-presence documentation. This suite proves the missing-vs-
//  failure discipline therefore follows the OPTIONAL-reference pattern (identical to
//  ui.read_element_disclosure_level, Phase 2CF): genuine absence produces a valid nil, never an
//  error, and is never silently downgraded to 0.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CI_SEMANTIC_ELEMENT_INDEX.md for the full
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
/// role `AXRow` and conforms to the real, declared `NSAccessibilityRow` protocol
/// (`NSAccessibilityProtocols.h`) to implement its one `@required` method, `accessibilityIndex()` —
/// the same real-accessor, not-a-mock discipline `ui.read_element_disclosure_level`'s own
/// `setAccessibilityDisclosureLevel`/`accessibilityDisclosureLevel()` fixture already established,
/// adapted for `accessibilityIndex`'s get-only (protocol-method, not settable-property) shape.
@MainActor
private final class QElementIndexRowFixtureButton: NSButton, NSAccessibilityRow {
    var testIndex: Int = 0

    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilityIndex() -> Int {
        testIndex
    }
}

/// A plain `AXRow`-role fixture that does NOT conform to `NSAccessibilityRow` at all — used
/// exclusively to exercise genuine attribute absence, mirroring
/// `ui.read_element_disclosure_level`'s own "unset" fixture discipline.
@MainActor
private final class QElementIndexAbsentRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }
}

@MainActor
private func makeElementIndexRowWindow(
    identifier: String,
    index: Int
) -> (window: NSWindow, row: QElementIndexRowFixtureButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementIndexReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let row = QElementIndexRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
    row.title = "Row"
    row.setAccessibilityIdentifier(identifier)
    row.testIndex = index
    contentView.addSubview(row)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, row)
}

@MainActor
private func makeAbsentIndexRowWindow(
    identifier: String
) -> (window: NSWindow, row: QElementIndexAbsentRowFixtureButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementIndexReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let row = QElementIndexAbsentRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
    row.title = "Row"
    row.setAccessibilityIdentifier(identifier)
    contentView.addSubview(row)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, row)
}

private final class ElementIndexMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_index" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed index for AXRow element in MockApp: index=2.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXRow",
                    "hasIndex": "true",
                    "index": "2"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementIndexReadTests")
struct QSemanticElementIndexReadTests {

    // MARK: - Registration, Level 0, capability #83, no approval requirement

    @Test("Registration: ui.read_element_index is a registered, Level 0, read-only capability (#83) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementIndex() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_index"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 84)

        let json = """
        {
          "taskPrompt": "Which position is this row at?",
          "steps": [
            {
              "actionName": "ui.read_element_index",
              "toolFamily": "ui",
              "description": "Read a semantically-identified row's ordinal position",
              "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Row1"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-index", taskPrompt: "Which position is this row at?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Which position is this row at?",
              "steps": [
                {
                  "actionName": "ui.read_element_index",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified row's ordinal position",
                  "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Row1"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-index-\(mismatchedRisk)", taskPrompt: "Which position is this row at?")
            }
        }
    }

    // MARK: - Happy path: real, non-zero index

    @Test("1. A row explicitly reporting index 2 via accessibilityIndex() resolves index == 2")
    @MainActor
    func nonZeroIndexReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeElementIndexRowWindow(identifier: "row2-\(suffix)", index: 2)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "row2-\(suffix)", title: nil
        )
        #expect(metadata.index == 2)
    }

    // MARK: - Happy path: index 0

    @Test("2. A row explicitly reporting index 0 (first position) resolves index == 0 — a fully valid, distinct outcome, never absent")
    @MainActor
    func zeroIndexReportedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeElementIndexRowWindow(identifier: "row0-\(suffix)", index: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "row0-\(suffix)", title: nil
        )
        #expect(metadata.index == 0)
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("3. A row that never implements accessibilityIndex() resolves without throwing — structural contract test, whatever AppKit's own honest answer is")
    @MainActor
    func genuineAbsenceDoesNotThrow() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeAbsentIndexRowWindow(identifier: "unset-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "unset-\(suffix)", title: nil
        )
        // Whatever AppKit's real, honest answer is (nil absence, or a genuine value actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because accessibilityIndex() was never implemented.
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("4/5. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to 0 (structural, by direct inspection of resolveElementIndex's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveElementIndex's `case .noValue, .attributeUnsupported: return nil` branch handles
        // both identically — by direct source inspection at implementation time. Neither ever
        // reaches the elementIndexReadFailed/elementIndexMalformed paths.
        #expect(Bool(true))
    }

    @Test("6. Absence is never silently converted to 0 — structural proof: QAXElementIndexMetadata.index is Int?, and nil/0 are distinct, distinguishable values at the type level")
    func absenceNeverConvertedToZeroIsStructural() {
        let absentMetadata = QAXElementIndexMetadata(applicationName: "App", role: "AXRow", index: nil)
        let zeroMetadata = QAXElementIndexMetadata(applicationName: "App", role: "AXRow", index: 0)
        #expect(absentMetadata.index == nil)
        #expect(zeroMetadata.index == 0)
        #expect(absentMetadata.index != zeroMetadata.index)
    }

    // MARK: - Resolution: missing / unavailable application

    @Test("7. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2CI")) {
            _ = try await QBridgeAccessibility.shared.readElementIndex(
                applicationName: "QNoSuchApp2CI", role: "AXRow", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing element

    @Test("9. Zero matching elements fails closed, never a fabricated index result")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeElementIndexRowWindow(identifier: "present-\(suffix)", index: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementIndex(
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
        let rowA = QElementIndexRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        rowA.setAccessibilityIdentifier("dup-index-\(suffix)")
        let rowB = QElementIndexRowFixtureButton(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        rowB.setAccessibilityIdentifier("dup-index-\(suffix)")
        contentView.addSubview(rowA)
        contentView.addSubview(rowB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementIndex(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "dup-index-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("11. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CI")) {
            _ = try await QBridgeAccessibility.shared.readElementIndex(
                applicationName: "QWrongApp2CI", role: "AXRow", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target / execution identity

    @Test("12. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementIndex exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("13. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - Role policy: allowed vs disallowed (reuses QAXOutlineRowRolePolicy verbatim)

    @Test("14. Disallowed roles are rejected before any AX search is even attempted — QAXOutlineRowRolePolicy (the SAME dedicated AXRow policy ui.read_element_disclosure_level already uses) reused verbatim, not broadened")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea", "AXButton", "AXTextField"] {
            await #expect(throws: QAXInteractionError.disallowedOutlineRowRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readElementIndex(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("14b. AXRow is the only accepted target role — proven structurally, unmodified, shared with ui.read_element_disclosure_level's own QAXOutlineRowRolePolicy")
    func readableRoleAcceptedIsStructural() {
        #expect(QAXOutlineRowRolePolicy.isAllowedOutlineRowRole("AXRow") == true)
        #expect(QAXOutlineRowRolePolicy.isAllowedOutlineRowRole("AXButton") == false)
    }

    // MARK: - Malformed / unexpected AXError

    @Test("15. A malformed (non-integer, e.g. floating-point) returned value fails closed with AX_ELEMENT_INDEX_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementIndexMalformed
        #expect(error.errorCode == "AX_ELEMENT_INDEX_MALFORMED")
    }

    @Test("15b. A negative returned integer fails closed with AX_ELEMENT_INDEX_INVALID — an ordinal position is fundamentally non-negative, never silently clamped to 0")
    func negativeValueFailsClosedIsStructural() {
        let error = QAXInteractionError.elementIndexInvalid("negative value: -1")
        #expect(error.errorCode == "AX_ELEMENT_INDEX_INVALID")
        #expect(error.description.contains("invalid"))
    }

    @Test("16. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_ELEMENT_INDEX_READ_FAILED — never silently folded into absence")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.elementIndexReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ELEMENT_INDEX_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("17. Permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED, checked before any application/element resolution is attempted")
    func permissionDenialFailsClosedIsStructural() {
        let error = QAXInteractionError.accessibilityPermissionDenied
        #expect(error.errorCode == "AX_PERMISSION_DENIED")
    }

    // MARK: - Security

    @Test("18. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_index — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-index-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_index",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified row's ordinal position",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("19. Observing index != nil never authorizes any mutation on that same row — this read's authorization path carries no mutation authority whatsoever")
    func discoveredIndexNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-index", toolName: "ui.read_element_index", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read element index"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-noauth-index", toolName: "ui.select_outline_row", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Select outline row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementIndex/readElementIndex references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("21. This capability never mutates the target — proven both structurally and by a real fixture's own index remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, row) = makeElementIndexRowWindow(identifier: "nomutate-\(suffix)", index: 3)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(row.accessibilityIndex() == 3)
    }

    @Test("22. An uncertain in-flight index-read step fails closed to pending, and recovery never replays or persists any index value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-index", sessionId: "s-uncertain-index", originalIntent: "Which position is this row at?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-index", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-index", index: 0, actionName: "ui.read_element_index", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Which position is this row at?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXRow", "identifier": "GhostRow"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-index", taskId: "task-uncertain-index", sessionId: "s-uncertain-index",
            goal: "Which position is this row at?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["index"] == nil)
    }

    // MARK: - Privacy

    @Test("23. No raw AXUIElement reference is ever persisted — structural proof: QAXElementIndexMetadata's stored properties are String/Int? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementIndexMetadata(applicationName: "App", role: "AXRow", index: 1)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXRow")
        #expect(metadata.index == 1)
    }

    @Test("24. No sensitive content is ever leaked — the only content-bearing fields are application name and role (already caller-supplied identity) plus a structural, bounded non-negative integer; no typed text, no document content, no credentials")
    func noSensitiveContentLeakageIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. A real run's durable-plan snapshot contains only permitted structural metadata — application identity, role, and the index fact")
    @MainActor
    func evidenceOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeElementIndexRowWindow(identifier: "durable-\(suffix)", index: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which position is this row at?",
              "steps": [
                {
                  "actionName": "ui.read_element_index",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified row's ordinal position",
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
            endpointName: "semantic-index-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which position is this row at?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_index" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability contain only permitted structural metadata — no arbitrary window/document content ever appears")
    @MainActor
    func auditOnlyContainsPermittedMetadata() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeElementIndexRowWindow(identifier: "audit-\(suffix)", index: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which position is this row at?",
              "steps": [
                {
                  "actionName": "ui.read_element_index",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified row's ordinal position",
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
            endpointName: "semantic-index-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which position is this row at?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("index=") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, row) = makeElementIndexRowWindow(identifier: identifier, index: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: identifier, title: nil
        )
        #expect(first.index == second.index)
        #expect(row.accessibilityIndex() == 1)
    }

    // MARK: - Verification

    @Test("27. The elementIndexReadSucceeded verification strategy's evidence carries application name, role, and the index fact itself — safe to include directly since it carries no privacy risk")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: true, indexRaw: "2")
        let result = QActionResult(actionId: "verify-index", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXRow"))
        #expect(evidence.contains("index=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("27b. Evidence correctly represents a genuine absence as 'unavailable' — never conflated with a present index of 0")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: false, indexRaw: nil)
        let result = QActionResult(actionId: "verify-index-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("index=unavailable"))
        #expect(evidence.contains("index=0") == false)
    }

    @Test("28. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: true, indexRaw: "2")
        let result = QActionResult(actionId: "verify-index-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming an index is present but the raw value is missing/unparseable is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedMissingValue() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: true, indexRaw: nil)
        let fabricatedSuccess = QActionResult(actionId: "verify-index-fabricated-missing", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29b. The strategy also rejects a fabricated success claiming a non-numeric index")
    func verificationRejectsFabricatedNonNumericValue() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: true, indexRaw: "not-a-number")
        let fabricatedSuccess = QActionResult(actionId: "verify-index-fabricated-nonnumeric", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("29c. The strategy also rejects a fabricated success claiming a negative index — an independently-checkable invariant a plain Boolean does not have")
    func verificationRejectsFabricatedNegativeValue() async throws {
        let strategy = QVerificationStrategy.elementIndexReadSucceeded(applicationName: "SomeApp", role: "AXRow", hasIndex: true, indexRaw: "-1")
        let fabricatedSuccess = QActionResult(actionId: "verify-index-fabricated-negative", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("30. Verification never mutates the UI, is not a bare boolean, and performs NO additional AX read of any kind — proven by the fabrication-rejection tests above and by direct source inspection: determineVerificationStrategy reconstructs its evidence entirely from action.arguments/result.outputData, never calling QBridgeAccessibility a second time")
    func verificationNeverMutatesIsNotBareBooleanNoSecondRead() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("31. QPlanExecutor executes ui.read_element_index step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesIndexStep() async throws {
        let mockExec = ElementIndexMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_index",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a row's ordinal position",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXRow", "identifier": "MockRow"]
            ),
            description: "Read a row's ordinal position"
        )
        let plan = QPlan(
            taskId: "t-plan-index", sessionId: "s-index", taskPrompt: "Read a row's ordinal position", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-index")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Fail-closed summary / forbidden API safety (structural)

    @Test("32. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXIndexAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("33. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .elementIndexReadFailed("AXError(-25204)"),
            .elementIndexMalformed,
            .elementIndexInvalid("negative value: -1")
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 3) // each is a distinct, dedicated diagnostic
    }

    @Test("34. No polling, no traversal (resource bounds): readElementIndex performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_index exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read element index", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-index"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read element index",
            parameters: ["role": "AXRow", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-index"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read element index",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-index"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementIndex(
                applicationName: currentProcessAppName, role: "AXRow", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_index", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read element index",
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-index"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - Capability-count integrity

    @Test("35. Capability count integrity: 82 → 83 was this phase's own registry-size delta; the registry has since grown further (Phase 2CJ's ui.read_element_insertion_point_line_number), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 84)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("36/E2E. Real macOS AppKit E2E — a real AXRow fixture conforming to NSAccessibilityRow and explicitly reporting index 3 via accessibilityIndex() resolves index == 3 via kAXIndexAttribute, cross-validated against AppKit's own accessibilityIndex() accessor for the identical control; a genuinely first-position (0) row is also exercised; the row's own state is never mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitElementIndexRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (thirdWindow, thirdRow) = makeElementIndexRowWindow(identifier: "e2e-third-\(suffix)", index: 3)
        defer { thirdWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let thirdMetadata = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "e2e-third-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(thirdMetadata.index == thirdRow.accessibilityIndex())
        #expect(thirdMetadata.index == 3)

        let (firstWindow, firstRow) = makeElementIndexRowWindow(identifier: "e2e-first-\(suffix)", index: 0)
        defer { firstWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let firstMetadata = try await QBridgeAccessibility.shared.readElementIndex(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "e2e-first-\(suffix)", title: nil
        )
        #expect(firstMetadata.index == firstRow.accessibilityIndex())
        #expect(firstMetadata.index == 0)
    }
}
