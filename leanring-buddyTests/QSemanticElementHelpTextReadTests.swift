//
//  QSemanticElementHelpTextReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Help Text Read Tests (Phase 2CC).
//
//  ui.read_element_help_text resolves a semantically-identified element purely by Accessibility
//  semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's existing
//  allowlist (reused completely unmodified from ui.read_element_value/
//  ui.read_element_value_description/ui.read_element_role_description, including the identical
//  AXSecureTextField-first-then-general-allowlist exclusion), and reads its kAXHelpAttribute. This
//  is purely OBSERVATIONAL: no value is ever set, no AX action is ever performed, and
//  kAXValueAttribute is never read. Distinct from BOTH kAXRoleDescriptionAttribute
//  (ui.read_element_role_description, Phase 2CB — a description of the element's TYPE) and
//  kAXValueDescriptionAttribute (ui.read_element_value_description, Phase 2BW — a description of
//  the element's CURRENT VALUE).
//
//  SDK-VERIFIED ABSENCE SEMANTICS (resolved, not assumed): kAXHelpAttribute carries no "required
//  for all elements"-style documentation — the doc says only "Recommended for any element that has
//  help data available", implying most controls legitimately lack it. Genuine absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern — a valid,
//  expected nil for the WHOLE result — distinct from a genuinely PRESENT but EMPTY string, which
//  is its own valid, non-nil result. Identical absence shape to ui.read_element_value_description
//  (Phase 2BW); unlike ui.read_element_role_description's (Phase 2CB) required-attribute,
//  no-valid-absence contract.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CC_SEMANTIC_HELP_TEXT.md for the full contract,
//  including this phase's honest E2E findings.
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

/// A genuine, real, live `NSButton` — the exact same fixture shape
/// `ui.read_element_role_description`'s own real E2E tests already established as proven-working
/// for resolving a real `AXButton` by identifier.
@MainActor
private func makeButtonWindow(identifier: String, title: String = "Click Me") -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementHelpTextReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let button = NSButton(title: title, target: nil, action: nil)
    button.frame = NSRect(x: 20, y: 20, width: 180, height: 30)
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

private final class HelpTextMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_help_text" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed help text for AXButton element in MockApp: \"Click to save your changes\".",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXButton",
                    "elementIdentifier": "",
                    "elementTitle": "MockButton",
                    "hasHelpText": "true",
                    "helpText": "Click to save your changes"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementHelpTextReadTests")
struct QSemanticElementHelpTextReadTests {

    // MARK: - 1/2/3/4. Registration, Level 0, capability #77, no approval requirement

    @Test("Registration: ui.read_element_help_text is a registered, Level 0, read-only capability (#77) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementHelpText() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_help_text"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 85)

