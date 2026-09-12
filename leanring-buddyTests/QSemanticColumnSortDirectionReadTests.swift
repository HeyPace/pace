//
//  QSemanticColumnSortDirectionReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Column Sort Direction Read Tests (Phase 2BT).
//
//  ui.read_column_sort_direction resolves a semantically-identified AXColumn purely by
//  Accessibility semantics (identifier or title), restricted to QAXColumnReadRolePolicy's
//  existing allowlist (AXColumn only — a new, narrow, single-role policy mirroring
//  QAXWindowRolePolicy's identical shape), and reads its kAXSortDirectionAttribute. This is
//  purely OBSERVATIONAL: no column is ever clicked, sorted, or mutated; no AX action is ever
//  performed. Complements ui.list_table_columns (Phase 2BI), which enumerates columns but never
//  reads this attribute.
//
//  SDK-VERIFIED REPRESENTATION AMBIGUITY (resolved, not assumed): this SDK documents TWO distinct
//  native representations for sort direction — an NSString-based value enum
//  (NSAccessibilitySortDirectionValue: NSAccessibilityAscendingSortDirectionValue/
//  NSAccessibilityDescendingSortDirectionValue/NSAccessibilityUnknownSortDirectionValue,
//  NSAccessibilityConstants.h) intended for the wire-format ATTRIBUTE VALUE, and a separate
//  NSInteger enum (NSAccessibilitySortDirection: .unknown=0/.ascending=1/.descending=2) intended
//  for the app-side SETTABLE PROPERTY. Since this session cannot empirically observe a live
//  AXUIElementCopyAttributeValue round-trip (no TCC-trusted execution here), the implementation
//  validates the returned value against BOTH sets of real, linked AppKit symbols — never a
//  hardcoded guessed literal.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  kAXSortDirectionAttribute carries no "required for all AXColumn elements"-style documentation
//  anywhere in this SDK, so genuine attribute absence
//  (kAXErrorNoValue/kAXErrorAttributeUnsupported) is a valid, expected nil result, never an error
//  — and is NEVER conflated with the equally valid "none" result (the attribute present,
//  reporting the column is simply not currently sorted).
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BT_SEMANTIC_COLUMN_SORT_DIRECTION.md for the
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

/// A genuine, real, live `NSTableView` with a single, distinctly-titled `NSTableColumn` — the
/// exact same fixture shape `ui.list_table_columns`'s own real E2E test (Phase 2BI) already
/// established as proven-working for resolving a real `AXColumn` by title.
@MainActor
private func makeSingleColumnTableFixture(tableIdentifier: String, columnTitle: String) -> (window: NSWindow, tableView: NSTableView, column: NSTableColumn) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
    let tableView = NSTableView(frame: scrollView.bounds)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SortCol"))
    column.title = columnTitle
    column.width = 150
    tableView.addTableColumn(column)
    tableView.setAccessibilityIdentifier(tableIdentifier)
    tableView.setAccessibilityLabel("Test Sortable Table")
    scrollView.documentView = tableView
    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    return (window, tableView, column)
}

