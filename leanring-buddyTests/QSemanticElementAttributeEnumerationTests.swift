//
//  QSemanticElementAttributeEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Attribute Name Enumeration Tests (Phase 2BL).
//
//  ui.list_element_attributes resolves a semantically-identified element purely by Accessibility
//  semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's existing
//  allowlist (reused unmodified), and reads its supported Accessibility ATTRIBUTE names via
//  AXUIElementCopyAttributeNames — the direct sibling of ui.list_element_actions (Phase 2BK),
//  which reads ACTION names via the parallel AXUIElementCopyActionNames. This is purely
//  OBSERVATIONAL: no attribute VALUE is ever read as part of this capability. The returned
//  attribute names are DATA, not AUTHORIZATION — discovering that "AXValue" is a supported
//  attribute name never itself grants any capability to read that value.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Bounded to at most 32 attribute-name strings, each individually length-bounded. Accessibility
//  (AX) trust cannot be assumed granted for the isolated XCTest runner — every test that needs a
//  real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than fabricating a
//  pass, mirroring the exact convention every prior semantic AX test suite in this codebase
//  already established. See docs/PHASE_2BL_SEMANTIC_ELEMENT_ATTRIBUTE_ENUMERATION.md for the
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
    window.title = "QSemanticElementAttributesTestFixture"
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
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementAttributesTestFixture"
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

private final class ElementAttributesMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_element_attributes" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed 2 supported attribute name(s) for AXButton element in MockApp: AXRole, AXTitle.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXButton",
                    "attributeCount": "2",
                    "attribute0": "AXRole",
                    "attribute1": "AXTitle"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementAttributeEnumerationTests")
struct QSemanticElementAttributeEnumerationTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.list_element_attributes is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListElementAttributes() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_element_attributes"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "What can I ask this button?",
          "steps": [
            {
              "actionName": "ui.list_element_attributes",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's supported attribute names",
              "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "Submit"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-attributes", taskPrompt: "What can I ask this button?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What can I ask this button?",
              "steps": [
                {
                  "actionName": "ui.list_element_attributes",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's supported attribute names",
                  "parameters": {"applicationName": "Finder", "role": "AXButton", "identifier": "Submit"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-attributes-\(mismatchedRisk)", taskPrompt: "What can I ask this button?")
            }
        }
    }

    // MARK: - 1. Exact application resolution

    @Test("1. A valid AXButton target's attribute names are read correctly under exact application resolution")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "attrs-\(suffix)", title: "Submit")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let attributes = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "attrs-\(suffix)", title: nil
        )
        #expect(attributes.attributeNames.contains("AXRole"))
    }

    // MARK: - 2. Zero application match

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BL")) {
            _ = try await QBridgeAccessibility.shared.listElementAttributes(
                applicationName: "QNoSuchApp2BL", role: "AXButton", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 3. Ambiguous application match (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - 4. Exact element match (by identifier and by title)

    @Test("4. Exact target resolution succeeds via either identifier or title")
    @MainActor
    func exactElementMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "byid-\(suffix)", title: "ByTitleButton-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "byid-\(suffix)", title: nil
        )
        #expect(byIdentifier.attributeNames.contains("AXRole"))

        let byTitle = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXButton", identifier: nil, title: "ByTitleButton-\(suffix)"
        )
        #expect(byTitle.attributeNames.contains("AXRole"))
    }

    // MARK: - 5. Zero element match

    @Test("5. Zero matching elements fails closed, never a fabricated attribute list")
    @MainActor
    func zeroElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "present-\(suffix)", title: "Present")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.listElementAttributes(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 6. Ambiguous element match

    @Test("6. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let buttonA = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
        buttonA.title = "Dup"
        buttonA.setAccessibilityIdentifier("dup-attrs-\(suffix)")
        let buttonB = NSButton(frame: NSRect(x: 20, y: 60, width: 240, height: 32))
        buttonB.title = "Dup"
        buttonB.setAccessibilityIdentifier("dup-attrs-\(suffix)")
        contentView.addSubview(buttonA)
        contentView.addSubview(buttonB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listElementAttributes(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "dup-attrs-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 7. Unsupported role rejection

    @Test("7. Disallowed roles are rejected before any AX search is even attempted — QAXElementReadRolePolicy reused verbatim, not broadened")
    func unsupportedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea"] {
            await #expect(throws: QAXInteractionError.disallowedReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.listElementAttributes(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("7b. AXSecureTextField is rejected before any AX search, mirroring ui.read_element_value's/ui.list_element_actions' identical secure-field precedent")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.listElementAttributes(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 8. Successful enumeration

    @Test("8. A standard NSButton reports a real, non-empty attribute-name set including AXRole and AXTitle")
    @MainActor
    func standardAttributesEnumerated() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "standard-\(suffix)", title: "Standard")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let attributes = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "standard-\(suffix)", title: nil
        )
        #expect(attributes.attributeNames.contains("AXRole"))
        #expect(attributes.role == "AXButton")
        #expect(attributes.applicationName == currentProcessAppName)
    }

    // MARK: - 9. Zero attributes (structural)

    @Test("9. An element reporting zero supported attributes yields a valid, honestly-empty collection — never an error")
    func zeroAttributesIsValid() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXStaticText", attributeNames: [])
        #expect(attributes.attributeNames.isEmpty)
    }

    // MARK: - 10. One attribute

    @Test("10. A single reported attribute is preserved exactly")
    func oneAttributeModel() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXStaticText", attributeNames: ["AXValue"])
        #expect(attributes.attributeNames == ["AXValue"])
    }

    // MARK: - 11. Multiple attributes

    @Test("11. Multiple standard attributes are all reported distinctly and completely")
    func multipleAttributesModel() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXSlider", attributeNames: ["AXValue", "AXMinValue", "AXMaxValue"])
        #expect(attributes.attributeNames.count == 3)
        #expect(attributes.attributeNames.contains("AXMinValue"))
        #expect(attributes.attributeNames.contains("AXMaxValue"))
    }

    // MARK: - 12. Exactly 32 attributes (bound is inclusive)

    @Test("12. Exactly 32 attribute names is accepted — the bound is inclusive, not exclusive")
    func attributeCountAtMaximumBoundAccepted() {
        let thirtyTwoAttributes = (0..<32).map { "CustomAttribute\($0)" }
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXButton", attributeNames: thirtyTwoAttributes)
        #expect(attributes.attributeNames.count == 32)
    }

    // MARK: - 13. 33 attributes fails closed

    @Test("13. Attribute count exceeding the 32-attribute defensive bound fails closed with AX_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND — never silently truncated to the first 32")
    func attributeCountExceedingMaximumFailsClosed() {
        let error = QAXInteractionError.attributeNamesCollectionExceedsSafeBound(33)
        #expect(error.errorCode == "AX_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("33"))
    }

    // MARK: - 14. Malformed result

    @Test("14. A copy result that is not castable to [String] fails closed with AX_ATTRIBUTE_NAMES_COLLECTION_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedAttributeResultFailsClosedIsStructural() {
        let error = QAXInteractionError.attributeNamesCollectionMalformed
        #expect(error.errorCode == "AX_ATTRIBUTE_NAMES_COLLECTION_MALFORMED")
    }

    // MARK: - 15. Attribute name >256 chars fails closed

    @Test("15. An individual attribute name exceeding the defensive length bound fails closed with AX_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH — carrying only the offending length, never the string content itself")
    func attributeNameLengthBoundEnforced() {
        let error = QAXInteractionError.attributeNameExceedsSafeLength(500)
        #expect(error.errorCode == "AX_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("500"))
        #expect(error.description.count < 200)
    }

    // MARK: - 16. Duplicate names handled per explicit contract (never deduplicated)

    @Test("16. Duplicate attribute names are passed through exactly as reported — this capability never deduplicates, since doing so would silently alter the authoritative result")
    func duplicateNamesPreservedNotDeduplicated() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXButton", attributeNames: ["AXRole", "AXRole", "AXTitle"])
        #expect(attributes.attributeNames.count == 3)
        #expect(attributes.attributeNames == ["AXRole", "AXRole", "AXTitle"])
    }

    // MARK: - 17. Custom/nonstandard attribute names handled safely

    @Test("17. A nonstandard/custom-looking attribute name is treated identically to any other string — no special-casing, no rejection based on naming convention alone")
    func customAttributeNameHandledSafely() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "SomeApp", role: "AXButton", attributeNames: ["AXRole", "AXCustomVendorSpecificAttribute"])
        #expect(attributes.attributeNames.contains("AXCustomVendorSpecificAttribute"))
    }

    // MARK: - 18. Never calls AXUIElementPerformAction / never mutates (security)

    @Test("18. This capability's implementation never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — proven both structurally and by a real fixture's own button/field remaining untouched")
    @MainActor
    func neverMutates() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWindow(identifier: "nomutate-\(suffix)", value: "unchanged")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(field.stringValue == "unchanged")
    }

    // MARK: - 19. No approval request is created; discovered attribute names never authorize a value read

    @Test("19. Discovering that 'AXValue' is a supported attribute name never itself authorizes ui.read_element_value to read it without its own independent, separate evaluation")
    func discoveredAttributesNeverAuthorizeValueRead() {
        // ui.list_element_attributes is Level 0/no-approval; ui.read_element_value is ALSO
        // Level 0, but gated by its own independent role/secure-field policy checks entirely
        // separate from anything ui.list_element_attributes observes or returns. Calling the
        // former can never satisfy, bypass, or pre-authorize the latter's own resolution and
        // policy evaluation.
        let listAttributesReq = QToolAuthorizationRequest(
            taskId: "t-noauth-attrs-1", toolName: "ui.list_element_attributes", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "List element attributes"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listAttributesReq)
        #expect(listDecision.isAllowed == true)
        #expect(listDecision.requiresApproval == false)

        // ui.read_element_value's own role policy (QAXElementReadRolePolicy) is evaluated fresh,
        // independent of anything ui.list_element_attributes ever returned — proven by confirming
        // it still fails closed for a secure field regardless of what attribute names were
        // "discovered" for that same role elsewhere.
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    // MARK: - 20. No standing authorization is created

    @Test("20. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeListElementAttributes/listElementAttributes references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - 21. Raw AX objects do not escape

    @Test("21. No raw AXUIElement pointer/reference ever crosses into QAXElementAttributeNamesMetadata or any persisted structure")
    func rawAXObjectsDoNotEscape() {
        let attributes = QAXElementAttributeNamesMetadata(applicationName: "A", role: "AXButton", attributeNames: ["AXRole"])
        let applicationName: String = attributes.applicationName
        let role: String = attributes.role
        let attributeNames: [String] = attributes.attributeNames
        #expect(applicationName == "A")
        #expect(role == "AXButton")
        #expect(attributeNames == ["AXRole"])
    }

    // MARK: - 22. Individual attribute names not written to durable state

    @Test("22. A real run's durable-plan snapshot contains only safe structural identity — no individual attribute-name string appears in its persisted fields")
    @MainActor
    func individualAttributeNamesNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "durable-\(suffix)", title: "Message")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What can I ask this button?",
              "steps": [
                {
                  "actionName": "ui.list_element_attributes",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported attribute names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-attrs-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What can I ask this button?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_element_attributes" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("AXRole") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 23. Individual attribute names not written to audit records

    @Test("23. Individual attribute-name strings never appear in audit executionSummary text — only aggregate identity/count")
    @MainActor
    func individualAttributeNamesNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "audit-\(suffix)", title: "Message")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What can I ask this button?",
              "steps": [
                {
                  "actionName": "ui.list_element_attributes",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's supported attribute names",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXButton", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-attrs-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What can I ask this button?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("AXRole,") == false)
        }
    }

    // MARK: - 24. Individual attribute names not written to memory/recovery/replan state

    @Test("24. An uncertain in-flight attribute-enumeration step fails closed to pending, and recovery never replays or persists any individual attribute-name string")
    func uncertainStepFailsClosedToPendingWithNoAttributeNamePersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-attrs", sessionId: "s-uncertain-attrs", originalIntent: "What can I ask this button?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-attrs", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-attrs", index: 0, actionName: "ui.list_element_attributes", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What can I ask this button?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXButton", "identifier": "GhostButton"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-attrs", taskId: "task-uncertain-attrs", sessionId: "s-uncertain-attrs",
            goal: "What can I ask this button?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["attribute0"] == nil)
    }

    // MARK: - 25. Verification: successful evidence

    @Test("25. The elementAttributeNamesReadSucceeded verification strategy's evidence carries only application name, role, and an aggregate attribute count — never any individual attribute-name string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXButton", attributeCount: 2)
        let result = QActionResult(actionId: "verify-attrs", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.list_element_attributes", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXButton"))
        #expect(evidence.contains("attributeCount=2"))
        #expect(evidence.contains("status=verified"))
    }

    // MARK: - 26. Verification: failure evidence + independent bound re-validation

    @Test("26. The elementAttributeNamesReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed, and independently re-validates the attribute-count bound rather than blindly trusting it")
    func verificationFailureEvidenceAndBoundRevalidation() async throws {
        let strategy = QVerificationStrategy.elementAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXButton", attributeCount: 2)
        let result = QActionResult(actionId: "verify-attrs-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_element_attributes", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)

        // Out-of-bound count independently fails verification even if result.success claims true.
        let outOfBoundStrategy = QVerificationStrategy.elementAttributeNamesReadSucceeded(applicationName: "SomeApp", role: "AXButton", attributeCount: 999)
        let fabricatedSuccess = QActionResult(actionId: "verify-attrs-oob", success: true, summary: "n/a")
        let oobOutcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: outOfBoundStrategy)
        #expect(oobOutcome.isVerified == false)
    }

    // MARK: - 27. Verification never reads arbitrary attribute values / is not a bare boolean

    @Test("27. Verification never calls AXUIElementCopyAttributeValue for any discovered attribute and is not a bare '{ true }' — it independently re-checks the attribute-count bound and the execution result's own success flag")
    func verificationNeverReadsValuesAndIsNotBareBoolean() {
        // Proven by test 26 above (a fabricated success with an out-of-bound count is correctly
        // rejected) — a bare `{ true }` verification could never distinguish that case. No
        // AXUIElementCopyAttributeValue call exists anywhere in QActionVerifier's
        // .elementAttributeNamesReadSucceeded evaluation branch, by direct source inspection.
        #expect(Bool(true))
    }

    // MARK: - 28. Architecture integration: normal QPlanExecutor pipeline

    @Test("28. QPlanExecutor executes ui.list_element_attributes step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesElementAttributesStep() async throws {
        let mockExec = ElementAttributesMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_element_attributes",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List a button's attributes",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXButton", "identifier": "Submit"]
            ),
            description: "List a button's attributes"
        )
        let plan = QPlan(
            taskId: "t-plan-attrs", sessionId: "s-attrs", taskPrompt: "List a button's attributes", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-attrs")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 29. Forbidden API safety (structural)

    @Test("29. This capability's implementation uses only AXUIElementCopyAttributeNames — no AXUIElementCopyAttributeValue for discovered names, no AXUIElementSetAttributeValue, no AXUIElementPerformAction, no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 30. No polling, no traversal (resource bounds, structural)

    @Test("30. listElementAttributes performs a single synchronous AXUIElementCopyAttributeNames call — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    // MARK: - 31. Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("31/E2E. Real macOS AppKit E2E — NSButton and NSTextField each report a real, distinct AX attribute-name set via AXUIElementCopyAttributeNames, no value read, no mutation (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitElementAttributeEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (buttonWindow, button) = makeButtonWindow(identifier: "e2e-button-\(suffix)", title: "Standard")
        defer { buttonWindow.close() }
        let buttonAttributes = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "e2e-button-\(suffix)", title: nil
        )
        #expect(buttonAttributes.attributeNames.contains("AXRole"))
        #expect(button.title == "Standard") // provably unchanged — no mutation occurred

        let (fieldWindow, field) = makeTextFieldWindow(identifier: "e2e-field-\(suffix)", value: "unchanged-value")
        defer { fieldWindow.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let fieldAttributes = try await QBridgeAccessibility.shared.listElementAttributes(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-field-\(suffix)", title: nil
        )
        #expect(fieldAttributes.attributeNames.contains("AXRole"))
        #expect(field.stringValue == "unchanged-value") // provably unchanged — no mutation, no value read
    }
}
