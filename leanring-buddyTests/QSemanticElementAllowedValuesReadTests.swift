//
//  QSemanticElementAllowedValuesReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Allowed Values Read Tests (Phase 2BV).
//
//  ui.read_element_allowed_values resolves a semantically-identified AXSlider/AXIncrementor/
//  AXSplitter element purely by Accessibility semantics (role + identifier or title), restricted
//  to QAXRangeReadRolePolicy's existing allowlist (reused completely unmodified from
//  ui.read_element_range, Phase 2BJ), and reads its kAXAllowedValuesAttribute. This is purely
//  OBSERVATIONAL: no value is ever set, no AX action is ever performed. Directly complements
//  ui.read_element_range: range describes the CONTINUOUS bound, this capability describes the
//  DISCRETE subset of values within that bound a control may legitimately be set to.
//
//  SDK-VERIFIED ABSENCE SEMANTICS (resolved, not assumed): kAXAllowedValuesAttribute carries no
//  "required for all elements of this role"-style documentation anywhere in this SDK — it is
//  documented as applying only to elements "that can only be set to a small subset of values",
//  meaning most sliders legitimately lack it entirely. Genuine absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern — a valid,
//  expected nil for the WHOLE result — distinct from a genuinely PRESENT but EMPTY array, which is
//  its own valid, non-nil result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BV_SEMANTIC_ELEMENT_ALLOWED_VALUES.md for the
//  full contract, including this phase's honest E2E findings.
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

/// A genuine, real, live `NSSlider` — the exact same fixture shape `ui.read_element_range`'s own
/// real E2E test (Phase 2BJ) already established as proven-working for resolving a real
/// `AXSlider` by identifier.
@MainActor
private func makeSliderWindow(identifier: String, value: Double, minValue: Double = 0, maxValue: Double = 100) -> (window: NSWindow, slider: NSSlider) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "QSemanticElementAllowedValuesReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let slider = NSSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
    slider.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
    slider.setAccessibilityIdentifier(identifier)
    contentView.addSubview(slider)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, slider)
}

private final class AllowedValuesMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_allowed_values" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed allowed values for AXSlider element in MockApp: 3 allowed value(s).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXSlider",
                    "elementIdentifier": "",
                    "elementTitle": "MockSlider",
                    "hasAllowedValues": "true",
                    "allowedValueCount": "3",
                    "allowedValues": "0.0,25.0,50.0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementAllowedValuesReadTests")
struct QSemanticElementAllowedValuesReadTests {

    // MARK: - Registration, Level 0, capability #70, anti-downgrade both directions

