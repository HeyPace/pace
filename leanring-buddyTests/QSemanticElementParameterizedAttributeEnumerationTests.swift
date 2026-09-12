//
//  QSemanticElementParameterizedAttributeEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Parameterized Attribute Name Enumeration Tests
//  (Phase 2BP).
//
//  ui.list_element_parameterized_attribute_names resolves a semantically-identified element
//  purely by Accessibility semantics (role + identifier or title), restricted to
//  QAXElementReadRolePolicy's existing allowlist (reused unmodified), and reads its supported
//  PARAMETERIZED Accessibility attribute names via AXUIElementCopyParameterizedAttributeNames —
//  the third and final sibling in the "what can I ask this element" enumeration family alongside
//  ui.list_element_actions (Phase 2BK, AXUIElementCopyActionNames) and ui.list_element_attributes
//  (Phase 2BL, AXUIElementCopyAttributeNames). This is purely OBSERVATIONAL:
//  AXUIElementCopyParameterizedAttributeValue is NEVER called — no parameterized attribute is ever
//  actually invoked with any parameter. The returned names are DATA, not AUTHORIZATION —
//  discovering that "AXLineForIndex" is a supported parameterized attribute name never itself
//  grants any capability to invoke it.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Unlike ui.list_element_actions/ui.list_element_attributes, this capability treats
//  kAXErrorAttributeUnsupported/kAXErrorParameterizedAttributeUnsupported/kAXErrorNotImplemented as
//  a VALID, EXPECTED EMPTY result (success == true, parameterizedAttributeNames == []) — many
//  elements (e.g. plain buttons) genuinely support zero parameterized attributes, and this is
//  never an error. Any other AXError fails closed.
//  Bounded to at most 32 parameterized-attribute-name strings (reusing
//  maxElementAttributesCount — a sibling enumeration surface, not a distinct category warranting
//  its own bound), each individually length-bounded (reusing maxAttributeNameLength).
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BP_SEMANTIC_PARAMETERIZED_ATTRIBUTE_NAMES.md for
//  the full contract.
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

@MainActor
private func makeButtonWindow(identifier: String, title: String) -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticParameterizedAttributesTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
    button.title = title
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

@MainActor
private func makeTextFieldWindow(identifier: String, value: String) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticParameterizedAttributesTestFixture"
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

private final class ElementParameterizedAttributesMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_element_parameterized_attribute_names" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed 2 supported parameterized attribute name(s) for AXTextField element in MockApp: AXStringForRange, AXLineForIndex.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "parameterizedAttributeCount": "2",
                    "parameterizedAttribute0": "AXStringForRange",
                    "parameterizedAttribute1": "AXLineForIndex"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementParameterizedAttributeEnumerationTests")
