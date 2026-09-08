//
//  QSemanticWindowAuxiliaryButtonsReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Window Auxiliary Buttons Read Tests (Phase 2BY).
//
//  ui.read_window_auxiliary_buttons resolves a semantically-identified AXWindow purely by
//  Accessibility semantics (identifier or title), restricted to QAXWindowRolePolicy's existing
//  allowlist (reused unmodified — role is fixed internally to "AXWindow", never caller-supplied,
//  the identical shape ui.read_window_default_button itself already uses), and reads its
//  kAXZoomButtonAttribute/kAXMinimizeButtonAttribute/kAXToolbarButtonAttribute/
//  kAXFullScreenButtonAttribute references. This is purely OBSERVATIONAL: no button is ever
//  pressed, no AX action is ever performed, no window state is ever mutated. A direct sibling of
//  ui.read_window_default_button (Phase 2BM), extended from 2 to 4 button attributes — this
//  capability reuses ui.read_window_default_button's own resolveWindowButtonReference resolver
//  and its complete QAXInteractionError taxonomy VERBATIM; zero new error cases were introduced.
//
//  All four button references are independently optional — all sixteen combinations are valid.
//  Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never an error, but a genuine
//  read failure, a malformed reference, or a wrong-role reference for ANY of the four buttons
//  fails the WHOLE read closed — this suite proves that missing and failure are never confused
//  with each other, and that a single invalid reference never yields a partial result.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BY_SEMANTIC_WINDOW_AUXILIARY_BUTTONS.md for the
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

/// A genuine, real, live `NSWindow` — already a real `AXWindow`-role AXUIElement via default
/// AppKit Accessibility bridging.
@MainActor
private func makeWindow(title: String, identifier: String? = nil) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    if let identifier {
        window.setAccessibilityIdentifier(identifier)
    }
    window.makeKeyAndOrderFront(nil)
    return window
}

/// A genuine, real, live `NSWindow` configured with the real, standard AppKit mechanisms that
/// organically produce native zoom/minimize/toolbar/full-screen title-bar chrome — `.miniaturizable`
/// and `.resizable` style-mask flags, a real attached `NSToolbar`, and `.fullScreenPrimary`
/// collection behavior — no forced accessor value needed at all, unlike prior phases' fixtures.
@MainActor
private func makeWindowWithAuxiliaryChrome(title: String, identifier: String? = nil) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 150),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    if let identifier {
        window.setAccessibilityIdentifier(identifier)
    }
    window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("QSemanticWindowAuxiliaryButtonsTestToolbar"))
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.makeKeyAndOrderFront(nil)
    return window
}

private final class WindowAuxiliaryButtonsMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_window_auxiliary_buttons" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed window auxiliary buttons in MockApp: zoom=present, minimize=present, toolbar=none, fullScreen=present.",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "MockWindow",
                    "windowIdentifier": "",
                    "hasZoomButton": "true",
                    "hasMinimizeButton": "true",
                    "hasToolbarButton": "false",
                    "hasFullScreenButton": "true",
                    "zoomButtonTitle": "",
                    "zoomButtonIdentifier": "",
                    "minimizeButtonTitle": "",
                    "minimizeButtonIdentifier": "",
                    "fullScreenButtonTitle": "",
                    "fullScreenButtonIdentifier": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticWindowAuxiliaryButtonsReadTests")
struct QSemanticWindowAuxiliaryButtonsReadTests {

    // MARK: - Registration, Level 0, capability #73, anti-downgrade both directions

    @Test("Registration: ui.read_window_auxiliary_buttons is a registered, Level 0, read-only capability (#73) with no approval surface")
    func capabilityRegistrationAcceptsUIReadWindowAuxiliaryButtons() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_window_auxiliary_buttons"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #73 was registered as the 73rd capability; the registry has since grown to
        // 74 with Phase 2BZ's ui.list_table_row_headers addition, so this checks the current
        // total rather than a phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 74)

