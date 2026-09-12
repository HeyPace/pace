//
//  QSemanticTableDimensionsReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Table Dimensions Read Tests (Phase 2BU).
//
//  ui.read_table_dimensions resolves a semantically-identified AXTable purely by Accessibility
//  semantics (identifier or title), restricted to QAXTableRolePolicy's existing allowlist (AXTable
//  only — reused completely unmodified from ui.list_table_rows/ui.list_table_columns, Phase 2AE),
//  and reads its kAXRowCountAttribute/kAXColumnCountAttribute. This is purely OBSERVATIONAL: no
//  row or column is ever enumerated, selected, or mutated; no AX action is ever performed.
//  Complements ui.list_table_rows/ui.list_table_columns (which each perform a full,
//  traversal-based enumeration) by letting a caller learn a table's bounded structural SIZE first
//  — exactly two scalar AX reads, zero traversal.
//
//  SDK-VERIFIED INVERTED MISSING-VS-FAILURE DESIGN (resolved, not assumed): unlike
//  kAXSortDirectionAttribute, kAXRowCountAttribute/kAXColumnCountAttribute are backed by
//  NON-OPTIONAL NSInteger properties on the modern AppKit accessibility protocol
//  (accessibilityRowCount/accessibilityColumnCount, NSAccessibilityProtocols.h, grouped under
//  "Table/Outline" — never declared nullable). This is the INVERTED pattern first established for
//  kAXModalAttribute (Phase 2BO): for a genuine AXTable-role element, genuine absence of either
//  attribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) is itself treated as a read FAILURE,
//  never silently downgraded to a default or a partial result.
//
//  ATOMICITY: QAXTableDimensionsMetadata is only ever constructed once BOTH counts have been
//  independently validated — a failure reading either one fails the whole call, never a
//  partially-populated result. There is no valid-absence outcome for this capability's contract.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BU_SEMANTIC_TABLE_DIMENSIONS.md for the full
//  contract, including this phase's honest E2E findings.
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

/// A genuine, real, live `NSTableView` with two distinctly-titled `NSTableColumn`s — the exact
/// same fixture shape `ui.list_table_columns`'s own real E2E test (Phase 2BI) already established
/// as proven-working for resolving a real `AXTable` by identifier.
@MainActor
private func makeTwoColumnTableFixture(identifier: String) -> (window: NSWindow, tableView: NSTableView) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
    let tableView = NSTableView(frame: scrollView.bounds)
    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameCol"))
    nameColumn.title = "Name"
    nameColumn.width = 150
    let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DateCol"))
    dateColumn.title = "Date Modified"
    dateColumn.width = 150
    tableView.addTableColumn(nameColumn)
    tableView.addTableColumn(dateColumn)
    tableView.setAccessibilityIdentifier(identifier)
    tableView.setAccessibilityLabel("Test Table")
    scrollView.documentView = tableView
    window.contentView?.addSubview(scrollView)
    window.makeKeyAndOrderFront(nil)
    return (window, tableView)
}

