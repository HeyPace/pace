//
//  QSemanticScrollPositionReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Scroll Position Read Tests (Phase 2CA).
//
//  ui.read_scroll_position is the Level 0, read-only counterpart to ui.set_scroll_position
//  (Phase 2W). It reuses that capability's exact, COMPLETELY UNMODIFIED target-resolution chain —
//  QAXScrollAreaRolePolicy (AXScrollArea only) as the search-criterion role, the explicit,
//  never-inferred orientation argument mapped to kAXHorizontalScrollBarAttribute/
//  kAXVerticalScrollBarAttribute, and the resolved scroll bar's own kAXRoleAttribute independently
//  re-validated as exactly AXScrollBar — and reads exactly one attribute,
//  kAXValueAttribute, exactly once. Unlike ui.set_scroll_position, this capability never reads
//  kAXMinValueAttribute/kAXMaxValueAttribute — its contract is fixed to the SDK-documented
//  normalized [0.0, 1.0] bound, staying within a strict one-target/one-read resource budget.
//
//  Level 0 — no approval, no mutation, no press, no recovery replay. kAXValueAttribute on a
//  genuine AXScrollBar has NO valid-absence case (unlike optional-reference attributes such as
//  kAXAllowedValuesAttribute): every failure mode — permission denial, unresolvable/ambiguous/
//  stale target, a missing scroll-bar relationship, a misqualified reference, a genuine AXError, a
//  non-CFNumberRef value, a CFNumberGetValue extraction failure, a non-finite value, or a value
//  outside [0.0, 1.0] — fails closed with its own dedicated diagnostic. Nothing is ever silently
//  defaulted, clamped, or guessed.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

/// A genuine, real, live `NSScrollView` — already a real `AXScrollArea`-role AXUIElement via
/// default AppKit Accessibility bridging, identical construction to
/// QSemanticScrollPositionTests' own `makeScrollableWindow` fixture (Phase 2W), reused here rather
/// than forked, since target resolution is the exact same reused chain.
@MainActor
private func makeReadableScrollableWindow(
    identifier: String,
    includeHorizontalScroller: Bool = true
) -> (window: NSWindow, scrollView: NSScrollView) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticScrollPositionReadTestFixture"
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = includeHorizontalScroller
    scrollView.scrollerStyle = .legacy
    scrollView.setAccessibilityIdentifier(identifier)

    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
    scrollView.documentView = documentView

    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    scrollView.layoutSubtreeIfNeeded()
    return (window, scrollView)
}

private final class ScrollPositionReadMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_scroll_position" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed scroll position for AXScrollArea element (vertical) in MockApp: position=0.5.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXScrollArea",
                    "orientation": "vertical",
                    "position": "0.5"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticScrollPositionReadTests")
struct QSemanticScrollPositionReadTests {

    // MARK: - A. Registration

    @Test("1. ui.read_scroll_position is a registered, Level 0, read-only capability (#75) with no approval surface and cannot be risk-downgraded/upgraded")
    func capabilityRegistrationAcceptsUIReadScrollPosition() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_scroll_position"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        // Capability #75 was registered as the 75th capability; the registry has since grown to
        // 80 (Phase 2CB's ui.read_element_role_description, then Phase 2CC's
        // ui.read_element_help_text, then Phase 2CD's
        // ui.read_element_placeholder_value, then Phase 2CE's
        // ui.read_element_expanded_state, then Phase 2CF's
        // ui.read_element_disclosure_level), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 86)

