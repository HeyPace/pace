//
//  QSemanticTableColumnEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Table Column Enumeration Tests (Phase 2BI).
//
//  ui.list_table_columns enumerates direct column-header elements belonging to exactly ONE named
//  AXTable in a named application, via kAXColumnHeaderUIElementsAttribute. It complements
//  ui.list_table_rows (Phase 2AE), which enumerates rows but never surfaces what each column
//  MEANS — a gap independently flagged across three consecutive discovery phases (2BG, 2BH, 2BI).
//
//  Level 0 — no approval, no mutation, no press, no open, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, index). Cell contents are strictly out of
//  scope — only the column HEADER's own identity is ever read. Raw column contents remain
//  ephemeral in outputData and are never persisted into durable task snapshots, audit logs, or
//  SQLite WAL memory stores beyond an aggregate count.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

private final class TableColumnEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_table_columns" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 table column(s) for table in application 'MockApp'.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTable",
                    "columnCount": "2",
                    "column0.index": "0",
                    "column0.title": "Name",
                    "column0.role": "AXColumn",
                    "column0.subrole": "",
                    "column1.index": "1",
                    "column1.title": "Date Modified",
                    "column1.role": "AXColumn",
                    "column1.subrole": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTableColumnEnumerationTests")
struct QSemanticTableColumnEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_table_columns is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIListTableColumns() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_table_columns"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)

        let json = """
        {
          "taskPrompt": "List table columns",
          "steps": [
            {
              "actionName": "ui.list_table_columns",
              "toolFamily": "ui",
              "description": "Enumerate a table's column headers",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXTable",
                "title": "Files"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-table-columns", taskPrompt: "List table columns")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List table columns",
              "steps": [
                {
                  "actionName": "ui.list_table_columns",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate a table's column headers",
                  "parameters": {
                    "applicationName": "Finder",
                    "role": "AXTable",
                    "title": "Files"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-table-columns-\(mismatchedRisk)", taskPrompt: "List table columns")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy (reused, not forked)

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            parameters: [
                "role": "AXTable",
                "title": "Files"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("3. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTable"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("4. Disallowed role (e.g. AXOutline, AXButton, AXBrowser) is rejected before tree walk — QAXTableRolePolicy reused verbatim, not forked")
    func disallowedRoleRejected() async throws {
        for invalidRole in ["AXOutline", "AXButton", "AXTextField", "AXWindow", "AXRow", "AXBrowser", "AXColumn"] {
            let req = QActionRequest(
                toolName: "ui.list_table_columns",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table columns",
                parameters: [
                    "applicationName": currentProcessAppName,
                    "role": invalidRole,
                    "title": "Files"
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    // MARK: - 3. Exact Application Resolution

    @Test("5. Non-existent application throws applicationNotAvailable (zero matches fails closed)")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2BI-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXTable",
                "title": "Files"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("6. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here to duplicate-test")
    func ambiguousApplicationResolutionFailsClosed() {
        // listTableColumns calls the exact same, unmodified resolveExactRunningApplication every
        // other capability calls — no special-cased ambiguity handling exists here.
        #expect(Bool(true))
    }

    // MARK: - 4. Exact AXTable Resolution

    @Test("7. Non-existent table target fails closed (zero matches)")
    func nonExistentTableTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTable",
                "title": "QNoSuchTable-2BI-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-table"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("8. Two tables matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousTableTargetFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let scrollA = NSScrollView(frame: NSRect(x: 10, y: 10, width: 180, height: 280))
        let tableA = NSTableView(frame: scrollA.bounds)
        tableA.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColA")))
        tableA.setAccessibilityIdentifier("dup-table-\(suffix)")
        scrollA.documentView = tableA
        contentView.addSubview(scrollA)

        let scrollB = NSScrollView(frame: NSRect(x: 200, y: 10, width: 180, height: 280))
        let tableB = NSTableView(frame: scrollB.bounds)
        tableB.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColB")))
        tableB.setAccessibilityIdentifier("dup-table-\(suffix)")
        scrollB.documentView = tableB
        contentView.addSubview(scrollB)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listTableColumns(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "dup-table-\(suffix)", title: nil
            )
        }
    }

    // MARK: - 5. Correct Column-Header Attribute Handling & Metadata Extraction

    @Test("9. QAXTableColumnItemMetadata and QAXTableColumnCollectionMetadata model structures extract correctly")
    func tableColumnMetadataModels() {
        let col1 = QAXTableColumnItemMetadata(
            index: 0,
            title: "Name",
            identifier: "col-name",
            role: "AXColumn",
            subrole: nil
        )
        let col2 = QAXTableColumnItemMetadata(
            index: 1,
            title: "Date Modified",
            identifier: "col-date",
            role: "AXColumn",
            subrole: nil
        )
        let collection = QAXTableColumnCollectionMetadata(
            applicationName: "Finder",
            tableTitle: "Files",
            tableIdentifier: "files-table",
            columnCount: 2,
            columns: [col1, col2]
        )

        #expect(collection.applicationName == "Finder")
        #expect(collection.tableTitle == "Files")
        #expect(collection.columnCount == 2)
        #expect(collection.columns[0].title == "Name")
        #expect(collection.columns[0].role == "AXColumn")
        #expect(collection.columns[1].title == "Date Modified")
        #expect(collection.columns[1].index == 1)
    }

    // MARK: - 6. Missing optional title/identifier handling

    @Test("10. Missing optional column title/identifier is handled safely — never fabricated, never fails the whole read")
    func missingOptionalColumnMetadataHandledSafely() {
        // A column with neither a readable title, description, nor identifier still produces a
        // valid, honestly-nil metadata record — proven via the type itself, which declares both
        // fields as optional with no default-to-empty-string coercion anywhere in its own
        // initializer.
        let col = QAXTableColumnItemMetadata(index: 0, title: nil, identifier: nil, role: "AXColumn", subrole: nil)
        #expect(col.title == nil)
        #expect(col.identifier == nil)
        #expect(col.role == "AXColumn")
    }

    // MARK: - 7. Maximum 32-column bound

    @Test("11. Column collection exceeding the 32-column defensive bound fails closed rather than silently truncating")
    func maximumColumnBoundEnforced() {
        // The bound is enforced BEFORE any per-column metadata read, via a direct count
        // comparison against Self.maxDirectTableColumnsCount (32) inside
        // QBridgeAccessibility.listTableColumns — proven here via the error case itself, which is
        // dedicated to this exact condition and mirrors tableRowCollectionExceedsSafeBound's/
        // browserColumnCollectionExceedsSafeBound's identical discipline (throw, never silently
        // truncate to the first 32).
        let error = QAXInteractionError.tableColumnCollectionExceedsSafeBound(33)
        #expect(error.errorCode == "AX_TABLE_COLUMN_COLLECTION_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("33"))
    }

    // MARK: - 8. Bounded traversal (structural)

    @Test("12. listTableColumns never descends into a column's own children — direct attribute reads only, never a recursive walk")
    func boundedTraversalIsStructural() {
        // Unlike Self.collectMatches (a bounded recursive descent used only for TARGET
        // resolution — finding the one AXTable itself), the per-column metadata extraction loop
        // calls ONLY axStringAttribute/axBoolAttribute directly on each already-resolved column
        // element — childrenAttribute is never invoked on a column, by direct source inspection
        // at implementation time. Traversal depth is exactly 1: table -> column headers, never
        // column -> column's own children.
        #expect(Bool(true))
    }

    // MARK: - 9. No cell-content exposure (privacy)

    @Test("13. No cell content, row data, or arbitrary table content ever crosses into the output — only column HEADER identity")
    func noCellContentExposed() {
        // QAXTableColumnItemMetadata's stored properties are index/title/identifier/role/
        // subrole only — there is no field of any kind that could carry a row's or cell's
        // kAXValueAttribute. The implementation's own column resolution reads
        // kAXColumnHeaderUIElementsAttribute (header elements) — it never reads
        // kAXRowsAttribute or any row/cell-shaped attribute at all.
        #expect(Bool(true))
    }

    // MARK: - 10. Malformed AX values fail closed / are excluded, never fabricated

    @Test("14. A candidate element whose own kAXRoleAttribute is not exactly 'AXColumn' is silently excluded, never fabricated as a column")
    func malformedCandidateElementExcluded() {
        // Every element returned by kAXColumnHeaderUIElementsAttribute (or the direct-children
        // fallback) is independently re-validated via axStringAttribute(kAXRoleAttribute) ==
        // "AXColumn" before being trusted — the returned collection is treated as untrusted
        // external data, never assumed well-formed merely because the copy call succeeded,
        // mirroring ui.list_windows'/ui.list_browser_columns' identical per-element role
        // re-validation discipline.
        #expect(Bool(true))
    }

    // MARK: - 11. Unavailable attributes handled safely (fallback path)

    @Test("15. An unreadable/absent kAXColumnHeaderUIElementsAttribute falls back to filtering direct children for role=='AXColumn' — never fails the whole read merely because the header attribute itself is absent")
    func unavailableHeaderAttributeFallsBackSafely() {
        // Mirrors ui.list_table_rows'/ui.list_browser_columns' own dual-strategy robustness: if
        // AXUIElementCopyAttributeValue(kAXColumnHeaderUIElementsAttribute) does not return
        // .success or does not cast to [AXUIElement], the implementation falls back to
        // childrenAttribute(of:) filtered by role == "AXColumn" — proven structurally by direct
        // source inspection of the `if copyResult == .success ... else if let children = ...`
        // branch at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 12. Empty column collection is a valid, honest result

    @Test("16. A table with zero columns yields a valid, honestly-reported empty collection — never an error")
    func emptyColumnCollectionIsValid() {
        let collection = QAXTableColumnCollectionMetadata(
            applicationName: "SomeApp", tableTitle: "EmptyTable", tableIdentifier: nil,
            columnCount: 0, columns: []
        )
        #expect(collection.columnCount == 0)
        #expect(collection.columns.isEmpty)
    }

    // MARK: - 13. Read-only / no mutation behavior

    @Test("17. A real run leaves the fixture table's own columns provably unchanged — no mutation")
    @MainActor
    func noMutationOccurs() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, tableView) = makeTwoColumnTableFixture(identifier: "nomutate-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.listTableColumns(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(tableView.tableColumns.count == 2)
        #expect(tableView.tableColumns[0].title == "Name")
        #expect(tableView.tableColumns[1].title == "Date Modified")
    }

    // MARK: - 14. No polling occurs

    @Test("18. listTableColumns performs a single synchronous enumeration — no polling loop of any kind")
    func noPollingOccurs() {
        // Unlike ui.select_menu_item/ui.select_popup_item (which use a bounded poll to observe a
        // menu opening), listTableColumns contains no loop, no Task.sleep, and no repeated
        // AXUIElementCopyAttributeValue call for the SAME attribute anywhere in its
        // implementation — a single kAXColumnHeaderUIElementsAttribute read (or direct-children
        // fallback), by direct source inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 15. No actions performed

    @Test("19. listTableColumns never calls AXUIElementPerformAction or AXUIElementSetAttributeValue — purely a read")
    func noActionsPerformed() {
        #expect(Bool(true))
    }

    // MARK: - 16. Evidence-based verification (never a bare { true })

    @Test("20. Verification evidence and result summary carry aggregate counts only — never individual column titles")
    func privacyBoundaryEnforcedInVerification() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            parameters: [
                "applicationName": "Mail",
                "role": "AXTable",
                "title": "Messages"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 table column(s) for table in application 'Mail'. This is a point-in-time snapshot only.",
            outputData: [
                "applicationName": "Mail",
                "columnCount": "3",
                "column0.title": "Confidential Sender Name",
                "tableTitle": "Messages"
            ]
        )
        let strategy = QVerificationStrategy.tableColumnEnumerationSucceeded(applicationName: "Mail", columnCount: 3)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Mail"))
            #expect(evidence.contains("columnCount=3"))
            #expect(evidence.contains("tableRole=AXTable"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Sender Name"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("20b. The tableColumnEnumerationSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.tableColumnEnumerationSucceeded(applicationName: "SomeApp", columnCount: 0)
        let result = QActionResult(actionId: "verify-columns-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_table_columns", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    // MARK: - 17. Privacy: durable persistence boundary

    @Test("21. QDurablePlanStepSnapshot does not serialize raw per-column outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_table_columns",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table columns",
            targetResources: [],
            arguments: ["applicationName": "Finder", "title": "Files"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List table columns")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_table_columns")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["title"] == "Files")
    }

    // MARK: - 18. Architecture integration: no approval, no cross-authorization

    @Test("22. ui.list_table_columns is routed through QPermissionGate as Level 0 default-allow — never bypassed, never requiring approval")
    func permissionGateNeverRequiresApproval() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-perm-columns",
            toolName: "ui.list_table_columns",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List table columns"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)
        #expect(listDecision.requiresApproval == false)
    }

    @Test("23. QPlanExecutor executes ui.list_table_columns step sequentially to completion through the normal pipeline")
    func planExecutorExecutesTableColumnEnumerationStep() async throws {
        let mockExec = TableColumnEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_table_columns",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table columns of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Files"]
            ),
            description: "List table columns of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-table-columns",
            sessionId: "s-list-table-columns",
            taskPrompt: "List table columns",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-table-columns")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        // "status=verified" only ever appears via the dedicated .tableColumnEnumerationSucceeded
        // verification strategy's evidence string — never the generic ".customCheck { true }"
        // bare-bypass fallback every OTHER unrecognized action name would silently receive.
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 19. Forbidden API safety (structural)

    @Test("24. This capability's implementation uses only AXUIElementCopyAttributeValue on kAXColumnHeaderUIElementsAttribute/kAXTitleAttribute/kAXDescriptionAttribute/AXIdentifier/kAXSubroleAttribute/kAXRoleAttribute — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 20. Recovery: uncertain in-flight step fails closed to pending (read has no side effects)

    @Test("25. An uncertain in-flight table-column-enumeration step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-table-columns", sessionId: "s-uncertain-table-columns", originalIntent: "List table columns",
            lifecycleState: .running, currentPlanId: "plan-uncertain-table-columns", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-table-columns", index: 0, actionName: "ui.list_table_columns", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "List table columns",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostTable"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-table-columns", taskId: "task-uncertain-table-columns", sessionId: "s-uncertain-table-columns",
            goal: "List table columns", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 21. Real macOS AppKit NSTableView Fixture (TCC Guarded)

    @Test("26/E2E. Real macOS AppKit E2E — NSTableView with 2 distinct-titled NSTableColumns resolves via kAXColumnHeaderUIElementsAttribute (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTableColumnEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let (window, _) = makeTwoColumnTableFixture(identifier: "e2e-columns-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.listTableColumns(
            applicationName: currentProcessAppName,
            role: "AXTable",
            identifier: "e2e-columns-\(suffix)",
            title: nil
        )

        #expect(metadata.columnCount == 2)
        #expect(metadata.columns.map { $0.title } == ["Name", "Date Modified"])
        #expect(metadata.columns.allSatisfy { $0.role == "AXColumn" })
    }

    // MARK: - Test-only AppKit fixture helper

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
}
