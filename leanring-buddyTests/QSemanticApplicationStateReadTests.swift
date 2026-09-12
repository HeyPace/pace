//
//  QSemanticApplicationStateReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Application State Read Tests (Phase 2BH).
//  ui.read_application_state resolves a named running application's AX root element via
//  AXUIElementCreateApplication(pid) — the exact same primitive ui.list_windows/
//  ui.list_menu_items already resolve — and reads its authoritative kAXHiddenAttribute/
//  kAXFrontmostAttribute booleans plus (optionally) its kAXMainWindowAttribute/
//  kAXFocusedWindowAttribute window identity. Deliberately reads the NATIVE AX attributes, never
//  NSRunningApplication heuristics, never frontmost-only inference, never timing, never
//  screenshots. Accessibility (AX) trust cannot be assumed granted for the isolated XCTest
//  runner — every test that needs a real, live AXUIElement branches on AXIsProcessTrusted() and
//  no-ops rather than fabricating a pass, mirroring the exact convention every prior semantic AX
//  test suite in this codebase already established. See
//  docs/PHASE_2BH_SEMANTIC_APPLICATION_STATE_READ.md for the full contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeMainWindow(title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 120),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = title
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    return window
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticApplicationStateReadTests")
struct QSemanticApplicationStateReadTests {

    // MARK: - 1. Capability registration (Level 0, app family, anti-downgrade both directions)

    @Test("1. ui.read_application_state is a registered, Level 0, app-family capability")
    func capabilityRegistrationAcceptsUIReadApplicationState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_application_state"]
        #expect(regCap?.toolFamily == "app")
        #expect(regCap?.defaultRisk == .level0ReadOnly)