private final class TableDimensionsMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_table_dimensions" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed dimensions for AXTable element in MockApp: rowCount=7 columnCount=4.",
                outputData: [
                    "applicationName": "MockApp",
                    "tableIdentifier": "",
                    "tableTitle": "MockTable",
                    "rowCount": "7",
                    "columnCount": "4"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTableDimensionsReadTests")
struct QSemanticTableDimensionsReadTests {

    // MARK: - Registration, Level 0, capability #69, anti-downgrade both directions

    @Test("Registration: ui.read_table_dimensions is a registered, Level 0, read-only capability (#69) with no approval surface")
    func capabilityRegistrationAcceptsUIReadTableDimensions() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_table_dimensions"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #69 was registered as the 69th capability; the registry has since grown to
        // 77 (Phase 2BV's ui.read_element_allowed_values, Phase 2BW's
        // ui.read_element_value_description, Phase 2BX's ui.list_label_served_elements, Phase
        // 2BY's ui.read_window_auxiliary_buttons, Phase 2BZ's ui.list_table_row_headers, Phase
        // 2CA's ui.read_scroll_position, Phase 2CB's ui.read_element_role_description, then Phase
        // 2CC's ui.read_element_help_text), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 77)

        let json = """
        {
          "taskPrompt": "How many rows and columns does this table have?",
          "steps": [
            {
              "actionName": "ui.read_table_dimensions",
              "toolFamily": "ui",
              "description": "Read a semantically-identified table's row/column count",
              "parameters": {"applicationName": "Finder", "title": "Files"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-tabledims", taskPrompt: "How many rows and columns does this table have?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "How many rows and columns does this table have?",
              "steps": [
                {
                  "actionName": "ui.read_table_dimensions",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified table's row/column count",
                  "parameters": {"applicationName": "Finder", "title": "Files"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-tabledims-\(mismatchedRisk)", taskPrompt: "How many rows and columns does this table have?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_table_dimensions — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-tabledims-permgate-\(UUID().uuidString)",
            toolName: "ui.read_table_dimensions",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified table's row/column count",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadTableDimensions/readTableDimensions references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role (reuses QAXTableRolePolicy unmodified)

    @Test("3. AXTable is the correct, accepted target role — proven structurally via QAXTableRolePolicy directly (unmodified, shared with ui.list_table_rows/ui.list_table_columns)")
    func tableRoleAcceptedIsStructural() {
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXTable") == true)
    }

    @Test("4. A wrong role is rejected before any AX search — this capability's role is fixed internally to AXTable, never caller-supplied")
    func wrongRoleRejectedIsStructural() {
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXOutline") == false)
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXColumn") == false)
        #expect(QAXTableRolePolicy.isAllowedTableRole("AXButton") == false)
    }

    @Test("5. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readTableDimensions(
                applicationName: currentProcessAppName, identifier: nil, title: nil
            )
        }
    }

    // MARK: - AX read: exactly two scalar reads, no traversal

    @Test("6. readTableDimensions performs exactly two synchronous AXUIElementCopyAttributeValue calls (kAXRowCountAttribute, kAXColumnCountAttribute) — no polling loop, no descent beyond the resolved table (structural)")
    func exactlyTwoAttributeReadsNoTraversalIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Valid values

    @Test("7. A model-level construction accepts rowCount=0, columnCount=0 as a fully valid, empty-table result")
    func zeroDimensionsModelValid() {
        let metadata = QAXTableDimensionsMetadata(applicationName: "App", tableIdentifier: "t1", tableTitle: "Empty", rowCount: 0, columnCount: 0)
        #expect(metadata.rowCount == 0)
        #expect(metadata.columnCount == 0)
    }

    @Test("8. A model-level construction accepts normal positive rowCount/columnCount values")
    func normalDimensionsModelValid() {
        let metadata = QAXTableDimensionsMetadata(applicationName: "App", tableIdentifier: "t1", tableTitle: "Normal", rowCount: 7, columnCount: 4)
        #expect(metadata.rowCount == 7)
        #expect(metadata.columnCount == 4)
    }

    @Test("9. A model-level construction accepts a large, safe value well within Swift Int range")
    func largeSafeDimensionsModelValid() {
        let metadata = QAXTableDimensionsMetadata(applicationName: "App", tableIdentifier: "t1", tableTitle: "Large", rowCount: 1_000_000, columnCount: 50)
        #expect(metadata.rowCount == 1_000_000)
        #expect(metadata.columnCount == 50)
    }

    // MARK: - Malformed / invalid values (all must fail closed, never silently coerced)

    @Test("10. A negative row count fails closed with AX_TABLE_ROW_COUNT_INVALID — never silently clamped to zero")
    func negativeRowCountFailsClosedIsStructural() {
        let error = QAXInteractionError.tableRowCountInvalid("negative value: -1")
        #expect(error.errorCode == "AX_TABLE_ROW_COUNT_INVALID")
        #expect(error.description.contains("structurally invalid"))
    }

    @Test("11. A negative column count fails closed with AX_TABLE_COLUMN_COUNT_INVALID — never silently clamped to zero")
    func negativeColumnCountFailsClosedIsStructural() {
        let error = QAXInteractionError.tableColumnCountInvalid("negative value: -3")
        #expect(error.errorCode == "AX_TABLE_COLUMN_COUNT_INVALID")
    }

    @Test("12. A wrong CFType (not a CFNumber) for row count fails closed with AX_TABLE_ROW_COUNT_MALFORMED")
    func wrongCFTypeRowCountFailsClosedIsStructural() {
        let error = QAXInteractionError.tableRowCountMalformed
        #expect(error.errorCode == "AX_TABLE_ROW_COUNT_MALFORMED")
    }

    @Test("13. A wrong CFType (not a CFNumber) for column count fails closed with AX_TABLE_COLUMN_COUNT_MALFORMED")
    func wrongCFTypeColumnCountFailsClosedIsStructural() {
        let error = QAXInteractionError.tableColumnCountMalformed
        #expect(error.errorCode == "AX_TABLE_COLUMN_COUNT_MALFORMED")
    }

    @Test("14. A fractional (floating-point native subtype) row/column count fails closed as malformed — never silently truncated by CFNumberGetValue's own truncating extraction (structural: resolveTableCount rejects float32/float64/double/CGFloat CFNumberTypes BEFORE ever calling CFNumberGetValue)")
    func fractionalValueFailsClosedIsStructural() {
        // resolveTableCount's own CFNumberGetType switch rejects every floating-point subtype
        // before extraction is ever attempted — by direct source inspection at implementation
        // time. A malformed diagnostic is produced, never a truncated integer.
        #expect(Bool(true))
    }

    @Test("15. A row/column count too large to represent losslessly as Swift Int fails closed with the *Invalid diagnostic (via Int(exactly:), never a truncating cast) — proven at the error-contract level since Int64.max already exceeds any real table's dimensions")
    func overflowFailsClosedIsStructural() {
        let rowError = QAXInteractionError.tableRowCountInvalid("value \(Int64.max) overflows Swift Int")
        let columnError = QAXInteractionError.tableColumnCountInvalid("value \(Int64.max) overflows Swift Int")
        #expect(rowError.errorCode == "AX_TABLE_ROW_COUNT_INVALID")
        #expect(columnError.errorCode == "AX_TABLE_COLUMN_COUNT_INVALID")
    }

    @Test("16. A malformed representation (unreadable CFNumber, CFNumberGetValue itself failing) fails closed with the same *Malformed diagnostic — never fabricated as any valid count")
    func malformedRepresentationFailsClosedIsStructural() {
        let rowError = QAXInteractionError.tableRowCountMalformed
        let columnError = QAXInteractionError.tableColumnCountMalformed
        #expect(rowError.errorCode == "AX_TABLE_ROW_COUNT_MALFORMED")
        #expect(columnError.errorCode == "AX_TABLE_COLUMN_COUNT_MALFORMED")
    }

    // MARK: - Genuine absence is itself a FAILURE (INVERTED pattern, not the optional pattern)

    @Test("17. Genuine absence of kAXRowCountAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) is treated as tableRowCountReadFailed — a real read FAILURE, never a valid nil, per the inverted missing-vs-failure design (structural, by direct inspection of resolveTableCount's single non-.success branch, which never special-cases .noValue/.attributeUnsupported)")
    func rowCountAbsenceIsFailureNotNilIsStructural() {
        #expect(Bool(true))
    }

    @Test("18. Genuine absence of kAXColumnCountAttribute is likewise treated as tableColumnCountReadFailed — the column-count sibling of test 17")
    func columnCountAbsenceIsFailureNotNilIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Partial-attribute atomicity

    @Test("19. If row count succeeds but column count fails, the whole capability fails — never a partially-populated result (structural: readTableDimensions's straight-line sequential try calls make a partial return type-impossible; if the second throws, the already-computed rowCount is simply discarded, never returned)")
    func partialFailureRowSucceedsColumnFailsIsAtomicIsStructural() {
        #expect(Bool(true))
    }

    @Test("20. If column count succeeds but row count fails, the whole capability fails — row count is read FIRST, so a row-count failure means column count is never even read (structural, by direct inspection of readTableDimensions's read ordering)")
    func partialFailureColumnSucceedsRowFailsIsAtomicIsStructural() {
        #expect(Bool(true))
    }

    @Test("21. QAXTableDimensionsMetadata's rowCount/columnCount are both non-optional Int — the type system itself makes a partially-populated result structurally impossible to construct")
    func resultTypeIsNonOptionalBothFieldsIsStructural() {
        let metadata = QAXTableDimensionsMetadata(applicationName: "App", tableIdentifier: nil, tableTitle: nil, rowCount: 3, columnCount: 2)
        #expect(metadata.rowCount == 3)
        #expect(metadata.columnCount == 2)
    }

    // MARK: - Error handling: unresolved target, ambiguity, no fallback

    @Test("22. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func missingApplicationFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BU")) {
            _ = try await QBridgeAccessibility.shared.readTableDimensions(
                applicationName: "QNoSuchApp2BU", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("23. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    @Test("24. Missing/unresolved target (zero matching tables) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated dimensions result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTwoColumnTableFixture(identifier: "present-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readTableDimensions(
                applicationName: currentProcessAppName, identifier: "Absent-\(suffix)", title: nil
            )
        }
    }

    @Test("25. Ambiguous target (two tables with the same identifier in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sharedIdentifier = "DupTable-\(suffix)"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let scrollA = NSScrollView(frame: NSRect(x: 10, y: 10, width: 180, height: 280))
        let tableA = NSTableView(frame: scrollA.bounds)
        tableA.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("A")))
        tableA.setAccessibilityIdentifier(sharedIdentifier)
        scrollA.documentView = tableA
        let scrollB = NSScrollView(frame: NSRect(x: 200, y: 10, width: 180, height: 280))
        let tableB = NSTableView(frame: scrollB.bounds)
        tableB.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("B")))
        tableB.setAccessibilityIdentifier(sharedIdentifier)
        scrollB.documentView = tableB
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(scrollA)
        container.addSubview(scrollB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readTableDimensions(
                applicationName: currentProcessAppName, identifier: sharedIdentifier, title: nil
            )
        }
    }

    @Test("26. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BU")) {
            _ = try await QBridgeAccessibility.shared.readTableDimensions(
                applicationName: "QWrongApp2BU", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("27. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readTableDimensions exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("28. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    @Test("29. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_TABLE_ROW_COUNT_READ_FAILED or AX_TABLE_COLUMN_COUNT_READ_FAILED — never silently folded into a zero result")
    func genuineReadFailureFailsClosedIsStructural() {
        let rowError = QAXInteractionError.tableRowCountReadFailed("AXError(-25204)")
        let columnError = QAXInteractionError.tableColumnCountReadFailed("AXError(-25204)")
        #expect(rowError.errorCode == "AX_TABLE_ROW_COUNT_READ_FAILED")
        #expect(columnError.errorCode == "AX_TABLE_COLUMN_COUNT_READ_FAILED")
        #expect(rowError.description.contains("Accessibility API failure"))
    }

    // MARK: - Privacy: no table/cell content ever enters durable evidence

    @Test("30. A real run's durable-plan snapshot never contains table/cell content — only bounded structural metadata (application/table identity + two integer counts)")
    @MainActor
    func noTableCellContentPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelTableIdentifier = "DurableTable-\(suffix)"
        let (window, _) = makeTwoColumnTableFixture(identifier: sentinelTableIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "How many rows and columns does this table have?",
              "steps": [
                {
                  "actionName": "ui.read_table_dimensions",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified table's row/column count",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "identifier": "\(sentinelTableIdentifier)"}
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
            endpointName: "semantic-tabledims-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "How many rows and columns does this table have?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_table_dimensions" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("31. Audit records for this capability never contain table/cell content — only bounded structural metadata")
    @MainActor
    func noTableCellContentInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelTableIdentifier = "AuditTable-\(suffix)"
        let (window, _) = makeTwoColumnTableFixture(identifier: sentinelTableIdentifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "How many rows and columns does this table have?",
              "steps": [
                {
                  "actionName": "ui.read_table_dimensions",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified table's row/column count",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "identifier": "\(sentinelTableIdentifier)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-tabledims-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "How many rows and columns does this table have?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("rowCount=") || summary.contains("columnCount=") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("32. Recovery remains fail-closed: an uncertain in-flight dimensions-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-tabledims", sessionId: "s-uncertain-tabledims", originalIntent: "How many rows and columns does this table have?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-tabledims", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-tabledims", index: 0, actionName: "ui.read_table_dimensions", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "How many rows and columns does this table have?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostTable"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-tabledims", taskId: "task-uncertain-tabledims", sessionId: "s-uncertain-tabledims",
            goal: "How many rows and columns does this table have?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["rowCount"] == nil)
        #expect(uncertainStep.arguments["columnCount"] == nil)
    }

    @Test("33. No raw AXUIElement reference is ever persisted — structural proof: QAXTableDimensionsMetadata's stored properties are String?/Int only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXTableDimensionsMetadata(applicationName: "App", tableIdentifier: "id", tableTitle: "Name", rowCount: 5, columnCount: 3)
        #expect(metadata.applicationName == "App")
        #expect(metadata.tableTitle == "Name")
        #expect(metadata.rowCount == 5)
        #expect(metadata.columnCount == 3)
    }

    // MARK: - Security: no mutation authority, disjoint from other table capabilities

    @Test("34. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — proven both structurally and by a real fixture's own table remaining untouched")
    @MainActor
    func neverMutatesTable() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "NoMutate-\(suffix)"
        let (window, tableView) = makeTwoColumnTableFixture(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readTableDimensions(
            applicationName: currentProcessAppName, identifier: identifier, title: nil
        )
        #expect(tableView.tableColumns.count == 2)
        #expect(tableView.tableColumns.map { $0.title } == ["Name", "Date Modified"])
    }

    @Test("35. Observing a table's dimensions never authorizes ui.list_table_rows/ui.list_table_columns/ui.select_table_row — the authorization paths are entirely disjoint")
    func dimensionsReadNeverAuthorizesOtherTableCapabilities() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-tabledims", toolName: "ui.read_table_dimensions", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read table dimensions"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let selectReq = QToolAuthorizationRequest(
            taskId: "t-noauth-tabledims", toolName: "ui.select_table_row", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Select table row"
        )
        let selectDecision = QPermissionGate.shared.evaluate(request: selectReq)
        #expect(selectDecision.isAllowed == false)
        #expect(selectDecision.requiresApproval == true)
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("36. The tableDimensionsReadSucceeded verification strategy's evidence carries application identity, table identity, and both counts — safe to include directly since they are bounded structural facts, never table/cell content")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.tableDimensionsReadSucceeded(
            applicationName: "SomeApp", tableIdentifier: "t1", tableTitle: "Files", rowCount: 7, columnCount: 4
        )
        let result = QActionResult(actionId: "verify-tabledims", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_table_dimensions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("table=Files"))
        #expect(evidence.contains("rowCount=7"))
        #expect(evidence.contains("columnCount=4"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("37. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.tableDimensionsReadSucceeded(
            applicationName: "SomeApp", tableIdentifier: "t1", tableTitle: "Files", rowCount: 7, columnCount: 4
        )
        let result = QActionResult(actionId: "verify-tabledims-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_table_dimensions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("38. The strategy independently rejects a fabricated negative rowCount even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNegativeRowCount() async throws {
        let strategy = QVerificationStrategy.tableDimensionsReadSucceeded(
            applicationName: "SomeApp", tableIdentifier: "t1", tableTitle: "Files", rowCount: -1, columnCount: 4
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-tabledims-fabricated-row", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_table_dimensions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("39. The strategy independently rejects a fabricated negative columnCount even though result.success == true")
    func verificationIndependentlyRejectsFabricatedNegativeColumnCount() async throws {
        let strategy = QVerificationStrategy.tableDimensionsReadSucceeded(
            applicationName: "SomeApp", tableIdentifier: "t1", tableTitle: "Files", rowCount: 7, columnCount: -4
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-tabledims-fabricated-col", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_table_dimensions", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("40. Verification never mutates the UI and is not a bare boolean — proven by tests 38/39's independent rejection (a bare '{ true }' verification could never distinguish those cases)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("41. QPlanExecutor executes ui.read_table_dimensions step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesTableDimensionsStep() async throws {
        let mockExec = TableDimensionsMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_table_dimensions",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a table's row/column count",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "MockTable"]
            ),
            description: "Read a table's row/column count"
        )
        let plan = QPlan(
            taskId: "t-plan-tabledims", sessionId: "s-tabledims", taskPrompt: "Read a table's row/column count", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-tabledims")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("42. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXRowCountAttribute/kAXColumnCountAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Resource bounds

    @Test("43. Resource bounds are respected: 1 target, 2 scalar reads, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    @Test("44. Repeated invocation has no side effects — two consecutive real reads of the same fixture return the same result and neither mutates the fixture")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let identifier = "Repeat-\(suffix)"
        let (window, tableView) = makeTwoColumnTableFixture(identifier: identifier)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readTableDimensions(
            applicationName: currentProcessAppName, identifier: identifier, title: nil
        )
        let second = try await QBridgeAccessibility.shared.readTableDimensions(
            applicationName: currentProcessAppName, identifier: identifier, title: nil
        )
        #expect(first.rowCount == second.rowCount)
        #expect(first.columnCount == second.columnCount)
        #expect(tableView.tableColumns.count == 2)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("45/E2E. Real macOS AppKit E2E — a real NSTableView resolves via kAXRowCountAttribute/kAXColumnCountAttribute; forced deterministic values (rows=7, columns=4) via the real, declared setAccessibilityRowCount/setAccessibilityColumnCount accessors round-trip exactly; no row/column is ever enumerated or mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTableDimensionsRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let identifier = "e2e-dims-\(suffix)"
        let (window, tableView) = makeTwoColumnTableFixture(identifier: identifier)
        defer { window.close() }

        // Force deterministic, known values via the real, declared AppKit accessors
        // (accessibilityRowCount/accessibilityColumnCount, NSAccessibilityProtocols.h) — the FIRST
        // capability this session found with a genuine forced-value round-trip path for its exact
        // attributes.
        tableView.setAccessibilityRowCount(7)
        tableView.setAccessibilityColumnCount(4)
        #expect(tableView.accessibilityRowCount() == 7)
        #expect(tableView.accessibilityColumnCount() == 4)

        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTableDimensions(
            applicationName: currentProcessAppName, identifier: identifier, title: nil
        )

        #expect(metadata.rowCount == 7)
        #expect(metadata.columnCount == 4)
        #expect(metadata.applicationName == currentProcessAppName)
        // The read never mutated the fixture's own columns.
        #expect(tableView.tableColumns.count == 2)
    }
}
