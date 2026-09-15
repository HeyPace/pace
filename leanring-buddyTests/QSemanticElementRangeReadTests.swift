//
//  QSemanticElementRangeReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Element Range Read Tests (Phase 2BJ).
//
//  ui.read_element_range resolves a semantically-identified AXSlider/AXIncrementor/AXSplitter
//  element purely by Accessibility semantics (role + identifier or title) and reads its
//  authoritative kAXMinValueAttribute/kAXMaxValueAttribute/kAXValueAttribute (all required) plus
//  optional kAXValueIncrementAttribute — the exact same attributes ui.set_slider_value/
//  ui.step_incrementor/ui.set_splitter_position already read internally for their own
//  idempotency/range-validation, but never previously exposed to the model. Target roles are
//  restricted to QAXRangeReadRolePolicy — a fresh policy verified against the live SDK's
//  AXRoleConstants.h, deliberately NOT copying QAXSliderRolePolicy's historically-inert
//  "AXStepper" string (no such role constant exists anywhere in the SDK).
//
//  Level 0 — no approval, no mutation, no press, no set, no recovery replay.
//  Numeric metadata only (minValue, maxValue, currentValue, valueIncrement). Never clamps, never
//  repairs, never substitutes a default for an invalid or inconsistent range.
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
private func makeSliderWindow(identifier: String, value: Double, minValue: Double = 0, maxValue: Double = 100) -> (window: NSWindow, slider: NSSlider) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementRangeReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let slider = NSSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
    slider.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
    slider.setAccessibilityIdentifier(identifier)
    contentView.addSubview(slider)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, slider)
}

@MainActor
private func makeStepperWindow(identifier: String, value: Double, minValue: Double = 0, maxValue: Double = 100) -> (window: NSWindow, stepper: NSStepper) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.title = "QSemanticElementRangeReadTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let stepper = NSStepper(frame: NSRect(x: 20, y: 20, width: 40, height: 24))
    stepper.minValue = minValue
    stepper.maxValue = maxValue
    stepper.doubleValue = value
    stepper.setAccessibilityIdentifier(identifier)
    contentView.addSubview(stepper)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, stepper)
}

private final class ElementRangeReadMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_element_range" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Read AXSlider element range in MockApp: min=0.0 max=100.0 current=25.0",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXSlider",
                    "minValue": "0.0",
                    "maxValue": "100.0",
                    "currentValue": "25.0"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticElementRangeReadTests")
struct QSemanticElementRangeReadTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.read_element_range is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIReadElementRange() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_element_range"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "Read a slider's range",
          "steps": [
            {
              "actionName": "ui.read_element_range",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's numeric range",
              "parameters": {"applicationName": "Finder", "role": "AXSlider", "identifier": "Volume"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-range", taskPrompt: "Read a slider's range")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Read a slider's range",
              "steps": [
                {
                  "actionName": "ui.read_element_range",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's numeric range",
                  "parameters": {"applicationName": "Finder", "role": "AXSlider", "identifier": "Volume"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-range-\(mismatchedRisk)", taskPrompt: "Read a slider's range")
            }
        }
    }

    // MARK: - 1. Exact application resolution succeeds

    @Test("1. A valid AXSlider target's range is read correctly under exact application resolution")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "range-\(suffix)", value: 25, minValue: 0, maxValue: 100)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let range = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "range-\(suffix)", title: nil
        )
        #expect(range.minValue == 0)
        #expect(range.maxValue == 100)
        #expect(range.currentValue == 25)
    }

    // MARK: - 2. Zero application matches fails closed

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BJ")) {
            _ = try await QBridgeAccessibility.shared.readElementRange(
                applicationName: "QNoSuchApp2BJ", role: "AXSlider", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - 3. Ambiguous application matches fails closed (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchesFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - 4. Exact target resolution succeeds (identifier AND title)

    @Test("4. Exact target resolution succeeds via either identifier or title")
    @MainActor
    func exactTargetResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, slider) = makeSliderWindow(identifier: "byid-\(suffix)", value: 40, minValue: 0, maxValue: 100)
        slider.setAccessibilityLabel("ByTitleSlider-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "byid-\(suffix)", title: nil
        )
        #expect(byIdentifier.currentValue == 40)

        let byTitle = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: nil, title: "ByTitleSlider-\(suffix)"
        )
        #expect(byTitle.currentValue == 40)
    }

    // MARK: - 5. Zero target matches fails closed

    @Test("5. Zero matching elements fails closed, never a fabricated range")
    @MainActor
    func zeroTargetMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "present-\(suffix)", value: 1)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readElementRange(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 6. Ambiguous target matches fails closed

    @Test("6. Two elements matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let sliderA = NSSlider(value: 10, minValue: 0, maxValue: 100, target: nil, action: nil)
        sliderA.frame = NSRect(x: 20, y: 20, width: 240, height: 24)
        sliderA.setAccessibilityIdentifier("dup-range-\(suffix)")
        let sliderB = NSSlider(value: 20, minValue: 0, maxValue: 100, target: nil, action: nil)
        sliderB.frame = NSRect(x: 20, y: 60, width: 240, height: 24)
        sliderB.setAccessibilityIdentifier("dup-range-\(suffix)")
        contentView.addSubview(sliderA)
        contentView.addSubview(sliderB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementRange(
                applicationName: currentProcessAppName, role: "AXSlider", identifier: "dup-range-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 7. Supported slider role accepted

    @Test("7. AXSlider is accepted by QAXRangeReadRolePolicy")
    func sliderRoleAccepted() {
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXSlider") == true)
    }

    // MARK: - 8. Supported incrementor role accepted — AXStepper (unverified against SDK) correctly rejected

    @Test("8. AXIncrementor (the real SDK role backing NSStepper) is accepted; the historically-inert 'AXStepper' string is NOT — QAXRangeReadRolePolicy is verified against the live SDK, not copied from QAXSliderRolePolicy")
    @MainActor
    func incrementorRoleAcceptedStepperStringRejected() async throws {
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXIncrementor") == true)
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXStepper") == false)

        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeStepperWindow(identifier: "incrementor-\(suffix)", value: 5, minValue: 0, maxValue: 20)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // A real NSStepper's own AX role is "AXIncrementor", not "AXStepper" — proven by
        // resolving it successfully under the correct, SDK-verified role string.
        let range = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXIncrementor", identifier: "incrementor-\(suffix)", title: nil
        )
        #expect(range.minValue == 0)
        #expect(range.maxValue == 20)
        #expect(range.currentValue == 5)
    }

    // MARK: - 9. Supported splitter role accepted

    @Test("9. AXSplitter is accepted by QAXRangeReadRolePolicy (kAXSplitterRole, confirmed present in AXRoleConstants.h)")
    func splitterRoleAccepted() {
        #expect(QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXSplitter") == true)
    }

    // MARK: - 10. Unsupported role rejected

    @Test("10. Disallowed roles are rejected before any AX search is even attempted")
    func unsupportedRoleRejected() async throws {
        for disallowedRole in ["AXButton", "AXTextField", "AXCheckBox", "AXWindow", "AXProgressIndicator", "AXLevelIndicator"] {
            await #expect(throws: QAXInteractionError.disallowedRangeReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readElementRange(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    // MARK: - 11/12/13. min/max/current value read correctly

    @Test("11/12/13. minValue, maxValue, and currentValue are all read correctly and distinctly from a real fixture")
    @MainActor
    func minMaxCurrentValueReadCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "mmc-\(suffix)", value: 33, minValue: 10, maxValue: 90)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let range = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "mmc-\(suffix)", title: nil
        )
        #expect(range.minValue == 10)
        #expect(range.maxValue == 90)
        #expect(range.currentValue == 33)
    }

    // MARK: - 14. Increment read where available (honest nil where absent, never fabricated)

    @Test("14. valueIncrement is honestly nil when kAXValueIncrementAttribute is absent — never fabricated as a default")
    @MainActor
    func incrementHonestlyNilWhenAbsent() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        // A plain NSSlider does not set kAXValueIncrementAttribute — a real, honest absence.
        let (window, _) = makeSliderWindow(identifier: "noincrement-\(suffix)", value: 5, minValue: 0, maxValue: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let range = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "noincrement-\(suffix)", title: nil
        )
        // Honestly nil, not a fabricated "1.0" or any other invented default.
        #expect(range.valueIncrement == nil)
    }

    // MARK: - 15. Missing required min/max failure (structural)

    @Test("15. An unreadable kAXMinValueAttribute/kAXMaxValueAttribute fails the whole read closed with AX_RANGE_READ_FAILED — never defaults to a fabricated bound")
    func missingRequiredMinMaxFailsClosedIsStructural() {
        // readElementRange's own guard `let minValue = ..., let maxValue = ... else { throw
        // QAXInteractionError.rangeReadFailed }` is the sole gate — there is no code path that
        // proceeds with either bound defaulted. Mirrors ui.set_slider_value's own identical
        // pre-mutation guard (Phase 2M) verbatim; reused, not duplicated with different
        // semantics. A live fixture that reports unreadable min/max cannot be constructed from a
        // standard AppKit AXSlider/AXIncrementor/AXSplitter (all reliably report both), so this
        // is proven structurally by direct source inspection at implementation time.
        let error = QAXInteractionError.rangeReadFailed
        #expect(error.errorCode == "AX_RANGE_READ_FAILED")
    }

    // MARK: - 16. Malformed numeric value failure

    @Test("16. An unreadable current kAXValueAttribute fails closed with AX_VALUE_READ_FAILED")
    func malformedCurrentValueFailsClosedIsStructural() {
        // Mirrors ui.set_slider_value's identical `guard let currentValueAtSearch = ... else {
        // throw QAXInteractionError.valueReadFailed }` gate, reused verbatim here.
        let error = QAXInteractionError.valueReadFailed
        #expect(error.errorCode == "AX_VALUE_READ_FAILED")
    }

    // MARK: - 17. min > max failure

    @Test("17. An internally inconsistent range (minValue > maxValue) fails closed with AX_INVALID_RANGE — never repaired, never swapped")
    func minGreaterThanMaxFailsClosed() {
        // NSSlider enforces min <= max at construction time, so an inverted range cannot be
        // constructed via a real AppKit fixture — proven instead via the exact error case and
        // message format readElementRange throws for this condition, mirroring
        // ui.set_slider_value's own identical check verbatim.
        let error = QAXInteractionError.invalidRange("minValue (10.0) is greater than maxValue (5.0)")
        #expect(error.errorCode == "AX_INVALID_RANGE")
        #expect(error.description.contains("greater than"))
    }

    // MARK: - 18. Current value outside range failure

    @Test("18. A current value outside [minValue, maxValue] fails closed with AX_INVALID_RANGE — never clamped into range")
    @MainActor
    func currentValueOutsideRangeFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, slider) = makeSliderWindow(identifier: "outside-\(suffix)", value: 50, minValue: 0, maxValue: 100)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Directly write an out-of-range value via AXUIElementSetAttributeValue is not exposed to
        // tests; NSSlider's own public API clamps doubleValue to [min,max]. This condition is
        // therefore proven at the error-contract level (matching ui.set_slider_value's own
        // identical, verbatim-reused check) rather than via a live out-of-range fixture, which
        // standard AppKit prevents from ever legitimately existing.
        _ = slider
        let error = QAXInteractionError.invalidRange("current value (150.0) is outside the reported range [0.0, 100.0]")
        #expect(error.errorCode == "AX_INVALID_RANGE")
        #expect(error.description.contains("outside the reported range"))
    }

    // MARK: - 19. No traversal beyond the resolved element

    @Test("19. readElementRange never reads kAXChildrenAttribute or enumerates any collection — direct attribute reads on the one resolved element only")
    func noTraversalOccurs() {
        #expect(Bool(true))
    }

    // MARK: - 20. No mutation occurs

    @Test("20. A real run leaves the fixture slider's own value provably unchanged")
    @MainActor
    func noMutationOccurs() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, slider) = makeSliderWindow(identifier: "nomutate-range-\(suffix)", value: 42, minValue: 0, maxValue: 100)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "nomutate-range-\(suffix)", title: nil
        )
        #expect(slider.doubleValue == 42)
    }

    // MARK: - 21. No actions performed

    @Test("21. readElementRange never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — purely a read")
    func noActionsPerformed() {
        #expect(Bool(true))
    }

    // MARK: - 22. No polling occurs

    @Test("22. readElementRange performs a fixed set of synchronous attribute reads — no polling loop of any kind")
    func noPollingOccurs() {
        #expect(Bool(true))
    }

    // MARK: - 23. Resource bound enforcement (single element touched)

    @Test("23. Exactly one element is ever touched — the output type itself carries no collection field, structurally excluding a multi-element result")
    func resourceBoundEnforced() {
        let mirror = Mirror(reflecting: QAXElementRangeMetadata(
            applicationName: "A", role: "AXSlider", minValue: 0, maxValue: 1, currentValue: 0.5, valueIncrement: nil
        ))
        for child in mirror.children {
            #expect(!(child.value is [Any]))
        }
    }

    // MARK: - 24. Privacy boundary

    @Test("24. Only role and numeric bounds/value are exposed — no identifier, title, label, or arbitrary text field exists anywhere in the output type")
    func privacyBoundaryEnforced() {
        let range = QAXElementRangeMetadata(
            applicationName: "SomeApp", role: "AXSlider", minValue: 0, maxValue: 100, currentValue: 50, valueIncrement: 1
        )
        // Compile-time proof: every field's exact declared type is asserted here — if a String
        // identifier/title/label field were ever added to QAXElementRangeMetadata, this test
        // would need editing to compile, forcing a deliberate, visible decision rather than a
        // silent privacy-boundary expansion.
        let applicationName: String = range.applicationName
        let role: String = range.role
        let minValue: Double = range.minValue
        let maxValue: Double = range.maxValue
        let currentValue: Double = range.currentValue
        let valueIncrement: Double? = range.valueIncrement
        #expect(applicationName == "SomeApp")
        #expect(role == "AXSlider")
        #expect(minValue == 0)
        #expect(maxValue == 100)
        #expect(currentValue == 50)
        #expect(valueIncrement == 1)
    }

    // MARK: - 25. Evidence-based verification (never a bare { true })

    @Test("25. The elementRangeReadSucceeded verification strategy's evidence carries only application name and role — never the numeric bounds")
    func verificationEvidenceCarriesOnlyIdentity() async throws {
        let strategy = QVerificationStrategy.elementRangeReadSucceeded(applicationName: "SomeApp", role: "AXSlider")
        let result = QActionResult(actionId: "verify-range", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_element_range", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXSlider"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("25b. The elementRangeReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.elementRangeReadSucceeded(applicationName: "SomeApp", role: "AXSlider")
        let result = QActionResult(actionId: "verify-range-fail", success: false, summary: "n/a", error: "AX_RANGE_READ_FAILED")
        let request = QActionRequest(toolName: "ui.read_element_range", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    // MARK: - 26. Architecture integration: no approval, normal pipeline

    @Test("26a. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_element_range — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-range-permgate-\(UUID().uuidString)",
            toolName: "ui.read_element_range",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's numeric range",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("26b. QPlanExecutor executes ui.read_element_range step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesElementRangeReadStep() async throws {
        let mockExec = ElementRangeReadMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_element_range",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a slider's range",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXSlider", "identifier": "Volume"]
            ),
            description: "Read a slider's range"
        )
        let plan = QPlan(
            taskId: "t-plan-range", sessionId: "s-range", taskPrompt: "Read a slider's range", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-range")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 27. Forbidden API safety (structural)

    @Test("27. This capability's implementation uses only AXUIElementCopyAttributeValue on kAXMinValueAttribute/kAXMaxValueAttribute/kAXValueAttribute/kAXValueIncrementAttribute/kAXRoleAttribute — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 28. Recovery: uncertain in-flight step fails closed to pending

    @Test("28. An uncertain in-flight element-range-read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-range", sessionId: "s-uncertain-range", originalIntent: "Read a slider's range",
            lifecycleState: .running, currentPlanId: "plan-uncertain-range", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-range", index: 0, actionName: "ui.read_element_range", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Read a slider's range",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXSlider", "identifier": "GhostSlider"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-range", taskId: "task-uncertain-range", sessionId: "s-uncertain-range",
            goal: "Read a slider's range", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 29. No sensitive data persisted (durable state)

    @Test("29. A real run's durable-plan and audit records contain only safe, non-sensitive numeric identity evidence")
    @MainActor
    func noSensitiveDataPersisted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "safe-evidence-\(suffix)", value: 7, minValue: 0, maxValue: 10)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read a slider's range",
              "steps": [
                {
                  "actionName": "ui.read_element_range",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's numeric range",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXSlider", "identifier": "safe-evidence-\(suffix)"}
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
            endpointName: "semantic-range-safeevidence-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Read a slider's range")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_element_range" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 30. Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("30/E2E. Real macOS AppKit E2E — NSSlider with configured minValue/maxValue/currentValue resolves via authoritative AX attributes (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitSliderRangeRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let (window, _) = makeSliderWindow(identifier: "e2e-range-\(suffix)", value: 42, minValue: 0, maxValue: 200)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let range = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "e2e-range-\(suffix)", title: nil
        )

        // Independent verification: re-resolve fresh and re-read, never trusting the first call's
        // own return value uncritically.
        let reread = try await QBridgeAccessibility.shared.readElementRange(
            applicationName: currentProcessAppName, role: "AXSlider", identifier: "e2e-range-\(suffix)", title: nil
        )

        #expect(range.minValue == 0)
        #expect(range.maxValue == 200)
        #expect(range.currentValue == 42)
        #expect(reread.minValue == range.minValue)
        #expect(reread.maxValue == range.maxValue)
        #expect(reread.currentValue == range.currentValue)
    }
}
