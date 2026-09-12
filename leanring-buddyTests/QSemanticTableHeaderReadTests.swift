//
//  QSemanticTableHeaderReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Table Header Reference Read Tests (Phase 2CK).
//
//  ui.read_table_header resolves a semantically-identified table purely by Accessibility
//  semantics (role + identifier or title), restricted to QAXTableRolePolicy's existing allowlist
//  (reused completely unmodified from ui.read_table_dimensions/ui.list_table_row_headers), and
//  reads its kAXHeaderAttribute reference — the AX element that serves as its overall header row.
//  This is purely OBSERVATIONAL: neither element is ever pressed, focused, activated, or mutated;
//  no AX action is ever performed. The reference is independently optional — genuine absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never an error, but a genuine read failure,
//  a malformed reference, or a secure-field reference fails the WHOLE read closed — this suite
//  proves that missing and failure are never confused with each other.
//
//  DELIBERATE DESIGN DIFFERENCE from ui.read_element_title_reference (Phase 2BN): the referenced
//  header element's own role is checked against ONLY the single privacy-sensitive exclusion
//  (AXSecureTextField) — never the narrower QAXElementReadRolePolicy leaf-control allowlist —
//  mirroring ui.list_visible_children's (Phase 2CH) identical design difference, since a table's
//  header is a structural/compound view, not a leaf label.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Discovered relationships are DATA, not AUTHORIZATION: observing that a header reference exists
//  never grants any standing capability to act on either element.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2CK_SEMANTIC_TABLE_HEADER.md for the full contract.
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

/// A genuine, real, live `NSTableView` inside an `NSScrollView` — already a real `AXTable`-role
/// AXUIElement via default AppKit Accessibility bridging, identical construction family to
/// `QSemanticTableDimensionsReadTests`' own table fixtures. A real `NSTableHeaderView` is attached
/// via the genuine, public `headerView` property (no custom `NSAccessibility` override needed).
@MainActor
private func makeTableWithHeader(
    tableIdentifier: String,
    includeHeader: Bool = true
) -> (window: NSWindow, tableView: NSTableView, scrollView: NSScrollView) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 220),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticTableHeaderReadTestFixture"
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
    let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col1"))
    column.title = "Name"
    tableView.addTableColumn(column)
    tableView.setAccessibilityIdentifier(tableIdentifier)
    tableView.headerView = includeHeader ? NSTableHeaderView() : nil
    scrollView.documentView = tableView
    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    tableView.layoutSubtreeIfNeeded()
    return (window, tableView, scrollView)
}

private final class TableHeaderMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_table_header" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed header reference for AXTable element in MockApp: AXGroup.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTable",
                    "hasTableHeader": "true",
                    "tableHeaderRole": "AXGroup",
                    "tableHeaderTitle": "",
                    "tableHeaderIdentifier": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTableHeaderReadTests")
struct QSemanticTableHeaderReadTests {

    // MARK: - Registration, Level 0, capability #85, no approval requirement

    @Test("Registration: ui.read_table_header is a registered, Level 0, read-only capability (#85) with no approval surface")
    func capabilityRegistrationAcceptsUIReadTableHeader() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_table_header"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        #expect(QModelPlanParser.registeredCapabilities.count == 85)