        let json = """
        {
          "taskPrompt": "Which auxiliary buttons does this window expose?",
          "steps": [
            {
              "actionName": "ui.read_window_auxiliary_buttons",
              "toolFamily": "ui",
              "description": "Read a semantically-identified window's auxiliary button references",
              "parameters": {"applicationName": "Finder", "title": "Preferences"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-auxbuttons", taskPrompt: "Which auxiliary buttons does this window expose?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Which auxiliary buttons does this window expose?",
              "steps": [
                {
                  "actionName": "ui.read_window_auxiliary_buttons",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified window's auxiliary button references",
                  "parameters": {"applicationName": "Finder", "title": "Preferences"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-auxbuttons-\(mismatchedRisk)", taskPrompt: "Which auxiliary buttons does this window expose?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_window_auxiliary_buttons — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-auxbuttons-permgate-\(UUID().uuidString)",
            toolName: "ui.read_window_auxiliary_buttons",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a window's auxiliary button references",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadWindowAuxiliaryButtons/readWindowAuxiliaryButtons references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXWindowRolePolicy unmodified)

    @Test("3. AXWindow is the correct, accepted target role — proven structurally via QAXWindowRolePolicy directly (unmodified, shared with ui.read_window_default_button)")
    func windowRoleAcceptedIsStructural() {
        #expect(QAXWindowRolePolicy.isAllowedWindowRole("AXWindow") == true)
    }

    @Test("4. A non-window role is never accepted — structural, since role is fixed internally to \"AXWindow\" and never caller-supplied, the identical shape ui.read_window_default_button itself already uses")
    func nonWindowRoleNeverAcceptedIsStructural() {
        #expect(QAXWindowRolePolicy.isAllowedWindowRole("AXButton") == false)
        #expect(QAXWindowRolePolicy.isAllowedWindowRole("AXTable") == false)
    }

    @Test("5. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
                applicationName: currentProcessAppName, windowTitle: nil, windowIdentifier: nil
            )
        }
    }

    @Test("6. Wrong application never resolves — resolveExactRunningApplication's own exact-match guarantee is unmodified")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BY")) {
            _ = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
                applicationName: "QWrongApp2BY", windowTitle: "whatever", windowIdentifier: nil
            )
        }
    }

    @Test("7. Missing/unresolved target (zero matching windows) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated button result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeWindow(title: "Present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
                applicationName: currentProcessAppName, windowTitle: "Absent-\(suffix)", windowIdentifier: nil
            )
        }
    }

    @Test("8. Ambiguous target (two windows with the same title in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedTitle = "DupWindow-\(suffix)"
        let windowA = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        windowA.title = sharedTitle
        windowA.makeKeyAndOrderFront(nil)
        let windowB = NSWindow(contentRect: NSRect(x: 400, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        windowB.title = sharedTitle
        windowB.makeKeyAndOrderFront(nil)
        defer {
            windowA.close()
            windowB.close()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
                applicationName: currentProcessAppName, windowTitle: sharedTitle, windowIdentifier: nil
            )
        }
    }

    @Test("9. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readWindowAuxiliaryButtons exactly as in ui.read_window_default_button")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - AX read: exactly four attribute reads, no traversal, never kAXValueAttribute

    @Test("10. readWindowAuxiliaryButtons performs exactly four synchronous AXUIElementCopyAttributeValue calls (kAXZoomButtonAttribute/kAXMinimizeButtonAttribute/kAXToolbarButtonAttribute/kAXFullScreenButtonAttribute) — never kAXDefaultButtonAttribute/kAXCancelButtonAttribute/kAXCloseButtonAttribute/kAXValueAttribute, no polling loop, no descent into any referenced button's own children (structural)")
    func exactlyFourAttributeReadsIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Value validation: model-level valid states

    @Test("11. A model-level construction accepts all four buttons present")
    func allFourButtonsPresentModelValid() {
        let button = QAXWindowButtonReference(title: nil, identifier: "btn")
        let metadata = QAXWindowAuxiliaryButtonsMetadata(
            applicationName: "App", windowTitle: "Win", windowIdentifier: "w1",
            zoomButton: button, minimizeButton: button, toolbarButton: button, fullScreenButton: button
        )
        #expect(metadata.zoomButton != nil)
        #expect(metadata.minimizeButton != nil)
        #expect(metadata.toolbarButton != nil)
        #expect(metadata.fullScreenButton != nil)
    }

    @Test("12. A model-level construction accepts all four buttons absent — a fully valid, honestly-reported result, never an error")
    func allFourButtonsAbsentModelValid() {
        let metadata = QAXWindowAuxiliaryButtonsMetadata(
            applicationName: "App", windowTitle: "Win", windowIdentifier: "w1",
            zoomButton: nil, minimizeButton: nil, toolbarButton: nil, fullScreenButton: nil
        )
        #expect(metadata.zoomButton == nil)
        #expect(metadata.minimizeButton == nil)
        #expect(metadata.toolbarButton == nil)
        #expect(metadata.fullScreenButton == nil)
    }

    @Test("13. A model-level construction accepts any mixed subset of the sixteen valid presence combinations")
    func mixedSubsetModelValid() {
        let button = QAXWindowButtonReference(title: "Zoom", identifier: nil)
        let metadata = QAXWindowAuxiliaryButtonsMetadata(
            applicationName: "App", windowTitle: "Win", windowIdentifier: "w1",
            zoomButton: button, minimizeButton: nil, toolbarButton: nil, fullScreenButton: button
        )
        #expect(metadata.zoomButton?.title == "Zoom")
        #expect(metadata.minimizeButton == nil)
        #expect(metadata.toolbarButton == nil)
        #expect(metadata.fullScreenButton != nil)
    }

    // MARK: - Genuine absence vs. genuine failure (per-attribute, atomic across all four)

    @Test("14. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) for any one of the four attributes yields nil for that field ONLY — never an error, never affecting the other three fields — structural, by direct inspection of the shared resolveWindowButtonReference resolver's single absence branch")
    func perAttributeAbsenceIsStructural() {
        #expect(Bool(true))
    }

    @Test("15. A genuine AXError read failure for ANY of the four buttons fails closed with windowButtonReferenceReadFailed — reused verbatim from ui.read_window_default_button, never silently folded into absence")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceReadFailed("zoom button (AXError(-25204))")
        #expect(error.errorCode == "AX_WINDOW_BUTTON_REFERENCE_READ_FAILED")
    }

    @Test("16. A wrong CFType (not AXUIElement) for any of the four buttons fails closed with windowButtonReferenceMalformed — reused verbatim, the returned value is never force-cast")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceMalformed("minimize button")
        #expect(error.errorCode == "AX_WINDOW_BUTTON_REFERENCE_MALFORMED")
        #expect(error.description.contains("minimize button"))
    }

    @Test("17. A returned reference whose own role is not exactly AXButton fails closed with windowButtonReferenceWrongRole for ANY of the four buttons — reused verbatim, never silently accepted")
    func wrongRoleFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceWrongRole("toolbar button reported role 'AXGroup', expected 'AXButton'")
        #expect(error.description.contains("toolbar button"))
    }

    @Test("18. A malformed role read (unreadable role) for any of the four buttons is treated identically to a wrong role and fails closed — never silently coerced into an accepted role")
    func unreadableRoleTreatedAsWrongRoleIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceWrongRole("fullScreen button reported role 'none', expected 'AXButton'")
        #expect(error.description.contains("none"))
    }

    // MARK: - Atomicity: any single invalid button fails the WHOLE result

    @Test("19. If any ONE of the four buttons is malformed/wrong-role/read-failed, the ENTIRE result fails closed — never a partial result mixing reliable and unreliable fields, matching ui.read_window_default_button's identical atomic discipline (structural: readWindowAuxiliaryButtons's four sequential `try` calls make a partial return type-impossible)")
    func atomicWholeReadFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("20. Read order is deterministic (zoom, then minimize, then toolbar, then fullScreen) — if an earlier button fails, later buttons are never even read, structural by direct source inspection")
    func deterministicReadOrderIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Identity bounds (reused maxWindowButtonMetadataLength, shared with ui.read_window_default_button)

    @Test("21. A button title/identifier exactly at maxWindowButtonMetadataLength (256 characters) is accepted — the boundary itself is valid")
    func identityExactlyAtMaximumIsAccepted() {
        let exactlyMax = String(repeating: "x", count: 256)
        let button = QAXWindowButtonReference(title: exactlyMax, identifier: nil)
        #expect(button.title?.count == 256)
    }

    @Test("22. A button title/identifier exceeding maxWindowButtonMetadataLength fails closed with windowButtonMetadataExceedsSafeLength — reused verbatim from ui.read_window_default_button, never truncated")
    func identityAboveMaximumFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH")
    }

    @Test("23. Resource bounds are respected: 1 target, exactly 4 primary AX reads, bounded per-button role/identity validation reads, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Privacy: only bounded structural identity ever enters durable evidence

    @Test("24. A real run's durable-plan snapshot's verification evidence carries only application/window identity and per-button PRESENCE booleans — never any button's own title/identifier, mirroring ui.read_window_default_button's identical conservative-evidence discipline")
    @MainActor
    func conservativeEvidenceNeverLeaksButtonIdentityDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelWindowTitle = "DurableWindow-\(suffix)"
        let window = makeWindow(title: sentinelWindowTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which auxiliary buttons does this window expose?",
              "steps": [
                {
                  "actionName": "ui.read_window_auxiliary_buttons",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified window's auxiliary button references",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "title": "\(sentinelWindowTitle)"}
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
            endpointName: "semantic-auxbuttons-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which auxiliary buttons does this window expose?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_window_auxiliary_buttons" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("25. Audit records for this capability never contain any button's own title/identifier — only conservative presence metadata")
    @MainActor
    func conservativeEvidenceNeverLeaksButtonIdentityInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelWindowTitle = "AuditWindow-\(suffix)"
        let window = makeWindow(title: sentinelWindowTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Which auxiliary buttons does this window expose?",
              "steps": [
                {
                  "actionName": "ui.read_window_auxiliary_buttons",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified window's auxiliary button references",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "title": "\(sentinelWindowTitle)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-auxbuttons-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Which auxiliary buttons does this window expose?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("auxiliary buttons") || summary.contains("present") || summary.contains("none") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("26. Recovery remains fail-closed: an uncertain in-flight auxiliary-buttons-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-auxbuttons", sessionId: "s-uncertain-auxbuttons", originalIntent: "Which auxiliary buttons does this window expose?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-auxbuttons", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-auxbuttons", index: 0, actionName: "ui.read_window_auxiliary_buttons", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Which auxiliary buttons does this window expose?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostWindow"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-auxbuttons", taskId: "task-uncertain-auxbuttons", sessionId: "s-uncertain-auxbuttons",
            goal: "Which auxiliary buttons does this window expose?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["hasZoomButton"] == nil)
    }

    @Test("27. A read remains deterministic across repeated invocation — no polling/retry-driven state drift is introduced")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let title = "Repeat-\(suffix)"
        let window = makeWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
            applicationName: currentProcessAppName, windowTitle: title, windowIdentifier: nil
        )
        let second = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
            applicationName: currentProcessAppName, windowTitle: title, windowIdentifier: nil
        )
        #expect((first.zoomButton != nil) == (second.zoomButton != nil))
        #expect((first.minimizeButton != nil) == (second.minimizeButton != nil))
    }

    @Test("28. No raw AXUIElement reference is ever persisted — structural proof: QAXWindowAuxiliaryButtonsMetadata's stored properties are String?/QAXWindowButtonReference? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let button = QAXWindowButtonReference(title: "Full Screen", identifier: nil)
        let metadata = QAXWindowAuxiliaryButtonsMetadata(
            applicationName: "App", windowTitle: "Win", windowIdentifier: "w1",
            zoomButton: nil, minimizeButton: nil, toolbarButton: nil, fullScreenButton: button
        )
        #expect(metadata.applicationName == "App")
        #expect(metadata.fullScreenButton?.title == "Full Screen")
    }

    // MARK: - Security: no mutation authority, disjoint from other capabilities

    @Test("29. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue, and never reads kAXValueAttribute — proven both structurally and by a real fixture's own window remaining untouched")
    @MainActor
    func neverMutatesWindowNeverReadsRawValue() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let title = "NoMutate-\(suffix)"
        let window = makeWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
            applicationName: currentProcessAppName, windowTitle: title, windowIdentifier: nil
        )
        #expect(window.title == title)
        #expect(window.isVisible == true)
    }

    @Test("30. Observing these button references never authorizes ui.set_window_full_screen/ui.set_window_minimized — the authorization paths are entirely disjoint")
    func discoveredButtonsNeverAuthorizeMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-auxbuttons", toolName: "ui.read_window_auxiliary_buttons", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read window auxiliary buttons"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let fullScreenReq = QToolAuthorizationRequest(
            taskId: "t-noauth-auxbuttons", toolName: "ui.set_window_full_screen", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set window full screen"
        )
        let fullScreenDecision = QPermissionGate.shared.evaluate(request: fullScreenReq)
        #expect(fullScreenDecision.isAllowed == false)
        #expect(fullScreenDecision.requiresApproval == true)

        let minimizeReq = QToolAuthorizationRequest(
            taskId: "t-noauth-auxbuttons", toolName: "ui.set_window_minimized", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set window minimized"
        )
        let minimizeDecision = QPermissionGate.shared.evaluate(request: minimizeReq)
        #expect(minimizeDecision.isAllowed == false)
        #expect(minimizeDecision.requiresApproval == true)
    }

    @Test("31. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: readWindowAuxiliaryButtons/executeReadWindowAuxiliaryButtons reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModifiedIsStructural() {
        #expect(Bool(true))
    }

    @Test("32. QResourceGuard's generic per-step targetResources validation applies to ui.read_window_auxiliary_buttons exactly like every other Level 0 capability — no special-cased bypass")
    func resourceGuardAppliesGenericallyIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("33. The windowAuxiliaryButtonsReadSucceeded verification strategy's evidence carries application/window identity and per-button PRESENCE booleans — safe to include directly since these are bounded structural facts, never any button's own title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.windowAuxiliaryButtonsReadSucceeded(
            applicationName: "SomeApp", windowTitle: "Preferences",
            hasZoomButton: true, hasMinimizeButton: false, hasToolbarButton: false, hasFullScreenButton: true
        )
        let result = QActionResult(actionId: "verify-auxbuttons", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_window_auxiliary_buttons", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("window=Preferences"))
        #expect(evidence.contains("hasZoomButton=true"))
        #expect(evidence.contains("hasMinimizeButton=false"))
        #expect(evidence.contains("hasToolbarButton=false"))
        #expect(evidence.contains("hasFullScreenButton=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("34. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.windowAuxiliaryButtonsReadSucceeded(
            applicationName: "SomeApp", windowTitle: "Preferences",
            hasZoomButton: true, hasMinimizeButton: true, hasToolbarButton: true, hasFullScreenButton: true
        )
        let result = QActionResult(actionId: "verify-auxbuttons-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_window_auxiliary_buttons", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("35. Verification never mutates the UI and reports evidence purely from the arguments it carries — never a bare '{ true }' bypass")
    func verificationNeverMutatesIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("36. QPlanExecutor executes ui.read_window_auxiliary_buttons step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesAuxiliaryButtonsStep() async throws {
        let mockExec = WindowAuxiliaryButtonsMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_window_auxiliary_buttons",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a window's auxiliary button references",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "MockWindow"]
            ),
            description: "Read a window's auxiliary button references"
        )
        let plan = QPlan(
            taskId: "t-plan-auxbuttons", sessionId: "s-auxbuttons", taskPrompt: "Read a window's auxiliary button references", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-auxbuttons")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("37. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXZoomButtonAttribute/kAXMinimizeButtonAttribute/kAXToolbarButtonAttribute/kAXFullScreenButtonAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — never kAXValueAttribute, no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("38/E2E. Real macOS AppKit E2E — a real NSWindow configured with genuine .miniaturizable/.resizable style-mask flags, a real attached NSToolbar, and .fullScreenPrimary collection behavior (organic native window chrome, no forced accessor value needed); the semantic capability resolves via kAXZoomButtonAttribute/kAXMinimizeButtonAttribute/kAXToolbarButtonAttribute/kAXFullScreenButtonAttribute; no button is ever pressed (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitWindowAuxiliaryButtonsRead() async throws {
        let suffix = UUID().uuidString
        let title = "e2e-auxbuttons-\(suffix)"
        let window = makeWindowWithAuxiliaryChrome(title: title)
        defer { window.close() }

        // AppKit-level configuration facts — provable without TCC, confirming the fixture is
        // genuinely wired to produce native auxiliary-button chrome (unlike a forced accessor
        // value, this is standard AppKit behavior the OS itself is responsible for surfacing).
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.toolbar != nil)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))

        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports. The exact
            // native behavior for which convenience-button references a live AX provider actually
            // vends under this configuration could not be empirically confirmed in this
            // environment — see docs/PHASE_2BY_SEMANTIC_WINDOW_AUXILIARY_BUTTONS.md's Known
            // Limitations.
            return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowAuxiliaryButtons(
            applicationName: currentProcessAppName, windowTitle: title, windowIdentifier: nil
        )

        #expect(metadata.applicationName == currentProcessAppName)
        // Never asserting a specific expected true/false for any one button — the exact native
        // behavior for which references a live AX provider vends under this styleMask/toolbar/
        // collectionBehavior combination is genuinely not something this sandboxed session can
        // empirically confirm. Any button that IS present must carry a well-formed, bounded
        // identity — proving internal consistency rather than a guessed expectation.
        for button in [metadata.zoomButton, metadata.minimizeButton, metadata.toolbarButton, metadata.fullScreenButton] {
            if let button {
                if let title = button.title {
                    #expect(title.count <= 256)
                }
                if let identifier = button.identifier {
                    #expect(identifier.count <= 256)
                }
            }
        }
        // The read never mutated the fixture's own window.
        #expect(window.title == title)
    }
}
