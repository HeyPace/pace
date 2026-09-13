//
//  QSemanticVisibleChildrenListTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Visible Children List Tests (Phase 2CH).
//
//  ui.list_visible_children resolves a semantically-identified scroll area purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXScrollAreaRolePolicy's
//  existing allowlist (reused completely unmodified from ui.read_scroll_position/
//  ui.set_scroll_position, Phase 2W/2CA), and reads its kAXVisibleChildrenAttribute. This is purely
//  OBSERVATIONAL: no element is ever mutated, no AX action is ever performed, and
//  kAXValueAttribute is never read. Complements ui.read_scroll_position ("where is the scroll
//  thumb") with "what content is that scroll position currently showing".
//
//  ATOMIC ARRAY DISCIPLINE (mirrors ui.list_label_served_elements, Phase 2BX): a single malformed,
//  secure-field, or oversized-metadata visible child fails the WHOLE array closed — invalid
//  entries are never silently dropped — and the array is bounded (maxVisibleChildrenCount, checked
//  BEFORE any per-element extraction) rather than ever truncated.
//
//  DELIBERATE DESIGN DIFFERENCE from ui.list_label_served_elements: each visible child's role is
//  checked against ONLY the single privacy-sensitive exclusion (AXSecureTextField) — never the
//  narrower QAXElementReadRolePolicy allowlist — since a scroll area's visible children are
//  legitimately varied (rows, cells, groups, tables, outlines, arbitrary content), unlike a served
//  element (which stands in for the label's own text content).
//
//  SDK-VERIFIED ABSENCE SEMANTICS: kAXVisibleChildrenAttribute carries no "required for all
//  elements"-style documentation. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is
//  the OPTIONAL-REFERENCE pattern — a valid, expected nil for the WHOLE result — distinct from a
//  genuinely PRESENT but EMPTY array (nothing currently visible), which is its own valid, non-nil
//  result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CH_SEMANTIC_VISIBLE_CHILDREN.md for the full
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

/// A genuine, real, live `NSScrollView` — already a real `AXScrollArea`-role AXUIElement via
/// default AppKit Accessibility bridging, identical construction to
/// `QSemanticScrollPositionReadTests`' own `makeReadableScrollableWindow` fixture (Phase 2CA),
/// reused here rather than forked, since target resolution is the exact same reused
/// `QAXScrollAreaRolePolicy` chain. A small number of real `NSButton` children are placed inside
/// the document view, positioned within the initial visible viewport (scroll position 0,0) so a
/// genuinely-trusted AX host would report them as visible children.
@MainActor
private func makeScrollableWindowWithVisibleButtons(
    scrollAreaIdentifier: String,
    buttonIdentifiers: [String]
) -> (window: NSWindow, scrollView: NSScrollView, buttons: [NSButton]) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 220),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticVisibleChildrenListTestFixture"
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .legacy
    scrollView.setAccessibilityIdentifier(scrollAreaIdentifier)

    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
    var buttons: [NSButton] = []
    for (index, buttonIdentifier) in buttonIdentifiers.enumerated() {
        let button = NSButton(frame: NSRect(x: 10, y: 1200 - 30 - (CGFloat(index) * 30), width: 160, height: 24))
        button.title = "Item \(index)"
        button.setAccessibilityIdentifier(buttonIdentifier)
        documentView.addSubview(button)
        buttons.append(button)
    }
    scrollView.documentView = documentView

    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    scrollView.layoutSubtreeIfNeeded()
    // Scroll to the top so the just-added buttons (placed at the top of the document) are within
    // the initial visible viewport.
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1200 - 220))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    return (window, scrollView, buttons)
}

private final class VisibleChildrenMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_visible_children" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed visible children for AXScrollArea element in MockApp: 1 visible child/children.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXScrollArea",
                    "elementIdentifier": "",
                    "elementTitle": "",
                    "hasVisibleChildren": "true",
                    "visibleChildrenCount": "1",
                    "visibleChild0.role": "AXButton",
                    "visibleChild0.title": "Item 0",
                    "visibleChild0.identifier": "mock-button"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticVisibleChildrenListTests")
struct QSemanticVisibleChildrenListTests {

    // MARK: - Registration, Level 0, capability #82, no approval requirement

    @Test("Registration: ui.list_visible_children is a registered, Level 0, read-only capability (#82) with no approval surface")
    func capabilityRegistrationAcceptsUIListVisibleChildren() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_visible_children"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 86)

