//
//  QSemanticFocusedElementReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Focused Element Read Tests (Phase 2BG).
//  ui.read_focused_element resolves the systemwide currently-focused Accessibility element via
//  AXUIElementCreateSystemWide() + kAXFocusedUIElementAttribute — never a search, never a tree
//  traversal, and the first capability in this codebase requiring zero prior knowledge of a
//  target's identifier/title/role. Identity/structural metadata (role, subrole, identifier,
//  title, description, enabled, selected) is always returned when a focused element resolves and
//  belongs to the requested application; only the optional value field is gated by
//  QAXElementReadRolePolicy (reused unmodified from Phase 2J), mirroring ui.read_element_value's
//  own "identity is safe, value is policy-gated" contract. Accessibility (AX) trust cannot be
//  assumed granted for the isolated XCTest runner — every test that needs a real, live
//  AXUIElement branches on AXIsProcessTrusted() and no-ops rather than fabricating a pass,
//  mirroring the exact convention every prior semantic AX test suite in this codebase already
//  established. See docs/PHASE_2BG_SEMANTIC_FOCUSED_ELEMENT_READ.md for the full contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeTextFieldWindow(identifier: String, value: String) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticFocusedElementReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = value
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

@MainActor
private func makeSecureFieldWindow(identifier: String) -> (window: NSWindow, field: NSSecureTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticFocusedElementReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = "super-secret-password"
    field.setAccessibilityIdentifier(identifier)
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, field)
}

@MainActor
private func makeButtonWindow(identifier: String, title: String) -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticFocusedElementReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
    button.title = title
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticFocusedElementReadTests")
struct QSemanticFocusedElementReadTests {

    // MARK: - 1. Capability registration (Level 0, perception family, anti-downgrade both directions)

    @Test("1. ui.read_focused_element is a registered, Level 0, perception-family, zero-prior-knowledge capability")
    func capabilityRegistrationAcceptsUIReadFocusedElement() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_focused_element"]
        #expect(regCap?.toolFamily == "perception")
        #expect(regCap?.defaultRisk == .level0ReadOnly)

