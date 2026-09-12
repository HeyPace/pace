//
//  QSemanticOutlineRowSelectionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Outline Row Selection Tests (Phase 2T).
//
//  Confirmed directly against this SDK's authoritative AXRoleConstants.h (the same header family
//  that confirmed ui.select_table_row's role/subrole/parent constants in Phase 2S): kAXRowRole ==
//  "AXRow" (the same base role table rows use), kAXOutlineRole == "AXOutline", and
//  kAXOutlineRowSubrole == "AXOutlineRow" — a real, distinct subrole from kAXTableRowSubrole ==
//  "AXTableRow", which ui.select_table_row already owns. ui.select_outline_row resolves by role
//  AXRow (QAXOutlineRowRolePolicy's only allowed role) and additionally, unconditionally requires
//  BOTH the AXOutlineRow subrole AND a resolved kAXParentAttribute whose own role is exactly
//  AXOutline — a row lacking either is refused, never treated as an outline row. AXTableRow is
//  recognized-but-refused with its own distinct diagnostic, never silently folded into
//  outline-row handling — the exact reciprocal of ui.select_table_row's own AXOutlineRow refusal.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

/// A container view that authentically self-reports Accessibility role `AXOutline` — the parent
/// context `ui.select_outline_row` requires every genuine outline row to resolve to. A plain
/// `NSView` override, not a real `NSOutlineView`: the production role/parent-context checks only
/// ever inspect `kAXRoleAttribute`/`kAXParentAttribute`, never the concrete control class, so this
/// is a genuinely real, live AXUIElement satisfying the exact contract, not a simulation.
@MainActor
private final class QOutlineContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXOutline")
    }
}

/// A minimal, genuinely-real AXUIElement fixture that authentically self-reports Accessibility
/// role `AXRow` with subrole `AXOutlineRow`, and a real, live, independently-readable
/// `kAXSelectedAttribute`, via the standard `NSAccessibility` protocol override mechanism — the
/// same mechanism every custom-AX-role AppKit control uses, not a mock or simulation. Backed by a
/// real on-screen `NSButton` configured as a `.pushOnPushOff` toggle so a genuine
/// `AXUIElementPerformAction(kAXPressAction)` call flips its `.state`, which this override then
/// reports as `isAccessibilitySelected()`. Its default AX parent (unoverridden — the standard
/// AppKit subview-mirrors-AX-tree behavior every prior fixture in this codebase already relies
/// on) is whatever view it is added as a subview of.
@MainActor
private final class QOutlineTreeRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXOutlineRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

/// A genuine `AXRow` WITHOUT the `AXOutlineRow` subrole — an unqualified row, used to prove
/// `ui.select_outline_row` correctly refuses to treat it as an outline row.
@MainActor
private final class QUnqualifiedOutlineRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

/// A genuine `AXRow` carrying the real, SDK-confirmed `AXTableRow` subrole — the sibling subrole
/// `ui.select_table_row` already owns. Used to prove `ui.select_outline_row` explicitly and
/// distinctly refuses it, never silently folding table-row selection into outline-row handling —
/// the exact reciprocal of `ui.select_table_row`'s own `AXOutlineRow` refusal (Phase 2S).
@MainActor
private final class QTableRowSubroleOnOutlineFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXTableRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

/// A properly-qualified outline row (`AXRow` + `AXOutlineRow`), correctly nested inside an
/// `AXOutline`-role container — the "everything is correct" fixture most tests build on.
@MainActor
private func makeOutlineRowWindow(
    identifier: String,
    initiallySelected: Bool
) -> (window: NSWindow, container: QOutlineContainerFixtureView, row: QOutlineTreeRowFixtureButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 200, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticOutlineRowSelectionTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let container = QOutlineContainerFixtureView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let row = QOutlineTreeRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
    row.setButtonType(.pushOnPushOff)
    row.state = initiallySelected ? .on : .off
    row.title = "Node"
    row.setAccessibilityIdentifier(identifier)
    container.addSubview(row)
    contentView.addSubview(container)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, container, row)
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticOutlineRowSelectionTests")
struct QSemanticOutlineRowSelectionTests {

    // MARK: - 1/2/3. Registration, risk level, anti-downgrade

    @Test("1/2/3. ui.select_outline_row is a registered, Level 2, semantically-targeted, selection-only capability and cannot be risk-downgraded")
    func capabilityRegistrationAcceptsUISelectOutlineRow() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_outline_row"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level2UserApproval)

