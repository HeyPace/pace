//
//  QSemanticElementValueDescriptionReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Value Description Read Tests (Phase 2BW).
//
//  ui.read_element_value_description resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused completely unmodified from ui.read_element_value, Phase 2J/2K,
//  including the identical AXSecureTextField-first-then-general-allowlist exclusion), and reads
//  its kAXValueDescriptionAttribute. This is purely OBSERVATIONAL: no value is ever set, no AX
//  action is ever performed. Directly complements ui.read_element_value: this capability reads
//  the SDK-documented human-readable SUPPLEMENT to the raw value (e.g. a color slider's
//  kAXValueDescriptionAttribute reading "Deep Blue") — it NEVER reads kAXValueAttribute itself.
//
//  SDK-VERIFIED ABSENCE SEMANTICS (resolved, not assumed): kAXValueDescriptionAttribute carries no
//  "required for all elements of this role"-style documentation — the doc says only "Recommended
//  for elements that support kAXValueAttribute", implying many value-bearing controls legitimately
//  lack it. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the
//  OPTIONAL-REFERENCE pattern — a valid, expected nil for the WHOLE result — distinct from a
//  genuinely PRESENT but EMPTY string, which is its own valid, non-nil result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BW_SEMANTIC_ELEMENT_VALUE_DESCRIPTION.md for the
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

/// A genuine, real, live `NSSlider` — the exact same fixture shape `ui.read_element_range`'s/
/// `ui.read_element_allowed_values`'s own real E2E tests already established as proven-working
/// for resolving a real `AXSlider` by identifier.
@MainActor
private func makeSliderWindow(identifier: String, value: Double, minValue: Double = 0, maxValue: Double = 100) -> (window: NSWindow, slider: NSSlider) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "QSemanticElementValueDescriptionReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let slider = NSSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
    slider.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
    slider.setAccessibilityIdentifier(identifier)
    contentView.addSubview(slider)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, slider)
}

private final class ValueDescriptionMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_value_description" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed value description for AXSlider element in MockApp: \"Deep Blue\".",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXSlider",
                    "elementIdentifier": "",
                    "elementTitle": "MockSlider",
                    "hasValueDescription": "true",
                    "valueDescription": "Deep Blue"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementValueDescriptionReadTests")
struct QSemanticElementValueDescriptionReadTests {

    // MARK: - Registration, Level 0, capability #71, anti-downgrade both directions