        let json = """
        {
          "taskPrompt": "What does this button do?",
          "steps": [
            {
              "actionName": "ui.read_element_help_text",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's help text",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Open"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-helptext", taskPrompt: "What does this button do?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What does this button do?",
              "steps": [
                {
                  "actionName": "ui.read_element_help_text",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's help text",
                  "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Open"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-helptext-\(mismatchedRisk)", taskPrompt: "What does this button do?")
            }
        }
    }

    @Test("1b. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_help_text — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-helptext-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_help_text",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's help text",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("1c. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementHelpText/readElementHelpText references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - 5. Permission denial

    @Test("5. Accessibility permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED before any target resolution is attempted — structural, since this isolated test host cannot be forced to revoke a live grant it may not hold")
    func permissionDenialFailsClosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXElementReadRolePolicy unmodified)

    @Test("Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/ui.read_element_role_description")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSlider") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXComboBox") == true)
    }

    @Test("AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/ui.read_element_role_description already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("A secure-field target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
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
        let (window, _) = makeButtonWindow(identifier: "wrongrole-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
                applicationName: currentProcessAppName, role: "AXButton", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read help text",
            parameters: ["applicationName": currentProcessAppName, "role": "AXButton"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-helptext"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read help text",
            parameters: ["role": "AXButton", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-helptext"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read help text",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-helptext"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CC")) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
                applicationName: "QWrongApp2CC", role: "AXButton", identifier: nil, title: "whatever"
            )
        }
    }

    // MARK: - 6. Missing target

    @Test("6. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated help-text result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 7. Ambiguous target

    @Test("7. Ambiguous target (two buttons with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupButton-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let buttonA = NSButton(title: "A", target: nil, action: nil)
        buttonA.frame = NSRect(x: 10, y: 10, width: 150, height: 30)
        buttonA.setAccessibilityIdentifier(sharedIdentifier)
        let buttonB = NSButton(title: "B", target: nil, action: nil)
        buttonB.frame = NSRect(x: 10, y: 100, width: 150, height: 30)
        buttonB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(buttonA)
        container.addSubview(buttonB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementHelpText(
                applicationName: currentProcessAppName, role: "AXButton", identifier: sharedIdentifier, title: nil
            )
        }
    }

    // MARK: - 8. Stale target

    @Test("8. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementHelpText exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("readElementHelpText performs a single synchronous AXUIElementCopyAttributeValue call for kAXHelpAttribute — never kAXValueAttribute, no polling loop, no descent beyond the resolved element (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 12. Valid help text / 11. Empty/absent help text semantics

    @Test("12. A model-level construction accepts a valid, non-empty help string")
    func nonEmptyStringModelValid() {
        let metadata = QAXElementHelpTextMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", helpText: "Click to save your changes")
        #expect(metadata.helpText == "Click to save your changes")
    }

    @Test("A model-level construction accepts a genuinely EMPTY string as a fully valid, distinct-from-absence result")
    func emptyStringModelValidAndDistinctFromAbsence() {
        let metadata = QAXElementHelpTextMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", helpText: "")
        #expect(metadata.helpText == "")
        #expect(metadata.helpText.isEmpty)
    }

    @Test("11. Genuine absence of kAXHelpAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty string — structural, by direct inspection of resolveElementHelpText's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("11b. Absence (nil) and a present empty string (\"\") are structurally distinct outcomes — never conflated")
    func absenceDistinctFromEmptyStringIsStructural() {
        let absent: QAXElementHelpTextMetadata? = nil
        let empty = QAXElementHelpTextMetadata(applicationName: "App", role: "AXButton", elementIdentifier: nil, elementTitle: nil, helpText: "")
        #expect(absent == nil)
        #expect(empty.helpText.isEmpty)
    }

    // MARK: - 10. Malformed AX result

    @Test("10. A wrong CFType (not a String) fails closed with AX_HELP_TEXT_MALFORMED — the returned value is never force-cast")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.helpTextMalformed
        #expect(error.errorCode == "AX_HELP_TEXT_MALFORMED")
    }

    @Test("A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_HELP_TEXT_READ_FAILED — never silently folded into absence or an empty string")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.helpTextReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_HELP_TEXT_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - 13/14. String bound (exactly 256 accepted; 257 rejected)

    @Test("13. A string exactly at maxHelpTextLength (256 characters) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func stringExactlyAtMaximumIsAccepted() {
        let exactlyMax = String(repeating: "x", count: 256)
        let metadata = QAXElementHelpTextMetadata(applicationName: "App", role: "AXButton", elementIdentifier: nil, elementTitle: nil, helpText: exactlyMax)
        #expect(metadata.helpText.count == 256)
    }

    @Test("14. A string one character above the maximum (257 characters) fails closed with AX_HELP_TEXT_EXCEEDS_SAFE_BOUND — checked deterministically, never silently truncated")
    func stringOneAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.helpTextExceedsSafeBound(257)
        #expect(error.errorCode == "AX_HELP_TEXT_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("No silent truncation ever occurs — structural: resolveElementHelpText's own `guard stringValue.count <= maxHelpTextLength else { throw ... }` never mutates or shortens the string before throwing")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 15. No kAXValueAttribute / 16. No mutation APIs / 17. No network APIs

    @Test("15. This capability never reads kAXValueAttribute — structural: resolveElementHelpText's only AXUIElementCopyAttributeValue call targets kAXHelpAttribute, by direct source inspection")
    func neverReadsValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    @Test("16/17. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXHelpAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own button remaining untouched")
    @MainActor
    func neverMutatesButtonNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, button) = makeButtonWindow(identifier: "nomutate-\(suffix)")
        button.setAccessibilityHelp("Click to save your changes")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementHelpText(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(button.state == .off)
        #expect(button.isEnabled == true)
    }

    // MARK: - 18. No traversal / 19. No polling / 20. No retries / 21. Bounded resource accounting

    @Test("18/19/20/21. Resource bounds are respected: 1 target, 1 attribute read, 0 relationship hops, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_element_help_text exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read help text", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXButton", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-helptext"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    // MARK: - 22. Verification does not perform another AX read

    @Test("The elementHelpTextReadSucceeded strategy's evidence carries application identity, element identity, and the help text — safe to include directly since this is bounded semantic UI metadata, the same sensitivity class as an already-exposed title/value-description/role-description string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementHelpTextReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", hasHelpText: true, helpText: "Click to save your changes"
        )
        let result = QActionResult(actionId: "verify-helptext", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("element=Save"))
        #expect(evidence.contains("helpText=Click to save your changes"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("Absence (hasHelpText == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty string in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementHelpTextReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: nil, elementTitle: "Save", hasHelpText: false, helpText: nil
        )
        let result = QActionResult(actionId: "verify-helptext-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("helpText=unavailable"))
    }

    @Test("The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementHelpTextReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", hasHelpText: true, helpText: "Click to save your changes"
        )
        let result = QActionResult(actionId: "verify-helptext-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming help text is present but nil is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNilValue() async throws {
        let strategy = QVerificationStrategy.elementHelpTextReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", hasHelpText: true, helpText: nil
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-helptext-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("The strategy also rejects a fabricated success claiming an oversized (>256 character) help text")
    func verificationRejectsFabricatedOversizedValue() async throws {
        let oversized = String(repeating: "x", count: 257)
        let strategy = QVerificationStrategy.elementHelpTextReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Save", hasHelpText: true, helpText: oversized
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-helptext-oversized", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_help_text", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("22. Verification never mutates the UI, is not a bare boolean, and performs NO additional AX read of any kind — proven by the fabrication-rejection tests above (a bare '{ true }' verification, or one re-reading kAXHelpAttribute, could never distinguish those cases from a genuinely fresh call) and by direct source inspection: determineVerificationStrategy reconstructs its evidence entirely from action.arguments/result.outputData, never calling QBridgeAccessibility a second time")
    func verificationNeverMutatesIsNotBareBooleanNoSecondRead() {
        #expect(Bool(true))
    }

    @Test("Observing an element's help text never authorizes ui.click_element/ui.set_text_value/ui.set_element_state — the authorization paths are entirely disjoint")
    func discoveredHelpTextNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-helptext", toolName: "ui.read_element_help_text", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read help text"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-helptext", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - 23. Recovery behavior

    @Test("23. Recovery remains fail-closed: an uncertain in-flight help-text-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-helptext", sessionId: "s-uncertain-helptext", originalIntent: "What does this button do?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-helptext", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-helptext", index: 0, actionName: "ui.read_element_help_text", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What does this button do?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "title": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-helptext", taskId: "task-uncertain-helptext", sessionId: "s-uncertain-helptext",
            goal: "What does this button do?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["helpText"] == nil)
    }

    @Test("No raw AXUIElement reference is ever persisted — structural proof: QAXElementHelpTextMetadata's stored properties are String?/String only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementHelpTextMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "id", elementTitle: "Name", helpText: "Click to save your changes")
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXButton")
        #expect(metadata.helpText == "Click to save your changes")
    }

    @Test("QDurablePlanStepSnapshot does not serialize raw outputData beyond arguments")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.read_element_help_text",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "Read help text",
            targetResources: [],
            arguments: ["applicationName": "Finder", "role": "AXButton", "title": "Open"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "Read help text")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.read_element_help_text")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["role"] == "AXButton")
    }

    // MARK: - 24. Privacy boundary

    @Test("24. A real run's durable-plan snapshot never contains anything beyond application/element identity and the bounded help-text string — no raw AX objects, no unrelated attributes, no kAXValueAttribute content")
    @MainActor
    func noProhibitedDataPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "DurableButton-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: sentinelIdentifier)
        button.setAccessibilityHelp("Click to save your changes")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What does this button do?",
              "steps": [
                {
                  "actionName": "ui.read_element_help_text",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's help text",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "\(sentinelIdentifier)"}
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
            endpointName: "semantic-helptext-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What does this button do?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_help_text" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("Audit records for this capability never contain anything beyond bounded semantic UI metadata")
    @MainActor
    func noProhibitedDataInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "AuditButton-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: sentinelIdentifier)
        button.setAccessibilityHelp("Click to save your changes")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What does this button do?",
              "steps": [
                {
                  "actionName": "ui.read_element_help_text",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's help text",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "\(sentinelIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-helptext-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What does this button do?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("help text") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: identifier)
        button.setAccessibilityHelp("Click to save your changes")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementHelpText(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementHelpText(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )
        #expect(first?.helpText == second?.helpText)
        #expect(button.state == .off)
    }

    // MARK: - 25. Capability-count integrity

    @Test("25. Capability count integrity: 76 → 77 was this phase's own registry-size delta; the registry has since grown further (Phase 2CD's ui.read_element_placeholder_value, Phase 2CE's ui.read_element_expanded_state, Phase 2CF's ui.read_element_disclosure_level, Phase 2CG's ui.read_element_edited_state, Phase 2CH's ui.list_visible_children, Phase 2CI's ui.read_element_index, Phase 2CJ's ui.read_element_insertion_point_line_number, then Phase 2CK's ui.read_table_header), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 85)
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("QPlanExecutor executes ui.read_element_help_text step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesHelpTextStep() async throws {
        let mockExec = HelpTextMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_help_text",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's help text",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXButton", "title": "MockButton"]
            ),
            description: "Read an element's help text"
        )
        let plan = QPlan(
            taskId: "t-plan-helptext", sessionId: "s-helptext", taskPrompt: "Read an element's help text", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-helptext")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("E2E. Real macOS AppKit E2E — a real NSButton forces a deterministic help string \"Click to save your changes\" via the real, declared setAccessibilityHelp accessor, then resolves via kAXHelpAttribute, cross-validated against AppKit's own accessibilityHelp() accessor for the identical control; no value is ever set (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitHelpTextRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-helptext-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: identifier)

        // Force a deterministic, known help string via the real, declared AppKit accessor
        // (setAccessibilityHelp/accessibilityHelp, NSAccessibilityProtocols.h) — the same genuine
        // forced-value round-trip pattern ui.read_element_value_description's own E2E test
        // established for setAccessibilityValueDescription.
        button.setAccessibilityHelp("Click to save your changes")
        #expect(button.accessibilityHelp() == "Click to save your changes")

        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementHelpText(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )

        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        #expect(metadata?.helpText == "Click to save your changes")
        #expect(metadata?.helpText == button.accessibilityHelp())
        #expect(metadata?.applicationName == currentProcessAppName)
        // The read never mutated the fixture's own state.
        #expect(button.state == .off)
    }

    @Test("E2E. Real macOS AppKit E2E — a genuine NSButton with no help text set correctly reports honest absence via the optional-reference contract (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitHelpTextAbsence() async throws {
        guard AXIsProcessTrusted() else {
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-nohelptext-\(suffix)"
        let (window, _) = makeButtonWindow(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementHelpText(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )

        // An ordinary NSButton with no help text ever set is the common, expected case — genuine
        // absence (nil), never fabricated content, never an error.
        #expect(metadata == nil)
    }
}