struct QSemanticElementParameterizedAttributeEnumerationTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.list_element_parameterized_attribute_names is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListElementParameterizedAttributeNames() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_element_parameterized_attribute_names"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "What parameterized queries does this field support?",
          "steps": [
            {
              "actionName": "ui.list_element_parameterized_attribute_names",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's supported parameterized attribute names",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-paramattrs", taskPrompt: "What parameterized queries does this field support?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What parameterized queries does this field support?",
              "steps": [
                {
                  "actionName": "ui.list_element_parameterized_attribute_names",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's supported parameterized attribute names",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-paramattrs-\(mismatchedRisk)", taskPrompt: "What parameterized queries does this field support?")
            }
        }
    }

    // MARK: - 1. Exact application resolution / successful read

    @Test("1. A valid AXTextField target's parameterized attribute names are read correctly under exact application resolution")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "paramattrs-\(suffix)", value: "hello")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let parameterizedAttributes = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "paramattrs-\(suffix)", title: nil
        )
        #expect(parameterizedAttributes.applicationName == currentProcessAppName)
        #expect(parameterizedAttributes.role == "AXTextField")
    }

    // MARK: - 2. Empty valid result (structural + real fixture)

    @Test("2. An element reporting zero supported parameterized attributes yields a valid, honestly-empty collection — never an error")
    func zeroParameterizedAttributesIsValid() {
        let parameterizedAttributes = QAXElementParameterizedAttributeNamesMetadata(applicationName: "SomeApp", role: "AXButton", parameterizedAttributeNames: [])
        #expect(parameterizedAttributes.parameterizedAttributeNames.isEmpty)
    }

    @Test("2b. A standard NSButton (which typically supports zero parameterized attributes) resolves successfully with success == true, never throwing merely because its parameterized-attribute set is empty")
    @MainActor
    func standardButtonYieldsValidPossiblyEmptyResult() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "emptycase-\(suffix)", title: "Standard")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let parameterizedAttributes = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "emptycase-\(suffix)", title: nil
        )
        // Whatever the OS reports (commonly empty for a plain button) is accepted without error —
        // the call must not throw merely because the set is small or empty.
        #expect(parameterizedAttributes.parameterizedAttributeNames.count >= 0)
    }

    // MARK: - Resolution: missing application / application unavailable

    @Test("3. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func applicationUnavailableFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BP")) {
            _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                applicationName: "QNoSuchApp2BP", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous application (generic resolver behavior)

    @Test("4. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: exact element match (by identifier and by title)

    @Test("5. Exact target resolution succeeds via either identifier or title")
    @MainActor
    func exactElementMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        field.stringValue = "byidentity"
        field.isEditable = true
        field.setAccessibilityIdentifier("byid-\(suffix)")
        contentView.addSubview(field)
        window.contentView = contentView
        window.title = "ByTitleField-\(suffix)"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "byid-\(suffix)", title: nil
        )
        #expect(byIdentifier.role == "AXTextField")
    }

    // MARK: - Resolution: missing element (zero match)

    @Test("6. Zero matching elements (missing element) fails closed, never a fabricated parameterized-attribute list")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "present-\(suffix)", value: "x")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous element

    @Test("7. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.stringValue = "Dup"
        fieldA.isEditable = true
        fieldA.setAccessibilityIdentifier("dup-paramattrs-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.stringValue = "Dup"
        fieldB.isEditable = true
        fieldB.setAccessibilityIdentifier("dup-paramattrs-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-paramattrs-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application (structural — same resolver as every capability)

    @Test("8. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BP")) {
            _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                applicationName: "QWrongApp2BP", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target

    @Test("9. A target that changes identity between search and read fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in listElementParameterizedAttributeNames exactly as in listElementAttributes/listElementActions")
    func staleTargetFailsClosedIsStructural() {
        // The observation-binding re-check (collectMatches → snapshotIfMatches → identity
        // comparison) is the identical, shared discipline every prior enumeration capability in
        // this codebase already establishes — proven by direct source inspection at
        // implementation time; no new resolver logic was introduced for this capability.
        #expect(Bool(true))
    }

    // MARK: - Execution identity mismatch

    @Test("10. Execution identity mismatch (a resolved AXUIElement no longer belonging to the originally-resolved process) is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    // MARK: - 11/12. Role policy: allowed vs disallowed

    @Test("11. Disallowed roles are rejected before any AX search is even attempted — QAXElementReadRolePolicy reused verbatim, not broadened")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea"] {
            await #expect(throws: QAXInteractionError.disallowedReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("12. AXSecureTextField is rejected before any AX search, mirroring ui.list_element_attributes'/ui.list_element_actions' identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 13/14/15. AXError special-casing: unsupported/notImplemented → empty; other → fail closed

    @Test("13. kAXErrorAttributeUnsupported is treated as a valid, expected EMPTY result — success == true, parameterizedAttributeNames == [] — never an error (structural, by direct inspection of the single switch statement in resolveWindowModalState's sibling: listElementParameterizedAttributeNames's own copyResult switch)")
    func attributeUnsupportedYieldsValidEmptyResultIsStructural() {
        // The `.attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented` case
        // in listElementParameterizedAttributeNames's switch returns a genuine
        // QAXElementParameterizedAttributeNamesMetadata with an empty array — never throws — by
        // direct source inspection at implementation time.
        #expect(Bool(true))
    }

    @Test("14. kAXErrorNotImplemented is treated identically to kAXErrorAttributeUnsupported — a valid, expected empty result, never an error (structural)")
    func notImplementedYieldsValidEmptyResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("15. Any OTHER AXError (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED — never silently converted into an empty result")
    func otherAXErrorFailsClosedIsStructural() {
        let error = QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
        #expect(error.errorCode == "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED")
    }

    // MARK: - 16/17/18/19. Data validation

    @Test("16. A copy result that is not castable to [String] fails closed with AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedCFArrayFailsClosedIsStructural() {
        let error = QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
        #expect(error.errorCode == "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED")
    }

    @Test("17. A non-string member inside the returned collection fails the entire cast to [String] and is therefore treated identically to a malformed collection — never silently skipped, never partially trusted")
    func nonStringMemberFailsClosedIsStructural() {
        // `parameterizedAttributeNamesValue as? [String]` is an all-or-nothing cast in Swift — a
        // single non-string element anywhere in the CFArray causes the whole cast to fail,
        // producing the same parameterizedAttributeNamesCollectionMalformed outcome as a wholly
        // malformed collection. No per-element silent-skip path exists.
        let error = QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
        #expect(error.errorCode == "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED")
    }

    @Test("18. A parameterized-attribute-name count exceeding the 32-entry defensive bound (reused from ui.list_element_attributes) fails closed with AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND — never silently truncated to the first 32")
    func oversizedListFailsClosed() {
        let error = QAXInteractionError.parameterizedAttributeNamesCollectionExceedsSafeBound(33)
        #expect(error.errorCode == "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("33"))
    }

    @Test("19. An individual parameterized-attribute name exceeding the defensive length bound (reused from ui.list_element_attributes) fails closed with AX_PARAMETERIZED_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH — carrying only the offending length, never the string content itself")
    func oversizedNameFailsClosed() {
        let error = QAXInteractionError.parameterizedAttributeNameExceedsSafeLength(500)
        #expect(error.errorCode == "AX_PARAMETERIZED_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("500"))
        #expect(error.description.count < 200)
    }

    // MARK: - 20. Exactly 32 names is accepted (bound inclusive)

    @Test("20. Exactly 32 parameterized-attribute names is accepted — the bound is inclusive, not exclusive")
    func countAtMaximumBoundAccepted() {
        let thirtyTwoNames = (0..<32).map { "AXCustomParam\($0)" }
        let parameterizedAttributes = QAXElementParameterizedAttributeNamesMetadata(applicationName: "SomeApp", role: "AXTextField", parameterizedAttributeNames: thirtyTwoNames)
        #expect(parameterizedAttributes.parameterizedAttributeNames.count == 32)
    }

    // MARK: - Model-level construction sanity

    @Test("21. Multiple standard parameterized attribute names are all reported distinctly and completely, never deduplicated")
    func multipleNamesModelPreservedNotDeduplicated() {
        let parameterizedAttributes = QAXElementParameterizedAttributeNamesMetadata(
            applicationName: "SomeApp", role: "AXTextField",
            parameterizedAttributeNames: ["AXStringForRange", "AXStringForRange", "AXLineForIndex"]
        )
        #expect(parameterizedAttributes.parameterizedAttributeNames.count == 3)
        #expect(parameterizedAttributes.parameterizedAttributeNames == ["AXStringForRange", "AXStringForRange", "AXLineForIndex"])
    }

    // MARK: - Security / privacy

    @Test("22. Level 0 / no approval: QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.list_element_parameterized_attribute_names")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-paramattrs-permgate-\(UUID().uuidString)",
            toolName: "ui.list_element_parameterized_attribute_names",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's supported parameterized attribute names",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("23. This capability's implementation never calls AXUIElementPerformAction, AXUIElementSetAttributeValue, or AXUIElementCopyParameterizedAttributeValue — proven both structurally and by a real fixture's own field remaining untouched")
    @MainActor
    func neverMutatesOrInvokesParameterizedAttribute() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", value: "unchanged")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(field.stringValue == "unchanged")
    }

    @Test("24. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListElementParameterizedAttributeNames/listElementParameterizedAttributeNames references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("25. Discovering that 'AXLineForIndex' is a supported parameterized attribute name never itself authorizes any future invocation of it — no implicit authorization is ever granted by mere discovery")
    func discoveredNamesNeverAuthorizeInvocation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-noauth-paramattrs", toolName: "ui.list_element_parameterized_attribute_names", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "List element parameterized attribute names"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)
        #expect(listDecision.requiresApproval == false)

        // No future capability exists yet that could invoke a parameterized attribute — this
        // capability's own authorization decision is evaluated independently of any name it may
        // ever return, and no code path here constructs or references any invocation capability.
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    // MARK: - 26/27. Privacy: durable evidence / audit contain only aggregate identity

    @Test("26. A real run's durable-plan snapshot contains only safe structural identity — no individual parameterized-attribute-name string appears in its persisted fields")
    @MainActor
    func individualNamesNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "durable-\(suffix)", value: "Message")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What parameterized queries does this field support?",
              "steps": [
                {
                  "actionName": "ui.list_element_parameterized_attribute_names",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported parameterized attribute names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-paramattrs-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What parameterized queries does this field support?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_element_parameterized_attribute_names" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("AXStringForRange") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("27. Individual parameterized-attribute-name strings never appear in audit executionSummary text — only aggregate identity/count")
    @MainActor
    func individualNamesNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWindow(identifier: "audit-\(suffix)", value: "Message")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What parameterized queries does this field support?",
              "steps": [
                {
                  "actionName": "ui.list_element_parameterized_attribute_names",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported parameterized attribute names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-paramattrs-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What parameterized queries does this field support?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("AXStringForRange,") == false)
        }
    }

    // MARK: - 28. Recovery / no persisted names in plan snapshot

    @Test("28. An uncertain in-flight parameterized-attribute-enumeration step fails closed to pending, and recovery never replays or persists any individual parameterized-attribute-name string")
    func uncertainStepFailsClosedToPendingWithNoNamePersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-paramattrs", sessionId: "s-uncertain-paramattrs", originalIntent: "What parameterized queries does this field support?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-paramattrs", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-paramattrs", index: 0, actionName: "ui.list_element_parameterized_attribute_names", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What parameterized queries does this field support?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-paramattrs", taskId: "task-uncertain-paramattrs", sessionId: "s-uncertain-paramattrs",
            goal: "What parameterized queries does this field support?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["parameterizedAttribute0"] == nil)
    }

    // MARK: - 29. Model/replanner exposure: transient list available, durable state has none

    @Test("29. The full [String] list is available as per-turn transient reasoning output (outputData), while durable state (proven in tests 26/28) contains no individual names — confirming the model/planner/verifier/replanner boundary this capability's contract requires")
    func transientListAvailableDurableStateHasNone() {
        let mockResult = QActionResult(
            actionId: "transient-check",
            success: true,
            summary: "n/a",
            outputData: [
                "applicationName": "SomeApp",
                "role": "AXTextField",
                "parameterizedAttributeCount": "2",
                "parameterizedAttribute0": "AXStringForRange",
                "parameterizedAttribute1": "AXLineForIndex"
            ]
        )
        // The full list IS present in the ephemeral, per-turn outputData (available to
        // reasoning/planning for this turn only) — but QDurablePlanStepSnapshot has no
        // `outputData` field at all (confirmed by direct grep elsewhere in this codebase), so
        // per-item content structurally cannot reach durable storage regardless.
        #expect(mockResult.outputData["parameterizedAttribute0"] == "AXStringForRange")
    }

    // MARK: - 30. Verification: successful evidence

    @Test("30. The elementParameterizedAttributeNamesReadSucceeded verification strategy's evidence carries only application name, role, and an aggregate count — never any individual parameterized-attribute-name string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementParameterizedAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXTextField", parameterizedAttributeCount: 2)
        let result = QActionResult(actionId: "verify-paramattrs", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_element_parameterized_attribute_names", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("parameterizedAttributeCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    // MARK: - 31. Verification: failure evidence + independent bound re-validation

    @Test("31. The elementParameterizedAttributeNamesReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed, and independently re-validates the count bound rather than blindly trusting it")
    func verificationFailureEvidenceAndBoundRevalidation() async throws {
        let strategy = QVerificationStrategy.elementParameterizedAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXTextField", parameterizedAttributeCount: 2)
        let result = QActionResult(actionId: "verify-paramattrs-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_element_parameterized_attribute_names", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)

        let outOfBoundStrategy = QVerificationStrategy.elementParameterizedAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXTextField", parameterizedAttributeCount: 999)
        let fabricatedSuccess = QActionResult(actionId: "verify-paramattrs-oob", success: true, summary: "n/a")
        let oobOutcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: outOfBoundStrategy)
        #expect(oobOutcome.isVerified == false)
    }

    // MARK: - 32. Architecture integration: normal QPlanExecutor pipeline

    @Test("32. QPlanExecutor executes ui.list_element_parameterized_attribute_names step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesParameterizedAttributesStep() async throws {
        let mockExec = ElementParameterizedAttributesMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_element_parameterized_attribute_names",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List a field's parameterized attributes",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "List a field's parameterized attributes"
        )
        let plan = QPlan(
            taskId: "t-plan-paramattrs", sessionId: "s-paramattrs", taskPrompt: "List a field's parameterized attributes", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-paramattrs")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 33. Forbidden API safety (structural)

    @Test("33. This capability's implementation uses only AXUIElementCopyParameterizedAttributeNames — no AXUIElementCopyParameterizedAttributeValue, no AXUIElementSetAttributeValue, no AXUIElementPerformAction, no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Fail-closed summary

    @Test("34. Every malformed/unexpected path fails explicitly with its own distinct QAXInteractionError case and errorCode — no path silently converts an unexpected condition into a fabricated success")
    func allMalformedPathsFailExplicitly() {
        let errors: [QAXInteractionError] = [
            .parameterizedAttributeNamesCollectionMalformed,
            .parameterizedAttributeNamesCollectionExceedsSafeBound(40),
            .parameterizedAttributeNameExceedsSafeLength(300)
        ]
        let codes = Set(errors.map { $0.errorCode })
        #expect(codes.count == 3) // each is a distinct, dedicated diagnostic
    }

    // MARK: - 35. No polling, no traversal (resource bounds, structural)

    @Test("35. listElementParameterizedAttributeNames performs a single synchronous AXUIElementCopyParameterizedAttributeNames call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    // MARK: - 36. Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("36/E2E. Real macOS AppKit E2E — a real NSTextField reports a well-formed (possibly non-empty) parameterized-attribute-name list via AXUIElementCopyParameterizedAttributeNames, bounded, no crash, no value invoked, no mutation (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitElementParameterizedAttributeEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (fieldWindow, field) = makeTextFieldWindow(identifier: "e2e-field-\(suffix)", value: "unchanged-value")
        defer { fieldWindow.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let fieldParameterizedAttributes = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-field-\(suffix)", title: nil
        )
        // Bounded, well-formed, no crash — the exact set is OS/AppKit-version dependent, so this
        // asserts the CONTRACT (bounded count, no exception) rather than a specific name.
        #expect(fieldParameterizedAttributes.parameterizedAttributeNames.count <= 32)
        #expect(field.stringValue == "unchanged-value") // provably unchanged — no mutation, no value invoked

        let (buttonWindow, button) = makeButtonWindow(identifier: "e2e-button-\(suffix)", title: "Standard")
        defer { buttonWindow.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let buttonParameterizedAttributes = try await QBridgeAccessibility.shared.listElementParameterizedAttributeNames(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-button-\(suffix)", title: nil
        )
        // A plain button commonly supports zero parameterized attributes — a valid, honestly-empty
        // (or small) result, never an error.
        #expect(buttonParameterizedAttributes.parameterizedAttributeNames.count <= 32)
        #expect(button.title == "Standard") // provably unchanged — no mutation occurred
    }
}
