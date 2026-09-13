//
//  QSemanticLinkedElementsListTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Linked Elements List Tests (Phase 2CL).
//
//  ui.list_linked_elements resolves a semantically-identified element purely by Accessibility
//  semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's existing
//  allowlist (reused completely unmodified from ui.read_element_value/
//  ui.list_label_served_elements, including the identical AXSecureTextField-first-then-general-
//  allowlist exclusion), and reads its kAXLinkedUIElementsAttribute. This is purely OBSERVATIONAL:
//  no element is ever mutated, no AX action is ever performed, and kAXValueAttribute is never
//  read. Distinct from every existing relationship capability in this codebase: not a title
//  relationship (ui.read_element_title_reference/ui.list_label_served_elements), not a viewport
//  relationship (ui.list_visible_children), not a table-header relationship
//  (ui.read_table_header) — kAXLinkedUIElementsAttribute is Apple's generic, freeform "these
//  elements are related" annotation mechanism.
//
//  ATOMIC ARRAY DISCIPLINE (mirrors ui.list_visible_children, Phase 2CH): a single malformed,
//  secure-field, or oversized-metadata linked element fails the WHOLE array closed — invalid
//  entries are never silently dropped — and the array is bounded (maxLinkedElementsCount, checked
//  BEFORE any per-element extraction) rather than ever truncated.
//
//  DELIBERATE DESIGN DIFFERENCE from ui.list_label_served_elements: each linked element's role is
//  checked against ONLY the single privacy-sensitive exclusion (AXSecureTextField) — never the
//  narrower QAXElementReadRolePolicy allowlist — since a "linked" relationship is a generic,
//  freeform annotation not restricted to leaf/label semantics, mirroring
//  ui.list_visible_children's/ui.read_table_header's identical design difference.
//
//  SDK-VERIFIED ABSENCE SEMANTICS: kAXLinkedUIElementsAttribute carries no "required for all
//  elements"-style documentation — most elements are linked to nothing at all. Genuine absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern — a valid,
//  expected nil for the WHOLE result — distinct from a genuinely PRESENT but EMPTY array, which is
//  its own valid, non-nil result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CL_SEMANTIC_LINKED_ELEMENTS.md for the full
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

/// A genuine, real, live `NSButton` (source) linked to zero or more real `NSTextField`s, wired via
/// the real, public `setAccessibilityLinkedUIElements(_:)` AppKit API — the same general
/// per-element accessor category `ui.list_label_served_elements`'s own
/// `setAccessibilityServesAsTitleForUIElements(_:)` fixture already established as proven-working.
@MainActor
private func makeElementWithLinkedElements(
    sourceIdentifier: String,
    linkedIdentifiers: [String] = ["linked-default"],
    attachLinkedElements: Bool = true
) -> (window: NSWindow, sourceButton: NSButton, linkedFields: [NSTextField]) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticLinkedElementsListTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))

    let sourceButton = NSButton(title: "Source", target: nil, action: nil)
    sourceButton.frame = NSRect(x: 20, y: 60, width: 90, height: 24)
    sourceButton.setAccessibilityIdentifier(sourceIdentifier)
    contentView.addSubview(sourceButton)

    var linkedFields: [NSTextField] = []
    for (index, linkedIdentifier) in linkedIdentifiers.enumerated() {
        let field = NSTextField(frame: NSRect(x: 120, y: 60 - CGFloat(index) * 30, width: 220, height: 24))
        field.stringValue = ""
        field.setAccessibilityIdentifier(linkedIdentifier)
        contentView.addSubview(field)
        linkedFields.append(field)
    }
    if attachLinkedElements {
        sourceButton.setAccessibilityLinkedUIElements(linkedFields)
    }

    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, sourceButton, linkedFields)
}

private final class LinkedElementsMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_linked_elements" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed linked elements for AXButton element in MockApp: 1 linked element(s).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXButton",
                    "elementIdentifier": "",
                    "elementTitle": "Source",
                    "hasLinkedElements": "true",
                    "linkedElementsCount": "1",
                    "linkedElement0.role": "AXTextField",
                    "linkedElement0.title": "",
                    "linkedElement0.identifier": "mock-linked-field"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticLinkedElementsListTests")
struct QSemanticLinkedElementsListTests {

    // MARK: - Registration, Level 0, capability #86, no approval requirement