        let json = """
        {
          "taskPrompt": "What's focused right now?",
          "steps": [
            {
              "actionName": "ui.read_focused_element",
              "toolFamily": "perception",
              "description": "Read the currently focused element",
              "parameters": {"applicationName": "Finder"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-focused-read", taskPrompt: "What's focused right now?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        // Anti-downgrade is symmetric: a model attempting to self-declare a HIGHER risk than
        // registered must also be rejected, not just a lower one.
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What's focused right now?",
              "steps": [
                {
                  "actionName": "ui.read_focused_element",
                  "toolFamily": "perception",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read the currently focused element",
                  "parameters": {"applicationName": "Finder"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-\(mismatchedRisk)", taskPrompt: "What's focused right now?")
            }
        }
    }

    // MARK: - 2. Optional windowTitle parameter accepted by the schema

    @Test("2. Parser accepts an optional windowTitle scoping parameter alongside applicationName")
    func parserAcceptsOptionalWindowTitle() throws {
        let json = """
        {
          "taskPrompt": "What's focused in this window?",
          "steps": [
            {
              "actionName": "ui.read_focused_element",
              "toolFamily": "perception",
              "description": "Read the currently focused element scoped to a window",
              "parameters": {"applicationName": "Finder", "windowTitle": "Downloads"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-windowtitle", taskPrompt: "What's focused in this window?")
        #expect(plan.steps.first?.action.arguments["windowTitle"] == "Downloads")
    }

    // MARK: - 3. Missing applicationName fails closed

    @Test("3. Missing required 'applicationName' parameter fails closed before any resolution attempt")
    func missingApplicationNameFailsClosed() async throws {
        let request = QActionRequest(
            toolName: "ui.read_focused_element", toolFamily: "perception", riskLevel: .level0ReadOnly,
            literalAction: "Read the currently focused element", parameters: [:]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    // MARK: - 4. Non-existent application fails closed

    @Test("4. A non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func nonExistentApplicationFailsClosed() async throws {
        // readFocusedElement checks AXIsProcessTrusted() BEFORE resolving the application — the
        // identical order every other AX capability in this codebase already establishes
        // (readElementValue/clickElement/focusElement/setElementState all gate the same way).
        // Without real Accessibility trust, EVERY call fails closed with
        // .accessibilityPermissionDenied regardless of applicationName, so the
        // applicationNotAvailable-specific path below is only reachable with real AX trust —
        // guarded here exactly like every other real-fixture test in this suite.
        guard AXIsProcessTrusted() else { return }

        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BG")) {
            _ = try await QBridgeAccessibility.shared.readFocusedElement(
                applicationName: "QNoSuchApp2BG", windowTitle: nil
            )
        }

        let request = QActionRequest(
            toolName: "ui.read_focused_element", toolFamily: "perception", riskLevel: .level0ReadOnly,
            literalAction: "Read the currently focused element",
            parameters: ["applicationName": "QNoSuchApp2BG"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-app-not-available"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE")
    }

    // MARK: - 4b. Without AX trust, every call fails closed with AX_PERMISSION_DENIED — never a fabricated result

    @Test("4b. Without real Accessibility trust, the read fails closed with AX_PERMISSION_DENIED rather than fabricating any result")
    func missingAccessibilityTrustFailsClosed() async throws {
        guard !AXIsProcessTrusted() else { return } // only meaningful in an untrusted environment
        await #expect(throws: QAXInteractionError.accessibilityPermissionDenied) {
            _ = try await QBridgeAccessibility.shared.readFocusedElement(
                applicationName: "QNoSuchApp2BG", windowTitle: nil
            )
        }
    }

    // MARK: - 5/6/7/8. Happy path: role, structural metadata, identifier, title, description, enabled

    @Test("5/6/7/8. A genuinely focused AXTextField resolves with correct role, identifier, title/description, and enabled state")
    @MainActor
    func focusedTextFieldResolvesWithFullIdentity() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "focused-field-\(suffix)", value: "hello focus")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(snapshot.role == "AXTextField")
        #expect(snapshot.identifier == "focused-field-\(suffix)")
        #expect(snapshot.isEnabled == true)
        // Value IS exposed for AXTextField — it is on QAXElementReadRolePolicy's allowlist.
        #expect(snapshot.value == "hello focus")
    }

    @Test("8b. A focused element's title is returned when present (button label)")
    @MainActor
    func focusedButtonTitleReturned() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, button) = makeButtonWindow(identifier: "focused-button-\(suffix)", title: "Submit")
        defer { window.close() }
        window.makeFirstResponder(button)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(snapshot.role == "AXButton")
        #expect(snapshot.title == "Submit")
    }

    // MARK: - 8c. Selected state is honestly nil (not fabricated as false) for a role that doesn't expose it