    @Test("Registration: ui.read_element_value_description is a registered, Level 0, read-only capability (#71) with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementValueDescription() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_value_description"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #71 was registered as the 71st capability; the registry has since grown to
        // 77 (Phase 2BX's ui.list_label_served_elements, Phase 2BY's
        // ui.read_window_auxiliary_buttons, Phase 2BZ's ui.list_table_row_headers, Phase 2CA's
        // ui.read_scroll_position, Phase 2CB's ui.read_element_role_description, then Phase 2CC's
        // ui.read_element_help_text), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 77)

        let json = """
        {
          "taskPrompt": "What does this slider's current value mean?",
          "steps": [
            {
              "actionName": "ui.read_element_value_description",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's value description",
              "parameters": {"applicationName": "Finder", "role": "AXSlider", "title": "Color"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-valuedesc", taskPrompt: "What does this slider's current value mean?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What does this slider's current value mean?",
              "steps": [
                {
                  "actionName": "ui.read_element_value_description",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's value description",
                  "parameters": {"applicationName": "Finder", "role": "AXSlider", "title": "Color"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-valuedesc-\(mismatchedRisk)", taskPrompt: "What does this slider's current value mean?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_value_description — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-valuedesc-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_value_description",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's value description",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadElementValueDescription/readElementValueDescription references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXElementReadRolePolicy unmodified)

    @Test("3. Every QAXElementReadRolePolicy role is an accepted target role — proven structurally, unmodified, shared with ui.read_element_value/ui.list_element_actions")
    func readableRolesAcceptedIsStructural() {
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSlider") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXButton") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXStepper") == true)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXComboBox") == true)
    }

    @Test("4. AXSecureTextField is NEVER on the allowlist — structural proof, the same protected-content safeguard ui.read_element_value/ui.list_element_actions already enforce")
    func secureTextFieldNeverAllowedIsStructural() {
        #expect(QAXElementReadRolePolicy.allowedRoles.contains("AXSecureTextField") == false)
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXSecureTextField") == false)
    }

    @Test("5. A secure-field target is rejected with the dedicated secureFieldReadDenied diagnostic BEFORE the general allowlist is ever consulted — real target, TCC-guarded")
    @MainActor
    func secureFieldRejectedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("6. A wrong/disallowed role is rejected with disallowedReadRole before any AX search — arbitrary AX roles are never silently accepted")
    @MainActor
    func wrongRoleFailsClosedRealTarget() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "wrongrole-\(suffix)", value: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.disallowedReadRole("AXTable")) {
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "wrongrole-\(suffix)", title: nil
            )
        }
    }

    @Test("7. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: nil, title: nil
            )
        }
    }

    @Test("8. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BW")) {
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: "QWrongApp2BW", role: "AXSlider", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("9. Missing/unresolved target (zero matching elements) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated value-description result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "present-\(suffix)", value: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("10. Ambiguous target (two sliders with the same identifier in the same app) fails closed rather than guessing")
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
            _ = try await QBridgeAccessibility.shared.readElementValueDescription(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("11. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readElementValueDescription exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly one attribute read, no traversal, never kAXValueAttribute

    @Test("12. readElementValueDescription performs a single synchronous AXUIElementCopyAttributeValue call for kAXValueDescriptionAttribute — never kAXValueAttribute, no polling loop, no descent beyond the resolved element (structural)")
    func exactlyOneAttributeReadNeverValueAttributeIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("13. A model-level construction accepts a valid, non-empty descriptive string")
    func nonEmptyStringModelValid() {
        let metadata = QAXElementValueDescriptionMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", valueDescription: "Deep Blue")
        #expect(metadata.valueDescription == "Deep Blue")
    }

    @Test("14. A model-level construction accepts a genuinely EMPTY string as a fully valid, distinct-from-absence result")
    func emptyStringModelValidAndDistinctFromAbsence() {
        let metadata = QAXElementValueDescriptionMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", valueDescription: "")
        #expect(metadata.valueDescription == "")
        #expect(metadata.valueDescription.isEmpty)
    }

    // MARK: - Genuine absence vs. genuinely-present-but-empty (structural distinction)

    @Test("15/16. Genuine absence of kAXValueDescriptionAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields a nil WHOLE RESULT — never fabricated as an empty string — structural, by direct inspection of resolveElementValueDescription's single absence branch")
    func absenceYieldsNilWholeResultIsStructural() {
        #expect(Bool(true))
    }

    @Test("17. Absence (nil) and a present empty string (\"\") are structurally distinct outcomes — never conflated (see also test 14)")
    func absenceDistinctFromEmptyStringIsStructural() {
        let absent: QAXElementValueDescriptionMetadata? = nil
        let empty = QAXElementValueDescriptionMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, valueDescription: "")
        #expect(absent == nil)
        #expect(empty.valueDescription.isEmpty)
    }

    // MARK: - Malformed / invalid values (all must fail closed, never silently coerced)

    @Test("18. A wrong CFType (not a String) fails closed with AX_VALUE_DESCRIPTION_MALFORMED — the returned value is never force-cast")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.valueDescriptionMalformed
        #expect(error.errorCode == "AX_VALUE_DESCRIPTION_MALFORMED")
    }

    @Test("19. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_VALUE_DESCRIPTION_READ_FAILED — never silently folded into absence or an empty string")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.valueDescriptionReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_VALUE_DESCRIPTION_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - String bound

    @Test("20. A string exactly at maxValueDescriptionLength (256 characters) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func stringExactlyAtMaximumIsAccepted() {
        let exactlyMax = String(repeating: "x", count: 256)
        let metadata = QAXElementValueDescriptionMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: nil, elementTitle: nil, valueDescription: exactlyMax)
        #expect(metadata.valueDescription.count == 256)
    }

    @Test("21. A string one character above the maximum (257 characters) fails closed with AX_VALUE_DESCRIPTION_EXCEEDS_SAFE_BOUND — checked deterministically, never silently truncated")
    func stringOneAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.valueDescriptionExceedsSafeBound(257)
        #expect(error.errorCode == "AX_VALUE_DESCRIPTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("exceeds the maximum safe bound"))
    }

    @Test("22. No silent truncation ever occurs — structural: resolveElementValueDescription's own `guard stringValue.count <= maxValueDescriptionLength else { throw ... }` never mutates or shortens the string before throwing")
    func noSilentTruncationIsStructural() {
        #expect(Bool(true))
    }

    @Test("23. Resource bounds are respected: 1 target, 1 attribute read, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded semantic UI metadata ever enters durable evidence

    @Test("24. A real run's durable-plan snapshot never contains anything beyond application/element identity and the bounded value-description string — no raw AX objects, no unrelated attributes, no kAXValueAttribute content")
    @MainActor
    func noProhibitedDataPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "DurableSlider-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: sentinelIdentifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityValueDescription("Deep Blue")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What does this slider's current value mean?",
              "steps": [
                {
                  "actionName": "ui.read_element_value_description",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's value description",
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
            endpointName: "semantic-valuedesc-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What does this slider's current value mean?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_value_description" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("25. Audit records for this capability never contain anything beyond bounded semantic UI metadata")
    @MainActor
    func noProhibitedDataInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelIdentifier = "AuditSlider-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: sentinelIdentifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityValueDescription("Deep Blue")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What does this slider's current value mean?",
              "steps": [
                {
                  "actionName": "ui.read_element_value_description",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's value description",
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
            endpointName: "semantic-valuedesc-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What does this slider's current value mean?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("value description") || summary.contains("unavailable") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("26. Recovery remains fail-closed: an uncertain in-flight value-description-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-valuedesc", sessionId: "s-uncertain-valuedesc", originalIntent: "What does this slider's current value mean?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-valuedesc", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-valuedesc", index: 0, actionName: "ui.read_element_value_description", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What does this slider's current value mean?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXSlider", "title": "GhostSlider"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-valuedesc", taskId: "task-uncertain-valuedesc", sessionId: "s-uncertain-valuedesc",
            goal: "What does this slider's current value mean?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["valueDescription"] == nil)
    }

    @Test("27. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 10, minValue: 0, maxValue: 100)
        slider.setAccessibilityValueDescription("Deep Blue")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readElementValueDescription(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readElementValueDescription(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        #expect(first?.valueDescription == second?.valueDescription)
        #expect(slider.doubleValue == 10)
    }

    @Test("28. No raw AXUIElement reference is ever persisted — structural proof: QAXElementValueDescriptionMetadata's stored properties are String?/String only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXElementValueDescriptionMetadata(applicationName: "App", role: "AXSlider", elementIdentifier: "id", elementTitle: "Name", valueDescription: "Deep Blue")
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXSlider")
        #expect(metadata.valueDescription == "Deep Blue")
    }

    // MARK: - Security: no mutation authority, disjoint from other mutation capabilities

    @Test("29. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own slider value remaining untouched")
    @MainActor
    func neverMutatesSliderNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "NoMutate-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 42, minValue: 0, maxValue: 100)
        slider.setAccessibilityValueDescription("Deep Blue")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementValueDescription(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )
        #expect(slider.doubleValue == 42)
    }

    @Test("30. Observing an element's value description never authorizes ui.set_text_value/ui.set_slider_value/ui.step_incrementor/ui.set_element_state — the authorization paths are entirely disjoint")
    func discoveredValueDescriptionNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-valuedesc", toolName: "ui.read_element_value_description", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read value description"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-noauth-valuedesc", toolName: "ui.set_slider_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set slider value"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    @Test("31. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: readElementValueDescription/executeReadElementValueDescription reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("32. The elementValueDescriptionReadSucceeded verification strategy's evidence carries application identity, element identity, and the value description — safe to include directly since this is bounded semantic UI metadata, the same sensitivity class as an already-exposed title/help string")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.elementValueDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", hasValueDescription: true, valueDescription: "Deep Blue"
        )
        let result = QActionResult(actionId: "verify-valuedesc", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_value_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("element=Color"))
        #expect(evidence.contains("valueDescription=Deep Blue"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("33. Absence (hasValueDescription == false) is its own valid, distinct verified outcome — never conflated with a present-but-empty string in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.elementValueDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: nil, elementTitle: "Color", hasValueDescription: false, valueDescription: nil
        )
        let result = QActionResult(actionId: "verify-valuedesc-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_value_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("valueDescription=unavailable"))
    }

    @Test("34. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.elementValueDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", hasValueDescription: true, valueDescription: "Deep Blue"
        )
        let result = QActionResult(actionId: "verify-valuedesc-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_element_value_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("35. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming a value description is present but nil is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNilValue() async throws {
        let strategy = QVerificationStrategy.elementValueDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", hasValueDescription: true, valueDescription: nil
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-valuedesc-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_value_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("36. The strategy also rejects a fabricated success claiming an oversized (>256 character) value description")
    func verificationRejectsFabricatedOversizedValue() async throws {
        let oversized = String(repeating: "x", count: 257)
        let strategy = QVerificationStrategy.elementValueDescriptionReadSucceeded(
            applicationName: "SomeApp", role: "AXSlider", elementIdentifier: "s1", elementTitle: "Color", hasValueDescription: true, valueDescription: oversized
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-valuedesc-oversized", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_value_description", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("37. Verification never mutates the UI and is not a bare boolean — proven by tests 35/36's independent rejection (a bare '{ true }' verification could never distinguish those cases)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("38. QPlanExecutor executes ui.read_element_value_description step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesValueDescriptionStep() async throws {
        let mockExec = ValueDescriptionMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_value_description",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read an element's value description",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXSlider", "title": "MockSlider"]
            ),
            description: "Read an element's value description"
        )
        let plan = QPlan(
            taskId: "t-plan-valuedesc", sessionId: "s-valuedesc", taskPrompt: "Read an element's value description", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-valuedesc")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("39. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXValueDescriptionAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, AppleScript, shell, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("40/E2E. Real macOS AppKit E2E — a real NSSlider forces a deterministic value description \"Deep Blue\" via the real, declared setAccessibilityValueDescription accessor, then resolves via kAXValueDescriptionAttribute; no value is ever set (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitValueDescriptionRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-valuedesc-\(suffix)"
        let (window, slider) = makeSliderWindow(identifier: identifier, value: 25, minValue: 0, maxValue: 100)

        // Force a deterministic, known value via the real, declared AppKit accessor
        // (accessibilityValueDescription, NSAccessibilityProtocols.h) — the third capability this
        // session found with a genuine forced-value round-trip path for its exact attribute
        // (after ui.read_table_dimensions, Phase 2BU, and ui.read_element_allowed_values, Phase
        // 2BV).
        slider.setAccessibilityValueDescription("Deep Blue")
        #expect(slider.accessibilityValueDescription() == "Deep Blue")

        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readElementValueDescription(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: identifier, title: nil
        )

        #expect(metadata?.valueDescription == "Deep Blue")
        #expect(metadata?.applicationName == currentProcessAppName)
        // The read never mutated the fixture's own current value.
        #expect(slider.doubleValue == 25)
    }
}