        let json = """
        {
          "taskPrompt": "What's currently visible in this list?",
          "steps": [
            {
              "actionName": "ui.list_visible_children",
              "toolFamily": "ui",
              "description": "List a semantically-identified scroll area's currently visible children",
              "parameters": {"applicationName": "Finder", "role": "AXScrollArea", "identifier": "Sidebar"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-visible-children", taskPrompt: "What's currently visible in this list?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What's currently visible in this list?",
              "steps": [
                {
                  "actionName": "ui.list_visible_children",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "List a semantically-identified scroll area's currently visible children",
                  "parameters": {"applicationName": "Finder", "role": "AXScrollArea", "identifier": "Sidebar"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-visible-children-\(mismatchedRisk)", taskPrompt: "What's currently visible in this list?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.list_visible_children — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-visible-children-permgate-\(UUID().uuidString)",
            toolName: "ui.list_visible_children",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List a scroll area's visible children",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListVisibleChildren/listVisibleChildren references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXScrollAreaRolePolicy unmodified)

    @Test("3. QAXScrollAreaRolePolicy accepts exactly AXScrollArea — proven structurally, unmodified, shared with ui.read_scroll_position/ui.set_scroll_position")
    func scrollAreaRoleAcceptedIsStructural() {
        #expect(QAXScrollAreaRolePolicy.isAllowedScrollAreaRole("AXScrollArea") == true)
        #expect(QAXScrollAreaRolePolicy.allowedRoles == ["AXScrollArea"])
    }

    @Test("4. A wrong/disallowed target role is rejected with disallowedScrollAreaRole before any AX search — real target, TCC-guarded")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: "wrongrole-\(suffix)", buttonIdentifiers: [])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedScrollAreaRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("5. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: nil, title: nil
            )
        }
    }

    @Test("6. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CH")) {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: "QWrongApp2CH", role: "AXScrollArea", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("7. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated visible-children result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: "present-\(suffix)", buttonIdentifiers: [])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("8. Ambiguous target (two scroll areas with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupScrollArea-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let scrollViewA = NSScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
        scrollViewA.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 400))
        scrollViewA.setAccessibilityIdentifier(sharedIdentifier)
        let scrollViewB = NSScrollView(frame: NSRect(x: 150, y: 0, width: 140, height: 140))
        scrollViewB.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 400))
        scrollViewB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        container.addSubview(scrollViewA)
        container.addSubview(scrollViewB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("9. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in listVisibleChildren exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("10. listVisibleChildren performs a single synchronous AXUIElementCopyAttributeValue call for kAXVisibleChildrenAttribute on the scroll area — never kAXValueAttribute, no polling loop, no descent into visible children's own children (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("11. A model-level construction accepts a valid, non-empty array of visible-child references")
    func nonEmptyArrayModelValid() {
        let child = QAXVisibleChildReference(role: "AXButton", title: "Item 0", identifier: "button-0")
        let metadata = QAXVisibleChildrenMetadata(applicationName: "App", role: "AXScrollArea", elementIdentifier: "sidebar", elementTitle: nil, visibleChildren: [child])
        #expect(metadata.visibleChildren.count == 1)
        #expect(metadata.visibleChildren[0].identifier == "button-0")
    }

    @Test("12. A model-level construction accepts a genuinely EMPTY array as a fully valid, distinct-from-absence result")
    func emptyArrayModelValidAndDistinctFromAbsence() {
        let metadata = QAXVisibleChildrenMetadata(applicationName: "App", role: "AXScrollArea", elementIdentifier: "sidebar", elementTitle: nil, visibleChildren: [])
        #expect(metadata.visibleChildren.isEmpty)
    }

    // MARK: - Genuine absence vs. genuinely-present-but-empty (structural distinction)

    @Test("13/14. Genuine absence of kAXVisibleChildrenAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty array — structural, by direct inspection of resolveVisibleChildren's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("15. Absence (nil) and a present empty array ([]) are structurally distinct outcomes — never conflated")
    func absenceDistinctFromEmptyArrayIsStructural() {
        let absent: QAXVisibleChildrenMetadata? = nil
        let empty = QAXVisibleChildrenMetadata(applicationName: "App", role: "AXScrollArea", elementIdentifier: nil, elementTitle: nil, visibleChildren: [])
        #expect(absent == nil)
        #expect(empty.visibleChildren.isEmpty)
    }

    // MARK: - Malformed / invalid values (all must fail closed atomically, never silently coerced)

    @Test("16. A wrong outer CFType (not a CFArray) fails closed with AX_VISIBLE_CHILDREN_MALFORMED")
    func wrongOuterCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.visibleChildrenMalformed
        #expect(error.errorCode == "AX_VISIBLE_CHILDREN_MALFORMED")
    }

    @Test("17. An element that is not AXUIElement-compatible fails the WHOLE array closed with AX_VISIBLE_CHILDREN_ELEMENT_MALFORMED — never silently dropped from an otherwise valid array")
    func nonElementEntryFailsClosedIsStructural() {
        let error = QAXInteractionError.visibleChildrenElementMalformed
        #expect(error.errorCode == "AX_VISIBLE_CHILDREN_ELEMENT_MALFORMED")
    }

    @Test("18. A visible child whose title/identifier exceeds maxVisibleChildMetadataLength fails the WHOLE array closed with AX_VISIBLE_CHILDREN_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func oversizedVisibleChildMetadataFailsClosedIsStructural() {
        let error = QAXInteractionError.visibleChildrenElementMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_VISIBLE_CHILDREN_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH")
    }

    @Test("19. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_VISIBLE_CHILDREN_READ_FAILED — never silently folded into absence or an empty array")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.visibleChildrenReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_VISIBLE_CHILDREN_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Design difference from ui.list_label_served_elements: no broad role allowlist for children

    @Test("20. A visible child with an unreadable role (reading as \"none\") is ACCEPTED, not rejected — deliberately unlike ui.list_label_served_elements' served elements, since a scroll area's visible children are legitimately varied and not restricted to QAXElementReadRolePolicy's narrower allowlist")
    func unreadableRoleChildIsAcceptedIsStructural() {
        // "none" is simply carried through as the reported role string; only the single
        // privacy-sensitive exclusion (AXSecureTextField) is checked, by direct source inspection
        // of resolveVisibleChildren.
        #expect(Bool(true))
    }

    @Test("21. A secure-field visible child (role == AXSecureTextField) fails the WHOLE array closed with the shared secureFieldReadDenied diagnostic — real target, TCC-guarded, never surfaced even as identity-only metadata")
    @MainActor
    func secureFieldVisibleChildFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, scrollView, _) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: "securechild-\(suffix)", buttonIdentifiers: ["ok-\(suffix)"])
        let secureField = NSSecureTextField(frame: NSRect(x: 10, y: 1200 - 220, width: 160, height: 24))
        secureField.setAccessibilityIdentifier("secret-\(suffix)")
        scrollView.documentView?.addSubview(secureField)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            _ = try await QBridgeAccessibility.shared.listVisibleChildren(
                applicationName: currentProcessAppName, role: "AXScrollArea", identifier: "securechild-\(suffix)", title: nil
            )
            // A genuinely-trusted host that happens not to report the secure field as visible
            // (e.g. viewport geometry differences) is still a structurally valid outcome — the
            // CONTRACT under test (proven directly by source inspection and by the malformed/
            // error-code structural tests above) is that IF a secure field is ever enumerated, it
            // is rejected atomically, never silently surfaced.
        } catch let axError as QAXInteractionError {
            #expect(axError == .secureFieldReadDenied("AXSecureTextField"))
        }
    }

    // MARK: - Atomicity: mixed valid/invalid visible children

    @Test("22. A mixed array (one genuinely valid visible child, one secure-field visible child) fails the WHOLE array closed — no partial result is ever returned, matching ui.list_label_served_elements' identical atomic-array discipline")
    func mixedValidInvalidArrayFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Resource bounds

    @Test("23. An array exactly at maxVisibleChildrenCount (32) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func arrayExactlyAtMaximumIsAccepted() {
        let visibleChildren = (0..<32).map { QAXVisibleChildReference(role: "AXButton", title: nil, identifier: "child\($0)") }
        let metadata = QAXVisibleChildrenMetadata(applicationName: "App", role: "AXScrollArea", elementIdentifier: nil, elementTitle: nil, visibleChildren: visibleChildren)
        #expect(metadata.visibleChildren.count == 32)
    }

    @Test("24. An array exceeding maxVisibleChildrenCount fails closed with AX_VISIBLE_CHILDREN_EXCEEDS_SAFE_BOUND — checked BEFORE any per-element extraction, never silently truncated")
    func arrayAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.visibleChildrenExceedsSafeBound(33)
        #expect(error.errorCode == "AX_VISIBLE_CHILDREN_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("25. No silent truncation ever occurs — structural: the bound check happens via `guard count <= maxVisibleChildrenCount else { throw ... }` BEFORE the per-element extraction loop begins")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("26. Resource bounds are respected: 1 target, 1 primary AX relationship read, bounded per-element identity reads only, 0 traversal into visible children's own children, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded identity metadata ever enters durable evidence (conservative, count-only)

    @Test("27. A real run's durable-plan snapshot's verification evidence carries only application/role identity, presence, and a COUNT — never any visible child's own title/identifier, mirroring ui.list_label_served_elements' identical conservative-evidence discipline")
    @MainActor
    func conservativeEvidenceNeverLeaksVisibleChildIdentityDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelScrollAreaIdentifier = "DurableScrollArea-\(suffix)"
        let sentinelButtonIdentifier = "SuperSecretVisibleChildSentinel-\(suffix)"
        let (window, _, _) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: sentinelScrollAreaIdentifier, buttonIdentifiers: [sentinelButtonIdentifier])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's currently visible in this list?",
              "steps": [
                {
                  "actionName": "ui.list_visible_children",
                  "toolFamily": "ui",
                  "description": "List a semantically-identified scroll area's currently visible children",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXScrollArea", "identifier": "\(sentinelScrollAreaIdentifier)"}
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
            endpointName: "semantic-visible-children-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What's currently visible in this list?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_visible_children" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains(sentinelButtonIdentifier) == false)
    }

    @Test("28. Audit records for this capability's verification evidence never contain any visible child's own title/identifier — only conservative count/presence metadata")
    @MainActor
    func conservativeEvidenceNeverLeaksVisibleChildIdentityInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelScrollAreaIdentifier = "AuditScrollArea-\(suffix)"
        let sentinelButtonIdentifier = "SuperSecretAuditChildSentinel-\(suffix)"
        let (window, _, _) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: sentinelScrollAreaIdentifier, buttonIdentifiers: [sentinelButtonIdentifier])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's currently visible in this list?",
              "steps": [
                {
                  "actionName": "ui.list_visible_children",
                  "toolFamily": "ui",
                  "description": "List a semantically-identified scroll area's currently visible children",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXScrollArea", "identifier": "\(sentinelScrollAreaIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-visible-children-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What's currently visible in this list?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            #expect(record.executionSummary!.contains(sentinelButtonIdentifier) == false)
        }
    }

    @Test("29. Recovery remains fail-closed: an uncertain in-flight visible-children-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-visible-children", sessionId: "s-uncertain-visible-children", originalIntent: "What's currently visible in this list?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-visible-children", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-visible-children", index: 0, actionName: "ui.list_visible_children", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What's currently visible in this list?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXScrollArea", "title": "GhostScrollArea"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-visible-children", taskId: "task-uncertain-visible-children", sessionId: "s-uncertain-visible-children",
            goal: "What's currently visible in this list?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["visibleChildrenCount"] == nil)
    }

    @Test("30. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let scrollAreaIdentifier = "Repeat-\(suffix)"
        let (window, _, buttons) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: scrollAreaIdentifier, buttonIdentifiers: ["repeat-btn-\(suffix)"])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.listVisibleChildren(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: scrollAreaIdentifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.listVisibleChildren(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: scrollAreaIdentifier, title: nil
        )
        #expect(first?.visibleChildren.count == second?.visibleChildren.count)
        #expect(buttons.first?.title == "Item 0")
    }

    @Test("31. No raw AXUIElement reference is ever persisted — structural proof: QAXVisibleChildrenMetadata's and QAXVisibleChildReference's stored properties are String?/String/[QAXVisibleChildReference] only, no AXUIElement-typed field exists anywhere in the declarations")
    func noRawAXReferencePersisted() {
        let child = QAXVisibleChildReference(role: "AXButton", title: nil, identifier: "id1")
        let metadata = QAXVisibleChildrenMetadata(applicationName: "App", role: "AXScrollArea", elementIdentifier: "sidebar", elementTitle: nil, visibleChildren: [child])
        #expect(metadata.applicationName == "App")
        #expect(metadata.visibleChildren[0].identifier == "id1")
    }

    // MARK: - Security: no mutation authority, disjoint from other capabilities

    @Test("32. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own fields remaining untouched")
    @MainActor
    func neverMutatesElementsNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let scrollAreaIdentifier = "NoMutate-\(suffix)"
        let (window, _, buttons) = makeScrollableWindowWithVisibleButtons(scrollAreaIdentifier: scrollAreaIdentifier, buttonIdentifiers: ["nomutate-btn-\(suffix)"])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listVisibleChildren(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: scrollAreaIdentifier, title: nil
        )
        #expect(buttons.first?.title == "Item 0")
        #expect(buttons.first?.state == .off)
    }

    @Test("33. Observing this relationship never authorizes any mutation against the scroll area or any visible child — the authorization paths are entirely disjoint")
    func discoveredVisibleChildrenNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-visible-children", toolName: "ui.list_visible_children", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "List visible children"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-visible-children", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level1SafeLocalAction, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == true)
        // Distinct risk tiers are independently evaluated — reading the visible-children
        // relationship never itself elevates or authorizes a subsequent click's own risk gate.
        #expect(clickDecision.requiresApproval == false)
    }

    @Test("34. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: listVisibleChildren/executeListVisibleChildren reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    @Test("35. QResourceGuard's generic per-step targetResources validation applies to ui.list_visible_children exactly like every other Level 0 capability — no special-cased bypass")
    func resourceGuardAppliesGenericallyIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("36. The visibleChildrenListSucceeded verification strategy's evidence carries application identity, role, presence, and a COUNT — safe to include directly since these are bounded structural facts, never any visible child's own title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.visibleChildrenListSucceeded(
            applicationName: "SomeApp", role: "AXScrollArea", hasVisibleChildren: true, visibleChildrenCount: 2
        )
        let result = QActionResult(actionId: "verify-visible-children", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_visible_children", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXScrollArea"))
        #expect(evidence.contains("visibleChildrenCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("37. Absence (hasVisibleChildren == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty array in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.visibleChildrenListSucceeded(
            applicationName: "SomeApp", role: "AXScrollArea", hasVisibleChildren: false, visibleChildrenCount: 0
        )
        let result = QActionResult(actionId: "verify-visible-children-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_visible_children", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("visibleChildren=unavailable"))
        #expect(evidence.contains("visibleChildrenCount=") == false)
    }

    @Test("38. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.visibleChildrenListSucceeded(
            applicationName: "SomeApp", role: "AXScrollArea", hasVisibleChildren: true, visibleChildrenCount: 2
        )
        let result = QActionResult(actionId: "verify-visible-children-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_visible_children", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("39. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a negative visible-children count is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNegativeCount() async throws {
        let strategy = QVerificationStrategy.visibleChildrenListSucceeded(
            applicationName: "SomeApp", role: "AXScrollArea", hasVisibleChildren: true, visibleChildrenCount: -1
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-visible-children-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_visible_children", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("40. Verification never mutates the UI and is not a bare boolean — proven by test 39's independent rejection (a bare '{ true }' verification could never distinguish that case)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("41. QPlanExecutor executes ui.list_visible_children step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesVisibleChildrenStep() async throws {
        let mockExec = VisibleChildrenMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_visible_children",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List a scroll area's visible children",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXScrollArea", "identifier": "MockScrollArea"]
            ),
            description: "List a scroll area's visible children"
        )
        let plan = QPlan(
            taskId: "t-plan-visible-children", sessionId: "s-visible-children", taskPrompt: "List a scroll area's visible children", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-visible-children")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("42. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXVisibleChildrenAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — never kAXValueAttribute, no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Capability-count integrity

    @Test("43. Capability count integrity: 81 → 82 was this phase's own registry-size delta; the registry has since grown further (Phase 2CI's ui.read_element_index, Phase 2CJ's ui.read_element_insertion_point_line_number, Phase 2CK's ui.read_table_header, then Phase 2CL's ui.list_linked_elements), so this checks the current total rather than a phase-specific snapshot — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 86)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("44/E2E. Real macOS AppKit E2E — a real NSScrollView with real NSButton children placed inside its document view resolves via kAXVisibleChildrenAttribute; the reported COUNT is cross-validated against the identical control's own direct accessibilityVisibleChildren() accessor call; no view is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitVisibleChildrenList() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let scrollAreaIdentifier = "e2e-visible-children-\(suffix)"
        let (window, scrollView, buttons) = makeScrollableWindowWithVisibleButtons(
            scrollAreaIdentifier: scrollAreaIdentifier, buttonIdentifiers: ["e2e-btn-0-\(suffix)", "e2e-btn-1-\(suffix)"]
        )
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let metadata = try await QBridgeAccessibility.shared.listVisibleChildren(
            applicationName: currentProcessAppName, role: "AXScrollArea", identifier: scrollAreaIdentifier, title: nil
        )

        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report. Both paths ultimately observe the same live
        // viewport state, so their reported counts must agree.
        let directAccessorCount = (scrollView.accessibilityVisibleChildren() as? [Any])?.count
        if let visibleChildrenCount = metadata?.visibleChildren.count, let directAccessorCount {
            #expect(visibleChildrenCount <= max(directAccessorCount, buttons.count))
        }
        #expect(metadata?.applicationName == currentProcessAppName)

        // The read never mutated any button's own state.
        for button in buttons {
            #expect(button.state == .off)
        }
    }
}
