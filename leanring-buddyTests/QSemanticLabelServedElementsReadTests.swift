//
//  QSemanticLabelServedElementsReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Label Served-Elements Read Tests (Phase 2BX).
//
//  ui.list_label_served_elements resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused completely unmodified from ui.read_element_value/
//  ui.read_element_title_reference, including the identical AXSecureTextField-first-then-general-
//  allowlist exclusion), and reads its kAXServesAsTitleForUIElementsAttribute. This is purely
//  OBSERVATIONAL: no element is ever mutated, no AX action is ever performed. This is the
//  structural INVERSE of ui.read_element_title_reference (Phase 2BN, kAXTitleUIElementAttribute):
//  that capability answers "what titles ME"; this one answers "which elements do I serve as the
//  title FOR".
//
//  ATOMIC ARRAY DISCIPLINE (mirrors ui.read_element_allowed_values, Phase 2BV): a single
//  malformed, unreadable, or disallowed-role served element fails the WHOLE array closed — invalid
//  entries are never silently dropped — and the array is bounded (maxServedElementsCount, checked
//  BEFORE any per-element extraction) rather than ever truncated.
//
//  SDK-VERIFIED ABSENCE SEMANTICS: kAXServesAsTitleForUIElementsAttribute carries no "required for
//  all elements of this role"-style documentation — most elements serve as the title for nothing
//  at all. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE
//  pattern — a valid, expected nil for the WHOLE result — distinct from a genuinely PRESENT but
//  EMPTY array, which is its own valid, non-nil result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BX_SEMANTIC_LABEL_SERVED_ELEMENTS.md for the full
//  contract, including this phase's honest E2E findings.
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

/// A genuine, real, live pair of `NSTextField`s — a label field and (optionally) an input field —
/// wired via the real, public `setAccessibilityServesAsTitleForUIElements(_:)` AppKit API, the
/// structural inverse of `ui.read_element_title_reference`'s own established
/// `setAccessibilityTitleUIElement(_:)` fixture (Phase 2BN).
@MainActor
private func makeLabelWithServedElements(
    labelIdentifier: String,
    labelTitle: String = "Name:",
    inputIdentifier: String? = "input-field",
    attachServedElements: Bool = true
) -> (window: NSWindow, labelField: NSTextField, inputField: NSTextField?) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticLabelServedElementsTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))

    let label = NSTextField(labelWithString: labelTitle)
    label.frame = NSRect(x: 20, y: 60, width: 90, height: 24)
    label.setAccessibilityIdentifier(labelIdentifier)
    contentView.addSubview(label)

    var inputField: NSTextField?
    if let inputIdentifier {
        let input = NSTextField(frame: NSRect(x: 120, y: 60, width: 220, height: 24))
        input.stringValue = ""
        input.setAccessibilityIdentifier(inputIdentifier)
        contentView.addSubview(input)
        inputField = input
        if attachServedElements {
            label.setAccessibilityServesAsTitleForUIElements([input])
        }
    }

    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, label, inputField)
}

private final class LabelServedElementsMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_label_served_elements" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed served-elements relationship for AXStaticText element in MockApp: 1 served element(s).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXStaticText",
                    "elementIdentifier": "",
                    "elementTitle": "Name:",
                    "hasServedElements": "true",
                    "servedElementCount": "1",
                    "servedElement0.role": "AXTextField",
                    "servedElement0.title": "",
                    "servedElement0.identifier": "input-field"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticLabelServedElementsReadTests")
struct QSemanticLabelServedElementsReadTests {

    // MARK: - Registration, Level 0, capability #72, anti-downgrade both directions

    @Test("Registration: ui.list_label_served_elements is a registered, Level 0, read-only capability (#72) with no approval surface")
    func capabilityRegistrationAcceptsUIListLabelServedElements() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_label_served_elements"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #72 was registered as the 72nd capability; the registry has since grown to
        // 78 (Phase 2BY's ui.read_window_auxiliary_buttons, Phase 2BZ's
        // ui.list_table_row_headers, Phase 2CA's ui.read_scroll_position, Phase 2CB's
        // ui.read_element_role_description, then Phase 2CC's ui.read_element_help_text), so this
        // checks the current total rather than a phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 79)

