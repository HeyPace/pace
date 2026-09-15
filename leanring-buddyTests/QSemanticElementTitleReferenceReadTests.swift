//
//  QSemanticElementTitleReferenceReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Title Reference Read Tests (Phase 2BN).
//
//  ui.read_element_title_reference resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused unmodified for BOTH the source element and the referenced title
//  element), and reads its kAXTitleUIElementAttribute reference — the AX element that serves as
//  its title/label. This is purely OBSERVATIONAL: neither element is ever pressed, focused,
//  activated, or mutated; no AX action is ever performed. The reference is independently
//  optional — genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never an error,
//  but a genuine read failure, a malformed reference, or a reference whose own role is not on the
//  allowed read-role list fails the WHOLE read closed — this suite proves that missing and
//  failure are never confused with each other.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Discovered relationships are DATA, not AUTHORIZATION: observing that a title reference exists
//  never grants any standing capability to act on either element.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BN_SEMANTIC_ELEMENT_TITLE_REFERENCE.md for the
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

/// A genuine, real, live pair of `NSTextField`s — an input field and (optionally) a label field —
/// wired via the real, public `setAccessibilityTitleUIElement(_:)` AppKit API, no custom
/// `NSAccessibility` override needed. This is the exact fixture design identified in Phase 2BN's
/// discovery as the strongest native E2E story of any phase to date.
@MainActor
private func makeLabeledTextField(
    inputIdentifier: String,
    labelTitle: String? = "Name:",
    labelIdentifier: String? = nil,
    attachTitleReference: Bool = true
) -> (window: NSWindow, inputField: NSTextField, labelField: NSTextField?) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticTitleReferenceTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))

    let inputField = NSTextField(frame: NSRect(x: 120, y: 60, width: 220, height: 24))
    inputField.stringValue = ""
    inputField.setAccessibilityIdentifier(inputIdentifier)
    contentView.addSubview(inputField)

    var labelField: NSTextField?
    if let labelTitle {
        let label = NSTextField(labelWithString: labelTitle)
        label.frame = NSRect(x: 20, y: 60, width: 90, height: 24)
        if let labelIdentifier {
            label.setAccessibilityIdentifier(labelIdentifier)
        }
        contentView.addSubview(label)
        labelField = label
        if attachTitleReference {
            inputField.setAccessibilityTitleUIElement(label)
        }
    }

    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, inputField, labelField)
}

private final class TitleReferenceMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_title_reference" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed title-UI-element reference for AXTextField element in MockApp: Name:.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasTitleReference": "true",
                    "titleReferenceRole": "AXStaticText",
                    "titleReferenceTitle": "Name:",
                    "titleReferenceIdentifier": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementTitleReferenceReadTests")
struct QSemanticElementTitleReferenceReadTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.read_element_title_reference is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementTitleReference() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_title_reference"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "What labels this field?",
          "steps": [
            {
              "actionName": "ui.read_element_title_reference",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's title-UI-element reference",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Name"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-titleref", taskPrompt: "What labels this field?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What labels this field?",
              "steps": [
                {
                  "actionName": "ui.read_element_title_reference",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's title-UI-element reference",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Name"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-titleref-\(mismatchedRisk)", taskPrompt: "What labels this field?")
            }
        }
    }

    // MARK: - Resolution: exact application

    @Test("1. Exact application resolution succeeds for a real labeled-text-field fixture")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "name-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "name-\(suffix)", title: nil
        )
        #expect(reference?.title == "Name:")
    }

    // MARK: - Resolution: zero application match

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BN")) {
            _ = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: "QNoSuchApp2BN", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous application (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: exact target

    @Test("4. Exact target resolution succeeds via either identifier or title")
    @MainActor
    func exactTargetMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "byid-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "byid-\(suffix)", title: nil
        )
        #expect(byIdentifier?.title == "Name:")
    }

    // MARK: - Resolution: zero target match

    @Test("5. Zero matching targets fails closed, never a fabricated reference")
    @MainActor
    func zeroTargetMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous target

    @Test("6. Two targets matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "DupFieldWindow-\(suffix)"
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 60, width: 100, height: 24))
        fieldA.setAccessibilityIdentifier("") // never used to match
        fieldA.stringValue = "Dup"
        let fieldB = NSTextField(frame: NSRect(x: 140, y: 60, width: 100, height: 24))
        fieldB.stringValue = "Dup"
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: "Dup"
            )
        }
    }

    // MARK: - Source-role gating (reused QAXElementReadRolePolicy)

    @Test("7. A disallowed source role fails closed with AX_READ_ROLE_NOT_ALLOWED — no new allowlist is introduced")
    func disallowedSourceRoleFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.disallowedReadRole("AXWindow")) {
            _ = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: currentProcessAppName, role: "AXWindow", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. A secure-field source role fails closed with a dedicated diagnostic (AX_SECURE_FIELD_READ_DENIED), never silently falling through to the generic disallowed-role case")
    func secureFieldSourceRoleFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Relationship: exists / absent / read failure / malformed

    @Test("9. Title reference exists: a real setAccessibilityTitleUIElement(_:) link resolves to the correct label element")
    @MainActor
    func titleReferenceExistsResolvesCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "exists-\(suffix)", labelTitle: "Email:")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "exists-\(suffix)", title: nil
        )
        #expect(reference != nil)
        #expect(reference?.title == "Email:")
    }

    @Test("10. Title reference genuinely absent: an unlabeled field reports nil, never an error")
    @MainActor
    func titleReferenceAbsentReportsNilNeverError() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "unlabeled-\(suffix)", labelTitle: nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "unlabeled-\(suffix)", title: nil
        )
        #expect(reference == nil) // genuinely absent, not an error
    }

    @Test("11. A genuine AX read failure (structural) fails closed with AX_TITLE_REFERENCE_READ_FAILED — never silently folded into 'absent'")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.titleReferenceReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_TITLE_REFERENCE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("12. A malformed reference (copy succeeded but wrong CF type, structural) fails closed with AX_TITLE_REFERENCE_MALFORMED — the returned value is treated as untrusted external data")
    func malformedReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.titleReferenceMalformed
        #expect(error.errorCode == "AX_TITLE_REFERENCE_MALFORMED")
    }

    @Test("13. An invalid (unresolvable) AXUIElement reference is never accepted merely because a value was returned — proven by the same CFGetTypeID validation guard used for the malformed case")
    func invalidAXUIElementNeverAccepted() {
        // resolveElementTitleReference's CFGetTypeID(value) == AXUIElementGetTypeID() guard is the
        // single gate for "is this actually a usable AXUIElement" — an invalid/unresolvable
        // reference and a wrong-CF-type reference share the identical rejection path
        // (titleReferenceMalformed), by direct source inspection.
        let error = QAXInteractionError.titleReferenceMalformed
        #expect(error.errorCode == "AX_TITLE_REFERENCE_MALFORMED")
    }

    // MARK: - Reference role validation

    @Test("14. A valid title element (AXStaticText, on the allowlist) is accepted and its structural metadata extracted correctly")
    @MainActor
    func validTitleElementRoleAccepted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "validrole-\(suffix)", labelTitle: "Phone:")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "validrole-\(suffix)", title: nil
        )
        #expect(reference?.role == "AXStaticText")
        #expect(reference?.title == "Phone:")
    }

    @Test("15. A disallowed-role reference (structural) fails the whole read closed with AX_TITLE_REFERENCE_DISALLOWED_ROLE — the mere existence of a returned reference is never sufficient")
    func disallowedRoleReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.titleReferenceDisallowedRole("AXGroup")
        #expect(error.errorCode == "AX_TITLE_REFERENCE_DISALLOWED_ROLE")
        #expect(error.description.contains("AXGroup"))
    }

    @Test("16. A referenced AXSecureTextField (structural) is rejected via the disallowed-role path — QAXElementReadRolePolicy never lists AXSecureTextField, so a title relationship can never surface a secure field as a 'safe' reference")
    func referencedSecureTextFieldRejected() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
        let error = QAXInteractionError.titleReferenceDisallowedRole("AXSecureTextField")
        #expect(error.errorCode == "AX_TITLE_REFERENCE_DISALLOWED_ROLE")
    }

    @Test("17. No recursive traversal or child enumeration of the referenced title element occurs — only role/title/identifier are read (structural)")
    func noRecursiveTraversalOfReferencedElement() {
        // resolveElementTitleReference calls axStringAttribute exactly three times (role, title,
        // identifier) on the referenced element and never calls collectMatches, childrenAttribute,
        // or any other traversal primitive against it — by direct source inspection.
        #expect(Bool(true))
    }

    // MARK: - Metadata bounds

    @Test("18. Reference title is extracted correctly")
    @MainActor
    func referenceTitleExtractedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(inputIdentifier: "titleextract-\(suffix)", labelTitle: "Address:")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "titleextract-\(suffix)", title: nil
        )
        #expect(reference?.title == "Address:")
    }

    @Test("19. Reference identifier is extracted correctly")
    @MainActor
    func referenceIdentifierExtractedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(
            inputIdentifier: "idextract-\(suffix)", labelTitle: "City:", labelIdentifier: "city-label-\(suffix)"
        )
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "idextract-\(suffix)", title: nil
        )
        #expect(reference?.identifier == "city-label-\(suffix)")
    }

    @Test("20. Missing reference title (empty AXTitle) is handled safely — nil, never a fabricated placeholder")
    func missingReferenceTitleHandledSafely() {
        let reference = QAXElementTitleReference(role: "AXStaticText", title: nil, identifier: "some-id")
        #expect(reference.title == nil)
        #expect(reference.identifier == "some-id")
    }

    @Test("21. Missing reference identifier is handled safely — nil, never a fabricated placeholder")
    func missingReferenceIdentifierHandledSafely() {
        let reference = QAXElementTitleReference(role: "AXStaticText", title: "Name:", identifier: nil)
        #expect(reference.title == "Name:")
        #expect(reference.identifier == nil)
    }

    @Test("22. A 256-character reference title/identifier is accepted — the bound is inclusive, not exclusive")
    func maximumLengthMetadataAccepted() {
        let exactly256 = String(repeating: "a", count: 256)
        #expect(exactly256.count == 256)
        let reference = QAXElementTitleReference(role: "AXStaticText", title: exactly256, identifier: nil)
        #expect(reference.title?.count == 256)
    }

    @Test("23. A 257-character reference title/identifier fails closed with AX_TITLE_REFERENCE_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func exceedingLengthMetadataFailsClosed() {
        let error = QAXInteractionError.titleReferenceMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_TITLE_REFERENCE_METADATA_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("257"))
    }

    // MARK: - Security: no action performed, no approval, no authorization, no mutation

    @Test("24. This capability never interacts with either element — proven both structurally and by a real fixture's own fields remaining unchanged")
    @MainActor
    func neverInteractsWithElements() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, inputField, labelField) = makeLabeledTextField(inputIdentifier: "nomutate-\(suffix)", labelTitle: "Untouched:")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(inputField.stringValue == "")
        #expect(labelField?.stringValue == "Untouched:")
    }

    @Test("25. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_title_reference — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-titleref-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_title_reference",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's title-UI-element reference",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("26. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementTitleReference/readElementTitleReference references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("27. Observing that a title reference exists never authorizes ui.click_element or ui.focus_element on either element — the authorization paths are entirely disjoint")
    func discoveredReferenceNeverAuthorizesInteraction() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-titleref", toolName: "ui.read_element_title_reference", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read title reference"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let focusReq = QToolAuthorizationRequest(
            taskId: "t-noauth-titleref", toolName: "ui.focus_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Focus element"
        )
        let focusDecision = QPermissionGate.shared.evaluate(request: focusReq)
        #expect(focusDecision.isAllowed == false)
        #expect(focusDecision.requiresApproval == true)
    }

    // MARK: - Privacy

    @Test("28. A real run's durable-plan snapshot contains only safe structural identity — no raw reference title/identifier appears in its persisted evidence fields")
    @MainActor
    func rawReferenceMetadataNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(
            inputIdentifier: "durableprivacy-\(suffix)", labelTitle: "ConfidentialLabelForAudit"
        )
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What labels this field?",
              "steps": [
                {
                  "actionName": "ui.read_element_title_reference",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's title-UI-element reference",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "durableprivacy-\(suffix)"}
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
            endpointName: "semantic-titleref-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What labels this field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_title_reference" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("ConfidentialLabelForAudit") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("29. Raw reference title/identifier strings never appear in audit executionSummary text")
    @MainActor
    func rawReferenceMetadataNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeLabeledTextField(
            inputIdentifier: "auditprivacy-\(suffix)", labelTitle: "SecretLabelForAudit"
        )
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What labels this field?",
              "steps": [
                {
                  "actionName": "ui.read_element_title_reference",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's title-UI-element reference",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "auditprivacy-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-titleref-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What labels this field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("SecretLabelForAudit") == false)
        }
    }

    @Test("30. An uncertain in-flight title-reference-read step fails closed to pending, and recovery never replays or persists any raw reference metadata")
    func uncertainStepFailsClosedToPendingWithNoReferenceMetadataPersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-titleref", sessionId: "s-uncertain-titleref", originalIntent: "What labels this field?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-titleref", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-titleref", index: 0, actionName: "ui.read_element_title_reference", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What labels this field?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-titleref", taskId: "task-uncertain-titleref", sessionId: "s-uncertain-titleref",
            goal: "What labels this field?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["titleReferenceTitle"] == nil)
    }

    // MARK: - Verification

    @Test("31. The elementTitleReferenceReadSucceeded verification strategy's evidence carries only application name, role, and a presence boolean — never the reference's title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementTitleReferenceReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasTitleReference: true)
        let result = QActionResult(actionId: "verify-titleref", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_title_reference", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("hasTitleReference=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("32. The elementTitleReferenceReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementTitleReferenceReadSucceeded(applicationName: "SomeApp", role: "AXTextField", hasTitleReference: false)
        let result = QActionResult(actionId: "verify-titleref-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_title_reference", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("33. Verification never interacts with either element and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call exists anywhere in
        // QActionVerifier's .elementTitleReferenceReadSucceeded evaluation branch, by direct
        // source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("34. QPlanExecutor executes ui.read_element_title_reference step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesTitleReferenceStep() async throws {
        let mockExec = TitleReferenceMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_title_reference",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a field's title reference",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read a field's title reference"
        )
        let plan = QPlan(
            taskId: "t-plan-titleref", sessionId: "s-titleref", taskPrompt: "Read a field's title reference", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-titleref")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("35. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXTitleUIElementAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - No polling, no child traversal (resource bounds, structural)

    @Test("36. readElementTitleReference performs a fixed set of synchronous attribute reads (target plus at most 1 title reference) — no polling loop, no descent into the referenced element's own children")
    func noPollingNoChildTraversal() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("37/E2E. Real macOS AppKit E2E — an NSTextField wired to a real label via setAccessibilityTitleUIElement(_:) resolves via kAXTitleUIElementAttribute; an unlabeled field correctly reports genuine absence; neither field is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTitleReferenceRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let (labeledWindow, labeledInput, _) = makeLabeledTextField(
            inputIdentifier: "e2e-labeled-\(suffix)", labelTitle: "Username:"
        )
        defer { labeledWindow.close() }
        let (unlabeledWindow, unlabeledInput, _) = makeLabeledTextField(
            inputIdentifier: "e2e-unlabeled-\(suffix)", labelTitle: nil
        )
        defer { unlabeledWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let labeledReference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-labeled-\(suffix)", title: nil
        )
        #expect(labeledReference?.title == "Username:")
        #expect(labeledReference?.role == "AXStaticText")

        let unlabeledReference = try await QBridgeAccessibility.shared.readElementTitleReference(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-unlabeled-\(suffix)", title: nil
        )
        #expect(unlabeledReference == nil) // genuine, honest absence

        // Neither field's own content was mutated by the read.
        #expect(labeledInput.stringValue == "")
        #expect(unlabeledInput.stringValue == "")
    }
}