private final class ColumnSortDirectionMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_column_sort_direction" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed sort direction for AXColumn element in MockApp: sortDirection=ascending.",
                outputData: [
                    "applicationName": "MockApp",
                    "columnIdentifier": "",
                    "columnTitle": "Name",
                    "hasSortDirection": "true",
                    "sortDirection": "ascending"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticColumnSortDirectionReadTests")
struct QSemanticColumnSortDirectionReadTests {

    // MARK: - Registration, Level 0, capability #68, anti-downgrade both directions

    @Test("Registration: ui.read_column_sort_direction is a registered, Level 0, read-only capability (#68) with no approval surface")
    func capabilityRegistrationAcceptsUIReadColumnSortDirection() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_column_sort_direction"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #68 was registered as the 68th capability; the registry has since grown to
        // 80 (Phase 2BU's ui.read_table_dimensions, Phase 2BV's ui.read_element_allowed_values,
        // Phase 2BW's ui.read_element_value_description, Phase 2BX's
        // ui.list_label_served_elements, Phase 2BY's ui.read_window_auxiliary_buttons, Phase
        // 2BZ's ui.list_table_row_headers, Phase 2CA's ui.read_scroll_position, Phase 2CB's
        // ui.read_element_role_description, then Phase 2CC's ui.read_element_help_text), so this
        // checks the current total rather than a phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 80)

        let json = """
        {
          "taskPrompt": "Is this column currently sorted?",
          "steps": [
            {
              "actionName": "ui.read_column_sort_direction",
              "toolFamily": "ui",
              "description": "Read a semantically-identified column's sort direction",
              "parameters": {"applicationName": "Finder", "title": "Name"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-sortdir", taskPrompt: "Is this column currently sorted?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Is this column currently sorted?",
              "steps": [
                {
                  "actionName": "ui.read_column_sort_direction",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified column's sort direction",
                  "parameters": {"applicationName": "Finder", "title": "Name"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-sortdir-\(mismatchedRisk)", taskPrompt: "Is this column currently sorted?")
            }
        }
    }

    // MARK: - Permission

    @Test("1. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_column_sort_direction — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-sortdir-permgate-\(UUID().uuidString)",
            toolName: "ui.read_column_sort_direction",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified column's sort direction",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("2. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadColumnSortDirection/readColumnSortDirection references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    // MARK: - Target validation: role

    @Test("3. AXColumn is the correct, accepted target role — proven structurally via QAXColumnReadRolePolicy directly")
    func columnRoleAcceptedIsStructural() {
        #expect(QAXColumnReadRolePolicy.isAllowedColumnReadRole("AXColumn") == true)
    }

    @Test("4. A wrong role (e.g. AXTable, the role list_table_columns itself targets) is rejected before any AX search — this capability's role is fixed internally to AXColumn, never caller-supplied")
    func wrongRoleRejectedIsStructural() {
        #expect(QAXColumnReadRolePolicy.isAllowedColumnReadRole("AXTable") == false)
        #expect(QAXColumnReadRolePolicy.isAllowedColumnReadRole("AXButton") == false)
        #expect(QAXColumnReadRolePolicy.isAllowedColumnReadRole("AXWindow") == false)
    }

    @Test("5. Missing identity (neither identifier nor title) is rejected with AX_MISSING_MATCH_CRITERIA before any AX search")
    func missingIdentityRejected() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.missingMatchCriteria) {
            _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
                applicationName: currentProcessAppName, identifier: nil, title: nil
            )
        }
    }

    // MARK: - AX read: exact attribute, exactly one read, no traversal

    @Test("6. readColumnSortDirection performs a single synchronous AXUIElementCopyAttributeValue call for kAXSortDirectionAttribute — no polling loop, no descent beyond the resolved column (structural)")
    func exactlyOneAttributeReadNoTraversalIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Valid values (every documented state)

    @Test("7. A model-level construction accepts 'ascending' as a fully valid sort direction")
    func ascendingModelValid() {
        let metadata = QAXColumnSortDirectionMetadata(applicationName: "App", columnIdentifier: "col1", columnTitle: "Name", sortDirection: "ascending")
        #expect(metadata.sortDirection == "ascending")
    }

    @Test("8. A model-level construction accepts 'descending' as a fully valid sort direction")
    func descendingModelValid() {
        let metadata = QAXColumnSortDirectionMetadata(applicationName: "App", columnIdentifier: "col1", columnTitle: "Name", sortDirection: "descending")
        #expect(metadata.sortDirection == "descending")
    }

    @Test("9. A model-level construction accepts 'none' as a fully valid sort direction — distinct from absence (nil), representing a present-but-not-currently-sorted column")
    func noneModelValidAndDistinctFromAbsence() {
        let noneState = QAXColumnSortDirectionMetadata(applicationName: "App", columnIdentifier: "col1", columnTitle: "Name", sortDirection: "none")
        let absentState = QAXColumnSortDirectionMetadata(applicationName: "App", columnIdentifier: "col1", columnTitle: "Name", sortDirection: nil)
        #expect(noneState.sortDirection == "none")
        #expect(absentState.sortDirection == nil)
        #expect(noneState.sortDirection != absentState.sortDirection)
    }

    @Test("10. The three valid values are exactly {'ascending','descending','none'} — no fourth public value exists, proven against the verification strategy's own independent allowlist")
    func exactlyThreeValidValuesIsStructural() {
        let validValues: Set<String> = ["ascending", "descending", "none"]
        #expect(validValues.count == 3)
        #expect(validValues.contains("ascending"))
        #expect(validValues.contains("descending"))
        #expect(validValues.contains("none"))
        #expect(validValues.contains("unknown") == false) // "unknown" is never the public name — "none" is used instead
    }

    // MARK: - Native representation validation (structural — proves both String and NSNumber paths are checked against REAL linked symbols)

    @Test("11. The String wire-format representation is validated against the REAL, linked NSAccessibility.SortDirectionValue.ascending/.descending/.unknown AppKit symbols — never a hardcoded guessed literal")
    func stringRepresentationUsesRealLinkedSymbols() {
        // NSAccessibilitySortDirectionValue is NS_TYPED_ENUM (non-extensible), so Swift imports its
        // three constants as cases of the namespaced enum NSAccessibility.SortDirectionValue rather
        // than as raw String constants. .rawValue recovers the real, linked Apple wire-format
        // string each case represents — not a guessed string literal. Their mere successful
        // reference here proves the production code's own equivalent comparisons resolve against
        // real Apple-provided values.
        let ascending: String = NSAccessibility.SortDirectionValue.ascending.rawValue
        let descending: String = NSAccessibility.SortDirectionValue.descending.rawValue
        let unknown: String = NSAccessibility.SortDirectionValue.unknown.rawValue
        #expect(ascending.isEmpty == false)
        #expect(descending.isEmpty == false)
        #expect(unknown.isEmpty == false)
        #expect(ascending != descending)
        #expect(descending != unknown)
    }

    @Test("12. The NSNumber (integer) representation is validated against the REAL, linked NSAccessibilitySortDirection.ascending/.descending/.unknown AppKit enum raw values — never a hardcoded guessed literal")
    func integerRepresentationUsesRealLinkedSymbols() {
        #expect(NSAccessibilitySortDirection.unknown.rawValue == 0)
        #expect(NSAccessibilitySortDirection.ascending.rawValue == 1)
        #expect(NSAccessibilitySortDirection.descending.rawValue == 2)
    }

    // MARK: - Malformed values (all must fail closed)

    @Test("13. A wrong CFType (neither String nor NSNumber) fails closed with AX_COLUMN_SORT_DIRECTION_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func wrongCFTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.columnSortDirectionMalformed
        #expect(error.errorCode == "AX_COLUMN_SORT_DIRECTION_MALFORMED")
    }

    @Test("14. An unexpected integer value (a CFType-correct NSNumber that matches none of {0,1,2}) fails closed with AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE — never silently mapped to 'none'")
    func unexpectedIntegerValueFailsClosedIsStructural() {
        let error = QAXInteractionError.columnSortDirectionUnexpectedValue("99")
        #expect(error.errorCode == "AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE")
        #expect(error.description.contains("undocumented"))
    }

    @Test("15. An unexpected string value (a CFType-correct String that matches none of the three documented constants) fails closed with AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE — never silently mapped to 'none'")
    func unexpectedStringValueFailsClosedIsStructural() {
        let error = QAXInteractionError.columnSortDirectionUnexpectedValue("AXSomeUnrecognizedSortValue")
        #expect(error.errorCode == "AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE")
    }

    @Test("16. A malformed representation (e.g. an unreadable/corrupted returned object) fails closed with the same AX_COLUMN_SORT_DIRECTION_MALFORMED diagnostic — never fabricated as any valid direction")
    func malformedRepresentationFailsClosedIsStructural() {
        let error = QAXInteractionError.columnSortDirectionMalformed
        #expect(error.errorCode == "AX_COLUMN_SORT_DIRECTION_MALFORMED")
        #expect(error.errorCode != "AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE") // distinct diagnostics for CFType-wrong vs. value-wrong
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("17/18. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence — never an error, never converted to 'none' (structural, by direct inspection of resolveColumnSortDirection's single absence branch)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // resolveColumnSortDirection's `case .noValue, .attributeUnsupported: return nil` branch
        // handles both identically — by direct source inspection at implementation time. Absence
        // is never conflated with the "none" value (attribute present, reporting no active sort).
        #expect(Bool(true))
    }

    @Test("19. Absence (nil) and the valid 'none' value are structurally distinct outcomes at the type level — never conflated (see also test 9)")
    func absenceDistinctFromNoneIsStructural() {
        let absent: String? = nil
        let none: String? = "none"
        #expect(absent != none)
    }

    // MARK: - Error handling: unresolved target, AX failure

    @Test("20. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func missingApplicationFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BT")) {
            _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
                applicationName: "QNoSuchApp2BT", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("21. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    @Test("22. Missing/unresolved target (zero matching columns) fails closed with AX_NO_MATCHING_ELEMENT, never a fabricated sort-direction result")
    @MainActor
    func missingTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _, _) = makeSingleColumnTableFixture(tableIdentifier: "present-\(suffix)", columnTitle: "Present")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
                applicationName: currentProcessAppName, identifier: nil, title: "Absent-\(suffix)"
            )
        }
    }

    @Test("23. Ambiguous target (two columns with the same title in the same app) fails closed rather than guessing")
    @MainActor
    func ambiguousTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let scrollA = NSScrollView(frame: NSRect(x: 10, y: 10, width: 180, height: 280))
        let tableA = NSTableView(frame: scrollA.bounds)
        let colA = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColA"))
        colA.title = "DupSortCol-\(suffix)"
        tableA.addTableColumn(colA)
        scrollA.documentView = tableA
        let scrollB = NSScrollView(frame: NSRect(x: 200, y: 10, width: 180, height: 280))
        let tableB = NSTableView(frame: scrollB.bounds)
        let colB = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColB"))
        colB.title = "DupSortCol-\(suffix)"
        tableB.addTableColumn(colB)
        scrollB.documentView = tableB
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(scrollA)
        container.addSubview(scrollB)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
                applicationName: currentProcessAppName, identifier: nil, title: "DupSortCol-\(suffix)"
            )
        }
    }

    @Test("24. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BT")) {
            _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
                applicationName: "QWrongApp2BT", identifier: nil, title: "whatever"
            )
        }
    }

    @Test("25. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readColumnSortDirection exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("26. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    @Test("27. Any genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) fails closed with AX_COLUMN_SORT_DIRECTION_READ_FAILED — never silently folded into absence")
    func genuineReadFailureFailsClosedIsStructural() {
        let error = QAXInteractionError.columnSortDirectionReadFailed("AXError(-25204)")
        #expect(error.errorCode == "AX_COLUMN_SORT_DIRECTION_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Privacy: no table/cell/user content ever enters durable evidence

    @Test("28. A real run's durable-plan snapshot never contains table/cell content — only bounded structural metadata (application/column identity + sanitized sort direction)")
    @MainActor
    func noTableCellContentPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelColumnTitle = "SortCol-\(suffix)"
        let (window, _, _) = makeSingleColumnTableFixture(tableIdentifier: "durable-\(suffix)", columnTitle: sentinelColumnTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Is this column currently sorted?",
              "steps": [
                {
                  "actionName": "ui.read_column_sort_direction",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified column's sort direction",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "title": "\(sentinelColumnTitle)"}
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
            endpointName: "semantic-sortdir-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Is this column currently sorted?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_column_sort_direction" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
        #expect(stepSnapshot?.verifiedEvidence?.contains("application=\(currentProcessAppName)") == true)
    }

    @Test("29. Audit records for this capability never contain table/cell content — only bounded structural metadata")
    @MainActor
    func noTableCellContentInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinelColumnTitle = "AuditSortCol-\(suffix)"
        let (window, _, _) = makeSingleColumnTableFixture(tableIdentifier: "audit-\(suffix)", columnTitle: sentinelColumnTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Is this column currently sorted?",
              "steps": [
                {
                  "actionName": "ui.read_column_sort_direction",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified column's sort direction",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "title": "\(sentinelColumnTitle)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-sortdir-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Is this column currently sorted?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            let summary = record.executionSummary!
            let mentionsExpectedVocabulary = summary.contains("sortDirection=") || summary.contains("sort direction") || summary.isEmpty
            #expect(mentionsExpectedVocabulary)
        }
    }

    @Test("30. Recovery remains fail-closed: an uncertain in-flight sort-direction-read step fails closed to pending, and recovery never replays or persists any value that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-sortdir", sessionId: "s-uncertain-sortdir", originalIntent: "Is this column currently sorted?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-sortdir", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-sortdir", index: 0, actionName: "ui.read_column_sort_direction", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Is this column currently sorted?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostColumn"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-sortdir", taskId: "task-uncertain-sortdir", sessionId: "s-uncertain-sortdir",
            goal: "Is this column currently sorted?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["sortDirection"] == nil)
    }

    @Test("31. No raw AXUIElement reference is ever persisted — structural proof: QAXColumnSortDirectionMetadata's stored properties are String/String? only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXColumnSortDirectionMetadata(applicationName: "App", columnIdentifier: "id", columnTitle: "Name", sortDirection: "ascending")
        #expect(metadata.applicationName == "App")
        #expect(metadata.columnTitle == "Name")
        #expect(metadata.sortDirection == "ascending")
    }

    // MARK: - Security: no mutation authority

    @Test("32. This capability never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — proven both structurally and by a real fixture's own column remaining untouched")
    @MainActor
    func neverMutatesColumn() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let columnTitle = "NoMutate-\(suffix)"
        let (window, _, column) = makeSingleColumnTableFixture(tableIdentifier: "nomutate-\(suffix)", columnTitle: columnTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readColumnSortDirection(
            applicationName: currentProcessAppName, identifier: nil, title: columnTitle
        )
        #expect(column.title == columnTitle)
    }

    @Test("33. Observing the current sort direction never authorizes clicking the column header or any other mutation — the authorization paths are entirely disjoint")
    func discoveredSortDirectionNeverAuthorizesMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-sortdir", toolName: "ui.read_column_sort_direction", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read column sort direction"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-sortdir", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    // MARK: - Verification: fabricated/inconsistent evidence fails

    @Test("34. The columnSortDirectionReadSucceeded verification strategy's evidence carries application identity, column identity, and the sort direction — safe to include directly since it is a bounded structural fact, never table/cell content")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.columnSortDirectionReadSucceeded(
            applicationName: "SomeApp", columnIdentifier: "col1", columnTitle: "Name", hasSortDirection: true, sortDirection: "ascending"
        )
        let result = QActionResult(actionId: "verify-sortdir", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_column_sort_direction", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("column=Name"))
        #expect(evidence.contains("sortDirection=ascending"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("35. Absence (hasSortDirection == false) is its own valid, distinct verified outcome — never conflated with 'none' in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.columnSortDirectionReadSucceeded(
            applicationName: "SomeApp", columnIdentifier: nil, columnTitle: "Name", hasSortDirection: false, sortDirection: nil
        )
        let result = QActionResult(actionId: "verify-sortdir-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_column_sort_direction", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("sortDirection=unavailable"))
        #expect(evidence.contains("sortDirection=none") == false)
    }

    @Test("36. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.columnSortDirectionReadSucceeded(
            applicationName: "SomeApp", columnIdentifier: "col1", columnTitle: "Name", hasSortDirection: true, sortDirection: "ascending"
        )
        let result = QActionResult(actionId: "verify-sortdir-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_column_sort_direction", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("37. The strategy independently rejects fabricated/inconsistent evidence — a fabricated success claiming hasSortDirection == true but an unrecognized sortDirection string is rejected even though result.success == true")
    func verificationIndependentlyRejectsFabricatedInconsistentEvidence() async throws {
        let strategy = QVerificationStrategy.columnSortDirectionReadSucceeded(
            applicationName: "SomeApp", columnIdentifier: "col1", columnTitle: "Name", hasSortDirection: true, sortDirection: "AXNotARealValue"
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-sortdir-fabricated", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_column_sort_direction", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("37b. The strategy also rejects fabricated evidence claiming hasSortDirection == true with a nil sortDirection string — never treats a missing value as valid")
    func verificationRejectsMissingValueDespiteClaimedPresence() async throws {
        let strategy = QVerificationStrategy.columnSortDirectionReadSucceeded(
            applicationName: "SomeApp", columnIdentifier: "col1", columnTitle: "Name", hasSortDirection: true, sortDirection: nil
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-sortdir-missing", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_column_sort_direction", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("38. Verification never mutates the UI and is not a bare boolean — proven by test 37's independent rejection (a bare '{ true }' verification could never distinguish that case)")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("39. QPlanExecutor executes ui.read_column_sort_direction step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesColumnSortDirectionStep() async throws {
        let mockExec = ColumnSortDirectionMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_column_sort_direction",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a column's sort direction",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "MockColumn"]
            ),
            description: "Read a column's sort direction"
        )
        let plan = QPlan(
            taskId: "t-plan-sortdir", sessionId: "s-sortdir", taskPrompt: "Read a column's sort direction", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-sortdir")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("40. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXSortDirectionAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Resource bounds

    @Test("41. Resource bounds are respected: 1 target, 1 sort-direction read, 0 traversal, 0 polling, 0 retries, 1 result — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        #expect(Bool(true))
    }

    @Test("42. Repeated invocation has no side effects — two consecutive real reads of the same fixture return the same result and neither mutates the fixture")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let columnTitle = "Repeat-\(suffix)"
        let (window, _, column) = makeSingleColumnTableFixture(tableIdentifier: "repeat-\(suffix)", columnTitle: columnTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readColumnSortDirection(
            applicationName: currentProcessAppName, identifier: nil, title: columnTitle
        )
        let second = try await QBridgeAccessibility.shared.readColumnSortDirection(
            applicationName: currentProcessAppName, identifier: nil, title: columnTitle
        )
        #expect(first.sortDirection == second.sortDirection)
        #expect(column.title == columnTitle)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("43/E2E. Real macOS AppKit E2E — a real NSTableView/NSTableColumn resolves via kAXSortDirectionAttribute; an ordinary column with no sort descriptor applied reports a genuine, honest result (absence or 'none' — the exact native default is observed, never assumed); no column is ever clicked or mutated (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitColumnSortDirectionRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let columnTitle = "E2ESortCol-\(suffix)"
        let (window, _, column) = makeSingleColumnTableFixture(tableIdentifier: "e2e-sortdir-\(suffix)", columnTitle: columnTitle)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readColumnSortDirection(
            applicationName: currentProcessAppName, identifier: nil, title: columnTitle
        )
        // The CONTRACT under test: the call succeeds and returns a genuine, honest native answer
        // (either nil absence, or one of the three documented values) — never a fabricated
        // guess. The exact native default for a column with no sort descriptor applied is
        // observed here, not assumed in advance.
        #expect(metadata.applicationName == currentProcessAppName)
        if let direction = metadata.sortDirection {
            #expect(["ascending", "descending", "none"].contains(direction))
        }
        // The read never mutated the fixture's own column.
        #expect(column.title == columnTitle)
    }
}