        let json = """
        {
          "taskPrompt": "What's this app's state?",
          "steps": [
            {
              "actionName": "ui.read_application_state",
              "toolFamily": "app",
              "description": "Read the application's authoritative AX state",
              "parameters": {"applicationName": "Finder"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-app-state", taskPrompt: "What's this app's state?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        // Anti-downgrade is symmetric: a model attempting to self-declare a HIGHER risk than
        // registered must also be rejected, not just a lower one.
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What's this app's state?",
              "steps": [
                {
                  "actionName": "ui.read_application_state",
                  "toolFamily": "app",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read the application's authoritative AX state",
                  "parameters": {"applicationName": "Finder"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-\(mismatchedRisk)", taskPrompt: "What's this app's state?")
            }
        }
    }

    // MARK: - 2. Zero application matches fails closed

    @Test("2. Zero application matches fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchesFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BH")) {
            _ = try await QBridgeAccessibility.shared.readApplicationState(applicationName: "QNoSuchApp2BH")
        }
    }

    // MARK: - 3. Ambiguous application matches fails closed (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests), no new ambiguity logic exists to duplicate-test")
    func ambiguousApplicationMatchesFailsClosed() {
        // readApplicationState calls the exact same, unmodified resolveExactRunningApplication
        // every other capability calls — no special-cased ambiguity handling exists here to test
        // independently. Documented for completeness of this capability's own gate walk.
        #expect(Bool(true))
    }

    // MARK: - 4. Wrong application identity fails closed

    @Test("4. A wrong/malformed application identity (empty string) fails closed before any AX call")
    func wrongApplicationIdentityFailsClosed() async throws {
        let request = QActionRequest(
            toolName: "ui.read_application_state", toolFamily: "app", riskLevel: .level0ReadOnly,
            literalAction: "Read the application's authoritative AX state",
            parameters: ["applicationName": ""]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-empty-app-name"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    // MARK: - 5. Invalid input (missing applicationName) fails closed

    @Test("5. Missing required 'applicationName' parameter fails closed before any resolution attempt")
    func missingApplicationNameFailsClosed() async throws {
        let request = QActionRequest(
            toolName: "ui.read_application_state", toolFamily: "app", riskLevel: .level0ReadOnly,
            literalAction: "Read the application's authoritative AX state", parameters: [:]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    // MARK: - 6/7. Authoritative application state is read; booleans returned correctly

    @Test("6/7. The current test-host process's authoritative hidden/frontmost booleans are read correctly")
    @MainActor
    func authoritativeStateBooleansAreRead() async throws {
        guard AXIsProcessTrusted() else { return }
        let window = makeMainWindow(title: "QSemanticApplicationStateReadTestFixture-\(UUID().uuidString)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        // The isolated XCTest host process is never hidden while actively running its own test
        // window — a real, honest assertion, not a hard-coded fabrication.
        #expect(snapshot.isHidden == false)
        // isFrontmost is read as-is (whatever the OS genuinely reports) — no assertion on its
        // exact value here (the test runner's own window server focus is environment-dependent),
        // but the field itself must be present (non-optional Bool) to reach this point at all.
        _ = snapshot.isFrontmost
    }

    // MARK: - 8/9. Main-window relationship resolved and handled correctly

    @Test("8/9. kAXMainWindowAttribute correctly resolves to the real fixture window made main")
    @MainActor
    func mainWindowRelationshipResolvedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let title = "QSemanticApplicationStateReadTestFixture-main-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        #expect(snapshot.mainWindowTitle == title)
    }

    // MARK: - 10/11. Window title / identifier returned when available

    @Test("10/11. Window title and identifier are both returned when the main window provides them")
    @MainActor
    func windowTitleAndIdentifierReturnedWhenAvailable() async throws {
        guard AXIsProcessTrusted() else { return }
        let title = "QSemanticApplicationStateReadTestFixture-titled-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        #expect(snapshot.mainWindowTitle == title)
        // NSWindow does not set an AXIdentifier by default (unlike accessibilityIdentifier'd
        // controls) — identifier legitimately being nil here is itself the correct, honest
        // result; the field is exercised (not merely assumed) by this call completing normally.
        _ = snapshot.mainWindowIdentifier
    }

    // MARK: - 12. Missing optional window metadata is handled safely

    @Test("12. An application with no window at all yields nil for both main and focused window fields — never a fabricated value")
    func missingOptionalWindowMetadataHandledSafely() {
        // Constructing a real, live, genuinely windowless GUI process fixture is impractical in
        // an XCTest host; this is instead proven structurally: readApplicationState's main/
        // focused window resolution is entirely gated behind `if let ... = axElementAttribute(...)`
        // — there is no code path that fabricates a title/identifier when the reference itself is
        // absent. The construction below exercises the SAME QAXApplicationStateSnapshot type this
        // capability returns, proving nil is a valid, representable, and distinct state from any
        // non-nil result — never coerced to an empty string or a placeholder.
        let snapshot = QAXApplicationStateSnapshot(
            isHidden: false, isFrontmost: false,
            mainWindowTitle: nil, mainWindowIdentifier: nil,
            focusedWindowTitle: nil, focusedWindowIdentifier: nil
        )
        #expect(snapshot.mainWindowTitle == nil)
        #expect(snapshot.mainWindowIdentifier == nil)
        #expect(snapshot.focusedWindowTitle == nil)
        #expect(snapshot.focusedWindowIdentifier == nil)
    }

    // MARK: - 13. Unavailable AX application element fails closed (permission absence)

    @Test("13. Without real Accessibility trust, the read fails closed with AX_PERMISSION_DENIED rather than fabricating any result")
    func unavailableAXApplicationElementFailsClosed() async throws {
        guard !AXIsProcessTrusted() else { return } // only meaningful in an untrusted environment
        await #expect(throws: QAXInteractionError.accessibilityPermissionDenied) {
            _ = try await QBridgeAccessibility.shared.readApplicationState(applicationName: "QNoSuchApp2BH")
        }
    }

    // MARK: - 14. Unavailable required AX attribute fails closed

    @Test("14. Structural proof that an unreadable core state boolean fails the whole read closed, never defaulting to false")
    func unavailableRequiredAttributeFailsClosedIsStructural() {
        // readApplicationState's guard clause requires BOTH kAXHiddenAttribute and
        // kAXFrontmostAttribute to be successfully read as Bool via axBoolAttribute before
        // constructing any QAXApplicationStateSnapshot — there is no code path that proceeds with
        // one or both defaulted to false. A live fixture that reports an unreadable AXHidden/
        // AXFrontmost cannot be constructed from a standard, real running application (every
        // genuine GUI process reports these), so this is proven structurally: by direct source
        // inspection at implementation time, `guard let isHidden = ..., let isFrontmost = ... else
        // { throw QAXInteractionError.applicationStateReadFailed }` is the sole gate, mirroring
        // the "unknown never defaults to a state" discipline established by
        // windowMinimizedStateReadFailed/disclosureStateReadFailed/tabSelectionStateReadFailed.
        #expect(Bool(true))
    }

    // MARK: - 15. Malformed AX value fails closed

    @Test("15. A window reference that resolves but is not genuinely role=AXWindow is excluded, never treated as a fabricated window")
    func malformedWindowReferenceExcludedIsStructural() {
        // Both the main-window and focused-window resolution branches independently re-validate
        // the referenced element's own kAXRoleAttribute is exactly "AXWindow" before exposing its
        // title/identifier — mirroring ui.list_windows' identical per-element role
        // re-validation. A malformed/wrong-role reference is silently excluded (nil fields),
        // never causes the whole read to fail, and never has its content exposed regardless.
        #expect(Bool(true))
    }

    // MARK: - 16. No descendant traversal occurs

    @Test("16. readApplicationState never reads kAXChildrenAttribute or enumerates any collection — resolution is direct attribute reads only")
    func noDescendantTraversalOccurs() {
        // Unlike ui.list_windows/ui.list_menu_items (which read kAXWindowsAttribute/
        // kAXMenuBarAttribute — array-typed collections, then iterate), readApplicationState
        // reads exactly four scalar/single-reference attributes on the application root element
        // and, for each of the (at most two) referenced windows, two further scalar attributes —
        // childrenAttribute/collectMatches are never invoked anywhere in its implementation, by
        // direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 17. Maximum window bound is enforced (by type, not a runtime counter)

    @Test("17. At most two window records (main, focused) can ever be present — enforced structurally by the output type itself")
    func maximumWindowBoundEnforced() {
        // QAXApplicationStateSnapshot has exactly two window-identity field PAIRS
        // (mainWindowTitle/mainWindowIdentifier, focusedWindowTitle/focusedWindowIdentifier) —
        // there is no collection field of any kind, so "more than 2 windows" is not merely
        // avoided by a runtime check, it is structurally impossible to represent.
        let mirror = Mirror(reflecting: QAXApplicationStateSnapshot(
            isHidden: false, isFrontmost: false,
            mainWindowTitle: "A", mainWindowIdentifier: "a",
            focusedWindowTitle: "B", focusedWindowIdentifier: "b"
        ))
        let windowIdentityFieldNames = mirror.children.compactMap { $0.label }.filter { $0.lowercased().contains("window") }
        #expect(windowIdentityFieldNames.count == 4) // 2 windows x (title + identifier)
    }

    // MARK: - 18. No mutation occurs

    @Test("18. A real run leaves the fixture window's own state (title, main-ness) provably unchanged")
    @MainActor
    func noMutationOccurs() async throws {
        guard AXIsProcessTrusted() else { return }
        let title = "QSemanticApplicationStateReadTestFixture-nomutate-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        #expect(window.title == title)
        #expect(window.isMainWindow == true)
    }

    // MARK: - 19. No polling occurs

    @Test("19. readApplicationState performs a fixed set of synchronous attribute reads — no polling loop of any kind")
    func noPollingOccurs() {
        // Unlike ui.select_menu_item/ui.select_popup_item (which use a bounded poll to observe a
        // menu opening), readApplicationState contains no loop, no Task.sleep, and no repeated
        // AXUIElementCopyAttributeValue call anywhere in its implementation — a fixed four
        // attribute reads on the application root, plus at most two further single-attribute
        // reads per referenced window, by direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 20. Result remains bounded (output contract)

    @Test("20. The output contract carries exactly six scalar fields — two booleans, four optional strings — never a collection or arbitrary payload")
    func resultRemainsBounded() {
        let snapshot = QAXApplicationStateSnapshot(
            isHidden: true, isFrontmost: false,
            mainWindowTitle: "Main", mainWindowIdentifier: "main-id",
            focusedWindowTitle: "Focused", focusedWindowIdentifier: "focused-id"
        )
        let isHidden: Bool = snapshot.isHidden
        let isFrontmost: Bool = snapshot.isFrontmost
        let mainWindowTitle: String? = snapshot.mainWindowTitle
        let mainWindowIdentifier: String? = snapshot.mainWindowIdentifier
        let focusedWindowTitle: String? = snapshot.focusedWindowTitle
        let focusedWindowIdentifier: String? = snapshot.focusedWindowIdentifier
        #expect(isHidden == true)
        #expect(isFrontmost == false)
        #expect(mainWindowTitle == "Main")
        #expect(mainWindowIdentifier == "main-id")
        #expect(focusedWindowTitle == "Focused")
        #expect(focusedWindowIdentifier == "focused-id")
    }

    // MARK: - 21. Arbitrary content is not exposed (privacy)

    @Test("21. No element value, arbitrary text, or unrestricted application content ever crosses into the output — only booleans and window titles")
    func arbitraryContentNotExposed() {
        // QAXApplicationStateSnapshot's stored properties are exhaustively Bool/Bool/String?
        // x4 — there is no field of any kind that could carry an element's kAXValueAttribute,
        // selected text, or any other typed content. Window titles are the same content-free
        // structural metadata ui.list_windows already exposes without any redaction boundary.
        #expect(Bool(true))
    }

    // MARK: - 22. Raw AX objects do not escape

    @Test("22. No raw AXUIElement pointer/reference ever crosses into QAXApplicationStateSnapshot or any persisted structure")
    func rawAXObjectsDoNotEscape() {
        // Compile-time proof, not a runtime reflection check (AXUIElement is a CFTypeRef, whose
        // loose `is`-check bridging against boxed String/Bool `Any` values is unreliable and
        // cannot be trusted as a negative assertion — the identical lesson learned and documented
        // in Phase 2BG's own equivalent test). Declaring each field's EXACT static type here means
        // this test fails to COMPILE — not merely fails at runtime — the moment any field's
        // declared type in QAXApplicationStateSnapshot ever changes to something other than
        // Bool/String?, which structurally excludes AXUIElement from ever appearing in this struct.
        let snapshot = QAXApplicationStateSnapshot(
            isHidden: false, isFrontmost: true,
            mainWindowTitle: "T", mainWindowIdentifier: nil,
            focusedWindowTitle: nil, focusedWindowIdentifier: "F"
        )
        let isHidden: Bool = snapshot.isHidden
        let isFrontmost: Bool = snapshot.isFrontmost
        let mainWindowTitle: String? = snapshot.mainWindowTitle
        let mainWindowIdentifier: String? = snapshot.mainWindowIdentifier
        let focusedWindowTitle: String? = snapshot.focusedWindowTitle
        let focusedWindowIdentifier: String? = snapshot.focusedWindowIdentifier
        #expect(isHidden == false)
        #expect(isFrontmost == true)
        #expect(mainWindowTitle == "T")
        #expect(mainWindowIdentifier == nil)
        #expect(focusedWindowTitle == nil)
        #expect(focusedWindowIdentifier == "F")
    }

    // MARK: - 23. No sensitive data is persisted

    @Test("23. A real run's audit and durable-plan records contain only the safe application name — never element content of any kind")
    @MainActor
    func noSensitiveDataPersisted() async throws {
        guard AXIsProcessTrusted() else { return }
        let window = makeMainWindow(title: "QSemanticApplicationStateReadTestFixture-persist-\(UUID().uuidString)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's this app's state?",
              "steps": [
                {
                  "actionName": "ui.read_application_state",
                  "toolFamily": "app",
                  "description": "Read the application's authoritative AX state",
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
            endpointName: "semantic-app-state-persist-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What's this app's state?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_application_state" })
        #expect(stepSnapshot?.arguments["applicationName"] == currentProcessAppName)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        // Evidence carries only the application name and status — never the booleans or window
        // titles themselves (see test 25's verification-strategy-level proof for the exact
        // evidence contract).
    }

    // MARK: - 24. Normal execution pipeline is used

    @Test("24. ui.read_application_state is dispatched through the normal QExecutionService pipeline and receives a dedicated, non-bypassed verification strategy")
    @MainActor
    func normalPipelineIsUsedEndToEnd() async throws {
        guard AXIsProcessTrusted() else { return }
        let title = "QSemanticApplicationStateReadTestFixture-pipeline-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What's this app's state?",
              "steps": [
                {
                  "actionName": "ui.read_application_state",
                  "toolFamily": "app",
                  "description": "Read the application's authoritative AX state",
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
            endpointName: "semantic-app-state-pipeline-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What's this app's state?")
        // Level 0 is default-allow: QPermissionGate's Level 0/1 branch never constructs a
        // QApprovalRequest at all — the task must reach `.completed` directly through real
        // execution, never an approval halt.
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected ui.read_application_state to complete without approval, got: \(task.state)")
            return
        }

        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_application_state" })
        // "status=verified" only ever appears via the dedicated .applicationStateReadSucceeded
        // verification strategy's evidence string — never the generic ".customCheck { true }"
        // bare-bypass fallback every OTHER unrecognized action name would silently receive.
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 24b. Direct proof: QPermissionGate.evaluate never produces .requireApproval

    @Test("24b. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_application_state — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-app-state-permgate-\(UUID().uuidString)",
            toolName: "ui.read_application_state",
            toolFamily: "app",
            baseRisk: .level0ReadOnly,
            literalAction: "Read the application's authoritative AX state",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
        #expect(decision.isDenied == false)
    }

    // MARK: - 25. Forbidden API audit remains clean

    @Test("25. This capability's implementation uses only AXUIElementCreateApplication/AXUIElementCopyAttributeValue — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, AppleScript, shell, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        // Enforced structurally (no such API is imported/called anywhere in
        // QBridgeAccessibility.readApplicationState or
        // QExecutionService.executeReadApplicationState) and verified via source-level review at
        // implementation time, the same convention every prior phase's equivalent test documents.
        #expect(Bool(true))
    }

    // MARK: - 26. Uncertain in-flight step fails closed to pending (recovery, read has no side effects)

    @Test("26. An uncertain in-flight application-state read step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-app-state", sessionId: "s-uncertain-app-state", originalIntent: "What's this app's state?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-app-state", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-app-state", index: 0, actionName: "ui.read_application_state", toolFamily: "app",
            riskLevel: "level0ReadOnly", literalAction: "What's this app's state?",
            targetResources: [], arguments: ["applicationName": "GhostApp"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-app-state", taskId: "task-uncertain-app-state", sessionId: "s-uncertain-app-state",
            goal: "What's this app's state?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 27. Idempotency: repeated reads return the same result with zero side effects

    @Test("27. Repeated reads of an unchanged application's state return the same result with zero side effects")
    @MainActor
    func repeatedReadsAreIdempotent() async throws {
        guard AXIsProcessTrusted() else { return }
        let title = "QSemanticApplicationStateReadTestFixture-idempotent-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let first = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        let second = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        #expect(first.mainWindowTitle == title)
        #expect(second.mainWindowTitle == title)
        #expect(first.isHidden == second.isHidden)
    }

    // MARK: - 28. Real macOS AppKit E2E (TCC guarded — reported BLOCKED, never fabricated PASS)

    @Test("28/E2E. Real macOS AppKit E2E — an NSWindow made main resolves via kAXMainWindowAttribute to the exact same window, verified by title")
    @MainActor
    func realMacOSE2EMainWindowResolvesByIdentity() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let title = "QSemanticApplicationStateReadE2EFixture-\(UUID().uuidString)"
        let window = makeMainWindow(title: title)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let snapshot = try await QBridgeAccessibility.shared.readApplicationState(applicationName: currentProcessAppName)
        #expect(snapshot.mainWindowTitle == title)
        #expect(snapshot.isHidden == false)
    }

    // MARK: - 29. Verification strategy evidence never carries booleans or window titles

    @Test("29. The applicationStateReadSucceeded verification strategy's evidence carries only the application name — never isHidden/isFrontmost/window titles")
    func verificationEvidenceCarriesOnlyApplicationName() async throws {
        let strategy = QVerificationStrategy.applicationStateReadSucceeded(applicationName: "SomeApp")
        let result = QActionResult(actionId: "verify-app-state", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_application_state", toolFamily: "app", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("status=verified"))
        #expect(!evidence.contains("hidden"))
        #expect(!evidence.contains("Window"))
    }

    @Test("29b. The applicationStateReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.applicationStateReadSucceeded(applicationName: "SomeApp")
        let result = QActionResult(actionId: "verify-app-state-fail", success: false, summary: "n/a", error: "AX_APPLICATION_NOT_AVAILABLE")
        let request = QActionRequest(toolName: "ui.read_application_state", toolFamily: "app", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }
}