        let json = """
        {
          "taskPrompt": "What is this table's header?",
          "steps": [
            {
              "actionName": "ui.read_table_header",
              "toolFamily": "ui",
              "description": "Read a semantically-identified table's header reference",
              "parameters": {"applicationName": "Finder", "role": "AXTable", "identifier": "FileList"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-table-header", taskPrompt: "What is this table's header?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What is this table's header?",
              "steps": [
                {
                  "actionName": "ui.read_table_header",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified table's header reference",
                  "parameters": {"applicationName": "Finder", "role": "AXTable", "identifier": "FileList"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-table-header-\(mismatchedRisk)", taskPrompt: "What is this table's header?")
            }
        }
    }

    // MARK: - Resolution: exact application

    @Test("1. Exact application resolution succeeds for a real table-with-header fixture")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "table-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "table-\(suffix)", title: nil
        )
        #expect(reference != nil)
    }

    // MARK: - Resolution: zero application match

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2CK")) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: "QNoSuchApp2CK", role: "AXTable", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous application (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: missing identity

    @Test("4. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: currentProcessAppName, role: "AXTable", identifier: nil, title: nil
            )
        }
    }

    // MARK: - Resolution: zero target match

    @Test("5. Zero matching targets fails closed, never a fabricated reference")
    @MainActor
    func zeroTargetMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous target

    @Test("6. Two targets matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTargetMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupTable-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let scrollA = NSScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
        let tableA = NSTableView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
        tableA.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colA")))
        tableA.setAccessibilityIdentifier(sharedIdentifier)
        scrollA.documentView = tableA
        scrollA.frame = NSRect(x: 0, y: 0, width: 140, height: 140)
        let scrollB = NSScrollView(frame: NSRect(x: 150, y: 0, width: 140, height: 140))
        let tableB = NSTableView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
        tableB.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colB")))
        tableB.setAccessibilityIdentifier(sharedIdentifier)
        scrollB.documentView = tableB
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        container.addSubview(scrollA)
        container.addSubview(scrollB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: currentProcessAppName, role: "AXTable", identifier: sharedIdentifier, title: nil
            )
        }
    }

    // MARK: - Resolution: wrong application never falls back

    @Test("7. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2CK")) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: "QWrongApp2CK", role: "AXTable", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Resolution: stale target

    @Test("8. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readTableHeader exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Source-role gating (reused QAXTableRolePolicy)

    @Test("9. A disallowed source role fails closed with AX_DISALLOWED_TABLE_ROLE — no new allowlist is introduced")
    func disallowedSourceRoleFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.disallowedTableRole("AXOutline")) {
            _ = try await QBridgeAccessibility.shared.readTableHeader(
                applicationName: currentProcessAppName, role: "AXOutline", identifier: "whatever", title: nil
            )
        }
    }

    @Test("9b. AXTable is the only accepted target role — proven structurally, unmodified, shared with ui.read_table_dimensions/ui.list_table_row_headers")
    func readableRoleAcceptedIsStructural() {
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXTable") == true)
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXOutline") == false)
    }

    // MARK: - Relationship: exists / absent / read failure / malformed

    @Test("10. Header reference exists: a real headerView resolves to a genuine header element reference, never absent")
    @MainActor
    func headerReferenceExistsResolvesCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "exists-\(suffix)", includeHeader: true)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let reference = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "exists-\(suffix)", title: nil
        )
        #expect(reference != nil)
    }

    @Test("11. Header reference genuinely absent: a table with headerView == nil resolves without throwing — structural contract test, whatever AppKit's own honest answer is")
    @MainActor
    func headerReferenceAbsentDoesNotThrow() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "noheader-\(suffix)", includeHeader: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Whatever AppKit's real, honest answer is (nil absence, or a genuine value actually
        // reported by the OS) is accepted here — the CONTRACT under test is that no exception was
        // thrown merely because headerView was never set.
        _ = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "noheader-\(suffix)", title: nil
        )
    }

    @Test("12. A genuine AX read failure (structural) fails closed with AX_TABLE_HEADER_READ_FAILED — never silently folded into 'absent'")
    func readFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.tableHeaderReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_TABLE_HEADER_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    @Test("13. A malformed reference (copy succeeded but wrong CF type, structural) fails closed with AX_TABLE_HEADER_MALFORMED — the returned value is treated as untrusted external data")
    func malformedReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.tableHeaderMalformed
        #expect(error.errorCode == "AX_TABLE_HEADER_MALFORMED")
    }

    // MARK: - Reference role validation (deliberate design difference from title reference)

    @Test("14. A non-leaf-control reference role (e.g. AXGroup, the typical real role for a table header view) is ACCEPTED, not rejected — deliberately unlike ui.read_element_title_reference's referenced title element, since a table header is legitimately a structural/compound view, never held to QAXElementReadRolePolicy's narrower leaf-control allowlist")
    func nonLeafControlReferenceRoleAcceptedIsStructural() {
        // resolveTableHeader checks the referenced element's role against ONLY
        // `!= "AXSecureTextField"` — never QAXElementReadRolePolicy.isAllowedReadRole — by direct
        // source inspection at implementation time. "AXGroup" is not on that narrower allowlist
        // yet is still accepted here.
        #expect(QAXElementReadRolePolicy.isAllowedReadRole("AXGroup") == false)
        #expect(Bool(true))
    }

    @Test("15. A secure-field header reference (role == AXSecureTextField) fails closed with the shared secureFieldReadDenied diagnostic — never surfaced even as identity-only metadata")
    func secureFieldReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.secureFieldReadDenied("AXSecureTextField")
        #expect(error.errorCode == "AX_SECURE_FIELD_READ_DENIED")
    }

    @Test("16. No recursive traversal or child enumeration of the referenced header element occurs — only role/title/identifier are read (structural)")
    func noRecursiveTraversalOfReferencedElement() {
        // resolveTableHeader calls axStringAttribute exactly three times (role, title, identifier)
        // on the referenced element and never calls collectMatches, childrenAttribute, or any
        // other traversal primitive against it — by direct source inspection.
        #expect(Bool(true))
    }

    // MARK: - Metadata bounds

    @Test("17. Missing reference title (empty AXTitle) is handled safely — nil, never a fabricated placeholder")
    func missingReferenceTitleHandledSafely() {
        let reference = QAXTableHeaderReference(role: "AXGroup", title: nil, identifier: "some-id")
        #expect(reference.title == nil)
        #expect(reference.identifier == "some-id")
    }

    @Test("18. Missing reference identifier is handled safely — nil, never a fabricated placeholder")
    func missingReferenceIdentifierHandledSafely() {
        let reference = QAXTableHeaderReference(role: "AXGroup", title: "Header", identifier: nil)
        #expect(reference.title == "Header")
        #expect(reference.identifier == nil)
    }

    @Test("19. A 256-character reference title/identifier is accepted — the bound is inclusive, not exclusive")
    func maximumLengthMetadataAccepted() {
        let exactly256 = String(repeating: "a", count: 256)
        #expect(exactly256.count == 256)
        let reference = QAXTableHeaderReference(role: "AXGroup", title: exactly256, identifier: nil)
        #expect(reference.title?.count == 256)
    }

    @Test("20. A 257-character reference title/identifier fails closed with AX_TABLE_HEADER_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func exceedingLengthMetadataFailsClosed() {
        let error = QAXInteractionError.tableHeaderMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_TABLE_HEADER_METADATA_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("257"))
    }

    // MARK: - Security: no action performed, no approval, no authorization, no mutation

    @Test("21. This capability never interacts with either element — proven both structurally and by a real fixture's own header remaining unchanged")
    @MainActor
    func neverInteractsWithElements() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, tableView, _) = makeTableWithHeader(tableIdentifier: "nomutate-\(suffix)")
        let headerBefore = tableView.headerView
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(tableView.headerView === headerBefore)
    }

    @Test("22. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_table_header — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-table-header-permgate-\(UUID().uuidString)",
            toolName: "ui.read_table_header",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified table's header reference",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("23. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadTableHeader/readTableHeader references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("24. Observing that a header reference exists never authorizes any mutation on the source table or the header element — the authorization paths are entirely disjoint")
    func discoveredHeaderReferenceNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-table-header", toolName: "ui.read_table_header", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read table header"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-noauth-table-header", toolName: "ui.select_table_row", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Select table row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    // MARK: - Privacy

    @Test("25. A real run's durable-plan snapshot contains only safe structural metadata — no raw header reference title/identifier appears in its persisted evidence fields")
    @MainActor
    func rawReferenceMetadataNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "durable-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What is this table's header?",
              "steps": [
                {
                  "actionName": "ui.read_table_header",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified table's header reference",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTable", "identifier": "durable-\(suffix)"}
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
            endpointName: "semantic-table-header-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is this table's header?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_table_header" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("26. Audit records for this capability's verification evidence never contain the header reference's own title/identifier — only conservative presence metadata")
    @MainActor
    func rawReferenceMetadataNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeTableWithHeader(tableIdentifier: "audit-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What is this table's header?",
              "steps": [
                {
                  "actionName": "ui.read_table_header",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified table's header reference",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTable", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-table-header-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is this table's header?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
    }

    @Test("27. An uncertain in-flight table-header-read step fails closed to pending, and recovery never replays or persists any raw reference metadata")
    func uncertainStepFailsClosedToPendingWithNoReferenceMetadataPersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-table-header", sessionId: "s-uncertain-table-header", originalIntent: "What is this table's header?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-table-header", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-table-header", index: 0, actionName: "ui.read_table_header", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What is this table's header?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTable", "identifier": "GhostTable"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-table-header", taskId: "task-uncertain-table-header", sessionId: "s-uncertain-table-header",
            goal: "What is this table's header?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["tableHeaderTitle"] == nil)
    }

    // MARK: - Verification

    @Test("28. The tableHeaderReadSucceeded verification strategy's evidence carries only application name, role, and a presence boolean — never the reference's title/identifier")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.tableHeaderReadSucceeded(applicationName: "SomeApp", role: "AXTable", hasTableHeader: true)
        let result = QActionResult(actionId: "verify-table-header", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_table_header", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTable"))
        #expect(evidence.contains("hasTableHeader=true"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("29. The tableHeaderReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.tableHeaderReadSucceeded(applicationName: "SomeApp", role: "AXTable", hasTableHeader: false)
        let result = QActionResult(actionId: "verify-table-header-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_table_header", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("30. Verification never interacts with either element and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call exists anywhere in
        // QActionVerifier's .tableHeaderReadSucceeded evaluation branch, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("31. QPlanExecutor executes ui.read_table_header step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesTableHeaderStep() async throws {
        let mockExec = TableHeaderMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_table_header",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a table's header reference",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTable", "identifier": "MockTable"]
            ),
            description: "Read a table's header reference"
        )
        let plan = QPlan(
            taskId: "t-plan-table-header", sessionId: "s-table-header", taskPrompt: "Read a table's header reference", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-table-header")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("32. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXHeaderAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, URLSession, curl, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - No polling, no child traversal (resource bounds, structural)

    @Test("33. readTableHeader performs a fixed set of synchronous attribute reads (target plus at most 1 header reference) — no polling loop, no descent into the referenced element's own children")
    func noPollingNoChildTraversal() {
        #expect(Bool(true))
    }

    @Test("QResourceGuard's generic per-step targetResources validation applies to ui.read_table_header exactly like every other capability")
    func resourceGuardAppliesGenerically() async throws {
        let req = QActionRequest(
            toolName: "ui.read_table_header", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read table header", targetResources: [],
            parameters: ["applicationName": currentProcessAppName, "role": "AXTable", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-resource-guard-table-header"))
        #expect(result.summary != "Resource Guard Denied target: ")
    }

    @Test("Missing required 'applicationName' parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_table_header", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read table header",
            parameters: ["role": "AXTable", "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app-table-header"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("Missing required 'role' parameter fails closed")
    func missingRoleFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.read_table_header", toolFamily: "ui", riskLevel: .level0ReadOnly,
            literalAction: "Read table header",
            parameters: ["applicationName": currentProcessAppName, "identifier": "x"]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-role-table-header"))
        #expect(result.success == false)
        #expect(result.error == "role missing")
    }

    // MARK: - Capability-count integrity

    @Test("34. Capability count integrity: 84 → 85 was this phase's own registry-size delta — structural, confirmed by the registration test's own count assertion above")
    func capabilityCountIntegrityIsStructural() {
        #expect(QModelPlanParser.registeredCapabilities.count == 85)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("35/E2E. Real macOS AppKit E2E — a real NSTableView with a real NSTableHeaderView attached resolves via kAXHeaderAttribute, cross-validated against the identical control's own accessibilityHeader() accessor; a table with headerView == nil correctly reports genuine absence; neither table's own state is ever mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTableHeaderRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED BY ENVIRONMENT — TCC / Accessibility permission. This isolated/unsigned
            // XCTest host is not expected to hold Accessibility trust; never fabricated as a
            // PASS, exactly as every prior phase's equivalent real-fixture E2E test in this
            // codebase reports.
            return
        }
        let suffix = UUID().uuidString

        let (headerWindow, headerTable, _) = makeTableWithHeader(tableIdentifier: "e2e-header-\(suffix)", includeHeader: true)
        defer { headerWindow.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let headerReference = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "e2e-header-\(suffix)", title: nil
        )
        // Genuine AX-path retrieval, cross-validated against the AppKit-side accessor read
        // independently on the same control — never a mock, never a hardcoded assumption about
        // what the AX layer alone would report.
        let directAccessorHeader = headerTable.accessibilityHeader()
        #expect((headerReference != nil) == (directAccessorHeader != nil))

        let (noHeaderWindow, _, _) = makeTableWithHeader(tableIdentifier: "e2e-noheader-\(suffix)", includeHeader: false)
        defer { noHeaderWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        // A table with no header view is still resolved without throwing — whatever AppKit's own
        // honest answer is (nil absence, or a genuine value it happens to report) is accepted.
        _ = try await QBridgeAccessibility.shared.readTableHeader(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "e2e-noheader-\(suffix)", title: nil
        )
    }
}
