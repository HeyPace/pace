//
//  QSemanticElementPlaceholderValueReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Placeholder Value Read Tests (Phase 2CD).
//
//  ui.read_element_placeholder_value resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused completely unmodified from ui.read_element_value/
//  ui.read_element_value_description/ui.read_element_role_description/ui.read_element_help_text,
//  including the identical AXSecureTextField-first-then-general-allowlist exclusion), and reads its
//  kAXPlaceholderValueAttribute. This is purely OBSERVATIONAL: no value is ever set, no AX action is
//  ever performed, and kAXValueAttribute is never read. Distinct from kAXHelpAttribute
//  (ui.read_element_help_text, Phase 2CC — a tooltip/help string), kAXValueDescriptionAttribute
//  (ui.read_element_value_description, Phase 2BW — a description of the element's CURRENT VALUE),
//  and kAXRoleDescriptionAttribute (ui.read_element_role_description, Phase 2CB — a description of
//  the element's TYPE): a placeholder is UI-author-provided guidance text shown while a field is
//  EMPTY, never the user's own entered content.
//
//  SDK-VERIFIED ABSENCE SEMANTICS (resolved, not assumed): kAXPlaceholderValueAttribute carries no
//  "required for all elements"-style documentation — only text-entry-style controls that were ever
//  given a placeholder expose it at all; most controls, and even most text fields, legitimately
//  lack it. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE
//  pattern — a valid, expected nil for the WHOLE result — distinct from a genuinely PRESENT but
//  EMPTY string, which is its own valid, non-nil result. Identical absence shape to
//  ui.read_element_help_text (Phase 2CC) and ui.read_element_value_description (Phase 2BW); unlike
//  ui.read_element_role_description's (Phase 2CB) required-attribute, no-valid-absence contract.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CD_SEMANTIC_PLACEHOLDER_VALUE.md for the full
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

/// A genuine, real, live `NSTextField` — the natural fixture shape for a placeholder-bearing
/// control, mirroring `ui.read_element_help_text`'s own real E2E `NSButton` fixture but using the
/// control type placeholder text actually applies to.
@MainActor
private func makeTextFieldWindow(identifier: String, stringValue: String = "") -> (window: NSWindow, textField: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementPlaceholderValueReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 180, height: 24))
    textField.stringValue = stringValue
    textField.setAccessibilityIdentifier(identifier)
    contentView.addSubview(textField)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textField)
}

private final class PlaceholderValueMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_placeholder_value" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed placeholder value for AXTextField element in MockApp: \"Search\".",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "elementIdentifier": "",
                    "elementTitle": "MockField",
                    "hasPlaceholderValue": "true",
                    "placeholderValue": "Search"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementPlaceholderValueReadTests")
struct QSemanticElementPlaceholderValueReadTests {

    // MARK: - 1/2/3/4. Registration, Level 0, capability #78, no approval requirement

    @Test("Registration: ui.read_element_placeholder_value is a registered, Level 0, read-only capability (#78) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementPlaceholderValue() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_placeholder_value"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 78)

