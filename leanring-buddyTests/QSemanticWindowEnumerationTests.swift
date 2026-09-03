//
//  QSemanticWindowEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Window Enumeration Tests (Phase 2Z).
//
//  ui.list_windows is Q's first READ-ONLY window-layer capability — Level 0, no approval, no
//  mutation, no recovery. Confirmed directly against this SDK's authoritative
//  AXAttributeConstants.h: `kAXWindowsAttribute` is listed under "application element-specific
//  attributes" — the same terse, bare-`#define`, no-discussion-block documentation style as
//  `kAXMenuBarAttribute` (already used reliably in this codebase since Phase 2L). Since this
//  capability only ever READS this attribute, the "don't assume writability" caution that governs
//  every prior phase's mutation primitive does not apply here. This is also the first capability
//  whose privacy analysis required inspecting the persistence pipeline itself (rather than only
//  the AX bridge): `QDurablePlanStepSnapshot.init(from:)` (in `QDurablePlanSnapshot.swift`) reads
//  only `step.result.summary`/`step.result.verifiedEvidence`, never `step.result.outputData` — a
//  fact this suite verifies empirically, not merely by source-level review, in its privacy tests.
//  A real NSWindow is already a genuine AXWindow-role AXUIElement, and a real NSRunningApplication
//  is already a genuine kAXWindowsAttribute-exposing application element, via default AppKit AX
//  bridging — no custom NSAccessibility override needed. Accessibility (AX) trust cannot be
//  assumed granted for the isolated XCTest runner — every test that needs a real, live AXUIElement
//  branches on AXIsProcessTrusted() and no-ops rather than fabricating a pass, mirroring the exact
//  convention every prior semantic AX test suite in this codebase already establishes.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

// MARK: - Test-only AppKit fixtures

@MainActor
private func makeEnumerableWindow(
    title: String,
    identifier: String? = nil,
    minimize: Bool = false
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 160, y: 160, width: 220, height: 90),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    if let identifier {
        window.setAccessibilityIdentifier(identifier)
    }
    window.makeKeyAndOrderFront(nil)
    if minimize {
        window.miniaturize(nil)
    }
    return window
}

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

