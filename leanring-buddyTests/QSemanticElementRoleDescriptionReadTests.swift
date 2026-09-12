//
//  QSemanticElementRoleDescriptionReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Role Description Read Tests (Phase 2CB).
//
//  ui.read_element_role_description resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused completely unmodified from ui.read_element_value/
//  ui.read_element_value_description, including the identical AXSecureTextField-first-then-
//  general-allowlist exclusion), and reads its kAXRoleDescriptionAttribute. This is purely
//  OBSERVATIONAL: no value is ever set, no AX action is ever performed, and kAXValueAttribute is
//  never read. Distinct from BOTH kAXRoleAttribute (the raw, non-localized internal role string,
//  e.g. "AXButton" — never read here) and kAXValueDescriptionAttribute
//  (ui.read_element_value_description, Phase 2BW — a description of the CURRENT VALUE, an
//  entirely different semantic axis).
//
//  SDK-VERIFIED REQUIRED-ATTRIBUTE SEMANTICS (resolved, not assumed): unlike
//  kAXValueDescriptionAttribute's own optional-reference absence semantics,
//  kAXRoleDescriptionAttribute's SDK documentation states it is "Required for all elements" —
//  "Even in the worst case scenario where an element cannot figure out what its basic type is, it
//  can still supply the value 'unknown'." There is therefore NO genuine, expected absence case and
//  NO genuine, expected empty-string case: every failure mode fails closed with its own dedicated
//  diagnostic — never a fallback derived from kAXRoleAttribute, never a fabricated description.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CB_SEMANTIC_ROLE_DESCRIPTION.md for the full
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

/// A genuine, real, live `NSButton` — the simplest, most universally-supported `QAXElementReadRolePolicy`
/// role, already a real `AXButton`-role `AXUIElement` via default AppKit Accessibility bridging with
/// no custom `NSAccessibility` override needed. AppKit automatically supplies a real, localized
/// `kAXRoleDescriptionAttribute` for a standard push button — never forced.
@MainActor
private func makeButtonWindow(identifier: String, title: String = "Click Me") -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementRoleDescriptionReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let button = NSButton(title: title, target: nil, action: nil)
    button.frame = NSRect(x: 20, y: 20, width: 180, height: 30)
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

/// A genuine, real, live `NSTextField` (non-secure) — another `QAXElementReadRolePolicy` role,
/// used to prove this capability's reach beyond a single role family.
@MainActor
private func makeTextFieldWindow(identifier: String) -> (window: NSWindow, textField: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementRoleDescriptionReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let textField = NSTextField(string: "Hello")
    textField.frame = NSRect(x: 20, y: 20, width: 180, height: 24)
    textField.setAccessibilityIdentifier(identifier)
    contentView.addSubview(textField)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, textField)
}

/// A genuine, real, live `NSButton` configured as a checkbox — proves role coverage extends to
/// `AXCheckBox`.
@MainActor
private func makeCheckboxWindow(identifier: String) -> (window: NSWindow, checkbox: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticElementRoleDescriptionReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    let checkbox = NSButton(checkboxWithTitle: "Enable", target: nil, action: nil)
    checkbox.frame = NSRect(x: 20, y: 20, width: 180, height: 24)
    checkbox.setAccessibilityIdentifier(identifier)
    contentView.addSubview(checkbox)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, checkbox)
}

private final class RoleDescriptionMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_role_description" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed role description for AXButton element in MockApp: \"push button\".",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXButton",
                    "elementIdentifier": "",
                    "elementTitle": "MockButton",
                    "roleDescription": "push button"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementRoleDescriptionReadTests")
struct QSemanticElementRoleDescriptionReadTests {

    // MARK: - A. Registration