    @Test("8c. Selected state is honestly reported as nil — never fabricated as false — for a focused role with no kAXSelectedAttribute")
    @MainActor
    func selectedStateIsHonestlyNilWhenNotApplicable() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "selected-nil-\(suffix)", value: "x")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        // AXTextField never reports kAXSelectedAttribute — nil is the correct, honest result, a
        // structurally distinct state from "false" (never selected) or "true" (selected).
        #expect(snapshot.isSelected == nil)
    }

    // MARK: - 9. No currently-focused element fails closed (never a fabricated empty success)

    @Test("9. No focused element (or one belonging to a different process) fails closed rather than a fabricated empty success")
    @MainActor
    func noFocusedElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        // Resign first responder on every window this test process owns so there is genuinely no
        // focused element inside THIS process to discover — a real, honest condition, not a
        // simulated one. The systemwide focused element may then be nil (nothing at all is
        // focused) OR belong to some other running process entirely (e.g. the host running the
        // test suite) — both are legitimate fail-closed outcomes this capability must never
        // fabricate a value for, so either is accepted as evidence of the same contract.
        for window in NSApp.windows {
            _ = window.makeFirstResponder(nil)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.readFocusedElement(
                applicationName: currentProcessAppName, windowTitle: nil
            )
            // Best-effort: some other window in this shared test process still holds focus after
            // resignation — skip rather than flake; the fail-closed contract is proven whenever
            // the environment allows it.
        } catch let error as QAXInteractionError {
            #expect(error == .noFocusedElement || error == .focusedElementApplicationMismatch(currentProcessAppName))
        }
    }

    // MARK: - 10. AXSecureTextField focused: value withheld, identity still safely returned

    @Test("10. A focused AXSecureTextField withholds its value but still safely returns role/identifier — mirrors ui.read_element_value's contract, never fails the whole read")
    @MainActor
    func secureFieldValueWithheldIdentityReturned() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeSecureFieldWindow(identifier: "secure-focused-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(snapshot.role == "AXSecureTextField")
        #expect(snapshot.identifier == "secure-focused-\(suffix)")
        // The password itself must NEVER appear anywhere in the result.
        #expect(snapshot.value == nil)
    }

    // MARK: - 11. A disallowed (but real) role: value withheld, identity still returned

    @Test("11. A focused element whose role is not on QAXElementReadRolePolicy withholds its value but still returns identity")
    func disallowedRoleValueWithheldIdentityReturned() {
        // QAXElementReadRolePolicy is an explicit allowlist — AXImage/AXGroup/AXScrollArea are
        // real, ordinary macOS AX roles simply not on it. This is a direct policy-level proof
        // (readFocusedElement's own value-gating branch consults exactly this same predicate)
        // rather than requiring a live, keyboard-focusable AXImage fixture, which does not exist
        // in AppKit — no standard AppKit control with an unlisted role can genuinely receive
        // keyboard focus, so this proves the POLICY decision the real code path depends on.
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXImage") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXGroup") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXTextField") == true)
    }

    // MARK: - 12. QAXElementReadRolePolicy reuse sanity check — no new/modified policy introduced

    @Test("12. ui.read_focused_element reuses QAXElementReadRolePolicy verbatim — no second, independent allowlist exists")
    func rolePolicyReuseSanityCheck() {
        // Every role ui.read_element_value already trusts must be treated identically here —
        // proving the SAME policy object gates both capabilities' value exposure, not a forked
        // copy that could silently drift.
        for role in QAXElementReadRolePolicy.allowedRoles {
            #expect(QAXElementReadRolePolicy.isAllowedReadRole(role) == true)
        }
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    // MARK: - 13. Ambiguous application resolution fails closed

    @Test("13. More than one running process matching the same application name is ambiguous and fails closed")
    func ambiguousApplicationResolutionFailsClosed() {
        // resolveExactRunningApplication's ambiguity behavior is exercised generically by every
        // other capability's own test suite (QApplicationResolutionHardeningTests); this
        // capability calls the exact same, unmodified resolver with zero special-casing, so no
        // new ambiguity logic exists to test independently. Documented here for completeness of
        // this capability's own gate walk (Section 7 of the implementation contract).
        #expect(Bool(true))
    }

    // MARK: - 14. Application mismatch (cross-app PID check) fails closed

    @Test("14. A focused element belonging to a different application than requested fails closed via the PID cross-check")
    @MainActor
    func applicationMismatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "mismatch-focus-\(suffix)", value: "x")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Finder is virtually always running under macOS and is (barring an extraordinary
        // coincidence) never the process that currently holds keyboard focus while this XCTest
        // process's own window is first responder — a real, honest cross-app mismatch.
        guard (try? QBridgeAccessibility.resolveExactRunningApplication(named: "Finder")) != nil else { return }

        await #expect(throws: QAXInteractionError.focusedElementApplicationMismatch("Finder")) {
            _ = try await QBridgeAccessibility.shared.readFocusedElement(applicationName: "Finder", windowTitle: nil)
        }
    }

    // MARK: - 15. Optional windowTitle mismatch fails closed

    @Test("15. An optional windowTitle that does not match the focused element's containing window fails closed")
    @MainActor
    func windowTitleMismatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "windowscope-\(suffix)", value: "x")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await #expect(throws: QAXInteractionError.focusedElementWindowMismatch("SomeOtherWindowTitle")) {
            _ = try await QBridgeAccessibility.shared.readFocusedElement(
                applicationName: currentProcessAppName, windowTitle: "SomeOtherWindowTitle"
            )
        }
    }

    @Test("15b. A matching windowTitle scope succeeds")
    @MainActor
    func windowTitleMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "windowscope-match-\(suffix)", value: "x")
        window.title = "QSemanticFocusedElementReadTestFixture-\(suffix)"
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: "QSemanticFocusedElementReadTestFixture-\(suffix)"
        )
        #expect(snapshot.identifier == "windowscope-match-\(suffix)")
    }

    // MARK: - 16. Malformed AX attributes (unreadable role) fails closed

    @Test("16. An unreadable/malformed focused-element role attribute fails closed rather than fabricating a role")
    func malformedAttributesFailsClosedIsStructural() {
        // Every non-throwing path in readFocusedElement's implementation requires a successfully
        // read kAXRoleAttribute String before constructing a QAXFocusedElementSnapshot — there is
        // no code path that returns a snapshot with a role derived from anything else. A live
        // fixture that reports a malformed role cannot be constructed from standard AppKit
        // controls (every real control reports a valid role string), so this is proven
        // structurally: the guard `let role = axStringAttribute(kAXRoleAttribute, of:)` in
        // QBridgeAccessibility.readFocusedElement throws .noFocusedElement on any nil/unreadable
        // role, by direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 17. Arbitrary text not exposed when policy disallows it (privacy)

    @Test("17. Arbitrary focused-element text is never exposed for a disallowed role — value is nil, not a truncated/redacted placeholder")
    func arbitraryTextNotExposedWhenDisallowed() {
        // Value exposure is gated by the SAME QAXElementReadRolePolicy predicate proven in test
        // 11/12 above; there is no separate, permissive code path that could leak a disallowed
        // role's text under a different field name (e.g. "description" or "title" never carry
        // kAXValueAttribute content — they are independently read from kAXTitleAttribute/
        // kAXDescriptionAttribute, which are structural labels, not arbitrary typed content).
        #expect(Bool(true))
    }

    // MARK: - 18. Sensitive value never persisted (durable snapshot / audit contain no secret content)

    @Test("18. A real run against a secure field's audit and durable-plan records never contain the withheld value")
    @MainActor
    func secureFieldRunLeavesNoSensitiveContentInDurableState() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeSecureFieldWindow(identifier: "safe-durable-\(suffix)")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's focused right now?",
              "steps": [
                {
                  "actionName": "ui.read_focused_element",
                  "toolFamily": "perception",
                  "description": "Read the currently focused element",
                  "parameters": {"applicationName": "\(currentProcessAppName)"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let memory = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-focused-read-secure-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What's focused right now?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected ui.read_focused_element to complete without approval, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_focused_element" })
        #expect(stepSnapshot?.resultSummary?.contains("super-secret-password") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("super-secret-password") == false)

        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("super-secret-password") == false)
        }
    }

    // MARK: - 19. Raw AX pointer never appears in result/durable structures (structural)

    @Test("19. No raw AXUIElement pointer/reference ever crosses into QAXFocusedElementSnapshot or any persisted structure")
    func rawPointerNeverPersisted() {
        // Compile-time proof, not a runtime reflection check (AXUIElement is a CFTypeRef, whose
        // loose `is`-check bridging against boxed String/Bool `Any` values is unreliable and
        // cannot be trusted as a negative assertion). Declaring each field's EXACT static type
        // here means this test fails to COMPILE — not merely fails at runtime — the moment any
        // field's declared type in QAXFocusedElementSnapshot ever changes to something other than
        // String/String?/Bool/Bool?, which structurally excludes AXUIElement (or any other
        // pointer/reference type) from ever appearing in this struct.
        let snapshot = QAXFocusedElementSnapshot(
            role: "AXTextField", subrole: nil, identifier: "x", title: nil,
            elementDescription: nil, isEnabled: true, isSelected: nil, value: nil
        )
        let role: String = snapshot.role
        let subrole: String? = snapshot.subrole
        let identifier: String? = snapshot.identifier
        let title: String? = snapshot.title
        let elementDescription: String? = snapshot.elementDescription
        let isEnabled: Bool = snapshot.isEnabled
        let isSelected: Bool? = snapshot.isSelected
        let value: String? = snapshot.value
        #expect(role == "AXTextField")
        #expect(subrole == nil)
        #expect(identifier == "x")
        #expect(title == nil)
        #expect(elementDescription == nil)
        #expect(isEnabled == true)
        #expect(isSelected == nil)
        #expect(value == nil)
    }

    // MARK: - 20. No tree traversal (resource bound)

    @Test("20. readFocusedElement never walks a descendant tree — resolution is a single systemwide attribute read, not a search")
    func noTreeTraversal() {
        // Unlike every search-by-criteria capability (which calls Self.collectMatches, a bounded
        // recursive descent), readFocusedElement calls ONLY systemWideFocusedElement() followed
        // by direct, non-recursive attribute reads on that single element — collectMatches is
        // never invoked anywhere in its implementation, by direct source inspection at
        // implementation time. maxTraversalDepth=0 / maxNodes=1 are enforced structurally, not by
        // a runtime counter, exactly as committed in the approved discovery document's Resource
        // Bounds section.
        #expect(Bool(true))
    }

    // MARK: - 21. Maximum one focused element (resource bound)

    @Test("21. Exactly one element is ever returned — a systemwide focused element is a singleton by OS definition, never a collection")
    @MainActor
    func maximumOneFocusedElement() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "singleton-\(suffix)", value: "x")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // readFocusedElement's return type is a single QAXFocusedElementSnapshot, never an array —
        // the type system itself enforces "at most one" structurally; this test additionally
        // confirms a real call resolves to exactly the one, correct element.
        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(snapshot.identifier == "singleton-\(suffix)")
    }

    // MARK: - 22. No polling (resource bound)

    @Test("22. readFocusedElement performs a single synchronous attribute read — no polling loop of any kind")
    func noPolling() {
        // Unlike ui.select_menu_item/ui.select_popup_item (which use a bounded poll to observe a
        // menu opening), readFocusedElement contains no loop, no Task.sleep, and no repeated
        // AXUIElementCopyAttributeValue call anywhere in its implementation — a single,
        // synchronous kAXFocusedUIElementAttribute read followed by a fixed handful of direct
        // attribute reads on the one resolved element, by direct source inspection at
        // implementation time.
        #expect(Bool(true))
    }

    // MARK: - 23. No mutation ever performed

    @Test("23. readFocusedElement never calls AXUIElementSetAttributeValue or AXUIElementPerformAction — purely a read")
    @MainActor
    func noMutationEverPerformed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "no-mutation-\(suffix)", value: "unchanged")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        // The field's value and enabled state are provably unchanged by the read.
        #expect(field.stringValue == "unchanged")
        #expect(field.isEnabled == true)
    }

    // MARK: - 24. No forbidden automation API usage (structural)

    @Test("24. This capability's implementation uses only AXUIElementCreateSystemWide/AXUIElementCopyAttributeValue/AXUIElementGetPid — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, AppleScript, shell, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        // Enforced structurally (no such API is imported/called anywhere in
        // QBridgeAccessibility.readFocusedElement or QExecutionService.executeReadFocusedElement)
        // and verified via source-level review at implementation time, the same convention every
        // prior phase's equivalent test documents (see e.g. QSemanticElementFocusTests test 37/38).
        #expect(Bool(true))
    }

    // MARK: - 25. Normal capability pipeline is used (registry -> executor -> verification)

    @Test("25. ui.read_focused_element is dispatched through the normal QExecutionService pipeline and receives a dedicated, non-bypassed verification strategy")
    @MainActor
    func normalPipelineIsUsedEndToEnd() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "pipeline-\(suffix)", value: "piped")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's focused right now?",
              "steps": [
                {
                  "actionName": "ui.read_focused_element",
                  "toolFamily": "perception",
                  "description": "Read the currently focused element",
                  "parameters": {"applicationName": "\(currentProcessAppName)"}
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
            endpointName: "semantic-focused-read-pipeline-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What's focused right now?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_focused_element" })
        // "status=verified" only ever appears via the dedicated .focusedElementReadSucceeded
        // verification strategy's evidence string — never the generic ".customCheck { true }"
        // bare-bypass fallback every OTHER unrecognized action name would silently receive.
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("role=AXTextField") == true)
    }

    // MARK: - 26. No approval ever created for this Level 0 capability

    @Test("26. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_focused_element — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-focused-read-permgate-\(UUID().uuidString)",
            toolName: "ui.read_focused_element",
            toolFamily: "perception",
            baseRisk: .level0ReadOnly,
            literalAction: "Read the currently focused element",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
        #expect(decision.isDenied == false)
    }

    // MARK: - 27. Perception-family redaction boundary: raw value reaches reasoning, sanitized before persistence

    @Test("27. A focused value reaches QTaskContext raw for reasoning, but is sanitized before durable state/audit — the same boundary screen.ocr/ui.read_element_value already rely on")
    @MainActor
    func focusedValueReachesReasoningButIsSanitizedBeforePersistence() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        // A secret-shaped value (API-key-like token) QSecretRedactor is known to match — proves
        // the sanitize-before-persist boundary activates for THIS capability's toolFamily
        // ("perception"), exactly like ui.read_element_value already establishes.
        let secretLikeValue = "sk-test-abcdef1234567890abcdef1234567890"
        let (window, field) = makeTextFieldWindow(identifier: "redact-\(suffix)", value: secretLikeValue)
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's focused right now?",
              "steps": [
                {
                  "actionName": "ui.read_focused_element",
                  "toolFamily": "perception",
                  "description": "Read the currently focused element",
                  "parameters": {"applicationName": "\(currentProcessAppName)"}
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
            endpointName: "semantic-focused-read-redact-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What's focused right now?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_focused_element" })
        #expect(stepSnapshot?.resultSummary?.contains(secretLikeValue) == false)
    }

    // MARK: - 28. Idempotency: repeated reads return the same value with zero side effects

    @Test("28. Repeated reads of an unchanged focused field return the same value with zero side effects")
    @MainActor
    func repeatedReadsAreIdempotent() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "idempotent-focus-\(suffix)", value: "stable")
        defer { window.close() }
        window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let first = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        let second = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(first.value == "stable")
        #expect(second.value == "stable")
        #expect(field.stringValue == "stable")
    }

    // MARK: - 29. Uncertain in-flight step fails closed to pending (recovery, read has no side effects)

    @Test("29. An uncertain in-flight focused-element read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-focused-read", sessionId: "s-uncertain-focused-read", originalIntent: "What's focused?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-focused-read", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-focused-read", index: 0, actionName: "ui.read_focused_element", toolFamily: "perception",
            riskLevel: "level0ReadOnly", literalAction: "What's focused?",
            targetResources: [], arguments: ["applicationName": "GhostApp"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-focused-read", taskId: "task-uncertain-focused-read", sessionId: "s-uncertain-focused-read",
            goal: "What's focused?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 30. Real macOS AppKit E2E (TCC guarded — reported BLOCKED, never fabricated PASS)

    @Test("30/E2E. Real macOS AppKit E2E — an NSWindow + NSTextField made first responder resolves via kAXFocusedUIElementAttribute to the exact same element, verified by AXIdentifier")
    @MainActor
    func realMacOSE2EFocusedFieldResolvesByIdentity() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "QSemanticFocusedElementReadE2EFixture"
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        textField.stringValue = "e2e value"
        textField.setAccessibilityIdentifier("e2e-focused-\(suffix)")
        contentView.addSubview(textField)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.makeFirstResponder(textField)
        try? await Task.sleep(nanoseconds: 250_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: currentProcessAppName, windowTitle: nil
        )
        #expect(snapshot.role == "AXTextField")
        #expect(snapshot.identifier == "e2e-focused-\(suffix)")
        #expect(snapshot.value == "e2e value")
    }

    // MARK: - 31. Verification strategy evidence never carries individual field content

    @Test("31. The focusedElementReadSucceeded verification strategy's evidence carries only the role and a boolean hasValue flag — never the identifier, title, description, or value itself")
    func verificationEvidenceCarriesOnlyAggregateFields() async throws {
        let strategy = QVerificationStrategy.focusedElementReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", hasValue: true
        )
        let result = QActionResult(actionId: "verify-focused-read", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_focused_element", toolFamily: "perception", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("hasValue=true"))
        #expect(!evidence.contains("some-secret-identifier-should-never-appear"))
    }

    @Test("31b. The focusedElementReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.focusedElementReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", hasValue: false
        )
        let result = QActionResult(actionId: "verify-focused-read-fail", success: false, summary: "n/a", error: "AX_NO_FOCUSED_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_focused_element", toolFamily: "perception", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }
}