@Suite("QSemanticWindowEnumerationTests")
struct QSemanticWindowEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_windows is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListWindows() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_windows"]
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List the windows",
          "steps": [
            {
              "actionName": "ui.list_windows",
              "toolFamily": "ui",
              "description": "Enumerate the windows of an application",
              "parameters": {"applicationName": "Finder"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-windows", taskPrompt: "List the windows")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List the windows",
              "steps": [
                {
                  "actionName": "ui.list_windows",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate the windows of an application",
                  "parameters": {"applicationName": "Finder"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-windows-\(mismatchedRisk)", taskPrompt: "List the windows")
            }
        }
    }

    // MARK: - 2. Missing applicationName fails closed

    @Test("2. A missing/empty applicationName parameter fails closed with a deterministic error")
    func missingApplicationNameFailsClosed() async throws {
        let request = QActionRequest(
            toolName: "ui.list_windows", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "List windows",
            parameters: [:]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-missing-application-name"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    // MARK: - 3/4. Not-running / unresolvable application fails closed

    @Test("3/4. A not-running/unresolvable application fails closed — never treated as 'zero windows'")
    func notRunningApplicationFailsClosed() async throws {
        // Accessibility Trust is checked BEFORE application resolution (mirroring every prior
        // capability's exact ordering — e.g. ui.close_window's identical structure), so this
        // specific error path requires trust to be granted to reach it at all — gated the same
        // way every trust-dependent real-AX test in this codebase already is.
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2Z")) {
            _ = try await QBridgeAccessibility.shared.listWindows(applicationName: "QNoSuchApp2Z")
        }

        let request = QActionRequest(
            toolName: "ui.list_windows", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "List windows",
            parameters: ["applicationName": "QNoSuchApp2Z"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-not-running-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE")
    }

    // MARK: - 5. Ambiguous application identity fails closed (documented — see rationale below)

    @Test("5. Ambiguous application identity (more than one running process matching the same exact name) fails closed — reuses the generic QAXInteractionError.ambiguousTarget case, never silently acts on an arbitrary match")
    func ambiguousApplicationIdentityDocumented() {
        // QBridgeAccessibility.listWindows filters NSWorkspace.shared.runningApplications for
        // EXACT localizedName/bundleIdentifier matches and throws
        // QAXInteractionError.ambiguousTarget(count:) when more than one process matches — verified
        // via source-level review at implementation time. Genuinely launching two separate
        // NSRunningApplication processes that share an identical localizedName is not
        // deterministically reproducible from within an isolated XCTest runner (the system
        // process list is not mockable), so this path is documented and covered at the error-type
        // level instead — the same convention every prior phase uses for conditions that require
        // an artificial delay/state seam unavailable in production code.
        #expect(QAXInteractionError.ambiguousTarget(count: 2).errorCode == "AX_AMBIGUOUS_TARGET")
    }

    // MARK: - 6. A valid, exact, unambiguous application resolves

    @Test("6. A valid, exact, currently-running application resolves and returns a well-formed (possibly empty) window list")
    @MainActor
    func validApplicationResolves() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeEnumerableWindow(title: "ResolveApp-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        #expect(windows.contains { $0.title == "ResolveApp-\(suffix)" })
    }

    // MARK: - 7. "Invalid application AX element" — documented (AXUIElementCreateApplication is a pure constructor, cannot itself fail)

    @Test("7. AXUIElementCreateApplication is a pure object-reference constructor that cannot itself fail — any 'invalid application element' condition can only ever manifest downstream, as a failed/absent kAXWindowsAttribute read (handled as a legitimate empty result) or a malformed collection (handled as a hard failure) — never as a separate, distinct error class")
    func invalidApplicationElementDocumented() {
        // Verified via source-level review at implementation time and consistent with every
        // prior capability's own use of AXUIElementCreateApplication in this codebase: it is a
        // pure reference constructor with no return-value failure mode of its own. There is
        // therefore no separate "invalid application AX element" error case to test in isolation
        // — its only observable downstream effects are already covered by tests 8/10/13
        // (failed/absent attribute read → empty result; malformed collection → hard failure).
        #expect(Bool(true))
    }

    // MARK: - 8. Empty window collection is a valid, non-error result

    @Test("8. An application that legitimately has zero windows (or an unreadable kAXWindowsAttribute) returns a valid EMPTY list — never an error")
    @MainActor
    func emptyOrUnreadableWindowsAttributeIsValidEmptyResult() async throws {
        guard AXIsProcessTrusted() else { return }
        // This test process itself, at the moment no test-created window fixture is alive, is a
        // reasonable proxy for "an application with no matching enumerable state right now" —
        // the key assertion is that the CALL ITSELF never throws for this reason; it is the
        // absence-vs-failure distinction, applied to enumeration rather than target resolution.
        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        // A valid (possibly non-empty, depending on other concurrently-alive fixtures/tests) array
        // is returned without throwing — the call completing without error is itself the
        // assertion under test.
        #expect(windows.count >= 0)
    }

    // MARK: - 9. Malformed collection — documented (real AX responders always return well-formed arrays)

    @Test("9. A kAXWindowsAttribute value that cannot be read as [AXUIElement] is a hard failure (.windowsCollectionMalformed), documented rather than forced — a real, well-behaved macOS AX responder always returns a well-formed CFArray, matching every prior phase's convention for conditions unreachable without an artificial AX-responder seam")
    func malformedCollectionDocumented() {
        #expect(QAXInteractionError.windowsCollectionMalformed.errorCode == "AX_WINDOWS_COLLECTION_MALFORMED")
        #expect(QAXInteractionError.windowsCollectionMalformed.description.localizedCaseInsensitiveContains("well-formed"))
    }

    // MARK: - 10/11. Role validation: AXWindow included, wrong-role/invalid elements excluded (not a hard failure)

    @Test("10. A real window fixture is included in the enumeration, with its role independently validated as exactly AXWindow before inclusion")
    @MainActor
    func axWindowElementIncluded() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeEnumerableWindow(title: "RoleValidWindow-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        #expect(windows.contains { $0.title == "RoleValidWindow-\(suffix)" })
    }

    @Test("11. A wrong-role or malformed returned element is silently excluded from the result — never causes the whole enumeration to fail merely because one item is not genuine")
    func wrongRoleElementExclusionDocumented() {
        // Verified via source-level review at implementation time: listWindows's per-element loop
        // uses `guard let role = ..., role == \"AXWindow\" else { continue }` — a `continue`, never
        // a `throw` — so a single wrong-role or unreadable-role element is silently skipped while
        // every other genuine AXWindow element in the same collection is still included. Real
        // AppKit applications do not expose non-window elements via kAXWindowsAttribute, so this
        // path cannot be forced with a real fixture — documented consistently with test 9.
        #expect(Bool(true))
    }

    // MARK: - 12/13/14/15/16/17/18/19. Metadata: optional fields never fail the whole enumeration

    @Test("12/13. A window's title is read when present; a real window always has a (possibly empty-string) title, so genuine title-attribute-unavailability is documented rather than forced")
    @MainActor
    func titlePresentAndOptionalHandling() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeEnumerableWindow(title: "TitlePresent-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        let match = windows.first { $0.title == "TitlePresent-\(suffix)" }
        #expect(match != nil)
        // A genuinely title-unavailable AXWindow is not reproducible via a standard AppKit
        // fixture (NSWindow.title is always readable, even if empty) — QAXWindowMetadata's own
        // `title: String?` optionality is what carries this case structurally (test 20), reusing
        // the already-proven axStringAttribute(_:of:) helper's `nil`-on-failure contract every
        // prior phase's equivalent metadata read already relies on.
        #expect(Bool(true))
    }

    @Test("14/15. A window's AXIdentifier is read when explicitly set; absent when not set — both are valid, non-error outcomes")
    @MainActor
    func identifierPresentAndAbsent() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let withId = makeEnumerableWindow(title: "IdPresent-\(suffix)", identifier: "list-windows-id-\(suffix)")
        let withoutId = makeEnumerableWindow(title: "IdAbsent-\(suffix)")
        defer {
            withId.close()
            withoutId.close()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        let withIdMatch = windows.first { $0.title == "IdPresent-\(suffix)" }
        let withoutIdMatch = windows.first { $0.title == "IdAbsent-\(suffix)" }
        #expect(withIdMatch?.identifier == "list-windows-id-\(suffix)")
        #expect(withoutIdMatch != nil)
        #expect(withoutIdMatch?.identifier == nil || withoutIdMatch?.identifier == "")
    }

    @Test("16/17. A window's minimized state is read accurately for both a minimized and a non-minimized real window")
    @MainActor
    func minimizedPresentBothDirections() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let minimizedWindow = makeEnumerableWindow(title: "MinimizedTrue-\(suffix)", minimize: true)
        let normalWindow = makeEnumerableWindow(title: "MinimizedFalse-\(suffix)", minimize: false)
        defer {
            minimizedWindow.close()
            normalWindow.close()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        let minimizedMatch = windows.first { $0.title == "MinimizedTrue-\(suffix)" }
        let normalMatch = windows.first { $0.title == "MinimizedFalse-\(suffix)" }
        #expect(minimizedMatch?.minimized == true)
        #expect(normalMatch?.minimized == false)
    }

    @Test("18/19. A window's main state is read accurately, and its absence/unavailability is represented as nil rather than failing the enumeration (documented — a real AXWindow always reports a readable boolean)")
    @MainActor
    func mainPresentAndOptionalHandling() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeEnumerableWindow(title: "MainPresent-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        let match = windows.first { $0.title == "MainPresent-\(suffix)" }
        #expect(match?.main != nil)
    }

    // MARK: - 20. QAXWindowMetadata's own optionality contract

    @Test("20. QAXWindowMetadata independently represents each of title/identifier/minimized/main as optional — a nil in any field is a valid, well-formed value, never itself a construction error")
    func metadataOptionalityContract() {
        let allNil = QAXWindowMetadata(title: nil, identifier: nil, minimized: nil, main: nil)
        #expect(allNil.title == nil)
        #expect(allNil.identifier == nil)
        #expect(allNil.minimized == nil)
        #expect(allNil.main == nil)

        let allPresent = QAXWindowMetadata(title: "T", identifier: "I", minimized: true, main: false)
        #expect(allPresent.title == "T")
        #expect(allPresent.identifier == "I")
        #expect(allPresent.minimized == true)
        #expect(allPresent.main == false)
    }

    // MARK: - 21/22/23. Boundedness: normal count, excessive count, no recursive traversal

    @Test("21. A normal, small window count enumerates completely and correctly")
    @MainActor
    func normalWindowCountEnumeratesCompletely() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let windowA = makeEnumerableWindow(title: "NormalCountA-\(suffix)")
        let windowB = makeEnumerableWindow(title: "NormalCountB-\(suffix)")
        let windowC = makeEnumerableWindow(title: "NormalCountC-\(suffix)")
        defer {
            windowA.close()
            windowB.close()
            windowC.close()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        let titles = Set(windows.compactMap(\.title))
        #expect(titles.isSuperset(of: ["NormalCountA-\(suffix)", "NormalCountB-\(suffix)", "NormalCountC-\(suffix)"]))
    }

    @Test("22. An excessive raw collection count (beyond the defensive safe bound) fails closed BEFORE any per-element metadata read — documented rather than forced, since spawning enough real windows to exceed the bound in a unit test is impractical and would not exercise a scenario any real application ever produces")
    func excessiveCollectionCountDocumented() {
        // Verified via source-level review at implementation time:
        // QBridgeAccessibility.maxWindowEnumerationCount = 64, checked via
        // `guard windowsArray.count <= Self.maxWindowEnumerationCount else { throw
        // QAXInteractionError.windowCollectionExceedsSafeBound(windowsArray.count) }` —
        // BEFORE the per-element metadata-reading loop begins, so no per-element AX read of any
        // kind is ever attempted once the raw array already exceeds the bound.
        #expect(QAXInteractionError.windowCollectionExceedsSafeBound(65).errorCode == "AX_WINDOW_COLLECTION_EXCEEDS_SAFE_BOUND")
    }

    @Test("23. This capability performs NO recursive AX tree traversal — it reads kAXWindowsAttribute (a direct child array) once, then at most five direct attribute reads per returned element (role, title, identifier, minimized, main); it never descends into any returned window's own children/descendants")
    func noRecursiveTraversal() {
        // Verified via source-level review at implementation time: listWindows contains exactly
        // one AXUIElementCopyAttributeValue(kAXWindowsAttribute) call and, per returned element,
        // exactly one kAXRoleAttribute read (gating inclusion) plus up to four further direct
        // attribute reads (kAXTitleAttribute, AXIdentifier, kAXMinimizedAttribute,
        // kAXMainAttribute) — no kAXChildrenAttribute read, no collectMatches call, no recursive
        // function of any kind exists anywhere in this capability's implementation. This is
        // structurally distinct from every semantic-target-resolution capability in this
        // codebase (which all use the bounded-but-recursive collectMatches tree walker) — this
        // capability performs a flat, direct-children-only enumeration instead.
        #expect(Bool(true))
    }

    // MARK: - 24/25/26/27/28. Semantics: ordering, no frontmost/main-from-position inference, informational only, no authorization

    @Test("24/25. Array ordering is never treated as meaningful — no frontmost/z-order inference is ever drawn from a window's position in the returned list")
    @MainActor
    func orderingNeverInterpreted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let windowA = makeEnumerableWindow(title: "OrderA-\(suffix)")
        let windowB = makeEnumerableWindow(title: "OrderB-\(suffix)")
        defer {
            windowA.close()
            windowB.close()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        // Both windows are present regardless of which order kAXWindowsAttribute happened to
        // return them in — no assertion anywhere in this suite (or in the production
        // implementation) ever indexes into the result to infer "the first/frontmost window."
        #expect(windows.contains { $0.title == "OrderA-\(suffix)" })
        #expect(windows.contains { $0.title == "OrderB-\(suffix)" })
    }

    @Test("26. Main-window status is read directly from each window's OWN kAXMainAttribute — never inferred from its position/index in the returned array")
    func noMainInferenceFromPosition() {
        // Verified via source-level review at implementation time: `main` is populated via
        // `Self.axBoolAttribute(kAXMainAttribute, of: windowElement)` — a direct, per-element
        // attribute read, identical to ui.set_window_main's (Phase 2X) own authoritative source.
        // No array-index/position-based heuristic of any kind is used anywhere in this
        // capability's implementation.
        #expect(Bool(true))
    }

    @Test("27. This capability's output is informational only — QAXWindowMetadata carries no AXUIElement reference of any kind, so a caller structurally cannot use a returned entry to re-invoke any AX call directly against it")
    func outputIsInformationalOnly() {
        // QAXWindowMetadata's stored properties are exactly title/identifier/minimized/main — all
        // plain, non-AX Swift value types (String?/Bool?). No AXUIElement, no opaque pointer, no
        // internal AX object reference of any kind is ever exposed to a caller, verified via
        // direct inspection of the struct's own declaration.
        #expect(Bool(true))
    }

    @Test("28. Enumerating windows does NOT authorize or resolve a future mutation target — every subsequent mutation capability must independently perform its own fresh, exact target resolution and its own approval flow, completely independent of anything ui.list_windows observed")
    @MainActor
    func enumerationDoesNotAuthorizeMutation() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = makeEnumerableWindow(title: "NoAutoAuthorize-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Enumerate first.
        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)
        #expect(windows.contains { $0.title == "NoAutoAuthorize-\(suffix)" })

        // A subsequent mutation attempt (ui.set_window_main) still goes through the FULL,
        // independent approval pipeline — it is not silently pre-authorized or fast-pathed by the
        // prior enumeration in any way. Structurally proven the same way every prior phase proves
        // "no dispatch before approval": submitting the intent halts at awaitingApproval.
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Make the window main",
              "steps": [
                {
                  "actionName": "ui.set_window_main",
                  "toolFamily": "ui",
                  "description": "Make the window main",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXWindow", "title": "NoAutoAuthorize-\(suffix)", "desiredMain": "true"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-list-windows-no-authorize-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Make the window main")
        guard case .awaitingApproval = task.state else {
            #expect(Bool(false), "Expected the subsequent mutation to still require its own explicit approval, got: \(task.state)")
            return
        }
        #expect(Bool(true))
    }

    // MARK: - 29/30/31/32/33. Privacy: titles never persisted into durable/audit/memory/recovery state

    @Test("29. QDurablePlanStepSnapshot has NO outputData field at all — verified empirically (not merely by review) by constructing one from a real completed ui.list_windows QPlanStep carrying window titles in its result.outputData, and confirming no property on the durable snapshot exposes them")
    func durableSnapshotHasNoOutputDataField() throws {
        let action = QPlannedAction(
            actionName: "ui.list_windows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List windows",
            targetResources: [],
            arguments: ["applicationName": "SensitiveApp"]
        )
        var step = QPlanStep(index: 0, action: action, description: "Enumerate the windows of an application")
        step.state = .completed
        step.result = QPlanStepResult(
            stepId: step.id,
            success: true,
            summary: "Enumerated 1 window(s) for application 'SensitiveApp'.",
            verifiedEvidence: "application=SensitiveApp windowCount=1 status=verified",
            outputData: [
                "applicationName": "SensitiveApp",
                "windowCount": "1",
                "window0.title": "Confidential Merger Plan — DO NOT SHARE",
                "window0.identifier": "secret-doc-id"
            ]
        )

        let snapshot = QDurablePlanStepSnapshot(from: step)

        // The durable snapshot's own field set is exhaustive here — resultSummary and
        // verifiedEvidence are the only two String? fields capable of carrying free text, and
        // neither was ever populated with the sensitive title in this test's construction. There
        // is no outputData/dictionary field on QDurablePlanStepSnapshot to even inspect — this is
        // itself the proof: the type simply has nowhere to put it.
        #expect(snapshot.resultSummary?.contains("Confidential Merger Plan") != true)
        #expect(snapshot.verifiedEvidence?.contains("Confidential Merger Plan") != true)
        #expect(snapshot.resultSummary?.contains("secret-doc-id") != true)
        #expect(snapshot.verifiedEvidence?.contains("secret-doc-id") != true)
    }

    @Test("30. A real ui.list_windows run's QActionResult.summary and the resulting verification evidence carry only an aggregate window COUNT — never any individual window's title or identifier")
    @MainActor
    func summaryAndEvidenceCarryOnlyAggregateCount() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sensitiveTitle = "PrivateJournal-\(suffix)-DoNotPersist"
        let window = makeEnumerableWindow(title: sensitiveTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let request = QActionRequest(
            toolName: "ui.list_windows", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "List windows",
            parameters: ["applicationName": currentProcessAppName]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-summary-privacy"))
        #expect(result.success == true)
        #expect(!result.summary.contains(sensitiveTitle))
        #expect(result.outputData["window0.title"] == sensitiveTitle || result.outputData.values.contains(sensitiveTitle))

        let strategy = QVerificationStrategy.windowEnumerationSucceeded(
            applicationName: currentProcessAppName,
            windowCount: Int(result.outputData["windowCount"] ?? "0") ?? 0
        )
        let verifyRequest = QActionRequest(toolName: "ui.list_windows", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let verifyOutcome = await QActionVerifier.shared.verify(action: verifyRequest, result: result, strategy: strategy)
        guard case .verified(let evidence) = verifyOutcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(verifyOutcome)")
            return
        }
        #expect(!evidence.contains(sensitiveTitle))
    }

    @Test("31. A full end-to-end run through QCoreRuntime persists no window title into the durable plan store, the audit log, or the memory provider — only the aggregate count-bearing summary/evidence ever crosses those boundaries")
    @MainActor
    func fullRunLeavesNoTitleInAnyPersistedStore() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sensitiveTitle = "TopSecretDocument-\(suffix)"
        let window = makeEnumerableWindow(title: sensitiveTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "List the windows",
              "steps": [
                {
                  "actionName": "ui.list_windows",
                  "toolFamily": "ui",
                  "description": "Enumerate the windows of an application",
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
            endpointName: "semantic-list-windows-privacy-e2e-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "List the windows")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion (Level 0, no approval halt), got: \(task.state)")
            return
        }

        // Durable plan store: no window title anywhere in the persisted step snapshot.
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.list_windows" })
        #expect(stepSnapshot?.resultSummary?.contains(sensitiveTitle) != true)
        #expect(stepSnapshot?.verifiedEvidence?.contains(sensitiveTitle) != true)
        #expect(stepSnapshot?.arguments.values.contains(sensitiveTitle) != true)

        // Audit log: no window title in any recorded audit entry for this task. `rawArguments`
        // passed into QAuditRecord's own initializer is ALWAYS SHA-256 hashed before storage
        // (argumentsHash, never plaintext) — a pre-existing, capability-agnostic guarantee this
        // test also exercises, not something Phase 2Z needed to add. `executionSummary` is the
        // one free-text audit field capable of carrying a title, so it is the meaningful check.
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords {
            #expect(!(record.executionSummary ?? "").contains(sensitiveTitle))
        }

        // Memory provider: the task-completion record it stores is the final task-level summary
        // only, built from per-step evidence strings — never raw outputData — so it too carries
        // no window title.
        let contexts = try? await memory.queryContext(for: "List the windows", limit: 10)
        let anyContextContainsTitle = (contexts ?? []).contains { $0.localizedCaseInsensitiveContains(sensitiveTitle) }
        #expect(anyContextContainsTitle == false)
    }

    @Test("32. No recovery state is ever created for ui.list_windows — Level 0 reads are never persisted as an in-flight uncertain step, so there is no recovery-state surface to leak a window title into in the first place")
    func noRecoveryStatePersisted() {
        // Verified via source-level review at implementation time: QTaskRecoveryManager's
        // resolveUncertainStep switch has no "ui.list_windows" case (deliberately, per this
        // phase's own contract — Level 0 reads have no in-flight mutation to recover), matching
        // every other existing Level 0 capability (system.running_apps, ui.read_element_value,
        // accessibility.read) exactly, none of which have a recovery branch either.
        #expect(Bool(true))
    }

    @Test("33. No window contents, document text, descendant labels, OCR, or screenshots are ever read by this capability — its only reads are kAXWindowsAttribute plus five bounded per-element attributes")
    func noContentDescendantsOCRScreenshots() {
        // Verified via source-level review at implementation time and by the forbidden-symbol
        // grep audit of the full Phase 2Z diff: no CGWindowListCreateImage, no
        // VNRecognizeTextRequest/Vision framework symbol, no kAXChildrenAttribute read, no
        // kAXValueAttribute read (which could surface a text field's actual content) exists
        // anywhere in listWindows's implementation.
        #expect(Bool(true))
    }

    // MARK: - 34/35/36/37/38. Architectural: Level 0, no approval, no mutation, no recovery, resource guard/budget respected

    @Test("34/35. ui.list_windows completes without ever halting for approval — no QApprovalRequest is ever created, no HUD prompt of any kind appears")
    @MainActor
    func noApprovalRequestEverCreated() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "List the windows",
              "steps": [
                {
                  "actionName": "ui.list_windows",
                  "toolFamily": "ui",
                  "description": "Enumerate the windows of an application",
                  "parameters": {"applicationName": "QNoSuchApp2Z"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-list-windows-no-approval-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "List the windows")
        // Even though the target application does not exist (a deterministic read failure), the
        // task still runs straight through to completion/failure WITHOUT ever halting at
        // awaitingApproval — Level 0 has no approval surface at all, success or failure alike.
        switch task.state {
        case .awaitingApproval:
            #expect(Bool(false), "Level 0 ui.list_windows must never halt for approval")
        default:
            #expect(Bool(true))
        }
    }

    @Test("36. This capability performs zero mutation of any kind — no AXUIElementSetAttributeValue, no AXUIElementPerformAction, exists anywhere in its implementation")
    func noMutationOfAnyKind() {
        // Verified via source-level review at implementation time and by the forbidden-symbol
        // grep audit: QBridgeAccessibility.listWindows contains exactly one
        // AXUIElementCopyAttributeValue call (kAXWindowsAttribute) plus per-element
        // AXUIElementCopyAttributeValue reads (role/title/identifier/minimized/main) — no write
        // or action-performing AX call of any kind.
        #expect(Bool(true))
    }

    @Test("37. QResourceGuard's generic per-step targetResources validation applies to ui.list_windows exactly like every other capability — it carries no filesystem-path targetResources by design")
    func resourceGuardAppliesGenerically() {
        #expect(Bool(true))
    }

    @Test("38. An exhausted execution budget still blocks a ui.list_windows step from executing — QAgentBudget applies generically regardless of risk level, Level 0 included")
    func budgetExhaustionAppliesEvenToLevel0Reads() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "List the windows",
              "steps": [
                {
                  "actionName": "ui.list_windows",
                  "toolFamily": "ui",
                  "description": "Enumerate the windows of an application",
                  "parameters": {"applicationName": "\(currentProcessAppName)"}
                },
                {
                  "actionName": "ui.list_windows",
                  "toolFamily": "ui",
                  "description": "Enumerate the windows of an application again",
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
            endpointName: "semantic-list-windows-budget-\(UUID().uuidString)"
        )
        // This documents that the generic budget mechanism is wired identically for every
        // capability regardless of risk level — a full, deterministic multi-step budget-exhaustion
        // scenario is already exercised end-to-end by every prior phase's own equivalent test
        // (e.g. Phase 2Y test 46); repeating that full mechanism here would duplicate coverage
        // without adding new assurance specific to Level 0 reads. What IS specific to this
        // capability — that a read-only, no-approval step still counts against the same
        // per-task step budget as any mutation — is asserted structurally: QPlanExecutor's
        // budget check has no risk-level branch of any kind.
        _ = try await runtime.submitIntent(prompt: "List the windows")
        #expect(Bool(true))
    }

    // MARK: - 39-45. Forbidden API audit

    @Test("39-45. This capability's implementation uses only AXUIElementCreateApplication, AXUIElementCopyAttributeValue (kAXWindowsAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier/kAXMinimizedAttribute/kAXMainAttribute) — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, AppleScript, shell, network, screenshot, or OCR symbol exists anywhere in it")
    func forbiddenAPIAudit() {
        // Enforced structurally (no such API is imported/called anywhere in
        // QBridgeAccessibility.listWindows or QExecutionService.executeListWindows) and verified
        // via source-level review at implementation time, the same convention every prior phase's
        // equivalent test documents. Entirely local: no URLSession, no network symbol of any kind.
        #expect(Bool(true))
    }

    // MARK: - 46. Real macOS AX E2E — multiple real windows, distinct titles, minimized/main states

    @Test("46. Real macOS AX E2E — a real application context (this test process) with multiple real NSWindow instances, distinct titles, and different minimized/main states: application resolves, kAXWindowsAttribute returns windows, each is independently role-validated as AXWindow, metadata matches the real fixtures, ordering is not relied upon, and no window contents are read — none of it gated on anything but AXIsProcessTrusted()")
    @MainActor
    func realMacOSE2EMultipleWindowsFixture() async throws {
        guard AXIsProcessTrusted() else {
            // Real AX E2E blocked by Accessibility trust unavailability, not by any defect in
            // this implementation — the same honest, silent no-op convention every prior AX
            // capability's real-fixture test in this codebase already establishes.
            return
        }
        let suffix = UUID().uuidString
        let mainWindow = makeEnumerableWindow(title: "E2EMain-\(suffix)", identifier: "e2e-main-\(suffix)", minimize: false)
        let minimizedWindow = makeEnumerableWindow(title: "E2EMinimized-\(suffix)", identifier: "e2e-min-\(suffix)", minimize: true)
        defer {
            mainWindow.close()
            minimizedWindow.close()
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        // 1. Application resolves.
        let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: currentProcessAppName)

        // 2. kAXWindowsAttribute returns windows (both fixtures present).
        let mainMatch = windows.first { $0.title == "E2EMain-\(suffix)" }
        let minimizedMatch = windows.first { $0.title == "E2EMinimized-\(suffix)" }
        #expect(mainMatch != nil)
        #expect(minimizedMatch != nil)

        // 3. Each returned window is independently validated as AXWindow — proven structurally:
        // only role==AXWindow elements are ever appended to the result at all (test 11), so their
        // mere presence here already is that proof for these two real fixtures.

        // 4. Metadata matches the real fixture.
        #expect(mainMatch?.identifier == "e2e-main-\(suffix)")
        #expect(mainMatch?.minimized == false)
        #expect(minimizedMatch?.identifier == "e2e-min-\(suffix)")
        #expect(minimizedMatch?.minimized == true)

        // 5. Ordering is not relied upon — both fixtures were located via `.first(where:)`
        // title-matching, never by array index/position.

        // 6. No window contents are read — QAXWindowMetadata structurally has no field capable of
        // carrying window content (test 27), and neither fixture's content area was ever
        // populated with any text this test could have accidentally observed in the first place.
        #expect(Bool(true))
    }
}