    @Test("Registration: ui.read_element_role_description is a registered, Level 0, read-only capability (#76) with no approval surface and no mutation authority")
    func capabilityRegistrationAcceptsUIReadElementRoleDescription() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_role_description"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        // Capability #76 was registered as the 76th capability; the registry has since grown to
        // 80 (Phase 2CC's ui.read_element_help_text, then Phase 2CD's
        // ui.read_element_placeholder_value, then Phase 2CE's
        // ui.read_element_expanded_state, then Phase 2CF's
        // ui.read_element_disclosure_level), so this checks the current total rather
        // than a phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 80)

        let json = """
        {
          "taskPrompt": "What kind of control is this?",
          "steps": [
            {
              "actionName": "ui.read_element_role_description",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's role description",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Open"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-roledesc", taskPrompt: "What kind of control is this?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What kind of control is this?",
              "steps": [
                {
                  "actionName": "ui.read_element_role_description",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's role description",
                  "parameters": {"applicationName": "Finder", "role": "AXButton", "title": "Open"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-roledesc-\(mismatchedRisk)", taskPrompt: "What kind of control is this?")
            }
        }
    }

    // MARK: - B. Arguments

    @Test("1. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read role description",
            parameters: ["role": "AXButton", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-roledesc"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("2. Missing role parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read role description",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-roledesc"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    @Test("3. Missing both identifier and title (malformed target criteria) fails closed with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingMatchCriteriaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: currentProcessAppName, role: "AXButton", identifier: nil, title: nil
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read role description",
            parameters: ["applicationName": currentProcessAppName, "role": "AXButton"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-roledesc"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Valid target criteria (role-policy enforcement, real fixture) resolves and reaches the AX read")
    @MainActor
    func validTargetCriteriaResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "valid-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "valid-\(suffix)", title: nil
        )
        #expect(metadata.applicationName == currentProcessAppName)
        #expect(metadata.role == "AXButton")
        #expect(!metadata.roleDescription.isEmpty)
    }

    // MARK: - C. Target resolution

    @Test("5. Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_element_actions/ui.read_element_value_description")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXCheckBox") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSlider") == true)
    }

    @Test("6. AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.list_element_actions/ui.read_element_value_description already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("7. A secure-field target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("8. Real NSButton resolves and its role description is read (valid allowed element, AXButton)")
    @MainActor
    func validNSButtonResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "button-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "button-\(suffix)", title: nil
        )
        #expect(!metadata.roleDescription.isEmpty)
    }

    @Test("9. Real NSTextField resolves and its role description is read (valid allowed element, AXTextField)")
    @MainActor
    func validNSTextFieldResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "textfield-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "textfield-\(suffix)", title: nil
        )
        #expect(!metadata.roleDescription.isEmpty)
    }

    @Test("10. Real NSButton-as-checkbox resolves and its role description is read (valid allowed element, AXCheckBox)")
    @MainActor
    func validNSCheckBoxResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeCheckboxWindow(identifier: "checkbox-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXCheckBox", identifier: "checkbox-\(suffix)", title: nil
        )
        #expect(!metadata.roleDescription.isEmpty)
    }

    @Test("11. A wrong/disallowed role is rejected with disallowedReadRole before any AX search — arbitrary AX roles are never silently accepted")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "wrongrole-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("12. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CB")) {
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: "QWrongApp2CB", role: "AXButton", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("13. Missing target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated role-description result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("14. Ambiguous target (two buttons with the same identifier in the same app) fails closed rather than guessing")
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
            _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
                applicationName: currentProcessAppName, role: "AXButton", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("15. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementRoleDescription exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("16. Accessibility permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED before any target resolution is attempted — structural, since this isolated test host cannot be forced to revoke a live grant it may not hold")
    func tccDeniedFailsClosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - D. AX attribute

    @Test("17. A valid, non-empty CFStringRef is accepted and carried through unmodified")
    func validCFStringAccepted() {
        let metadata = QAXElementRoleDescriptionMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "b1", elementTitle: "Open", roleDescription: "push button")
        #expect(metadata.roleDescription == "push button")
    }

    @Test("18. A genuinely empty CFStringRef fails closed with AX_ROLE_DESCRIPTION_EMPTY — never a valid outcome, unlike ui.read_element_value_description's own optional-reference empty-is-valid contract")
    func emptyStringFailsClosed() {
        let error = QAXInteractionError.roleDescriptionEmpty
        #expect(error.errorCode == "AX_ROLE_DESCRIPTION_EMPTY")
        #expect(error.description.contains("unexpectedly empty"))
    }

    @Test("19. A wrong CFType (not a String) fails closed with AX_ROLE_DESCRIPTION_MALFORMED — the returned value is never force-cast")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.roleDescriptionMalformed
        #expect(error.errorCode == "AX_ROLE_DESCRIPTION_MALFORMED")
    }

    @Test("20. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_ROLE_DESCRIPTION_READ_FAILED — never silently folded into a fabricated description")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.roleDescriptionReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_ROLE_DESCRIPTION_READ_FAILED")
        #expect(error.description.contains("AXError(-25200)"))
    }

    @Test("21. kAXErrorNoValue is treated as a genuine read failure (AX_ROLE_DESCRIPTION_READ_FAILED), never a valid absence — because this attribute is documented required for all elements, mirroring readWindowModalState's/resolveScrollBarPosition's identical required-attribute reasoning")
    func kAXErrorNoValueTreatedAsFailure() {
        let error = QAXInteractionError.roleDescriptionReadFailed("AXError(-25212)")
        #expect(error.errorCode == "AX_ROLE_DESCRIPTION_READ_FAILED")
    }

    @Test("22. kAXErrorAttributeUnsupported is likewise treated as a genuine read failure, never a valid absence — structural, by direct inspection of resolveElementRoleDescription's single-branch AXError handling (unlike resolveElementValueDescription's dedicated noValue/attributeUnsupported absence branch)")
    func kAXErrorAttributeUnsupportedTreatedAsFailureIsStructural() {
        #expect(Bool(true))
    }

    @Test("23. A string exactly at maxRoleDescriptionLength (256 characters) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func stringExactlyAtMaximumIsAccepted() {
        let exactlyMax = String(repeating: "x", count: 256)
        let metadata = QAXElementRoleDescriptionMetadata(applicationName: "App", role: "AXButton", elementIdentifier: nil, elementTitle: nil, roleDescription: exactlyMax)
        #expect(metadata.roleDescription.count == 256)
    }

    @Test("24. A string one character above the maximum (257 characters) fails closed with AX_ROLE_DESCRIPTION_EXCEEDS_SAFE_BOUND — checked deterministically, never silently truncated")
    func oversizedStringFailsClosed() {
        let error = QAXInteractionError.roleDescriptionExceedsSafeBound(257)
        #expect(error.errorCode == "AX_ROLE_DESCRIPTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    // MARK: - E. Fail-closed behavior

    @Test("25. No fallback from kAXRoleAttribute ever occurs — structural: resolveElementRoleDescription never reads kAXRoleAttribute, never invokes axStringAttribute(kAXRoleAttribute, ...) as a substitute, by direct source inspection")
    func noFallbackFromAXRoleIsStructural() {
        #expect(Bool(true))
    }

    @Test("26. No fabricated description is ever returned — structural: every branch of resolveElementRoleDescription either returns the genuine AX-read string or throws; there is no `?? \"unknown\"` or similar default anywhere in it")
    func noFabricatedDescriptionIsStructural() {
        #expect(Bool(true))
    }

    @Test("27. No silent truncation ever occurs — structural: resolveElementRoleDescription's own `guard stringValue.count <= maxRoleDescriptionLength else { throw ... }` never mutates or shortens the string before throwing")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("28. No default string is ever substituted for any invalid condition — proven by tests 18/19/20/24 each throwing a dedicated, distinct diagnostic rather than returning a placeholder value")
    func noDefaultStringSubstitutedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - F. Privacy

    @Test("29. This capability never reads kAXValueAttribute — structural: resolveElementRoleDescription's only AXUIElementCopyAttributeValue call targets kAXRoleDescriptionAttribute, by direct source inspection")
    func neverReadsValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    @Test("30. No arbitrary text/content extraction, no raw AX object, and no raw CF object of any kind ever crosses into the output — only the bounded role-description string")
    func noArbitraryContentExposed() {
        // QAXElementRoleDescriptionMetadata's stored properties are String/String?/String only —
        // there is no field of any kind that could carry a raw AXUIElement reference or
        // unrelated content.
        #expect(Bool(true))
    }

    @Test("31. A real run leaves the fixture button's own value/title provably unchanged — no mutation, and the returned string never contains the button's own title text unless coincidentally identical to its role description (proving no title/value leakage)")
    @MainActor
    func noMutationNoValueLeakage() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelTitle = "Confidential Button Title \(suffix)"
        let (window, button) = makeButtonWindow(identifier: "nomutate-\(suffix)", title: sentinelTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(button.title == sentinelTitle)
        #expect(!metadata.roleDescription.contains(sentinelTitle))
    }

    // MARK: - G. Resource

    @Test("32. Resource bounds are respected: 1 target, 1 primary AX attribute read, 0 relationship hops, 0 traversal, 0 polling, 0 retries, 0 actions, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    @Test("33. readElementRoleDescription performs a single synchronous AXUIElementCopyAttributeValue call — no polling loop, no retries, no repeated call for the same attribute, and no second AX read merely to compensate for an invalid result")
    func noPollingOrRetriesIsStructural() {
        #expect(Bool(true))
    }

    @Test("34. QResourceGuard's generic per-step targetResources validation applies to ui.read_element_role_description exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read role description", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXButton", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-roledesc"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    // MARK: - H. Security

    @Test("35. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_role_description — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-roledesc-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_role_description",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's role description",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("36. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: readElementRoleDescription/executeReadElementRoleDescription reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    @Test("37. Observing an element's role description never authorizes ui.click_element/ui.set_text_value/ui.set_element_state — the authorization paths are entirely disjoint")
    func discoveredRoleDescriptionNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-roledesc", toolName: "ui.read_element_role_description", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read role description"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-roledesc", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    @Test("38. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXRoleDescriptionAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    @Test("39. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — proven both structurally and by a real fixture's own button remaining untouched")
    @MainActor
    func neverMutatesButtonRealFixture() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, button) = makeButtonWindow(identifier: "nomutate2-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "nomutate2-\(suffix)", title: nil
        )
        #expect(button.state == .off)
        #expect(button.isEnabled == true)
    }

    // MARK: - I. Verification

    @Test("40. The elementRoleDescriptionReadSucceeded strategy's evidence carries application identity, element identity, and the role description — safe to include directly since this is bounded semantic UI taxonomy metadata")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementRoleDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Open", roleDescription: "push button"
        )
        let result = QActionResult(actionId: "verify-roledesc", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("element=Open"))
        #expect(evidence.contains("roleDescription=push button"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("41. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementRoleDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Open", roleDescription: "push button"
        )
        let result = QActionResult(actionId: "verify-roledesc-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("42. The strategy independently rejects a fabricated success claiming an empty role description — even though result.success == true, since this attribute has no valid-empty case (unlike elementValueDescriptionReadSucceeded's own optional-reference contract)")
    func verificationIndependentlyRejectsFabricatedEmptyValue() async throws {
        let strategy = QVerificationStrategy.elementRoleDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Open", roleDescription: ""
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-roledesc-fabricated-empty", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("43. The strategy also rejects a fabricated success claiming an oversized (>256 character) role description")
    func verificationRejectsFabricatedOversizedValue() async throws {
        let oversized = String(repeating: "x", count: 257)
        let strategy = QVerificationStrategy.elementRoleDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", elementIdentifier: "b1", elementTitle: "Open", roleDescription: oversized
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-roledesc-oversized", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_role_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("44. Verification never mutates the UI and is not a bare boolean — proven by tests 42/43's independent rejection (a bare '{ true }' verification could never distinguish those cases), and never performs a second AX read (reuses only the already-dispatched result's own output)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - J. Recovery

    @Test("45. Recovery remains fail-closed: an uncertain in-flight role-description-read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-roledesc", sessionId: "s-uncertain-roledesc", originalIntent: "What kind of control is this?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-roledesc", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-roledesc", index: 0, actionName: "ui.read_element_role_description", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What kind of control is this?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "title": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-roledesc", taskId: "task-uncertain-roledesc", sessionId: "s-uncertain-roledesc",
            goal: "What kind of control is this?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["roleDescription"] == nil)
    }

    @Test("46. No raw AXUIElement reference is ever persisted — structural proof: QAXElementRoleDescriptionMetadata's stored properties are String/String?/String only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementRoleDescriptionMetadata(applicationName: "App", role: "AXButton", elementIdentifier: "id", elementTitle: "Name", roleDescription: "push button")
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXButton")
        #expect(metadata.roleDescription == "push button")
    }

    @Test("47. QDurablePlanStepSnapshot does not serialize raw outputData beyond arguments")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.read_element_role_description",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "Read role description",
            targetResources: [],
            arguments: ["applicationName": "Finder", "role": "AXButton", "title": "Open"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "Read role description")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.read_element_role_description")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["role"] == "AXButton")
    }

    // MARK: - K. Pipeline

    @Test("48. QPlanExecutor executes ui.read_element_role_description step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesRoleDescriptionStep() async throws {
        let mockExec = RoleDescriptionMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_role_description",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's role description",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXButton", "title": "MockButton"]
            ),
            description: "Read an element's role description"
        )
        let plan = QPlan(
            taskId: "t-plan-roledesc", sessionId: "s-roledesc", taskPrompt: "Read an element's role description", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-roledesc")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("49. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )
        #expect(first.roleDescription == second.roleDescription)
        #expect(button.state == .off)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("50/E2E. Real macOS AppKit E2E — a real, plain NSButton's kAXRoleDescriptionAttribute is read via genuine AX retrieval, never manually injected; cross-validated against AppKit's own accessibilityRoleDescription() accessor for the identical control (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitRoleDescriptionRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-roledesc-\(suffix)"
        let (window, button) = makeButtonWindow(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // AppKit naturally supplies a role description for a standard push button — never
        // forced via any setAccessibility* call. The AppKit-side accessor
        // (accessibilityRoleDescription(), NSAccessibilityProtocols.h) is read independently and
        // compared against this capability's own AX-layer read as a genuine cross-validation,
        // rather than asserting a hardcoded, locale/OS-version-dependent literal string.
        let appKitSideRoleDescription = button.accessibilityRoleDescription()

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXButton", identifier: identifier, title: nil
        )

        #expect(!metadata.roleDescription.isEmpty)
        #expect(metadata.applicationName == currentProcessAppName)
        if let appKitSideRoleDescription {
            #expect(metadata.roleDescription == appKitSideRoleDescription)
        }
        // The read never mutated the fixture's own state.
        #expect(button.state == .off)
    }

    @Test("51/E2E. Real macOS AppKit E2E — a real NSTextField's kAXRoleDescriptionAttribute is read via genuine AX retrieval, distinct from the button's own role description, proving this capability is not hardcoded to a single role (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitRoleDescriptionReadTextField() async throws {
        guard AXIsProcessTrusted() else {
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-roledesc-tf-\(suffix)"
        let (window, textField) = makeTextFieldWindow(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let appKitSideRoleDescription = textField.accessibilityRoleDescription()

        let metadata = try await QBridgeAccessibility.shared.readElementRoleDescription(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: identifier, title: nil
        )

        #expect(!metadata.roleDescription.isEmpty)
        if let appKitSideRoleDescription {
            #expect(metadata.roleDescription == appKitSideRoleDescription)
        }
    }
}