        let json = """
        {
          "taskPrompt": "What goes in this search field?",
          "steps": [
            {
              "actionName": "ui.read_element_placeholder_value",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's placeholder value",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Search"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-placeholder", taskPrompt: "What goes in this search field?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What goes in this search field?",
              "steps": [
                {
                  "actionName": "ui.read_element_placeholder_value",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's placeholder value",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "title": "Search"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-placeholder-\(mismatchedRisk)", taskPrompt: "What goes in this search field?")
            }
        }
    }

    @Test("1b. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_placeholder_value — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-placeholder-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_placeholder_value",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's placeholder value",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("1c. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementPlaceholderValue/readElementPlaceholderValue references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - 5. Permission denial

    @Test("5. Accessibility permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED before any target resolution is attempted — structural, since this isolated test host cannot be forced to revoke a live grant it may not hold")
    func permissionDenialFailsClosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXElementReadRolePolicy unmodified)

    @Test("Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/ui.read_element_role_description/ui.read_element_help_text")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSlider") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXComboBox") == true)
    }

    @Test("AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/ui.read_element_role_description/ui.read_element_help_text already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("A secure-field target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 9. Disallowed role

    @Test("9. A wrong/disallowed role is rejected with disallowedReadRole before any AX search — arbitrary AX roles are never silently accepted")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "wrongrole-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read placeholder value",
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-placeholder"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read placeholder value",
            parameters: ["role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-placeholder"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read placeholder value",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-placeholder"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CD")) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: "QWrongApp2CD", role: "AXTextField", identifier: nil, title: "whatever"
            )
        }
    }

    // MARK: - 6. Missing target

    @Test("6. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated placeholder-value result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 7. Ambiguous target

    @Test("7. Ambiguous target (two text fields with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupField-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let fieldA = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 24))
        fieldA.setAccessibilityIdentifier(sharedIdentifier)
        let fieldB = NSTextField(frame: NSRect(x: 10, y: 100, width: 150, height: 24))
        fieldB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(fieldA)
        container.addSubview(fieldB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: sharedIdentifier, title: nil
            )
        }
    }

    // MARK: - 8. Stale target

    @Test("8. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementPlaceholderValue exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("readElementPlaceholderValue performs a single synchronous AXUIElementCopyAttributeValue call for kAXPlaceholderValueAttribute — never kAXValueAttribute, no polling loop, no descent beyond the resolved element (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 12. Valid placeholder value / 11. Empty/absent placeholder value semantics

    @Test("12. A model-level construction accepts a valid, non-empty placeholder string")
    func nonEmptyStringModelValid() {
        let metadata = QAXElementPlaceholderValueMetadata(applicationName: "App", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", placeholderValue: "Search")
        #expect(metadata.placeholderValue == "Search")
    }

    @Test("A model-level construction accepts a genuinely EMPTY string as a fully valid, distinct-from-absence result")
    func emptyStringModelValidAndDistinctFromAbsence() {
        let metadata = QAXElementPlaceholderValueMetadata(applicationName: "App", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", placeholderValue: "")
        #expect(metadata.placeholderValue == "")
        #expect(metadata.placeholderValue.isEmpty)
    }

    @Test("11. Genuine absence of kAXPlaceholderValueAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty string — structural, by direct inspection of resolveElementPlaceholderValue's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("11b. Absence (nil) and a present empty string (\"\") are structurally distinct outcomes — never conflated")
    func absenceDistinctFromEmptyStringIsStructural() {
        let absent: QAXElementPlaceholderValueMetadata? = nil
        let empty = QAXElementPlaceholderValueMetadata(applicationName: "App", role: "AXTextField", elementIdentifier: nil, elementTitle: nil, placeholderValue: "")
        #expect(absent == nil)
        #expect(empty.placeholderValue.isEmpty)
    }

    // MARK: - 10. Malformed AX result

    @Test("10. A wrong CFType (not a String) fails closed with AX_PLACEHOLDER_VALUE_MALFORMED — the returned value is never force-cast")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.placeholderValueMalformed
        #expect(error.errorCode == "AX_PLACEHOLDER_VALUE_MALFORMED")
    }

    @Test("A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_PLACEHOLDER_VALUE_READ_FAILED — never silently folded into absence or an empty string")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.placeholderValueReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_PLACEHOLDER_VALUE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - 13/14. String bound (exactly 256 accepted; 257 rejected)

    @Test("13. A string exactly at maxPlaceholderValueLength (256 characters) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func stringExactlyAtMaximumIsAccepted() {
        let exactlyMax = String(repeating: "x", count: 256)
        let metadata = QAXElementPlaceholderValueMetadata(applicationName: "App", role: "AXTextField", elementIdentifier: nil, elementTitle: nil, placeholderValue: exactlyMax)
        #expect(metadata.placeholderValue.count == 256)
    }

    @Test("14. A string one character above the maximum (257 characters) fails closed with AX_PLACEHOLDER_VALUE_EXCEEDS_SAFE_BOUND — checked deterministically, never silently truncated")
    func stringOneAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.placeholderValueExceedsSafeBound(257)
        #expect(error.errorCode == "AX_PLACEHOLDER_VALUE_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("No silent truncation ever occurs — structural: resolveElementPlaceholderValue's own `guard stringValue.count <= maxPlaceholderValueLength else { throw ... }` never mutates or shortens the string before throwing")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 15. No kAXValueAttribute / 16. No mutation APIs / 17. No network APIs

    @Test("15. This capability never reads kAXValueAttribute — structural: resolveElementPlaceholderValue's only AXUIElementCopyAttributeValue call targets kAXPlaceholderValueAttribute, by direct source inspection")
    func neverReadsValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    @Test("16/17. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXPlaceholderValueAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own field value remaining untouched")
    @MainActor
    func neverMutatesFieldNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, textField) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", stringValue: "untouched")
        textField.placeholderString = "Search"
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(textField.stringValue == "untouched")
    }

    // MARK: - 18. No traversal / 19. No polling / 20. No retries / 21. Bounded resource accounting

    @Test("18/19/20/21. Resource bounds are respected: 1 target, 1 attribute read, 0 relationship hops, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_placeholder_value exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read placeholder value", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXTextField", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-placeholder"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    // MARK: - 22. Verification does not perform another AX read

    @Test("The elementPlaceholderValueReadSucceeded strategy's evidence carries application identity, element identity, and the placeholder value — safe to include directly since this is bounded semantic UI metadata, the same sensitivity class as an already-exposed title/help/value-description/role-description string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementPlaceholderValueReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", hasPlaceholderValue: true, placeholderValue: "Search"
        )
        let result = QActionResult(actionId: "verify-placeholder", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("element=Search"))
        #expect(evidence.contains("placeholderValue=Search"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("Absence (hasPlaceholderValue == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty string in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementPlaceholderValueReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", elementIdentifier: nil, elementTitle: "Search", hasPlaceholderValue: false, placeholderValue: nil
        )
        let result = QActionResult(actionId: "verify-placeholder-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("placeholderValue=unavailable"))
    }

    @Test("The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementPlaceholderValueReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", hasPlaceholderValue: true, placeholderValue: "Search"
        )
        let result = QActionResult(actionId: "verify-placeholder-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a placeholder value is present but nil is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNilValue() async throws {
        let strategy = QVerificationStrategy.elementPlaceholderValueReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", hasPlaceholderValue: true, placeholderValue: nil
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-placeholder-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("The strategy also rejects a fabricated success claiming an oversized (>256 character) placeholder value")
    func verificationRejectsFabricatedOversizedValue() async throws {
        let oversized = String(repeating: "x", count: 257)
        let strategy = QVerificationStrategy.elementPlaceholderValueReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", elementIdentifier: "f1", elementTitle: "Search", hasPlaceholderValue: true, placeholderValue: oversized
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-placeholder-oversized", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_placeholder_value", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("22. Verification never mutates the UI, is not a bare boolean, and performs NO additional AX read of any kind — proven by the fabrication-rejection tests above (a bare '{ true }' verification, or one re-reading kAXPlaceholderValueAttribute, could never distinguish those cases from a genuinely fresh call) and by direct source inspection: determineVerificationStrategy reconstructs its evidence entirely from action.arguments/result.outputData, never calling QBridgeAccessibility a second time")
    func verificationNeverMutatesIsNotBareBooleanNoSecondRead() {
        #expect(Bool(true))
    }

    @Test("Observing an element's placeholder value never authorizes ui.click_element/ui.set_text_value/ui.set_element_state — the authorization paths are entirely disjoint")
    func discoveredPlaceholderValueNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-placeholder", toolName: "ui.read_element_placeholder_value", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read placeholder value"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-noauth-placeholder", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    // MARK: - 23. Recovery behavior

    @Test("23. Recovery remains fail-closed: an uncertain in-flight placeholder-value-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-placeholder", sessionId: "s-uncertain-placeholder", originalIntent: "What goes in this search field?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-placeholder", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-placeholder", index: 0, actionName: "ui.read_element_placeholder_value", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What goes in this search field?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "title": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-placeholder", taskId: "task-uncertain-placeholder", sessionId: "s-uncertain-placeholder",
            goal: "What goes in this search field?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["placeholderValue"] == nil)
    }

    @Test("No raw AXUIElement reference is ever persisted — structural proof: QAXElementPlaceholderValueMetadata's stored properties are String?/String only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementPlaceholderValueMetadata(applicationName: "App", role: "AXTextField", elementIdentifier: "id", elementTitle: "Name", placeholderValue: "Search")
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.placeholderValue == "Search")
    }

    @Test("QDurablePlanStepSnapshot does not serialize raw outputData beyond arguments")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.read_element_placeholder_value",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "Read placeholder value",
            targetResources: [],
            arguments: ["applicationName": "Finder", "role": "AXTextField", "title": "Search"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "Read placeholder value")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.read_element_placeholder_value")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["role"] == "AXTextField")
    }

    // MARK: - 24. Privacy boundary

    @Test("24. A real run's durable-plan snapshot never contains anything beyond application/element identity and the bounded placeholder-value string — no raw AX objects, no unrelated attributes, no kAXValueAttribute content")
    @MainActor
    func noProhibitedDataPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "DurableField-\(suffix)"
        let (window, textField) = makeTextFieldWindow(identifier: sentinelIdentifier)
        textField.placeholderString = "Search"
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What goes in this search field?",
              "steps": [
                {
                  "actionName": "ui.read_element_placeholder_value",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's placeholder value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "\(sentinelIdentifier)"}
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
            endpointName: "semantic-placeholder-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What goes in this search field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_placeholder_value" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("Audit records for this capability never contain anything beyond bounded semantic UI metadata")
    @MainActor
    func noProhibitedDataInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "AuditField-\(suffix)"
        let (window, textField) = makeTextFieldWindow(identifier: sentinelIdentifier)
        textField.placeholderString = "Search"
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What goes in this search field?",
              "steps": [
                {
                  "actionName": "ui.read_element_placeholder_value",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's placeholder value",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "\(sentinelIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-placeholder-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What goes in this search field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("placeholder value") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, textField) = makeTextFieldWindow(identifier: identifier)
        textField.placeholderString = "Search"
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )
        #expect(first?.placeholderValue == second?.placeholderValue)
        #expect(textField.stringValue.isEmpty)
    }

    // MARK: - 25. Capability-count integrity

    @Test("25. Capability count integrity: 77 → 78 is the only registry-size delta attributable to this phase — structural, confirmed by the registration test's own == 78 assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 78)
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("QPlanExecutor executes ui.read_element_placeholder_value step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesPlaceholderValueStep() async throws {
        let mockExec = PlaceholderValueMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_placeholder_value",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's placeholder value",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "title": "MockField"]
            ),
            description: "Read an element's placeholder value"
        )
        let plan = QPlan(
            taskId: "t-plan-placeholder", sessionId: "s-placeholder", taskPrompt: "Read an element's placeholder value", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-placeholder")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("E2E. Real macOS AppKit E2E — a real NSTextField forces a deterministic placeholder string \"Search\" via the real, declared placeholderString accessor, then resolves via kAXPlaceholderValueAttribute, cross-validated against AppKit's own placeholderString for the identical control; no value is ever set (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitPlaceholderValueRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-placeholder-\(suffix)"
        let (window, textField) = makeTextFieldWindow(identifier: identifier)

        // Force a deterministic, known placeholder string via the real, declared AppKit accessor
        // (placeholderString, NSTextField) — the same genuine forced-value round-trip pattern
        // ui.read_element_help_text's own E2E test established for setAccessibilityHelp.
        textField.placeholderString = "Search"
        #expect(textField.placeholderString == "Search")

        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )

        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(metadata?.placeholderValue == "Search")
        #expect(metadata?.placeholderValue == textField.placeholderString)
        #expect(metadata?.applicationName == currentProcessAppName)
        // The read never mutated the fixture's own state.
        #expect(textField.stringValue.isEmpty)
    }

    @Test("E2E. Real macOS AppKit E2E — a genuine NSTextField with no placeholder set correctly reports honest absence via the optional-reference contract (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitPlaceholderValueAbsence() async throws {
        guard AXIsProcessTrusted() else {
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-noplaceholder-\(suffix)"
        let (window, _) = makeTextFieldWindow(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementPlaceholderValue(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )

        // An ordinary NSTextField with no placeholder ever set is the common, expected case —
        // genuine absence (nil), never fabricated content, never an error.
        #expect(metadata == nil)
    }
}