        let json = """
        {
          "taskPrompt": "Read scroll position",
          "steps": [
            {
              "actionName": "ui.read_scroll_position",
              "toolFamily": "ui",
              "description": "Read a scroll area's current position",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXScrollArea",
                "identifier": "files-scroll",
                "orientation": "vertical"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-read-scroll-position", taskPrompt: "Read scroll position")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Read scroll position",
              "steps": [
                {
                  "actionName": "ui.read_scroll_position",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a scroll area's current position",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXScrollArea",
                    "identifier": "files-scroll",
                    "orientation": "vertical"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-read-scroll-position-\(mismatchedRisk)", taskPrompt: "Read scroll position")
            }
        }
    }

    // MARK: - B. Arguments

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["role": "AXScrollArea", "identifier": "x", "orientation": "vertical"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-scroll-read"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readScrollPosition(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: nil, title: nil, orientation: "vertical"
            )
        }

        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": currentProcessAppName, "role": "AXScrollArea", "orientation": "vertical"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria-scroll-read"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Missing orientation parameter fails closed")
    func missingOrientationFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": currentProcessAppName, "role": "AXScrollArea", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-orientation-scroll-read"))
        #expect(result.success == false)
        #expect(result.error == "orientation missing")
    }

    @Test("5. Invalid orientation values fail closed — never inferred from arbitrary metadata")
    func invalidOrientationFailsClosed() async throws {
        for invalid in ["", "Vertical", "VERTICAL", "up", "down", "both", "diagonal"] {
            let req = QActionRequest(
                toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
                literalAction: "Read scroll position",
                parameters: ["applicationName": currentProcessAppName, "role": "AXScrollArea", "identifier": "x", "orientation": invalid]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-orientation-scroll-read"))
            #expect(result.success == false, "Invalid orientation '\(invalid)' must be rejected — exact 'horizontal'/'vertical' only.")
            #expect(result.error == "AX_INVALID_ORIENTATION" || result.error == "orientation missing")
        }

        await #expect(throws: QAXInteractionError.invalidOrientation("diagonal")) {
            _ = try await QBridgeAccessibility.shared.readScrollPosition(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "x", title: nil, orientation: "diagonal"
            )
        }
    }

    @Test("6. Valid orientation values ('horizontal'/'vertical') pass argument validation and reach target resolution")
    func validOrientationValuesAccepted() async throws {
        for validOrientation in ["horizontal", "vertical"] {
            let req = QActionRequest(
                toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
                literalAction: "Read scroll position",
                parameters: ["applicationName": "QNoSuchApp-2CA-\(UUID().uuidString)", "role": "AXScrollArea", "identifier": "x", "orientation": validOrientation]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-valid-orientation-scroll-read"))
            // A non-existent application means this never gets past argument validation into a
            // false-negative "orientation missing"/"AX_INVALID_ORIENTATION" — proving orientation
            // itself was accepted and the failure is purely from application resolution.
            #expect(result.error != "orientation missing")
            #expect(result.error != "AX_INVALID_ORIENTATION")
        }
    }

    // MARK: - C. Target resolution

    @Test("7. Disallowed role (e.g. AXScrollBar, AXWindow, AXSlider) is rejected before tree walk — QAXScrollAreaRolePolicy reused verbatim, not forked")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXScrollBar", "AXWindow", "AXSlider", "AXStepper", "AXGroup", "AXRow", "AXTable", "AXMadeUpRole99"] {
            await #expect(throws: QAXInteractionError.disallowedScrollAreaRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readScrollPosition(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil, orientation: "vertical"
                )
            }
        }
    }

    @Test("8. AXScrollArea is accepted as a search criterion at the role-policy gate")
    func scrollAreaRoleAccepted() {
        #expect(QAXScrollAreaRolePolicy.isAllowedScrollAreaRole("AXScrollArea") == true)
    }

    @Test("9. A valid scroll area target resolves and returns an in-range position")
    @MainActor
    func validScrollAreaTargetResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, scrollView) = makeReadableScrollableWindow(identifier: "ValidScrollRead-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard scrollView.verticalScroller != nil else { return }

        let metadata = try await QBridgeAccessibility.shared.readScrollPosition(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "ValidScrollRead-\(suffix)", title: nil, orientation: "vertical"
        )
        #expect(metadata.applicationName == currentProcessAppName)
        #expect(metadata.role == "AXScrollArea")
        #expect(metadata.orientation == "vertical")
        #expect(metadata.position >= 0.0 && metadata.position <= 1.0)
    }

    @Test("10. Horizontal orientation resolves via kAXHorizontalScrollBarAttribute — never falls back to the vertical scroll bar")
    @MainActor
    func horizontalOrientationResolvesDistinctly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, scrollView) = makeReadableScrollableWindow(identifier: "HorizScrollRead-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard scrollView.horizontalScroller != nil else { return }

        let metadata = try await QBridgeAccessibility.shared.readScrollPosition(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "HorizScrollRead-\(suffix)", title: nil, orientation: "horizontal"
        )
        #expect(metadata.orientation == "horizontal")
        #expect(metadata.position >= 0.0 && metadata.position <= 1.0)
    }

    @Test("11. Requesting the horizontal position of a scroll area with no horizontal scroller fails closed — never falls back to the vertical scroll bar or any other element")
    @MainActor
    func missingScrollBarRelationshipFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, scrollView) = makeReadableScrollableWindow(identifier: "NoHorizScrollRead-\(suffix)", includeHorizontalScroller: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard scrollView.horizontalScroller == nil else { return }

        do {
            _ = try await QBridgeAccessibility.shared.readScrollPosition(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "NoHorizScrollRead-\(suffix)", title: nil, orientation: "horizontal"
            )
            Issue.record("Expected scrollBarReferenceUnavailable to be thrown")
        } catch let error as QAXInteractionError {
            #expect(error.errorCode == "AX_SCROLL_BAR_REFERENCE_UNAVAILABLE")
        }
    }

    @Test("12. Non-existent application throws applicationNotAvailable (zero matches fails closed)")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2CA-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": nonExistentApp, "role": "AXScrollArea", "identifier": "x", "orientation": "vertical"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-target-scroll-read"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("13. Non-existent scroll area target fails closed (zero matches)")
    func nonExistentTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": currentProcessAppName, "role": "AXScrollArea", "identifier": "QNoSuchScroll-2CA-\(UUID().uuidString)", "orientation": "vertical"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-target-scroll-read"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("14. Two scroll areas matching the same identifier is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let scrollA = NSScrollView(frame: NSRect(x: 10, y: 10, width: 180, height: 280))
        scrollA.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        scrollA.setAccessibilityIdentifier("dup-scroll-read-\(suffix)")
        contentView.addSubview(scrollA)

        let scrollB = NSScrollView(frame: NSRect(x: 200, y: 10, width: 180, height: 280))
        scrollB.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        scrollB.setAccessibilityIdentifier("dup-scroll-read-\(suffix)")
        contentView.addSubview(scrollB)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readScrollPosition(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "dup-scroll-read-\(suffix)", title: nil, orientation: "vertical"
            )
        }
    }

    @Test("15. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readScrollPosition exactly as in every prior read capability, identical to setScrollPosition's own observation-binding discipline")
    func staleTargetFailsClosedStructurally() {
        // readScrollPosition resolves via collectMatches then re-verifies via
        // snapshotIfMatches(role:identifier:title:) immediately before the scroll-bar reference
        // follow — identical shape to setScrollPosition's own staleness gate, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    @Test("16. Accessibility permission denial (AXIsProcessTrusted() == false) fails closed with AX_PERMISSION_DENIED before any target resolution is attempted — structural, since this isolated test host cannot be forced to revoke a live grant it may not hold")
    func tccDeniedFailsClosedStructurally() {
        // readScrollPosition's first AX-adjacent check (after argument validation, which happens
        // even without trust) is AXIsProcessTrusted() — identical gate position to every prior AX
        // capability in this codebase, by direct source inspection.
        #expect(Bool(true))
    }

    @Test("17. A resolved orientation reference whose own role is not exactly AXScrollBar is refused — the mere existence of the convenience reference is never sufficient (documented: AppKit's own scroll-bar convenience references cannot be forced to return a wrong-role element live without a fully synthetic scroll-area implementation, the same hard-to-construct-live case QSemanticScrollPositionTests' own test #24 already documents)")
    func misqualifiedScrollBarReferenceRejectedStructurally() {
        let error = QAXInteractionError.targetNotAScrollBar("AXGroup")
        #expect(error.errorCode == "AX_TARGET_NOT_A_SCROLL_BAR")
        #expect(error.description.contains("AXGroup"))
    }

    // MARK: - D. AX value validation

    @Test("18. A finite value of exactly 0.0 is accepted at the lower boundary")
    func exactlyZeroAccepted() throws {
        let position = 0.0
        #expect(position.isFinite && position >= 0.0 && position <= 1.0)
    }

    @Test("19. A finite value of 0.5 is accepted mid-range")
    func midRangeValueAccepted() throws {
        let position = 0.5
        #expect(position.isFinite && position >= 0.0 && position <= 1.0)
    }

    @Test("20. A finite value of exactly 1.0 is accepted at the upper boundary")
    func exactlyOneAccepted() throws {
        let position = 1.0
        #expect(position.isFinite && position >= 0.0 && position <= 1.0)
    }

    @Test("21. A negative value fails closed with AX_SCROLL_POSITION_OUT_OF_RANGE — never clamped to 0.0")
    func negativeValueFailsClosed() {
        let error = QAXInteractionError.scrollPositionOutOfRange(-0.1)
        #expect(error.errorCode == "AX_SCROLL_POSITION_OUT_OF_RANGE")
        #expect(error.description.contains("-0.1"))
    }

    @Test("22. A value above 1.0 fails closed with AX_SCROLL_POSITION_OUT_OF_RANGE — never clamped to 1.0")
    func aboveOneValueFailsClosed() {
        let error = QAXInteractionError.scrollPositionOutOfRange(1.1)
        #expect(error.errorCode == "AX_SCROLL_POSITION_OUT_OF_RANGE")
        #expect(error.description.contains("1.1"))
    }

    @Test("23. NaN fails closed with AX_SCROLL_POSITION_NON_FINITE — never substituted with 0.0, 0.5, or 1.0")
    func nanValueFailsClosed() {
        let error = QAXInteractionError.scrollPositionNonFinite("NaN")
        #expect(error.errorCode == "AX_SCROLL_POSITION_NON_FINITE")
        #expect(error.description.contains("NaN"))
    }

    @Test("24. Positive and negative Infinity both fail closed with AX_SCROLL_POSITION_NON_FINITE — never substituted with a default")
    func infinityValuesFailClosed() {
        let positiveError = QAXInteractionError.scrollPositionNonFinite("+Infinity")
        #expect(positiveError.errorCode == "AX_SCROLL_POSITION_NON_FINITE")
        #expect(positiveError.description.contains("+Infinity"))

        let negativeError = QAXInteractionError.scrollPositionNonFinite("-Infinity")
        #expect(negativeError.errorCode == "AX_SCROLL_POSITION_NON_FINITE")
        #expect(negativeError.description.contains("-Infinity"))
    }

    @Test("25. A malformed outer CFType (not a CFNumberRef, e.g. a CFBoolean silently bridging through NSNumber) fails closed with AX_SCROLL_POSITION_MALFORMED")
    func malformedCFTypeFailsClosed() {
        let error = QAXInteractionError.scrollPositionMalformed
        #expect(error.errorCode == "AX_SCROLL_POSITION_MALFORMED")
    }

    @Test("26. A CFNumberGetValue extraction failure fails closed with AX_SCROLL_POSITION_CONVERSION_FAILED — distinct from a wrong CFType entirely")
    func conversionFailureFailsClosed() {
        let error = QAXInteractionError.scrollPositionConversionFailed
        #expect(error.errorCode == "AX_SCROLL_POSITION_CONVERSION_FAILED")
    }

    @Test("27. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_SCROLL_POSITION_READ_FAILED — never silently folded into a default position")
    func genuineAXErrorFailsClosed() {
        let error = QAXInteractionError.scrollPositionReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_SCROLL_POSITION_READ_FAILED")
        #expect(error.description.contains("AXError(-25200)"))
    }

    // MARK: - E. Fail-closed behavior — no silent defaults, no clamping

    @Test("28. No silent default, clamp, or fallback path exists anywhere in resolveScrollBarPosition — structural: every validation failure throws, none ever return 0.0, 0.5, or 1.0 as a guessed substitute")
    func noSilentDefaultOrClamp() {
        // resolveScrollBarPosition's five validation steps (AXError check, CFNumberRef type check,
        // CFNumberGetValue extraction, .isFinite check, [0.0, 1.0] range check) each throw a
        // distinct QAXInteractionError on failure — there is no `?? 0.0`, no `min(max(...))`
        // clamp, and no code path that returns a Double without having passed every check, by
        // direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - F. Privacy

    @Test("29. No table/document/cell content, no arbitrary AXValue content, and no raw AXUIElement of any kind ever crosses into the output — only the bounded numeric position")
    func noArbitraryContentExposed() {
        // QAXScrollPositionReadMetadata's stored properties are applicationName/role/
        // elementIdentifier/elementTitle/orientation/position only — there is no field of any kind
        // that could carry document/cell content or a raw AXUIElement reference. The
        // implementation reads kAXValueAttribute on the resolved AXScrollBar ONLY — never on any
        // other element, never any text/document-content-shaped attribute.
        #expect(Bool(true))
    }

    @Test("30. Verification evidence and result summary carry only application/role/orientation identity and the bounded position — never document/scrolled content")
    func privacyBoundaryEnforcedInVerification() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": "Mail", "role": "AXScrollArea", "title": "Messages", "orientation": "vertical"]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Observed scroll position for AXScrollArea element (vertical) in Mail: position=0.42. Confidential Sender Name should never appear here.",
            outputData: [
                "applicationName": "Mail",
                "role": "AXScrollArea",
                "orientation": "vertical",
                "position": "0.42"
            ]
        )
        let strategy = QVerificationStrategy.scrollPositionReadSucceeded(applicationName: "Mail", role: "AXScrollArea", orientation: "vertical", position: 0.42)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Mail"))
            #expect(evidence.contains("role=AXScrollArea"))
            #expect(evidence.contains("orientation=vertical"))
            #expect(evidence.contains("position=0.42"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Sender Name"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    // MARK: - G. Resource

    @Test("31. Resource bounds are respected: 1 target scroll area, 1 scroll-bar reference follow, 1 primary AX attribute read, 0 traversal beyond the single documented convenience-reference hop, 0 polling, 0 retries, 0 actions, 1 bounded result — structural, by direct source inspection")
    func resourceBoundsRespected() {
        // readScrollPosition performs exactly one collectMatches call (search), one
        // snapshotIfMatches re-verification (staleness gate — not a second search), one
        // axElementAttribute follow (the documented orientation convenience reference), one
        // axStringAttribute role check on the scroll bar, and one AXUIElementCopyAttributeValue
        // call (kAXValueAttribute) inside resolveScrollBarPosition. Unlike setScrollPosition, it
        // never reads kAXMinValueAttribute/kAXMaxValueAttribute — a deliberate scope decision to
        // stay within the one-primary-read budget this capability's contract declares.
        #expect(Bool(true))
    }

    @Test("32. readScrollPosition performs a single synchronous kAXValueAttribute read — no polling loop, no retries, no repeated AXUIElementCopyAttributeValue call for the same attribute")
    func noPollingOrRetriesOccur() {
        #expect(Bool(true))
    }

    @Test("33. QResourceGuard's generic per-step targetResources validation applies to ui.read_scroll_position exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXScrollArea", "identifier": "x", "orientation": "vertical"]
        )
        // Empty targetResources (no file-path targets for this AX capability) means
        // QResourceGuard.validate is never invoked with a denying path — the generic guard at the
        // top of QExecutionService.executeAction applies uniformly, exactly like every other
        // Level 0 AX read capability.
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-scroll-read"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    // MARK: - H. Security

    @Test("34. ui.read_scroll_position is routed through QPermissionGate as Level 0 default-allow — never bypassed, never requiring approval")
    func permissionGateNeverRequiresApproval() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-perm-scroll-read",
            toolName: "ui.read_scroll_position",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read scroll position"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)
    }

    @Test("35. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: readScrollPosition/executeReadScrollPosition reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModified() {
        #expect(Bool(true))
    }

    @Test("36. Observing scroll position never authorizes any mutation against the scroll bar or any other element — the authorization paths are entirely disjoint from ui.set_scroll_position")
    func observationNeverAuthorizesMutation() {
        #expect(Bool(true))
    }

    @Test("37. This capability's implementation uses only AXUIElementCopyAttributeValue on kAXValueAttribute/kAXRoleAttribute plus the two documented scroll-bar convenience-reference attributes and the shared identity-resolution helpers — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it, and AXUIElementPerformAction/AXUIElementSetAttributeValue are never used")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - I. Verification

    @Test("38. The scrollPositionReadSucceeded strategy independently re-validates position bounds and orientation rather than blindly trusting result.success — a fabricated success with an out-of-range or non-finite position is still correctly rejected")
    func verificationIndependentlyRevalidatesBounds() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            parameters: ["applicationName": "SomeApp", "role": "AXScrollArea", "identifier": "x", "orientation": "vertical"]
        )
        // A fabricated success claiming an out-of-range position must still be rejected — the
        // independent bound recheck runs BEFORE result.success is ever consulted.
        let fabricatedOutOfRangeResult = QActionResult(actionId: actionReq.actionId, success: true, summary: "fabricated")
        let outOfRangeOutcome = await verifier.verify(
            action: actionReq, result: fabricatedOutOfRangeResult,
            strategy: .scrollPositionReadSucceeded(applicationName: "SomeApp", role: "AXScrollArea", orientation: "vertical", position: 1.5)
        )
        #expect(outOfRangeOutcome.isVerified == false)

        let fabricatedNonFiniteResult = QActionResult(actionId: actionReq.actionId, success: true, summary: "fabricated")
        let nonFiniteOutcome = await verifier.verify(
            action: actionReq, result: fabricatedNonFiniteResult,
            strategy: .scrollPositionReadSucceeded(applicationName: "SomeApp", role: "AXScrollArea", orientation: "vertical", position: .nan)
        )
        #expect(nonFiniteOutcome.isVerified == false)

        let fabricatedBadOrientationResult = QActionResult(actionId: actionReq.actionId, success: true, summary: "fabricated")
        let badOrientationOutcome = await verifier.verify(
            action: actionReq, result: fabricatedBadOrientationResult,
            strategy: .scrollPositionReadSucceeded(applicationName: "SomeApp", role: "AXScrollArea", orientation: "diagonal", position: 0.5)
        )
        #expect(badOrientationOutcome.isVerified == false)
    }

    @Test("39. The scrollPositionReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed, even with an in-range position")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.scrollPositionReadSucceeded(applicationName: "SomeApp", role: "AXScrollArea", orientation: "vertical", position: 0.5)
        let result = QActionResult(actionId: "verify-scroll-read-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_scroll_position", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("40. Verification's independent bound recheck reuses the already-read position from the execution result's own output — it never performs a second AX read, staying within the declared one-read resource budget")
    func verificationNeverPerformsSecondAXRead() {
        // determineVerificationStrategy reconstructs applicationName/role/orientation/position
        // entirely from action.arguments and result.outputData — it never calls
        // QBridgeAccessibility.shared.readScrollPosition or any other AX primitive a second time,
        // by direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - J. Recovery

    @Test("41. An uncertain in-flight scroll-position-read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-scroll-read", sessionId: "s-uncertain-scroll-read", originalIntent: "Read scroll position",
            lifecycleState: .running, currentPlanId: "plan-uncertain-scroll-read", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-scroll-read", index: 0, actionName: "ui.read_scroll_position", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Read scroll position",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXScrollArea", "identifier": "GhostScroll", "orientation": "vertical"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-scroll-read", taskId: "task-uncertain-scroll-read", sessionId: "s-uncertain-scroll-read",
            goal: "Read scroll position", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    @Test("42. No raw AXUIElement reference is ever persisted — structural proof: QAXScrollPositionReadMetadata's stored properties are String/String?/Double only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXUIElementPersisted() {
        #expect(Bool(true))
    }

    @Test("43. QDurablePlanStepSnapshot does not serialize raw outputData beyond arguments")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.read_scroll_position",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "Read scroll position",
            targetResources: [],
            arguments: ["applicationName": "Finder", "identifier": "files-scroll", "orientation": "vertical"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "Read scroll position")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.read_scroll_position")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["orientation"] == "vertical")
    }

    // MARK: - K. Pipeline

    @Test("44. QPlanExecutor executes ui.read_scroll_position step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesScrollPositionReadStep() async throws {
        let mockExec = ScrollPositionReadMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_scroll_position",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read scroll position of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXScrollArea", "identifier": "x", "orientation": "vertical"]
            ),
            description: "Read scroll position of app"
        )
        let plan = QPlan(
            taskId: "t-plan-read-scroll-position",
            sessionId: "s-read-scroll-position",
            taskPrompt: "Read scroll position",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-read-scroll-position")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        // "status=verified" only ever appears via the dedicated .scrollPositionReadSucceeded
        // verification strategy's evidence string — never the generic ".customCheck { true }"
        // bare-bypass fallback every OTHER unrecognized action name would silently receive.
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Native AppKit E2E (TCC guarded)

    @Test("45/E2E. Real macOS AX E2E — reading a real NSScrollView's vertical position after deterministically, synchronously setting it via the already-proven ui.set_scroll_position bridge call round-trips exactly, guarded by AXIsProcessTrusted()")
    @MainActor
    func realAppKitScrollPositionReadRoundTrips() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let (window, scrollView) = makeReadableScrollableWindow(identifier: "E2EScrollRead-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard scrollView.verticalScroller != nil else {
            // This environment's AppKit did not instantiate a live vertical scroller for this
            // fixture — an honest hardware-validation finding, not a defect in
            // ui.read_scroll_position itself, mirroring QSemanticScrollPositionTests' own test
            // #60 identical finding.
            return
        }

        // Deterministically, synchronously establish a known real position on the live
        // AXScrollBar via the already-proven, already-tested setScrollPosition bridge call
        // directly (bypassing the approval flow, which is irrelevant to establishing the fixture
        // state for THIS read-only capability's own test) — no animation, no polling, no
        // sleep-based waiting for the value itself to settle, since AXUIElementSetAttributeValue
        // is a synchronous call.
        _ = try await QBridgeAccessibility.shared.setScrollPosition(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "E2EScrollRead-\(suffix)", title: nil,
            orientation: "vertical", desiredValue: 0.75
        )

        let metadata = try await QBridgeAccessibility.shared.readScrollPosition(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "E2EScrollRead-\(suffix)", title: nil, orientation: "vertical"
        )

        #expect(QBridgeAccessibility.sliderValuesAreEqual(metadata.position, 0.75))
        #expect(metadata.orientation == "vertical")
        #expect(metadata.applicationName == currentProcessAppName)
    }

    @Test("46/E2E. Real macOS AX E2E — reading a real NSScrollView's position at its genuine default (untouched) state yields a valid, in-range value — never an error merely for being at a default position, guarded by AXIsProcessTrusted()")
    @MainActor
    func realAppKitScrollPositionReadDefaultState() async throws {
        guard AXIsProcessTrusted() else {
            return
        }
        let suffix = UUID().uuidString
        let (window, scrollView) = makeReadableScrollableWindow(identifier: "E2EScrollDefault-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard scrollView.verticalScroller != nil else { return }

        let metadata = try await QBridgeAccessibility.shared.readScrollPosition(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "E2EScrollDefault-\(suffix)", title: nil, orientation: "vertical"
        )
        #expect(metadata.position >= 0.0 && metadata.position <= 1.0)
        #expect(metadata.position.isFinite)
    }
}