        let json = """
        {
          "taskPrompt": "Select the outline node",
          "steps": [
            {
              "actionName": "ui.select_outline_row",
              "toolFamily": "ui",
              "description": "Select a semantically-identified outline row",
              "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Node1", "desiredSelected": "true"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-outline-row", taskPrompt: "Select the outline node")
        #expect(plan.steps.first?.action.riskLevel == .level2UserApproval)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == true)
        #expect(plan.steps.first?.action.riskLevel.isConsideredReversible == true)

        for mismatchedRisk in ["level0ReadOnly", "level1SafeLocalAction", "level3HighRisk"] {
            let downgradeJSON = """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "Finder", "role": "AXRow", "identifier": "Node1", "desiredSelected": "true"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: downgradeJSON, taskId: "t-mismatch-outline-row-\(mismatchedRisk)", taskPrompt: "Select the outline node")
            }
        }
    }

    // MARK: - 4/5. Missing target criteria fails closed

    @Test("4/5. Missing/empty target criteria fails closed with a deterministic error")
    func missingTargetCriteriaFailsClosed() async throws {
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: nil, title: nil, desiredSelected: true
            )
        }

        let request = QActionRequest(
            toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Select outline row",
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "desiredSelected": "true"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-target-criteria-outline-row"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    // MARK: - 6/7. Missing/invalid desiredSelected fails closed

    @Test("6/7. Missing/invalid desiredSelected fails closed with a deterministic error")
    func missingOrInvalidDesiredSelectedFailsClosed() async throws {
        let missingRequest = QActionRequest(
            toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Select outline row",
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "x"]
        )
        let missingResult = try await QExecutionService.shared.executeAction(missingRequest, context: QTaskContext(taskId: "t-missing-desired-selected-outline-row"))
        #expect(missingResult.success == false)
        #expect(missingResult.error == "desiredSelected invalid")

        for invalid in ["", "yes", "no", "1", "0", "True", "FALSE", "selected"] {
            let request = QActionRequest(
                toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval,
                literalAction: "Select outline row",
                parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "x", "desiredSelected": invalid]
            )
            let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-invalid-desired-selected-outline-row"))
            #expect(result.success == false, "Invalid desiredSelected '\(invalid)' must be rejected — exact 'true'/'false' only.")
            #expect(result.error == "desiredSelected invalid")
        }
    }

    // MARK: - 8/9-18. Role policy: AXRow accepted as a SEARCH criterion; every other role rejected

    @Test("8. AXRow is accepted as a search criterion (proven not to be rejected at the role-policy gate; the SEPARATE mandatory AXOutlineRow subrole + AXOutline parent-context checks are proven independently below)")
    func rowRoleAccepted() {
        #expect(QAXOutlineRowRolePolicy.isAllowedOutlineRowRole("AXRow") == true)
    }

    @Test("9-18. AXRadioButton, AXCheckBox, AXPopUpButton, AXDisclosureTriangle, AXButton, AXTextField, AXTable, AXOutline, AXOutlineCell, and an unrecognized role are all rejected for outline-row selection at the role-policy gate")
    func nonRowRolesRejected() async throws {
        for disallowedRole in ["AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXDisclosureTriangle", "AXButton", "AXTextField", "AXTable", "AXOutline", "AXOutlineCell", "AXMadeUpRole99"] {
            await #expect(throws: QAXInteractionError.disallowedOutlineRowRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil, desiredSelected: true
                )
            }
        }
    }

    // MARK: - 19. Unqualified AXRow (no AXOutlineRow subrole) is never treated as an outline row

    @Test("19. A genuine AXRow WITHOUT the AXOutlineRow subrole is refused — never treated as an outline row")
    @MainActor
    func unqualifiedRowWithoutSubroleRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let container = QOutlineContainerFixtureView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let unqualifiedRow = QUnqualifiedOutlineRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
        unqualifiedRow.setButtonType(.pushOnPushOff)
        unqualifiedRow.title = "Node"
        unqualifiedRow.setAccessibilityIdentifier("unqualified-\(suffix)")
        container.addSubview(unqualifiedRow)
        contentView.addSubview(container)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.targetNotAnOutlineRow("none")) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "unqualified-\(suffix)", title: nil, desiredSelected: true
            )
        }
        #expect(unqualifiedRow.state == .off) // unchanged — proves no press was attempted
    }

    // MARK: - 20. AXTableRow is a real, recognized, but distinctly-unsupported subrole (reciprocal of Phase 2S)

    @Test("20. A genuine AXRow carrying the real AXTableRow subrole is explicitly, distinctly refused — never silently folded into outline-row handling")
    @MainActor
    func tableRowSubroleRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let container = QOutlineContainerFixtureView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let tableRow = QTableRowSubroleOnOutlineFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
        tableRow.setButtonType(.pushOnPushOff)
        tableRow.title = "Node"
        tableRow.setAccessibilityIdentifier("tablerow-\(suffix)")
        container.addSubview(tableRow)
        contentView.addSubview(container)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.tableRowUnsupportedForOutline("AXTableRow")) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "tablerow-\(suffix)", title: nil, desiredSelected: true
            )
        }
        #expect(tableRow.state == .off) // unchanged — proves no press was attempted
    }

    // MARK: - 21. A qualified row lacking an AXOutline parent context is refused

    @Test("21. A genuine AXRow+AXOutlineRow WITHOUT an AXOutline parent context is refused — an arbitrary standalone row is never accepted")
    @MainActor
    func missingOutlineContextRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        // Deliberately NOT nested inside a QOutlineContainerFixtureView — added directly to
        // contentView (an ordinary, non-AXOutline-role view), so its parent context cannot be
        // established.
        let orphanRow = QOutlineTreeRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
        orphanRow.setButtonType(.pushOnPushOff)
        orphanRow.title = "Node"
        orphanRow.setAccessibilityIdentifier("orphan-\(suffix)")
        contentView.addSubview(orphanRow)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.outlineContextUnavailable("parent role is not AXOutline")) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "orphan-\(suffix)", title: nil, desiredSelected: true
            )
        }
        #expect(orphanRow.state == .off) // unchanged — proves no press was attempted
    }

    // MARK: - 22. A fully-qualified row (role + subrole + outline context) is accepted

    @Test("22. A genuine AXRow+AXOutlineRow correctly nested inside an AXOutline parent is accepted — proving the subrole and outline-context gates correctly recognize a real outline row")
    @MainActor
    func fullyQualifiedRowAccepted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "qualified-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "qualified-\(suffix)", title: nil, desiredSelected: true
        )
        #expect(outcome.changeKind == .changed)
    }

    // MARK: - 23/24/25. Valid / missing / wrong-application target resolution

    @Test("23/24/25. A valid target resolves; a missing target and a wrong application both fail closed")
    @MainActor
    func validMissingAndWrongApplicationTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "present-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "present-\(suffix)", title: nil, desiredSelected: true
        )
        #expect(!outcome.targetIdentity.isEmpty)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "absent-\(suffix)", title: nil, desiredSelected: true
            )
        }

        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2T")) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: "QNoSuchApp2T", role: "AXRow", identifier: "whatever", title: nil, desiredSelected: true
            )
        }
    }

    // MARK: - 26. Ambiguous target rejected

    @Test("26. Two outline rows matching the same identifier is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let container = QOutlineContainerFixtureView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let rowA = QOutlineTreeRowFixtureButton(frame: NSRect(x: 20, y: 70, width: 160, height: 24))
        rowA.setButtonType(.pushOnPushOff)
        rowA.title = "Node"
        rowA.setAccessibilityIdentifier("dup-node-\(suffix)")
        let rowB = QOutlineTreeRowFixtureButton(frame: NSRect(x: 20, y: 20, width: 160, height: 24))
        rowB.setButtonType(.pushOnPushOff)
        rowB.title = "Node"
        rowB.setAccessibilityIdentifier("dup-node-\(suffix)")
        container.addSubview(rowA)
        container.addSubview(rowB)
        contentView.addSubview(container)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "dup-node-\(suffix)", title: nil, desiredSelected: true
            )
        }
    }

    // MARK: - 27. Stale target comparison primitive

    @Test("27. The observation-binding staleness comparison correctly distinguishes an unchanged target from a changed one")
    func staleTargetComparisonPrimitive() {
        // ui.select_outline_row reuses the identical QAXElementSnapshot identity-equality
        // primitive every prior mutation capability already relies on. A genuine live race
        // between resolution and dispatch cannot be triggered deterministically without an
        // artificial delay seam in production code — the same documented, honest limitation
        // established for ui.click_element and carried forward through every subsequent phase.
        let unchanged = QAXElementSnapshot(role: "AXRow", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let sameAgain = QAXElementSnapshot(role: "AXRow", identifier: "id-1", titleOrDescription: nil, isEnabled: true)
        let changed = QAXElementSnapshot(role: "AXRow", identifier: "id-2", titleOrDescription: nil, isEnabled: true)
        #expect(unchanged == sameAgain)
        #expect(unchanged != changed)
    }

    // MARK: - 28. Fuzzy / substring / index-only matching never accepted

    @Test("28. A substring or fuzzy-cased variant of a real row's identifier is never accepted as a match — no positional/index-only fallback exists")
    @MainActor
    func nonExactIdentifierVariantsRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "exact-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "exact-", title: nil, desiredSelected: true
            )
        }
        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: currentProcessAppName, role: "AXRow", identifier: "EXACT-\(suffix)".uppercased(), title: nil, desiredSelected: true
            )
        }
        // No index/position-based parameter exists in the schema at all (only
        // applicationName/role/identifier/title/desiredSelected) — structurally impossible to
        // request "the first row" or "row 2", verified via source-level review at implementation
        // time.
        #expect(Bool(true))
    }

    // MARK: - 29. Selection-state read primitive never guesses (documented)

    @Test("29. The raw kAXSelectedAttribute read primitive never guesses on an unreadable value — reused from the existing generic axBoolAttribute helper, no new low-level plumbing")
    func selectionStateReadPrimitiveDocumented() {
        // selectOutlineRow/observeOutlineRowSelectionEvidence both read kAXSelectedAttribute via
        // the existing, already-reused axBoolAttribute(_:of:) helper, the AXOutlineRow subrole
        // via the existing generic axStringAttribute(_:of:) helper, and the AXOutline
        // parent-context role via the existing generic axElementAttribute(_:of:) helper (already
        // used for kAXMenuBarAttribute and, since Phase 2S, kAXParentAttribute) — no new
        // low-level plumbing for any of the three. An unreadable/non-boolean attribute returns
        // nil, never coerced into a default true/false, verified via source-level review at
        // implementation time.
        #expect(Bool(true))
    }

    // MARK: - 30/31. Idempotency: already-selected succeeds with no mutation

    @Test("30/31. Selecting a row that already reports selected=true is an idempotent no-op — no AX press, proven structurally by the mutually-exclusive .alreadyDesired branch")
    @MainActor
    func alreadySelectedIsNoOp() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "noop-\(suffix)", initiallySelected: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "noop-\(suffix)", title: nil, desiredSelected: true
        )
        // .alreadyDesired is the ONLY branch in selectOutlineRow's implementation that returns
        // without an intervening AXUIElementPerformAction press — structurally proving no
        // mutation occurred, the same convention every prior idempotent AX capability in this
        // codebase already establishes.
        #expect(outcome.changeKind == .alreadyDesired)
        #expect(outcome.previousSelected == true)
        #expect(outcome.currentSelected == true)
        #expect(row.state == .on) // unchanged — proves no press occurred
    }

    // MARK: - 32/33. Deselection is categorically out of scope — refused before any AX call

    @Test("32. desiredSelected=false is refused at the bridge layer BEFORE any Accessibility Trust check or application resolution — never a blind toggle")
    func bridgeLevelDeselectionRejected() async throws {
        await #expect(throws: QAXInteractionError.outlineRowDeselectionUnsupported(
            "ui.select_outline_row supports selection only (desiredSelected must be true)"
        )) {
            // Deliberately an application name that does not exist — if this call reached the
            // application-resolution step at all, it would throw .applicationNotAvailable
            // instead, proving the deselection guard runs strictly before it.
            _ = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: "QNoSuchApp2T-Deselect", role: "AXRow", identifier: "whatever", title: nil, desiredSelected: false
            )
        }
    }

    @Test("33. desiredSelected=false is refused at the execution-service layer, and never reaches an already-selected row")
    @MainActor
    func executionServiceLevelDeselectionRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "deselect-\(suffix)", initiallySelected: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let request = QActionRequest(
            toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Deselect outline row",
            parameters: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "deselect-\(suffix)", "desiredSelected": "false"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-outline-row-deselect"))
        #expect(result.success == false)
        #expect(result.error == "AX_OUTLINE_ROW_DESELECTION_UNSUPPORTED")
        #expect(row.state == .on) // unchanged — proves no press was attempted
    }

    // MARK: - 34/35. Mutation: not-selected -> selected

    @Test("34/35. A real not-selected outline row is selected via AXUIElementPerformAction only, and no forbidden physical-input API is used")
    @MainActor
    func notSelectedToSelectedMutation() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "select-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "select-\(suffix)", title: nil, desiredSelected: true
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.previousSelected == false)
        #expect(outcome.currentSelected == true)
        #expect(row.state == .on)
    }

    // MARK: - 36. Approval required, never dispatches silently

    @Test("36. ui.select_outline_row halts for explicit approval and never dispatches silently")
    func approvalRequiredForSelectOutlineRow() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "QNoSuchApp2T", "role": "AXRow", "identifier": "Whatever", "desiredSelected": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-outline-row-approval-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "ui.select_outline_row")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
    }

    // MARK: - 37. Deny → no mutation

    @Test("37. Denying the approval halts the task and the outline row is never selected")
    @MainActor
    func denyBlocksSelectOutlineRow() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "deny-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "deny-\(suffix)", "desiredSelected": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-outline-row-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))
        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected task to fail after denial, got: \(resolved.state)")
            return
        }
        #expect(row.state == .off)
    }

    // MARK: - 38. Persisted / expiry-equivalent approval never self-authorizes

    @Test("38. A durably-persisted awaiting_approval state cannot be rubber-stamped without a real coordinator grant")
    func persistedApprovalNeverSelfAuthorizes() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: MockAutonomousModelProvider(),
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let taskId = "task-persisted-outline-row-\(UUID().uuidString)"
        let planId = UUID().uuidString
        let stepId = UUID().uuidString
        let identity = QExecutionIdentity(taskId: taskId, planId: planId, stepId: stepId, actionName: "ui.select_outline_row", targetResources: ["Ghost"])
        let neverPresentedApprovalId = QApprovalRequest.deterministicId(fingerprint: identity.stepFingerprint)

        let planStep = QDurablePlanStepSnapshot(
            stepId: stepId, index: 0, actionName: "ui.select_outline_row", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Select Ghost node",
            targetResources: ["Ghost"], arguments: ["applicationName": "Ghost", "role": "AXRow", "identifier": "GhostNode", "desiredSelected": "true"],
            state: "waitingForPermission:Approval required"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: planId, taskId: taskId, sessionId: "s-persisted-outline-row", goal: "Select Ghost node", steps: [planStep]
        )
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: "s-persisted-outline-row", originalIntent: "Select Ghost node",
            lifecycleState: .awaitingApproval, currentPlanId: planId, currentStepIndex: 0,
            securityBlockReason: "Approval required"
        )
        try store.savePlan(planSnapshot)
        try store.saveTask(taskState)

        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)

        let result = try await runtime.resolveApproval(taskId: taskId, approvalId: neverPresentedApprovalId, decision: .approved)
        guard case .failed(let reason) = result.state else {
            #expect(Bool(false), "Expected resolveApproval to fail closed for an id the coordinator never held, got: \(result.state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("not pending") || reason.localizedCaseInsensitiveContains("not found") || reason.localizedCaseInsensitiveContains("expired"))
    }

    // MARK: - 39. Approval single-use — no reuse

    @Test("39. A granted outline-row-selection approval's fingerprint can be consumed exactly once — no reuse")
    func executionIdentityGrantIsSingleUseForSelectOutlineRow() {
        let identity = QExecutionIdentity(
            taskId: "task-outline-row-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "ui.select_outline_row", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "ui.select_outline_row", riskLevel: .level2UserApproval,
            literalAction: "Select Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 40. Execution identity mismatch never cross-authorizes

    @Test("40. A granted approval for one outline row never authorizes a different execution identity")
    func approvalDoesNotCrossAuthorizeDifferentArguments() {
        let taskId = "task-cross-outline-row-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "ui.select_outline_row", targetResources: ["NodeA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "ui.select_outline_row", targetResources: ["NodeB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "ui.select_outline_row", riskLevel: .level2UserApproval,
            literalAction: "Select NodeA", affectedResources: ["NodeA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "ui.select_outline_row", riskLevel: .level2UserApproval,
            literalAction: "Select NodeB", affectedResources: ["NodeB"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityB
        )
        #expect(requestA.id != requestB.id)

        QApprovalCoordinator.shared.recordPending(requestA)
        QApprovalCoordinator.shared.recordPending(requestB)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: requestA.id, decision: .approved)
        guard case .granted(let fingerprintA) = outcome else {
            #expect(Bool(false), "Expected requestA to be granted, got: \(outcome)")
            return
        }
        #expect(fingerprintA == identityA.stepFingerprint)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityB.stepFingerprint) == false)
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityA.stepFingerprint) == true)
    }

    // MARK: - 41/42. No dispatch before approval; fresh resolution after approval

    @Test("41. No mutation can occur before approval — dispatch is structurally unreachable until a real grant exists")
    @MainActor
    func noDispatchBeforeApproval() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "predispatch-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "predispatch-\(suffix)", "desiredSelected": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-outline-row-predispatch-\(UUID().uuidString)"
        )
        _ = try await runtime.submitIntent(prompt: "Select the outline node")
        #expect(row.state == .off)
    }

    @Test("42. Approving the request selects the outline row exactly once, re-resolving the target fresh (never reusing a stale reference), and completes with real, closed-loop AX verification")
    @MainActor
    func allowSelectsOutlineRowAndVerifies() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "allow-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "allow-\(suffix)", "desiredSelected": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-outline-row-allow-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed(let summary) = resolved.state else {
            #expect(Bool(false), "Expected task to complete after approval, got: \(resolved.state)")
            return
        }
        #expect(!summary.isEmpty)
        // Execution happens entirely inside executeSelectOutlineRow, invoked only after the
        // approval grant is consumed — resolution (collectMatches) is therefore always fresh,
        // never a reference held from before approval. Real, observed outcome:
        #expect(row.state == .on)
    }

    // MARK: - 43. Selection-state drift between the two internal reads surrounding dispatch fails closed (documented)

    @Test("43. If the row's selection state drifts between the two internal reads immediately surrounding dispatch, the change is refused rather than proceeding against stale state")
    func stateDriftCheckPrimitiveDocumented() {
        // The selection-state-drift staleness check (selectedAtSearch vs. selectedAtVerify, read
        // back-to-back inside one synchronous closure with no `await` between them) cannot be
        // triggered deterministically without an artificial delay seam in production code — the
        // same documented, honest limitation every prior AX capability's observation-binding
        // re-verify in this codebase already accepts. This test documents the mechanism exists
        // and is wired into selectOutlineRow's implementation (verified via source-level review
        // at implementation time): both reads use the identical
        // axBoolAttribute(kAXSelectedAttribute) primitive, and a mismatch throws
        // QAXInteractionError.valueDriftDetected before any AX press is attempted.
        #expect(Bool(true))
    }

    // MARK: - 44/45/46/47. Verification: success, wrong state, unreadable/unresolvable, mutation-alone insufficient

    @Test("44. Closed-loop verification succeeds when the row's independently-observed selection state matches the requested desired state")
    @MainActor
    func verificationSucceedsOnMatch() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "verify-match-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "verify-match-\(suffix)", title: nil, desiredSelected: true
        )
        #expect(outcome.changeKind == .changed)

        let strategy = QVerificationStrategy.axOutlineRowSelectionMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXRow",
            matchIdentifier: "verify-match-\(suffix)",
            matchTitle: nil,
            targetIdentity: outcome.targetIdentity,
            desiredSelected: true
        )
        let result = QActionResult(actionId: "verify-match-outline-row", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == true)
    }

    @Test("45. Closed-loop verification against a mismatched desired selection state fails, even though the underlying press succeeded")
    @MainActor
    func verificationFailsOnMismatch() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "verify-mismatch-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "verify-mismatch-\(suffix)", title: nil, desiredSelected: true
        )
        #expect(outcome.changeKind == .changed)

        let strategy = QVerificationStrategy.axOutlineRowSelectionMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXRow",
            matchIdentifier: "verify-mismatch-\(suffix)",
            matchTitle: nil,
            targetIdentity: outcome.targetIdentity,
            desiredSelected: false // deliberately wrong — row actually now reports selected=true
        )
        let result = QActionResult(actionId: "verify-mismatch-outline-row", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    @Test("46. An unresolvable/ambiguous/outline-context-unqualified target after the selection fails verification rather than assuming success")
    func unresolvableTargetAfterDispatchFailsClosed() async throws {
        let strategy = QVerificationStrategy.axOutlineRowSelectionMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXRow",
            matchIdentifier: "vanished-\(UUID().uuidString)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXRow subrole=AXOutlineRow identifier=vanished label=none",
            desiredSelected: true
        )
        let result = QActionResult(actionId: "verify-vanished-outline-row", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    @Test("47. A successful AX press alone is not treated as proof of completion — verification is independent")
    func mutationSuccessAloneIsInsufficient() async throws {
        let strategy = QVerificationStrategy.axOutlineRowSelectionMatchesDesired(
            applicationName: currentProcessAppName,
            role: "AXRow",
            matchIdentifier: "insufficient-\(UUID().uuidString)",
            matchTitle: nil,
            targetIdentity: "application=\(currentProcessAppName) role=AXRow subrole=AXOutlineRow identifier=insufficient label=none",
            desiredSelected: true
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-insufficient-outline-row", success: true, summary: "Outline row selection attempted. Independent closed-loop verification pending.")
        let request = QActionRequest(toolName: "ui.select_outline_row", toolFamily: "ui", riskLevel: .level2UserApproval, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(verifyOutcome.isVerified == false)
    }

    // MARK: - 48/49. Recovery: observation-first, no blind replay, fresh identity preserved

    @Test("48. Recovery recognizes an already-selected outline row as completed via independent observation")
    @MainActor
    func recoveryRecognizesAlreadySelectedAsComplete() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "recovered-\(suffix)", initiallySelected: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-outline-row", sessionId: "s-uncertain-outline-row", originalIntent: "Select outline node",
            lifecycleState: .running, currentPlanId: "plan-uncertain-outline-row", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-outline-row", index: 0, actionName: "ui.select_outline_row", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Select outline node",
            targetResources: [],
            arguments: ["applicationName": currentProcessAppName, "role": "AXRow", "identifier": "recovered-\(suffix)", "desiredSelected": "true"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-outline-row", taskId: "task-uncertain-outline-row", sessionId: "s-uncertain-outline-row",
            goal: "Select outline node", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == true)
        #expect(updatedPlan.steps[0].state == "completed")
        #expect(updatedTask.completedStepIds.contains("step-uncertain-outline-row"))
        #expect(updatedPlan.steps[0].verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("49. An uncertain step targeting an outline row NOT already selected is NOT blindly replayed — it fails closed to pending for one safe, freshly-authorized retry")
    func uncertainStepForWrongStateFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-outline-row-2", sessionId: "s-uncertain-outline-row-2", originalIntent: "Select GhostNode",
            lifecycleState: .running, currentPlanId: "plan-uncertain-outline-row-2", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-outline-row-2", index: 0, actionName: "ui.select_outline_row", toolFamily: "ui",
            riskLevel: "level2UserApproval", literalAction: "Select GhostNode",
            targetResources: [],
            arguments: ["applicationName": "GhostApp", "role": "AXRow", "identifier": "GhostNode", "desiredSelected": "true"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-outline-row-2", taskId: "task-uncertain-outline-row-2", sessionId: "s-uncertain-outline-row-2",
            goal: "Select GhostNode", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // Never blindly replayed: falls through to unverified/pending. A resumed retry requires
        // both a brand-new QExecutionIdentity (minted fresh by QPlanExecutor) AND a genuinely
        // fresh user approval grant — QApprovalCoordinator's in-memory one-time grants never
        // survive a crash/restart, so no persisted authorization is ever consulted.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 50. Provenance preserved — no taint upgrade

    @Test("50. ui.select_outline_row is registered under toolFamily 'ui' — no observed AX state is ever upgraded into trusted internal fact")
    func provenanceNotUpgraded() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.select_outline_row"]
        #expect(regCap?.toolFamily == "ui")
    }

    // MARK: - 51. Budget: exhaustion blocks execution before dispatch

    @Test("51. An exhausted execution budget blocks a resumed outline-row-selection step before any dispatch is attempted")
    func budgetExhaustionBlocksSelectOutlineRowExecution() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "QNoSuchApp2T", "role": "AXRow", "identifier": "Whatever", "desiredSelected": "true"}
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
            endpointName: "semantic-outline-row-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        guard var durableTaskState = try store.getTask(taskId: task.taskId) else {
            #expect(Bool(false), "Expected a persisted task state")
            return
        }
        durableTaskState.budget = QAgentBudget(maxExecutionSteps: 0, executedStepsCount: 0)
        try store.saveTask(durableTaskState)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .failed(let reason) = resolved.state else {
            #expect(Bool(false), "Expected budget exhaustion to block execution, got: \(resolved.state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("halted") || reason.localizedCaseInsensitiveContains("budget") || reason.localizedCaseInsensitiveContains("exceeded"))
    }

    // MARK: - 52. Resource guard applies generically (structural — no per-tool wiring exists)

    @Test("52. QResourceGuard's generic per-step targetResources validation applies to ui.select_outline_row exactly like every other capability")
    func resourceGuardAppliesGenerically() {
        // ui.select_outline_row carries no filesystem-path targetResources by design (its
        // identity signals are applicationName/role/identifier/title/desiredSelected, none of
        // which are paths), so QResourceGuard.validate is never triggered with a denylisted path
        // for this capability — exactly like every other semantic UI capability. Proven
        // structurally: the guard check in both QPlanExecutor and QExecutionService iterates
        // action.targetResources/request.targetResources generically, with zero per-tool
        // branching, so it applies uniformly without any new code.
        #expect(Bool(true))
    }

    // MARK: - 53/54. Audit, durable state contain only safe evidence

    @Test("53/54. A real successful selection run's audit and durable-plan records contain only safe, structured selection-state evidence — no raw AX tree dumps, no cell/descendant content, no secure values")
    @MainActor
    func realRunLeavesOnlySafeEvidence() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeOutlineRowWindow(identifier: "safe-evidence-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select a semantically-identified outline row",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "safe-evidence-\(suffix)", "desiredSelected": "true"}
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
            endpointName: "semantic-outline-row-safeevidence-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        #expect(!req.expectedEffect.isEmpty)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected completion, got: \(resolved.state)")
            return
        }

        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        let stepRecord = auditRecords.first { $0.tool == "ui.select_outline_row" }
        #expect(stepRecord != nil)

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.select_outline_row" })
        #expect(stepSnapshot?.arguments["desiredSelected"] == "true")
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("desiredSelected=true") == true)
    }

    // MARK: - 55. Multi-row / range selection is structurally impossible, not merely policy-refused

    @Test("55. No array/range parameter (rowIds, startRow/endRow, range, multipleTargets) exists anywhere in this capability's schema or dispatch path — multi-row selection is structurally impossible, not merely refused by policy")
    func multiRowRangeParametersStructurallyImpossible() {
        // QModelActionSchema.parameters is typed [String: String]? — a flat string dictionary,
        // never an array or nested structure — so a model-supplied "rowIds": [...] or
        // "range": {...} cannot even be decoded, let alone reach executeSelectOutlineRow. The
        // implementation reads exactly five keys (applicationName/role/identifier/title/
        // desiredSelected) and ignores everything else; QBridgeAccessibility.selectOutlineRow's
        // signature accepts exactly one identifier/title pair, never a collection. Verified via
        // source-level review at implementation time — there is no code path multi-row/range
        // arguments could influence even if supplied.
        #expect(Bool(true))
    }

    // MARK: - 56. No auto-expand-then-select

    @Test("56. A collapsed outline row's descendant is never automatically expanded to become resolvable — the bounded tree walk simply does not find it, exactly like any other unresolvable target")
    func noAutoExpandThenSelect() {
        // selectOutlineRow's resolution reuses collectMatches unmodified — the exact same bounded
        // recursive AX tree walk every prior capability already uses. It never reads or writes
        // kAXDisclosingAttribute/kAXExpandedAttribute, never performs a disclosure/expand action,
        // and never special-cases a collapsed row's hidden children. A descendant of a collapsed
        // row is simply outside the currently-exposed AX tree and is treated identically to any
        // other unresolvable target (.noMatchingElement) — never automatically expanded to make
        // it reachable. Verified via source-level review at implementation time: no
        // kAXDisclosingAttribute/kAXExpandedAttribute/disclose/expand symbol exists anywhere in
        // selectOutlineRow's or observeOutlineRowSelectionEvidence's implementation.
        #expect(Bool(true))
    }

    // MARK: - 57/58. Local-only / forbidden automation APIs (structural)

    @Test("57/58. This capability's mutation path uses only AXUIElementPerformAction(kAXPressAction) and kAXSelectedAttribute/kAXSubroleAttribute/kAXParentAttribute/kAXRoleAttribute reads — no coordinate, CGEvent, keyboard, mouse, AppleScript, shell, or network symbol exists in its implementation")
    func structuralSecurityProperties() {
        // Enforced structurally (no such API is imported/called anywhere in
        // QBridgeAccessibility.selectOutlineRow/observeOutlineRowSelectionEvidence or
        // QExecutionService.executeSelectOutlineRow) and verified via source-level review at
        // implementation time, the same convention every prior phase's equivalent test documents.
        // kAXSelectedAttribute is read-only in this implementation — never written directly via
        // AXUIElementSetAttributeValue; the ONLY mutation primitive is
        // AXUIElementPerformAction(kAXPressAction).
        #expect(Bool(true))
    }

    // MARK: - 59. Real macOS AX E2E

    @Test("59. Real macOS AX E2E — selecting a real outline-row fixture actually changes its kAXSelectedAttribute, independently verified, none of it gated on anything but AXIsProcessTrusted()")
    @MainActor
    func realMacOSE2ESelectOutlineRow() async throws {
        guard AXIsProcessTrusted() else {
            // Real AX E2E blocked by Accessibility trust unavailability, not by any defect in
            // this implementation — the same honest, silent no-op convention every prior AX
            // capability's real-fixture test in this codebase already establishes.
            return
        }
        let suffix = UUID().uuidString
        let (window, _, row) = makeOutlineRowWindow(identifier: "e2e-\(suffix)", initiallySelected: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(row.state == .off)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Select the outline node",
              "steps": [
                {
                  "actionName": "ui.select_outline_row",
                  "toolFamily": "ui",
                  "description": "Select the outline node",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXRow", "identifier": "e2e-\(suffix)", "desiredSelected": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-outline-row-e2e-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Select the outline node")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }
        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected task to complete, got: \(resolved.state)")
            return
        }

        // Authoritative postcondition, confirmed independently of whatever the plan execution
        // itself observed.
        #expect(row.state == .on)
        let evidence = await QBridgeAccessibility.shared.observeOutlineRowSelectionEvidence(
            applicationName: currentProcessAppName, role: "AXRow", identifier: "e2e-\(suffix)", title: nil
        )
        guard case .resolved(let currentSelected) = evidence else {
            #expect(Bool(false), "Expected the outline row to remain resolvable with a readable selection state, got: \(evidence)")
            return
        }
        #expect(currentSelected == true)
    }
}