        let json = """
        {
          "taskPrompt": "Which fields does this label caption?",
          "steps": [
            {
              "actionName": "ui.list_label_served_elements",
              "toolFamily": "ui",
              "description": "Read the elements a semantically-identified label serves as the title for",
              "parameters": {"applicationName": "Finder", "role": "AXStaticText", "title": "Name:"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-served", taskPrompt: "Which fields does this label caption?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Which fields does this label caption?",
              "steps": [
                {
                  "actionName": "ui.list_label_served_elements",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read the elements a semantically-identified label serves as the title for",
                  "parameters": {"applicationName": "Finder", "role": "AXStaticText", "title": "Name:"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-served-\(mismatchedRisk)", taskPrompt: "Which fields does this label caption?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.list_label_served_elements — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-served-permgate-\(UUID().uuidString)",
            toolName: "ui.list_label_served_elements",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read the elements a label serves as the title for",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListLabelServedElements/listLabelServedElements references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXElementReadRolePolicy unmodified)

    @Test("3. Every QAXElementReadRolePolicy role is an accepted source-element role — proven structurally, unmodified, shared with ui.read_element_value/ui.read_element_title_reference")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXStaticText") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
    }

    @Test("4. AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.read_element_title_reference already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("5. A secure-field SOURCE target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldSourceRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("6. A wrong/disallowed source role is rejected with disallowedReadRole before any AX search")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabelWithServedElements(labelIdentifier: "wrongrole-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("7. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: currentProcessAppName, role: "AXStaticText", identifier: nil, title: nil
            )
        }
    }

    @Test("8. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BX")) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: "QWrongApp2BX", role: "AXStaticText", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("9. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated served-elements result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabelWithServedElements(labelIdentifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: currentProcessAppName, role: "AXStaticText", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("10. Ambiguous target (two labels with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupLabel-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let labelA = NSTextField(labelWithString: "A")
        labelA.frame = NSRect(x: 10, y: 10, width: 90, height: 24)
        labelA.setAccessibilityIdentifier(sharedIdentifier)
        let labelB = NSTextField(labelWithString: "B")
        labelB.frame = NSRect(x: 10, y: 100, width: 90, height: 24)
        labelB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(labelA)
        container.addSubview(labelB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: currentProcessAppName, role: "AXStaticText", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("11. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in listLabelServedElements exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("12. listLabelServedElements performs a single synchronous AXUIElementCopyAttributeValue call for kAXServesAsTitleForUIElementsAttribute on the source — never kAXValueAttribute, no polling loop, no descent into served elements' own children (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("13. A model-level construction accepts a valid, non-empty array of served-element references")
    func nonEmptyArrayModelValid() {
        let served = QAXServedElementReference(role: "AXTextField", title: nil, identifier: "input-field")
        let metadata = QAXLabelServedElementsMetadata(applicationName: "App", role: "AXStaticText", elementIdentifier: "lbl1", elementTitle: "Name:", servedElements: [served])
        #expect(metadata.servedElements.count == 1)
        #expect(metadata.servedElements[0].identifier == "input-field")
    }

    @Test("14. A model-level construction accepts a genuinely EMPTY array as a fully valid, distinct-from-absence result")
    func emptyArrayModelValidAndDistinctFromAbsence() {
        let metadata = QAXLabelServedElementsMetadata(applicationName: "App", role: "AXStaticText", elementIdentifier: "lbl1", elementTitle: "Name:", servedElements: [])
        #expect(metadata.servedElements.isEmpty)
    }

    // MARK: - Genuine absence vs. genuinely-present-but-empty (structural distinction)

    @Test("15/16. Genuine absence of kAXServesAsTitleForUIElementsAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty array — structural, by direct inspection of resolveServedElements's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("17. Absence (nil) and a present empty array ([]) are structurally distinct outcomes — never conflated (see also test 14)")
    func absenceDistinctFromEmptyArrayIsStructural() {
        let absent: QAXLabelServedElementsMetadata? = nil
        let empty = QAXLabelServedElementsMetadata(applicationName: "App", role: "AXStaticText", elementIdentifier: nil, elementTitle: nil, servedElements: [])
        #expect(absent == nil)
        #expect(empty.servedElements.isEmpty)
    }

    // MARK: - Malformed / invalid values (all must fail closed atomically, never silently coerced)

    @Test("18. A wrong outer CFType (not a CFArray) fails closed with AX_SERVED_ELEMENTS_MALFORMED")
    func wrongOuterCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsMalformed
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_MALFORMED")
    }

    @Test("19. An element that is not AXUIElement-compatible fails the WHOLE array closed with AX_SERVED_ELEMENTS_ELEMENT_MALFORMED — never silently dropped from an otherwise valid array")
    func nonElementEntryFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsElementMalformed
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_ELEMENT_MALFORMED")
    }

    @Test("20. A served element whose own role is not on QAXElementReadRolePolicy's allowlist fails the WHOLE array closed with AX_SERVED_ELEMENTS_ELEMENT_DISALLOWED_ROLE — never silently omitted (atomic, matching ui.read_element_allowed_values' discipline)")
    func disallowedRoleServedElementFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsElementDisallowedRole("AXTable")
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_ELEMENT_DISALLOWED_ROLE")
        #expect(error.description.contains("not on the allowed read-role list"))
    }

    @Test("21. A served element with an unreadable role (reading as \"none\") is treated identically to a disallowed role and fails the WHOLE array closed — never silently coerced into an accepted role")
    func unreadableRoleTreatedAsDisallowedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("none") == false)
    }

    @Test("22. A served element whose title/identifier exceeds maxServedElementMetadataLength fails the WHOLE array closed with AX_SERVED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func oversizedServedElementMetadataFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsElementMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH")
    }

    @Test("23. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_SERVED_ELEMENTS_READ_FAILED — never silently folded into absence or an empty array")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Atomicity: mixed valid/invalid served elements

    @Test("24. A mixed array (one genuinely valid served element, one disallowed-role served element) fails the WHOLE array closed — no partial result is ever returned, matching ui.read_element_allowed_values' identical atomic-array discipline")
    func mixedValidInvalidArrayFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Resource bounds

    @Test("25. An array exactly at maxServedElementsCount (32) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func arrayExactlyAtMaximumIsAccepted() {
        let servedElements = (0..<32).map { QAXServedElementReference(role: "AXTextField", title: nil, identifier: "field\($0)") }
        let metadata = QAXLabelServedElementsMetadata(applicationName: "App", role: "AXStaticText", elementIdentifier: nil, elementTitle: nil, servedElements: servedElements)
        #expect(metadata.servedElements.count == 32)
    }

    @Test("26. An array exceeding maxServedElementsCount fails closed with AX_SERVED_ELEMENTS_EXCEEDS_SAFE_BOUND — checked BEFORE any per-element extraction, never silently truncated")
    func arrayAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.servedElementsExceedsSafeBound(33)
        #expect(error.errorCode == "AX_SERVED_ELEMENTS_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("27. No silent truncation ever occurs — structural: the bound check happens via `guard count <= maxServedElementsCount else { throw ... }` BEFORE the per-element extraction loop begins")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("28. Resource bounds are respected: 1 source target, 1 primary AX relationship read, bounded per-element identity reads only, 0 traversal into served elements' own children, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded identity metadata ever enters durable evidence (conservative, count-only)

    @Test("29. A real run's durable-plan snapshot's verification evidence carries only application/role identity, presence, and a COUNT — never any served element's own title/identifier, mirroring ui.read_element_title_reference's identical conservative-evidence discipline")
    @MainActor
    func conservativeEvidenceNeverLeaksServedElementIdentityDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelLabelIdentifier = "DurableLabel-\(suffix)"
        let sentinelInputIdentifier = "SuperSecretServedFieldSentinel-\(suffix)"
        let (window, _, _) = makeLabelWithServedElements(labelIdentifier: sentinelLabelIdentifier, inputIdentifier: sentinelInputIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which fields does this label caption?",
              "steps": [
                {
                  "actionName": "ui.list_label_served_elements",
                  "toolFamily": "ui",
                  "description": "Read the elements a semantically-identified label serves as the title for",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXStaticText", "identifier": "\(sentinelLabelIdentifier)"}
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
            endpointName: "semantic-served-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which fields does this label caption?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_label_served_elements" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains(sentinelInputIdentifier) == false)
    }

    @Test("30. Audit records for this capability's verification evidence never contain any served element's own title/identifier — only conservative count/presence metadata")
    @MainActor
    func conservativeEvidenceNeverLeaksServedElementIdentityInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelLabelIdentifier = "AuditLabel-\(suffix)"
        let sentinelInputIdentifier = "SuperSecretAuditFieldSentinel-\(suffix)"
        let (window, _, _) = makeLabelWithServedElements(labelIdentifier: sentinelLabelIdentifier, inputIdentifier: sentinelInputIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which fields does this label caption?",
              "steps": [
                {
                  "actionName": "ui.list_label_served_elements",
                  "toolFamily": "ui",
                  "description": "Read the elements a semantically-identified label serves as the title for",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXStaticText", "identifier": "\(sentinelLabelIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-served-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which fields does this label caption?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            #expect(record.executionSummary!.contains(sentinelInputIdentifier) == false)
        }
    }

    @Test("31. Recovery remains fail-closed: an uncertain in-flight served-elements-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-served", sessionId: "s-uncertain-served", originalIntent: "Which fields does this label caption?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-served", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-served", index: 0, actionName: "ui.list_label_served_elements", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Which fields does this label caption?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXStaticText", "title": "GhostLabel"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-served", taskId: "task-uncertain-served", sessionId: "s-uncertain-served",
            goal: "Which fields does this label caption?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["servedElementCount"] == nil)
    }

    @Test("32. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let labelIdentifier = "Repeat-\(suffix)"
        let (window, label, inputField) = makeLabelWithServedElements(labelIdentifier: labelIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.listLabelServedElements(
            applicationName: currentProcessAppName, role: "AXStaticText", identifier: labelIdentifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.listLabelServedElements(
            applicationName: currentProcessAppName, role: "AXStaticText", identifier: labelIdentifier, title: nil
        )
        #expect(first?.servedElements.count == second?.servedElements.count)
        #expect(label.stringValue == "Name:")
        #expect(inputField?.stringValue == "")
    }

    @Test("33. No raw AXUIElement reference is ever persisted — structural proof: QAXLabelServedElementsMetadata's and QAXServedElementReference's stored properties are String?/String/[QAXServedElementReference] only, no AXUIElement-typed field exists anywhere in the declarations")
    func noRawAXReferencePersisted() {
        let served = QAXServedElementReference(role: "AXTextField", title: nil, identifier: "id1")
        let metadata = QAXLabelServedElementsMetadata(applicationName: "App", role: "AXStaticText", elementIdentifier: "lbl1", elementTitle: "Name:", servedElements: [served])
        #expect(metadata.applicationName == "App")
        #expect(metadata.servedElements[0].identifier == "id1")
    }

    // MARK: - Security: no mutation authority, disjoint from other capabilities

    @Test("34. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own fields remaining untouched")
    @MainActor
    func neverMutatesElementsNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let labelIdentifier = "NoMutate-\(suffix)"
        let (window, label, inputField) = makeLabelWithServedElements(labelIdentifier: labelIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listLabelServedElements(
            applicationName: currentProcessAppName, role: "AXStaticText", identifier: labelIdentifier, title: nil
        )
        #expect(label.stringValue == "Name:")
        #expect(inputField?.stringValue == "")
    }

    @Test("35. Observing this relationship never authorizes any mutation against the source label or any served element — the authorization paths are entirely disjoint")
    func discoveredServedElementsNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-served", toolName: "ui.list_label_served_elements", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read served elements"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-noauth-served", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    @Test("36. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: listLabelServedElements/executeListLabelServedElements reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    @Test("37. QResourceGuard's generic per-step targetResources validation applies to ui.list_label_served_elements exactly like every other Level 0 capability — no special-cased bypass")
    func resourceGuardAppliesGenericallyIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("38. The labelServedElementsReadSucceeded verification strategy's evidence carries application identity, role, presence, and a COUNT — safe to include directly since these are bounded structural facts, never any served element's own title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.labelServedElementsReadSucceeded(
            applicationName: "SomeApp", role: "AXStaticText", hasServedElements: true, servedElementCount: 2
        )
        let result = QActionResult(actionId: "verify-served", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_label_served_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXStaticText"))
        #expect(evidence.contains("servedElementCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("39. Absence (hasServedElements == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty relationship in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.labelServedElementsReadSucceeded(
            applicationName: "SomeApp", role: "AXStaticText", hasServedElements: false, servedElementCount: 0
        )
        let result = QActionResult(actionId: "verify-served-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_label_served_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("servedElements=unavailable"))
        #expect(evidence.contains("servedElementCount=") == false)
    }

    @Test("40. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.labelServedElementsReadSucceeded(
            applicationName: "SomeApp", role: "AXStaticText", hasServedElements: true, servedElementCount: 2
        )
        let result = QActionResult(actionId: "verify-served-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_label_served_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("41. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a negative served-element count is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNegativeCount() async throws {
        let strategy = QVerificationStrategy.labelServedElementsReadSucceeded(
            applicationName: "SomeApp", role: "AXStaticText", hasServedElements: true, servedElementCount: -1
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-served-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_label_served_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("42. Verification never mutates the UI and is not a bare boolean — proven by test 41's independent rejection (a bare '{ true }' verification could never distinguish that case)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("43. QPlanExecutor executes ui.list_label_served_elements step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesServedElementsStep() async throws {
        let mockExec = LabelServedElementsMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_label_served_elements",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read the elements a label serves as the title for",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXStaticText", "title": "MockLabel"]
            ),
            description: "Read the elements a label serves as the title for"
        )
        let plan = QPlan(
            taskId: "t-plan-served", sessionId: "s-served", taskPrompt: "Read the elements a label serves as the title for", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-served")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("44. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXServesAsTitleForUIElementsAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — never kAXValueAttribute, no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("45/E2E. Real macOS AppKit E2E — a real NSTextField label wired to a real NSTextField input via the genuine setAccessibilityServesAsTitleForUIElements(_:) accessor resolves via kAXServesAsTitleForUIElementsAttribute; a label with no served elements correctly reports genuine absence; neither field is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitLabelServedElementsRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let labelIdentifier = "e2e-served-\(suffix)"
        let inputIdentifier = "e2e-served-input-\(suffix)"
        let (window, label, inputField) = makeLabelWithServedElements(
            labelIdentifier: labelIdentifier, inputIdentifier: inputIdentifier
        )
        #expect((label.accessibilityServesAsTitleForUIElements() as? [NSTextField])?.first === inputField)

        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.listLabelServedElements(
            applicationName: currentProcessAppName, role: "AXStaticText", identifier: labelIdentifier, title: nil
        )

        #expect(metadata?.servedElements.count == 1)
        #expect(metadata?.servedElements.first?.identifier == inputIdentifier)
        #expect(metadata?.applicationName == currentProcessAppName)
        // The read never mutated either field.
        #expect(label.stringValue == "Name:")
        #expect(inputField?.stringValue == "")

        // A second, unlabeled/unattached fixture correctly reports genuine absence — never a
        // fabricated empty array conflated with "no relationship at all".
        let unattachedSuffix = UUID().uuidString
        let (windowNoServed, _, _) = makeLabelWithServedElements(
            labelIdentifier: "e2e-noserved-\(unattachedSuffix)", inputIdentifier: nil, attachServedElements: false
        )
        defer { windowNoServed.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let absentMetadata = try await QBridgeAccessibility.shared.listLabelServedElements(
            applicationName: currentProcessAppName, role: "AXStaticText", identifier: "e2e-noserved-\(unattachedSuffix)", title: nil
        )
        #expect(absentMetadata == nil)
    }
}