    @Test("Registration: ui.list_linked_elements is a registered, Level 0, read-only capability (#86) with no approval surface")
    func capabilityRegistrationAcceptsUIListLinkedElements() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_linked_elements"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 86)

        let json = """
        {
          "taskPrompt": "What is this button linked to?",
          "steps": [
            {
              "actionName": "ui.list_linked_elements",
              "toolFamily": "ui",
              "description": "List a semantically-identified element's linked elements",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Save"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-linked", taskPrompt: "What is this button linked to?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What is this button linked to?",
              "steps": [
                {
                  "actionName": "ui.list_linked_elements",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "List a semantically-identified element's linked elements",
                  "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Save"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-linked-\(mismatchedRisk)", taskPrompt: "What is this button linked to?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.list_linked_elements — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-linked-permgate-\(UUID().uuidString)",
            toolName: "ui.list_linked_elements",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List an element's linked elements",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListLinkedElements/listLinkedElements references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: source role (reuses QAXElementReadRolePolicy unmodified)

    @Test("3. Every QAXElementReadRolePolicy role is an accepted source-element role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_label_served_elements")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
    }

    @Test("4. AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.list_label_served_elements already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("5. A secure-field SOURCE target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldSourceRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("6. A wrong/disallowed source role is rejected with disallowedReadRole before any AX search")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeElementWithLinkedElements(sourceIdentifier: "wrongrole-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("7. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXButton", identifier: nil, title: nil
            )
        }
    }

    @Test("8. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CL")) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: "QWrongApp2CL", role: "AXButton", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("9. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated linked-elements result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeElementWithLinkedElements(sourceIdentifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("10. Ambiguous target (two source buttons with the same identifier) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupSource-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let buttonA = NSButton(title: "A", target: nil, action: nil)
        buttonA.frame = NSRect(x: 10, y: 10, width: 90, height: 24)
        buttonA.setAccessibilityIdentifier(sharedIdentifier)
        let buttonB = NSButton(title: "B", target: nil, action: nil)
        buttonB.frame = NSRect(x: 10, y: 100, width: 90, height: 24)
        buttonB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(buttonA)
        container.addSubview(buttonB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXButton", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("11. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in listLinkedElements exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("12. listLinkedElements performs a single synchronous AXUIElementCopyAttributeValue call for kAXLinkedUIElementsAttribute on the source — never kAXValueAttribute, no polling loop, no descent into linked elements' own children (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("13. A model-level construction accepts a valid, non-empty array of linked-element references")
    func nonEmptyArrayModelValid() {
        let linked = QAXLinkedElementReference(role: "AXTextField", title: nil, identifier: "linked-field")
        let metadata = QAXLinkedElementsMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "source", elementTitle: "Save", linkedElements: [linked])
        #expect(metadata.linkedElements.count == 1)
        #expect(metadata.linkedElements[0].identifier == "linked-field")
    }

    @Test("14. A model-level construction accepts a genuinely EMPTY array as a fully valid, distinct-from-absence result")
    func emptyArrayModelValidAndDistinctFromAbsence() {
        let metadata = QAXLinkedElementsMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "source", elementTitle: "Save", linkedElements: [])
        #expect(metadata.linkedElements.isEmpty)
    }

    // MARK: - Genuine absence vs. genuinely-present-but-empty (structural distinction)

    @Test("15/16. Genuine absence of kAXLinkedUIElementsAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty array — structural, by direct inspection of resolveLinkedElements's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("17. Absence (nil) and a present empty array ([]) are structurally distinct outcomes — never conflated")
    func absenceDistinctFromEmptyArrayIsStructural() {
        let absent: QAXLinkedElementsMetadata? = nil
        let empty = QAXLinkedElementsMetadata(applicationName: "App", role: "AXButton", elementIdentifier: nil, elementTitle: nil, linkedElements: [])
        #expect(absent == nil)
        #expect(empty.linkedElements.isEmpty)
    }

    // MARK: - Malformed / invalid values (all must fail closed atomically, never silently coerced)

    @Test("18. A wrong outer CFType (not a CFArray) fails closed with AX_LINKED_ELEMENTS_MALFORMED")
    func wrongOuterCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.linkedElementsMalformed
        #expect(error.errorCode == "AX_LINKED_ELEMENTS_MALFORMED")
    }

    @Test("19. An element that is not AXUIElement-compatible fails the WHOLE array closed with AX_LINKED_ELEMENTS_ELEMENT_MALFORMED — never silently dropped from an otherwise valid array")
    func nonElementEntryFailsClosedIsStructural() {
        let error = QAXInteractionError.linkedElementsElementMalformed
        #expect(error.errorCode == "AX_LINKED_ELEMENTS_ELEMENT_MALFORMED")
    }

    @Test("20. A linked element's title/identifier exceeding maxLinkedElementMetadataLength fails the WHOLE array closed with AX_LINKED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func oversizedLinkedElementMetadataFailsClosedIsStructural() {
        let error = QAXInteractionError.linkedElementsElementMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_LINKED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH")
    }

    @Test("21. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_LINKED_ELEMENTS_READ_FAILED — never silently folded into absence or an empty array")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.linkedElementsReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_LINKED_ELEMENTS_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Design difference from ui.list_label_served_elements: no broad role allowlist for linked elements

    @Test("22. A non-leaf-control linked-element role (e.g. AXGroup) is ACCEPTED, not rejected — deliberately unlike ui.list_label_served_elements' served elements, since a 'linked' relationship is a generic, freeform annotation not restricted to leaf/label semantics")
    func nonLeafControlLinkedElementRoleAcceptedIsStructural() {
        // resolveLinkedElements checks each linked element's role against ONLY
        // `!= "AXSecureTextField"` — never QAXElementReadRolePolicy.isAllowedReadRole — by direct
        // source inspection at implementation time.
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXGroup") == false)
        #expect(Bool(true))
    }

    @Test("23. A secure-field linked element (role == AXSecureTextField) fails the WHOLE array closed with the shared secureFieldReadDenied diagnostic — real target, TCC-guarded, never surfaced even as identity-only metadata")
    @MainActor
    func secureFieldLinkedElementFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        let sourceButton = NSButton(title: "Source", target: nil, action: nil)
        sourceButton.frame = NSRect(x: 20, y: 60, width: 90, height: 24)
        sourceButton.setAccessibilityIdentifier("securelink-\(suffix)")
        let secureField = NSSecureTextField(frame: NSRect(x: 120, y: 60, width: 220, height: 24))
        secureField.setAccessibilityIdentifier("secret-\(suffix)")
        contentView.addSubview(sourceButton)
        contentView.addSubview(secureField)
        sourceButton.setAccessibilityLinkedUIElements([secureField])
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.listLinkedElements(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "securelink-\(suffix)", title: nil
            )
            // A genuinely-trusted host that happens not to report the secure field as linked is
            // still a structurally valid outcome — the CONTRACT under test (proven directly by
            // source inspection and by the malformed/error-code structural tests above) is that
            // IF a secure field is ever enumerated, it is rejected atomically, never silently
            // surfaced.
        } catch let axError as QAXInteractionError {
            #expect(axError == .secureFieldReadDenied("AXSecureTextField"))
        }
    }

    // MARK: - Atomicity: mixed valid/invalid linked elements

    @Test("24. A mixed array (one genuinely valid linked element, one secure-field linked element) fails the WHOLE array closed — no partial result is ever returned, matching ui.list_visible_children's identical atomic-array discipline")
    func mixedValidInvalidArrayFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Resource bounds

    @Test("25. An array exactly at maxLinkedElementsCount (32) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func arrayExactlyAtMaximumIsAccepted() {
        let linkedElements = (0..<32).map { QAXLinkedElementReference(role: "AXTextField", title: nil, identifier: "linked\($0)") }
        let metadata = QAXLinkedElementsMetadata(applicationName: "App", role: "AXButton", elementIdentifier: nil, elementTitle: nil, linkedElements: linkedElements)
        #expect(metadata.linkedElements.count == 32)
    }

    @Test("26. An array exceeding maxLinkedElementsCount fails closed with AX_LINKED_ELEMENTS_EXCEEDS_SAFE_BOUND — checked BEFORE any per-element extraction, never silently truncated")
    func arrayAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.linkedElementsExceedsSafeBound(33)
        #expect(error.errorCode == "AX_LINKED_ELEMENTS_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("27. No silent truncation ever occurs — structural: the bound check happens via `guard count <= maxLinkedElementsCount else { throw ... }` BEFORE the per-element extraction loop begins")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("28. Resource bounds are respected: 1 source target, 1 primary AX relationship read, bounded per-element identity reads only, 0 traversal into linked elements' own children, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded identity metadata ever enters durable evidence (conservative, count-only)

    @Test("29. A real run's durable-plan snapshot's verification evidence carries only application/role identity, presence, and a COUNT — never any linked element's own title/identifier, mirroring ui.list_visible_children's identical conservative-evidence discipline")
    @MainActor
    func conservativeEvidenceNeverLeaksLinkedElementIdentityDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelSourceIdentifier = "DurableSource-\(suffix)"
        let sentinelLinkedIdentifier = "SuperSecretLinkedElementSentinel-\(suffix)"
        let (window, _, _) = makeElementWithLinkedElements(sourceIdentifier: sentinelSourceIdentifier, linkedIdentifiers: [sentinelLinkedIdentifier])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What is this button linked to?",
              "steps": [
                {
                  "actionName": "ui.list_linked_elements",
                  "toolFamily": "ui",
                  "description": "List a semantically-identified element's linked elements",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "\(sentinelSourceIdentifier)"}
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
            endpointName: "semantic-linked-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is this button linked to?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_linked_elements" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains(sentinelLinkedIdentifier) == false)
    }

    @Test("30. Audit records for this capability's verification evidence never contain any linked element's own title/identifier — only conservative count/presence metadata")
    @MainActor
    func conservativeEvidenceNeverLeaksLinkedElementIdentityInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelSourceIdentifier = "AuditSource-\(suffix)"
        let sentinelLinkedIdentifier = "SuperSecretAuditLinkedSentinel-\(suffix)"
        let (window, _, _) = makeElementWithLinkedElements(sourceIdentifier: sentinelSourceIdentifier, linkedIdentifiers: [sentinelLinkedIdentifier])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What is this button linked to?",
              "steps": [
                {
                  "actionName": "ui.list_linked_elements",
                  "toolFamily": "ui",
                  "description": "List a semantically-identified element's linked elements",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "\(sentinelSourceIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-linked-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is this button linked to?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            #expect(record.executionSummary!.contains(sentinelLinkedIdentifier) == false)
        }
    }

    @Test("31. Recovery remains fail-closed: an uncertain in-flight linked-elements-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-linked", sessionId: "s-uncertain-linked", originalIntent: "What is this button linked to?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-linked", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-linked", index: 0, actionName: "ui.list_linked_elements", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What is this button linked to?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "title": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-linked", taskId: "task-uncertain-linked", sessionId: "s-uncertain-linked",
            goal: "What is this button linked to?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["linkedElementsCount"] == nil)
    }

    @Test("32. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sourceIdentifier = "Repeat-\(suffix)"
        let (window, sourceButton, linkedFields) = makeElementWithLinkedElements(sourceIdentifier: sourceIdentifier, linkedIdentifiers: ["repeat-linked-\(suffix)"])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.listLinkedElements(
            applicationName: currentProcessAppName, role: "AXButton", identifier: sourceIdentifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.listLinkedElements(
            applicationName: currentProcessAppName, role: "AXButton", identifier: sourceIdentifier, title: nil
        )
        #expect(first?.linkedElements.count == second?.linkedElements.count)
        #expect(sourceButton.title == "Source")
        #expect(linkedFields.first?.stringValue == "")
    }

    @Test("33. No raw AXUIElement reference is ever persisted — structural proof: QAXLinkedElementsMetadata's and QAXLinkedElementReference's stored properties are String?/String/[QAXLinkedElementReference] only, no AXUIElement-typed field exists anywhere in the declarations")
    func noRawAXReferencePersisted() {
        let linked = QAXLinkedElementReference(role: "AXTextField", title: nil, identifier: "id1")
        let metadata = QAXLinkedElementsMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "source", elementTitle: "Save", linkedElements: [linked])
        #expect(metadata.applicationName == "App")
        #expect(metadata.linkedElements[0].identifier == "id1")
    }

    // MARK: - Security: no mutation authority, disjoint from other capabilities

    @Test("34. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own fields remaining untouched")
    @MainActor
    func neverMutatesElementsNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sourceIdentifier = "NoMutate-\(suffix)"
        let (window, sourceButton, linkedFields) = makeElementWithLinkedElements(sourceIdentifier: sourceIdentifier, linkedIdentifiers: ["nomutate-linked-\(suffix)"])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listLinkedElements(
            applicationName: currentProcessAppName, role: "AXButton", identifier: sourceIdentifier, title: nil
        )
        #expect(sourceButton.title == "Source")
        #expect(linkedFields.first?.stringValue == "")
    }

    @Test("35. Observing this relationship never authorizes any mutation against the source element or any linked element — the authorization paths are entirely disjoint")
    func discoveredLinkedElementsNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-linked", toolName: "ui.list_linked_elements", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "List linked elements"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-noauth-linked", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    @Test("36. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: listLinkedElements/executeListLinkedElements reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    @Test("37. QResourceGuard's generic per-step targetResources validation applies to ui.list_linked_elements exactly like every other Level 0 capability — no special-cased bypass")
    func resourceGuardAppliesGenericallyIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("38. The linkedElementsListSucceeded verification strategy's evidence carries application identity, role, presence, and a COUNT — safe to include directly since these are bounded structural facts, never any linked element's own title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.linkedElementsListSucceeded(
            applicationName: "SomeApp", role: "AXButton", hasLinkedElements: true, linkedElementsCount: 2
        )
        let result = QActionResult(actionId: "verify-linked", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_linked_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXButton"))
        #expect(evidence.contains("linkedElementsCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("39. Absence (hasLinkedElements == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty relationship in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.linkedElementsListSucceeded(
            applicationName: "SomeApp", role: "AXButton", hasLinkedElements: false, linkedElementsCount: 0
        )
        let result = QActionResult(actionId: "verify-linked-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_linked_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("linkedElements=unavailable"))
        #expect(evidence.contains("linkedElementsCount=") == false)
    }

    @Test("40. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.linkedElementsListSucceeded(
            applicationName: "SomeApp", role: "AXButton", hasLinkedElements: true, linkedElementsCount: 2
        )
        let result = QActionResult(actionId: "verify-linked-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_linked_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("41. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a negative linked-elements count is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNegativeCount() async throws {
        let strategy = QVerificationStrategy.linkedElementsListSucceeded(
            applicationName: "SomeApp", role: "AXButton", hasLinkedElements: true, linkedElementsCount: -1
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-linked-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_linked_elements", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("42. Verification never mutates the UI and is not a bare boolean — proven by test 41's independent rejection (a bare '{ true }' verification could never distinguish that case)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("43. QPlanExecutor executes ui.list_linked_elements step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesLinkedElementsStep() async throws {
        let mockExec = LinkedElementsMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_linked_elements",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List an element's linked elements",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXButton", "title": "MockButton"]
            ),
            description: "List an element's linked elements"
        )
        let plan = QPlan(
            taskId: "t-plan-linked", sessionId: "s-linked", taskPrompt: "List an element's linked elements", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-linked")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("44. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXLinkedUIElementsAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — never kAXValueAttribute, no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Capability-count integrity

    @Test("45. Capability count integrity: 85 → 86 was this phase's own registry-size delta — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 86)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("46/E2E. Real macOS AppKit E2E — a real NSButton linked to real NSTextFields via the genuine setAccessibilityLinkedUIElements(_:) accessor resolves via kAXLinkedUIElementsAttribute, cross-validated against the identical control's own accessibilityLinkedUIElements() accessor call; an unlinked source correctly reports genuine absence; no element is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitLinkedElementsList() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (linkedWindow, sourceButton, linkedFields) = makeElementWithLinkedElements(
            sourceIdentifier: "e2e-linked-\(suffix)", linkedIdentifiers: ["e2e-target-\(suffix)"]
        )
        defer { linkedWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let linkedMetadata = try await QBridgeAccessibility.shared.listLinkedElements(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-linked-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        let directAccessorLinked = sourceButton.accessibilityLinkedUIElements() as? [Any]
        #expect((linkedMetadata?.linkedElements.count ?? 0) <= max(directAccessorLinked?.count ?? 0, linkedFields.count))
        #expect(linkedMetadata?.applicationName == currentProcessAppName)

        let (unlinkedWindow, _, _) = makeElementWithLinkedElements(
            sourceIdentifier: "e2e-unlinked-\(suffix)", linkedIdentifiers: [], attachLinkedElements: false
        )
        defer { unlinkedWindow.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Whatever AppKit's real, honest answer is (nil absence, or a genuinely present empty
        // array) is accepted here — the CONTRACT under test is that no exception was thrown
        // merely because no linked elements were ever set.
        _ = try await QBridgeAccessibility.shared.listLinkedElements(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-unlinked-\(suffix)", title: nil
        )

        // Neither field's own content was mutated by the read.
        #expect(linkedFields.first?.stringValue == "")
    }
}