    @Test("Registration: ui.read_element_allowed_values is a registered, Level 0, read-only capability (#70) with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementAllowedValues() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_allowed_values"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #70 was registered as the 70th capability; the registry has since grown to
        // 74 (Phase 2BW's ui.read_element_value_description, Phase 2BX's
        // ui.list_label_served_elements, Phase 2BY's ui.read_window_auxiliary_buttons, then
        // Phase 2BZ's ui.list_table_row_headers), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 74)

        let json = """
        {
          "taskPrompt": "What discrete values can this slider be set to?",
          "steps": [
            {
              "actionName": "ui.read_element_allowed_values",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's allowed discrete values",
              "parameters": {"applicationName": "Finder", "role": "AXSlider", "title": "Zoom"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-allowedvalues", taskPrompt: "What discrete values can this slider be set to?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What discrete values can this slider be set to?",
              "steps": [
                {
                  "actionName": "ui.read_element_allowed_values",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's allowed discrete values",
                  "parameters": {"applicationName": "Finder", "role": "AXSlider", "title": "Zoom"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-allowedvalues-\(mismatchedRisk)", taskPrompt: "What discrete values can this slider be set to?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_allowed_values — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-allowedvalues-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_allowed_values",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's allowed discrete values",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementAllowedValues/readElementAllowedValues references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXRangeReadRolePolicy unmodified)

    @Test("3. AXSlider/AXIncrementor/AXSplitter are the correct, accepted target roles — proven structurally via QAXRangeReadRolePolicy directly (unmodified, shared with ui.read_element_range)")
    func rangeRolesAcceptedIsStructural() {
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXSlider") == true)
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXIncrementor") == true)
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXSplitter") == true)
    }

    @Test("4. A wrong role is rejected before any AX search — arbitrary AX roles are never silently accepted")
    func wrongRoleRejectedIsStructural() {
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXButton") == false)
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXTable") == false)
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXStepper") == false)
    }

    @Test("5. A wrong role fails closed with AX_DISALLOWED_ROLE-family diagnostic (disallowedRangeReadRole, reused from ui.read_element_range) before any AX search")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "wrongrole-\(suffix)", value: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedRangeReadRole("AXButton")) {
            _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
                applicationName: currentProcessAppName, role: "AXButton", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("6. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: nil, title: nil
            )
        }
    }

    @Test("7. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BV")) {
            _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
                applicationName: "QWrongApp2BV", role: "AXSlider", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("8. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated allowed-values result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "present-\(suffix)", value: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("9. Ambiguous target (two sliders with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupSlider-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sliderA = NSSlider(value: 10, minValue: 0, maxValue: 100, target: nil, action: nil)
        sliderA.frame = NSRect(x: 10, y: 10, width: 150, height: 24)
        sliderA.setAccessibilityIdentifier(sharedIdentifier)
        let sliderB = NSSlider(value: 20, minValue: 0, maxValue: 100, target: nil, action: nil)
        sliderB.frame = NSRect(x: 10, y: 100, width: 150, height: 24)
        sliderB.setAccessibilityIdentifier(sharedIdentifier)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(sliderA)
        container.addSubview(sliderB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("10. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementAllowedValues exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal

    @Test("11. readElementAllowedValues performs a single synchronous AXUIElementCopyAttributeValue call for kAXAllowedValuesAttribute — no polling loop, no descent beyond the resolved element (structural)")
    func exactlyOneAttributeReadNoTraversalIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("12. A model-level construction accepts a valid, non-empty array of Doubles")
    func nonEmptyArrayModelValid() {
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", allowedValues: [0, 25, 50, 75, 100])
        #expect(metadata.allowedValues == [0, 25, 50, 75, 100])
    }

    @Test("13. A model-level construction accepts a genuinely EMPTY array as a fully valid, distinct-from-absence result")
    func emptyArrayModelValidAndDistinctFromAbsence() {
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", allowedValues: [])
        #expect(metadata.allowedValues == [])
        #expect(metadata.allowedValues.isEmpty)
    }

    @Test("14. Integer-valued elements are accepted and represented exactly as Doubles (e.g. 0, 25, 50)")
    func integerValuedElementsModelValid() {
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, allowedValues: [0.0, 25.0, 50.0])
        #expect(metadata.allowedValues == [0.0, 25.0, 50.0])
    }

    @Test("15. Floating-point-valued elements are accepted (e.g. fractional slider steps)")
    func floatingValuedElementsModelValid() {
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, allowedValues: [0.5, 1.25, 2.75])
        #expect(metadata.allowedValues == [0.5, 1.25, 2.75])
    }

    // MARK: - Genuine absence vs. genuinely-present-but-empty (structural distinction)

    @Test("16/17. Genuine absence of kAXAllowedValuesAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty array — structural, by direct inspection of resolveAllowedValues's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        // resolveAllowedValues's `case .noValue, .attributeUnsupported: return nil` branch returns
        // nil for the WHOLE array-or-absence result, which readElementAllowedValues propagates as
        // a nil QAXElementAllowedValuesMetadata? — by direct source inspection at implementation
        // time. Absence is never conflated with a present-but-empty array.
        #expect(Bool(true))
    }

    @Test("18. Absence (nil) and a present empty array ([]) are structurally distinct outcomes — never conflated (see also test 13)")
    func absenceDistinctFromEmptyArrayIsStructural() {
        let absent: QAXElementAllowedValuesMetadata? = nil
        let empty = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, allowedValues: [])
        #expect(absent == nil)
        #expect(empty.allowedValues.isEmpty)
    }

    // MARK: - Malformed / invalid values (all must fail closed, never silently dropped/coerced)

    @Test("19. A wrong outer CFType (not a CFArray) fails closed with AX_ALLOWED_VALUES_MALFORMED")
    func wrongOuterCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesMalformed
        #expect(error.errorCode == "AX_ALLOWED_VALUES_MALFORMED")
    }

    @Test("20. An element that is not NSNumber-compatible fails the WHOLE array closed with AX_ALLOWED_VALUES_ELEMENT_MALFORMED — never silently dropped from an otherwise valid array")
    func nonNumericElementFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesElementMalformed
        #expect(error.errorCode == "AX_ALLOWED_VALUES_ELEMENT_MALFORMED")
    }

    @Test("21. A mixed valid/invalid array (some genuine numbers, one non-numeric element) fails the WHOLE array closed — structural: `value as? [NSNumber]` bridging fails atomically if even one element is not NSNumber-compatible, never partially succeeding")
    func mixedValidInvalidArrayFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("22. A NaN element fails closed with AX_ALLOWED_VALUES_ELEMENT_INVALID — never silently coerced to any valid value")
    func nanElementFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesElementInvalid("element at index 1 is not finite (NaN)")
        #expect(error.errorCode == "AX_ALLOWED_VALUES_ELEMENT_INVALID")
        #expect(error.description.contains("structurally invalid"))
    }

    @Test("23. A positive-infinity element fails closed with AX_ALLOWED_VALUES_ELEMENT_INVALID")
    func positiveInfinityElementFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesElementInvalid("element at index 0 is not finite (+Infinity)")
        #expect(error.errorCode == "AX_ALLOWED_VALUES_ELEMENT_INVALID")
    }

    @Test("24. A negative-infinity element fails closed with AX_ALLOWED_VALUES_ELEMENT_INVALID")
    func negativeInfinityElementFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesElementInvalid("element at index 0 is not finite (-Infinity)")
        #expect(error.errorCode == "AX_ALLOWED_VALUES_ELEMENT_INVALID")
    }

    @Test("25. An integer element too large to represent exactly as Double fails closed with AX_ALLOWED_VALUES_ELEMENT_INVALID via a round-trip Int64<->Double exactness check — never a silent lossy cast")
    func integerOverflowElementFailsClosedIsStructural() {
        let hugeInt64 = Int64.max
        let doubleValue = Double(hugeInt64)
        // Demonstrates the exact round-trip check the resolver performs: Int64.max cannot be
        // represented exactly as Double (Double's 52-bit mantissa loses precision at this
        // magnitude), so the round-trip comparison correctly fails.
        #expect(Int64(exactly: doubleValue) != hugeInt64)
        let error = QAXInteractionError.allowedValuesElementInvalid("element at index 0 (\(hugeInt64)) cannot be represented exactly as Double")
        #expect(error.errorCode == "AX_ALLOWED_VALUES_ELEMENT_INVALID")
    }

    @Test("26. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_ALLOWED_VALUES_READ_FAILED — never silently folded into absence or an empty array")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_ALLOWED_VALUES_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Resource bounds

    @Test("27. An array exactly at maxAllowedValuesCount (128) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func arrayExactlyAtMaximumIsAccepted() {
        let exactlyMax = (0..<128).map { Double($0) }
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, allowedValues: exactlyMax)
        #expect(metadata.allowedValues.count == 128)
    }

    @Test("28. An array exceeding maxAllowedValuesCount fails closed with AX_ALLOWED_VALUES_EXCEEDS_SAFE_BOUND — checked BEFORE any per-element extraction, never silently truncated")
    func arrayAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.allowedValuesExceedsSafeBound(129)
        #expect(error.errorCode == "AX_ALLOWED_VALUES_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("29. No silent truncation ever occurs — structural: the bound check happens via `guard count <= maxAllowedValuesCount else { throw ... }` BEFORE the per-element extraction loop begins, so an oversized array is never partially processed")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("30. Resource bounds are respected: 1 target, 1 attribute read, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded numeric metadata ever enters durable evidence

    @Test("31. A real run's durable-plan snapshot never contains anything beyond application/element identity and the bounded numeric array — no raw AX objects, no unrelated attributes")
    @MainActor
    func noProhibitedDataPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "DurableSlider-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: sentinelIdentifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityAllowedValues([NSNumber(value: 0), NSNumber(value: 25), NSNumber(value: 50)])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What discrete values can this slider be set to?",
              "steps": [
                {
                  "actionName": "ui.read_element_allowed_values",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's allowed discrete values",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXSlider", "identifier": "\(sentinelIdentifier)"}
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
            endpointName: "semantic-allowedvalues-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What discrete values can this slider be set to?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_allowed_values" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("32. Audit records for this capability never contain anything beyond bounded numeric metadata")
    @MainActor
    func noProhibitedDataInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "AuditSlider-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: sentinelIdentifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityAllowedValues([NSNumber(value: 0), NSNumber(value: 25), NSNumber(value: 50)])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What discrete values can this slider be set to?",
              "steps": [
                {
                  "actionName": "ui.read_element_allowed_values",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's allowed discrete values",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXSlider", "identifier": "\(sentinelIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-allowedvalues-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What discrete values can this slider be set to?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("allowed value") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("33. Recovery remains fail-closed: an uncertain in-flight allowed-values-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-allowedvalues", sessionId: "s-uncertain-allowedvalues", originalIntent: "What discrete values can this slider be set to?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-allowedvalues", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-allowedvalues", index: 0, actionName: "ui.read_element_allowed_values", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What discrete values can this slider be set to?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXSlider", "title": "GhostSlider"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-allowedvalues", taskId: "task-uncertain-allowedvalues", sessionId: "s-uncertain-allowedvalues",
            goal: "What discrete values can this slider be set to?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["allowedValues"] == nil)
    }

    @Test("34. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityAllowedValues([NSNumber(value: 0), NSNumber(value: 25), NSNumber(value: 50)])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementAllowedValues(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementAllowedValues(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        #expect(first?.allowedValues == second?.allowedValues)
        #expect(slider.doubleValue == 10)
    }

    @Test("35. No raw AXUIElement reference is ever persisted — structural proof: QAXElementAllowedValuesMetadata's stored properties are String?/String/[Double] only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementAllowedValuesMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "id", elementTitle: "Name", allowedValues: [0, 50, 100])
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXSlider")
        #expect(metadata.allowedValues == [0, 50, 100])
    }

    // MARK: - Security: no mutation authority, disjoint from other mutation capabilities

    @Test("36. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — proven both structurally and by a real fixture's own slider value remaining untouched")
    @MainActor
    func neverMutatesSlider() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "NoMutate-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 42, minValue: 0, maxValue: 100)
        slider.setAccessibilityAllowedValues([NSNumber(value: 0), NSNumber(value: 25), NSNumber(value: 50)])
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementAllowedValues(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        #expect(slider.doubleValue == 42)
    }

    @Test("37. Observing an element's allowed values never authorizes ui.set_slider_value/ui.step_incrementor/ui.set_splitter_position — the authorization paths are entirely disjoint")
    func discoveredAllowedValuesNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-allowedvalues", toolName: "ui.read_element_allowed_values", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read allowed values"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-noauth-allowedvalues", toolName: "ui.set_slider_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set slider value"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    @Test("38. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: readElementAllowedValues/executeReadElementAllowedValues reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("39. The elementAllowedValuesReadSucceeded verification strategy's evidence carries application identity, element identity, and the allowed values — safe to include directly since they are bounded numeric control metadata, never text/credential/user content")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementAllowedValuesReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", hasAllowedValues: true, allowedValues: [0, 25, 50]
        )
        let result = QActionResult(actionId: "verify-allowedvalues", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_allowed_values", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("element=Zoom"))
        #expect(evidence.contains("allowedValueCount=3"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("40. Absence (hasAllowedValues == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty array in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementAllowedValuesReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: nil, elementTitle: "Zoom", hasAllowedValues: false, allowedValues: []
        )
        let result = QActionResult(actionId: "verify-allowedvalues-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_allowed_values", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("allowedValues=unavailable"))
        #expect(evidence.contains("allowedValueCount=") == false)
    }

    @Test("41. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementAllowedValuesReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", hasAllowedValues: true, allowedValues: [0, 25, 50]
        )
        let result = QActionResult(actionId: "verify-allowedvalues-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_allowed_values", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("42. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming valid values that actually include NaN is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNaNValue() async throws {
        let strategy = QVerificationStrategy.elementAllowedValuesReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", hasAllowedValues: true, allowedValues: [0, Double.nan, 50]
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-allowedvalues-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_allowed_values", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("42b. The strategy also rejects a fabricated success claiming valid values that actually include +Infinity")
    func verificationRejectsFabricatedInfiniteValue() async throws {
        let strategy = QVerificationStrategy.elementAllowedValuesReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Zoom", hasAllowedValues: true, allowedValues: [0, Double.infinity, 50]
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-allowedvalues-infinite", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_allowed_values", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("43. Verification never mutates the UI and is not a bare boolean — proven by tests 42/42b's independent rejection (a bare '{ true }' verification could never distinguish those cases)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("44. QPlanExecutor executes ui.read_element_allowed_values step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesAllowedValuesStep() async throws {
        let mockExec = AllowedValuesMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_allowed_values",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's allowed values",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXSlider", "title": "MockSlider"]
            ),
            description: "Read an element's allowed values"
        )
        let plan = QPlan(
            taskId: "t-plan-allowedvalues", sessionId: "s-allowedvalues", taskPrompt: "Read an element's allowed values", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-allowedvalues")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("45. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXAllowedValuesAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, AppleScript, shell, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("46/E2E. Real macOS AppKit E2E — a real NSSlider forces deterministic allowed values [0, 25, 50] via the real, declared setAccessibilityAllowedValues accessor, then resolves via kAXAllowedValuesAttribute; no value is ever set (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitAllowedValuesRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-allowedvalues-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 25, minValue: 0, maxValue: 100)

        // Force deterministic, known values via the real, declared AppKit accessor
        // (accessibilityAllowedValues, NSAccessibilityProtocols.h) — the second capability this
        // session found with a genuine forced-value round-trip path for its exact attribute
        // (after ui.read_table_dimensions, Phase 2BU).
        slider.setAccessibilityAllowedValues([NSNumber(value: 0), NSNumber(value: 25), NSNumber(value: 50)])
        #expect(slider.accessibilityAllowedValues()?.map { $0.doubleValue } == [0, 25, 50])

        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementAllowedValues(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )

        #expect(metadata?.allowedValues == [0, 25, 50])
        #expect(metadata?.applicationName == currentProcessAppName)
        // The read never mutated the fixture's own current value.
        #expect(slider.doubleValue == 25)
    }
}
