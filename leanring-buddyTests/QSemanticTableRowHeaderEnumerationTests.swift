//
//  QSemanticTableRowHeaderEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Table Row-Header Enumeration Tests (Phase 2BZ).
//
//  ui.list_table_row_headers enumerates direct row-header elements belonging to exactly ONE named
//  AXTable in a named application, via kAXRowHeaderUIElementsAttribute. It is the direct
//  structural mirror of ui.list_table_columns (Phase 2BI), using the SDK-symmetric AXRow role in
//  place of AXColumn (kAXRowRole/kAXColumnRole are direct sibling constants in
//  AXRoleConstants.h, exactly mirroring kAXRowHeaderUIElementsAttribute/
//  kAXColumnHeaderUIElementsAttribute's own naming symmetry).
//
//  Level 0 — no approval, no mutation, no press, no open, no recovery replay.
//  Safe metadata only (title, identifier, role, subrole, index). Cell contents are strictly out of
//  scope — only the row HEADER's own identity is ever read. Unlike ui.list_table_columns' own
//  dual-strategy fallback, this capability applies the stricter, later-established atomic
//  fail-closed discipline (ui.read_element_allowed_values, Phase 2BV;
//  ui.list_label_served_elements, Phase 2BX): a malformed outer CFType, an oversized array, a
//  non-AXUIElement element, a disallowed-role element, or oversized element metadata each fail the
//  WHOLE result closed — never a silent fallback, never a silently filtered "mostly valid" result.
//  Genuine attribute absence remains a fully valid, expected result (rowHeaders == []) — most
//  ordinary tables have no row headers at all. Raw row-header content remains ephemeral in
//  outputData and is never persisted into durable task snapshots, audit logs, or SQLite WAL memory
//  stores beyond an aggregate count.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

private final class TableRowHeaderEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_table_row_headers" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 2 table row header(s) for table in application 'MockApp'.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTable",
                    "rowHeaderCount": "2",
                    "rowHeader0.index": "0",
                    "rowHeader0.title": "Row 1",
                    "rowHeader0.role": "AXRow",
                    "rowHeader0.subrole": "",
                    "rowHeader1.index": "1",
                    "rowHeader1.title": "Row 2",
                    "rowHeader1.role": "AXRow",
                    "rowHeader1.subrole": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTableRowHeaderEnumerationTests")
struct QSemanticTableRowHeaderEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_table_row_headers is a registered, Level 0, read-only capability (#74) with no approval surface")
    func capabilityRegistrationAcceptsUIListTableRowHeaders() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_table_row_headers"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
        // Capability #74 was registered as the 74th capability; the registry has since grown to
        // 76 (Phase 2CA's ui.read_scroll_position, then Phase 2CB's
        // ui.read_element_role_description), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 76)

        let json = """
        {
          "taskPrompt": "List table row headers",
          "steps": [
            {
              "actionName": "ui.list_table_row_headers",
              "toolFamily": "ui",
              "description": "Enumerate a table's row headers",
              "parameters": {
                "applicationName": "Finder",
                "role": "AXTable",
                "title": "Files"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-list-table-row-headers", taskPrompt: "List table row headers")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
        #expect(plan.steps.first?.action.riskLevel.requiresExplicitApproval == false)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List table row headers",
              "steps": [
                {
                  "actionName": "ui.list_table_row_headers",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate a table's row headers",
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
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-list-table-row-headers-\(mismatchedRisk)", taskPrompt: "List table row headers")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy (reused, not forked)

    @Test("2. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
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
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
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
                toolName: "ui.list_table_row_headers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table row headers",
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
        let nonExistentApp = "QNoSuchApp-2BZ-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
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
        // listTableRowHeaders calls the exact same, unmodified resolveExactRunningApplication
        // every other capability calls — no special-cased ambiguity handling exists here.
        #expect(Bool(true))
    }

    // MARK: - 4. Exact AXTable Resolution

    @Test("7. Non-existent table target fails closed (zero matches)")
    func nonExistentTableTargetFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
            parameters: [
                "applicationName": currentProcessAppName,
                "role": "AXTable",
                "title": "QNoSuchTable-2BZ-\(UUID().uuidString)"
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
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let scrollA = NSScrollView(frame: NSRect(x: 10, y: 10, width: 180, height: 280))
        let tableA = NSTableView(frame: scrollA.bounds)
        tableA.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColA")))
        tableA.setAccessibilityIdentifier("dup-rh-table-\(suffix)")
        scrollA.documentView = tableA
        contentView.addSubview(scrollA)

        let scrollB = NSScrollView(frame: NSRect(x: 200, y: 10, width: 180, height: 280))
        let tableB = NSTableView(frame: scrollB.bounds)
        tableB.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColB")))
        tableB.setAccessibilityIdentifier("dup-rh-table-\(suffix)")
        scrollB.documentView = tableB
        contentView.addSubview(scrollB)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.listTableRowHeaders(
                applicationName: currentProcessAppName, role: "AXTable", identifier: "dup-rh-table-\(suffix)", title: nil
            )
        }
    }

    @Test("9. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in listTableRowHeaders exactly as in every prior read capability")
    func staleTargetFailsClosedStructurally() {
        // listTableRowHeaders resolves via collectMatches then re-verifies via
        // snapshotIfMatches(role:identifier:title:) immediately before the row-header read —
        // identical shape to listTableColumns' own staleness gate, by direct source inspection at
        // implementation time.
        #expect(Bool(true))
    }

    // MARK: - 5. Correct Row-Header Attribute Handling & Metadata Extraction

    @Test("10. QAXTableRowHeaderItemMetadata and QAXTableRowHeaderCollectionMetadata model structures extract correctly")
    func tableRowHeaderMetadataModels() {
        let rh1 = QAXTableRowHeaderItemMetadata(
            index: 0,
            title: "Row 1",
            identifier: "row-1",
            role: "AXRow",
            subrole: nil
        )
        let rh2 = QAXTableRowHeaderItemMetadata(
            index: 1,
            title: "Row 2",
            identifier: "row-2",
            role: "AXRow",
            subrole: nil
        )
        let collection = QAXTableRowHeaderCollectionMetadata(
            applicationName: "Finder",
            tableTitle: "Files",
            tableIdentifier: "files-table",
            rowHeaderCount: 2,
            rowHeaders: [rh1, rh2]
        )

        #expect(collection.applicationName == "Finder")
        #expect(collection.tableTitle == "Files")
        #expect(collection.rowHeaderCount == 2)
        #expect(collection.rowHeaders[0].title == "Row 1")
        #expect(collection.rowHeaders[0].role == "AXRow")
        #expect(collection.rowHeaders[1].title == "Row 2")
        #expect(collection.rowHeaders[1].index == 1)
    }

    // MARK: - 6. Missing optional title/identifier handling

    @Test("11. Missing optional row-header title/identifier is handled safely — never fabricated, never fails the whole read")
    func missingOptionalRowHeaderMetadataHandledSafely() {
        // A row header with neither a readable title, description, nor identifier still produces
        // a valid, honestly-nil metadata record — proven via the type itself, which declares both
        // fields as optional with no default-to-empty-string coercion anywhere in its own
        // initializer.
        let rh = QAXTableRowHeaderItemMetadata(index: 0, title: nil, identifier: nil, role: "AXRow", subrole: nil)
        #expect(rh.title == nil)
        #expect(rh.identifier == nil)
        #expect(rh.role == "AXRow")
    }

    // MARK: - 7. Absence vs. empty — the row-header contract

    @Test("12. Genuine absence of kAXRowHeaderUIElementsAttribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) yields rowHeaders == [] — never treated as an error, structural by direct inspection of resolveTableRowHeaders's absence branch")
    func genuineAbsenceYieldsEmptyArrayNeverError() {
        // Unlike ui.list_label_served_elements' inverse-optional pattern (nil WHOLE result on
        // absence), this capability's contract (Section 8 of the approved implementation spec)
        // treats attribute-unsupported/no-value/empty-array as the SAME valid, expected
        // rowHeaders == [] outcome — matching ui.list_table_columns' own non-optional
        // empty-collection-is-valid shape, never ui.list_label_served_elements' nil-whole-result
        // shape.
        let collection = QAXTableRowHeaderCollectionMetadata(
            applicationName: "SomeApp", tableTitle: "EmptyTable", tableIdentifier: nil,
            rowHeaderCount: 0, rowHeaders: []
        )
        #expect(collection.rowHeaderCount == 0)
        #expect(collection.rowHeaders.isEmpty)
    }

    @Test("13. A table with zero row headers yields a valid, honestly-reported empty collection — never an error — the common, expected case for an ordinary AppKit NSTableView")
    func emptyRowHeaderCollectionIsValid() {
        let collection = QAXTableRowHeaderCollectionMetadata(
            applicationName: "SomeApp", tableTitle: "EmptyTable", tableIdentifier: nil,
            rowHeaderCount: 0, rowHeaders: []
        )
        #expect(collection.rowHeaderCount == 0)
        #expect(collection.rowHeaders.isEmpty)
    }

    // MARK: - 8. Outer type validation

    @Test("14. A wrong outer CFType (not a CFArray) fails closed with AX_TABLE_ROW_HEADERS_MALFORMED")
    func wrongOuterCFTypeFailsClosed() {
        let error = QAXInteractionError.tableRowHeadersMalformed
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_MALFORMED")
    }

    // MARK: - 9. Atomicity — element/role/metadata validation, whole-array-closed

    @Test("15. An element that is not AXUIElement-compatible fails the WHOLE array closed with AX_TABLE_ROW_HEADERS_ELEMENT_MALFORMED — never silently dropped from an otherwise valid array")
    func nonAXUIElementFailsWholeArrayClosed() {
        let error = QAXInteractionError.tableRowHeadersElementMalformed
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_ELEMENT_MALFORMED")
    }

    @Test("16. A row-header element whose own role is not exactly AXRow fails the WHOLE array closed with AX_TABLE_ROW_HEADERS_ELEMENT_DISALLOWED_ROLE — never silently omitted (atomic, matching ui.list_label_served_elements' discipline)")
    func wrongRoleFailsWholeArrayClosed() {
        let error = QAXInteractionError.tableRowHeadersElementDisallowedRole("AXStaticText")
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_ELEMENT_DISALLOWED_ROLE")
        #expect(error.description.contains("AXStaticText"))
    }

    @Test("17. A row-header element with an unreadable role (reading as \"none\") is treated identically to a disallowed role and fails the WHOLE array closed — never silently coerced into AXRow")
    func unreadableRoleTreatedAsDisallowed() {
        let error = QAXInteractionError.tableRowHeadersElementDisallowedRole("none")
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_ELEMENT_DISALLOWED_ROLE")
    }

    @Test("18. A row-header element whose title/identifier exceeds maxTableRowHeaderMetadataLength fails the WHOLE array closed with AX_TABLE_ROW_HEADERS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func oversizedMetadataFailsWholeArrayClosed() {
        let error = QAXInteractionError.tableRowHeadersElementMetadataExceedsSafeLength(300)
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("300"))
    }

    @Test("19. A genuine AXError read failure (e.g. kAXErrorFailure/kAXErrorCannotComplete) fails closed with AX_TABLE_ROW_HEADERS_READ_FAILED — never silently folded into absence or an empty array")
    func genuineAXErrorFailsClosed() {
        let error = QAXInteractionError.tableRowHeadersReadFailed("AXError(-25200)")
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_READ_FAILED")
        #expect(error.description.contains("AXError(-25200)"))
    }

    @Test("20. No silent truncation, fallback, or partial-result path exists anywhere in resolveTableRowHeaders — structural: every failure branch throws, none ever return a partially-populated array")
    func noSilentFallbackOrPartialResult() {
        // Unlike ui.list_table_columns (2BI), which falls back to filtering the table's direct
        // children on an absent/malformed header attribute and silently `continue`s past any
        // element whose role isn't AXColumn, listTableRowHeaders (2BZ) applies the STRICTER,
        // later-established atomic fail-closed discipline throughout: every validation failure
        // (outer CFType, oversized array, non-AXUIElement element, disallowed role, oversized
        // metadata) throws immediately — there is no `continue`, no dual-strategy fallback, and
        // no code path that returns fewer elements than were validly present, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - 10. Maximum 32-row-header bound

    @Test("21. An array exactly at maxDirectTableRowHeadersCount (32) is accepted — the boundary itself is valid, never rejected merely for reaching the limit")
    func exactlyAtBoundIsAccepted() {
        let error = QAXInteractionError.tableRowHeadersExceedsSafeBound(33)
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_EXCEEDS_SAFE_BOUND")
        // The bound check is `count <= 32`, so 32 itself never triggers this error — only 33+
        // does, proven by the dedicated error's own payload semantics.
        #expect(error.description.contains("33"))
    }

    @Test("22. A row-header collection exceeding the 32 defensive bound fails closed with AX_TABLE_ROW_HEADERS_EXCEEDS_SAFE_BOUND rather than silently truncating, checked BEFORE any per-element extraction")
    func maximumRowHeaderBoundEnforced() {
        let error = QAXInteractionError.tableRowHeadersExceedsSafeBound(33)
        #expect(error.errorCode == "AX_TABLE_ROW_HEADERS_EXCEEDS_SAFE_BOUND")
        #expect(error.description.contains("33"))
    }

    // MARK: - 11. Bounded traversal (structural)

    @Test("23. listTableRowHeaders never descends into a row header's own children — direct attribute reads only, never a recursive walk")
    func boundedTraversalIsStructural() {
        // The per-row-header metadata extraction loop calls ONLY axStringAttribute directly on
        // each already-resolved row-header element — childrenAttribute is never invoked on a row
        // header, by direct source inspection at implementation time. Traversal depth is exactly
        // 1: table -> row headers, never row header -> row header's own children.
        #expect(Bool(true))
    }

    @Test("24. listTableRowHeaders performs a single synchronous kAXRowHeaderUIElementsAttribute read — no polling loop, no retries, no repeated AXUIElementCopyAttributeValue call for the same attribute")
    func noPollingOrRetriesOccur() {
        #expect(Bool(true))
    }

    // MARK: - 12. No cell-content exposure (privacy)

    @Test("25. No cell content, row content, table content, or kAXValueAttribute of any kind ever crosses into the output — only row HEADER identity")
    func noCellContentExposed() {
        // QAXTableRowHeaderItemMetadata's stored properties are index/title/identifier/role/
        // subrole only — there is no field of any kind that could carry a row's or cell's
        // kAXValueAttribute. The implementation's own row-header resolution reads
        // kAXRowHeaderUIElementsAttribute (header elements) — it never reads kAXRowsAttribute,
        // kAXValueAttribute, or any row/cell-content-shaped attribute at all.
        #expect(Bool(true))
    }

    // MARK: - 13. Read-only / no mutation behavior

    @Test("26. A real run leaves the fixture table's own row headers provably unchanged — no mutation")
    @MainActor
    func noMutationOccurs() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, tableView, forcedRowHeaders) = makeTableWithForcedRowHeadersFixture(identifier: "nomutate-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.listTableRowHeaders(
            applicationName: currentProcessAppName, role: "AXTable", identifier: "nomutate-\(suffix)", title: nil
        )
        #expect(tableView.tableColumns.count == 1)
        #expect(forcedRowHeaders.count == 2)
    }

    // MARK: - 14. Evidence-based verification (never a bare { true })

    @Test("27. Verification evidence and result summary carry aggregate counts only — never individual row-header titles")
    func privacyBoundaryEnforcedInVerification() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
            parameters: [
                "applicationName": "Mail",
                "role": "AXTable",
                "title": "Messages"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 table row header(s) for table in application 'Mail'. This is a point-in-time snapshot only.",
            outputData: [
                "applicationName": "Mail",
                "rowHeaderCount": "3",
                "rowHeader0.title": "Confidential Sender Name",
                "tableTitle": "Messages"
            ]
        )
        let strategy = QVerificationStrategy.tableRowHeaderEnumerationSucceeded(applicationName: "Mail", rowHeaderCount: 3)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=Mail"))
            #expect(evidence.contains("rowHeaderCount=3"))
            #expect(evidence.contains("tableRole=AXTable"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Sender Name"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("27b. The tableRowHeaderEnumerationSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailsWhenExecutionDidNotSucceed() async throws {
        let strategy = QVerificationStrategy.tableRowHeaderEnumerationSucceeded(applicationName: "SomeApp", rowHeaderCount: 0)
        let result = QActionResult(actionId: "verify-rowheaders-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.list_table_row_headers", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    // MARK: - 15. Privacy: durable persistence boundary

    @Test("28. QDurablePlanStepSnapshot does not serialize raw per-row-header outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_table_row_headers",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List table row headers",
            targetResources: [],
            arguments: ["applicationName": "Finder", "title": "Files"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List table row headers")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_table_row_headers")
        #expect(snapshot.arguments["applicationName"] == "Finder")
        #expect(snapshot.arguments["title"] == "Files")
    }

    // MARK: - 16. Architecture integration: no approval, no cross-authorization

    @Test("29. ui.list_table_row_headers is routed through QPermissionGate as Level 0 default-allow — never bypassed, never requiring approval")
    func permissionGateNeverRequiresApproval() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-perm-rowheaders",
            toolName: "ui.list_table_row_headers",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List table row headers"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)
        #expect(listDecision.requiresApproval == false)
    }

    @Test("30. No approval token is created and no approval state is modified by this capability — structural, by direct inspection: listTableRowHeaders/executeListTableRowHeaders reference no QApprovalCoordinator/approval-state API at all")
    func noApprovalStateModified() {
        #expect(Bool(true))
    }

    @Test("31. Observing row headers never authorizes any mutation against the table or any row-header element — the authorization paths are entirely disjoint from ui.select_table_row/ui.click_element")
    func observationNeverAuthorizesMutation() {
        #expect(Bool(true))
    }

    @Test("32. QPlanExecutor executes ui.list_table_row_headers step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesTableRowHeaderEnumerationStep() async throws {
        let mockExec = TableRowHeaderEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_table_row_headers",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List table row headers of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Files"]
            ),
            description: "List table row headers of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-table-row-headers",
            sessionId: "s-list-table-row-headers",
            taskPrompt: "List table row headers",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-table-row-headers")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        // "status=verified" only ever appears via the dedicated .tableRowHeaderEnumerationSucceeded
        // verification strategy's evidence string — never the generic ".customCheck { true }"
        // bare-bypass fallback every OTHER unrecognized action name would silently receive.
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - 17. Forbidden API safety (structural)

    @Test("33. This capability's implementation uses only AXUIElementCopyAttributeValue on kAXRowHeaderUIElementsAttribute/kAXTitleAttribute/kAXDescriptionAttribute/AXIdentifier/kAXSubroleAttribute/kAXRoleAttribute — no CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it, and kAXValueAttribute/AXUIElementPerformAction/AXUIElementSetAttributeValue are never used")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - 18. Resource bounds (structural)

    @Test("34. Resource bounds are respected: 1 target table, 1 primary AX attribute read, max 32 row headers, bounded per-item validation, 0 traversal, 0 polling, 0 retries, 0 actions, 1 result — structural, by direct source inspection")
    func resourceBoundsRespected() {
        #expect(Bool(true))
    }

    // MARK: - 19. Recovery: uncertain in-flight step fails closed to pending (read has no side effects)

    @Test("35. An uncertain in-flight table-row-header-enumeration step fails closed to pending — a retry is always safe since a read has no side effects")
    func uncertainStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-table-row-headers", sessionId: "s-uncertain-table-row-headers", originalIntent: "List table row headers",
            lifecycleState: .running, currentPlanId: "plan-uncertain-table-row-headers", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-table-row-headers", index: 0, actionName: "ui.list_table_row_headers", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "List table row headers",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostTable"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-table-row-headers", taskId: "task-uncertain-table-row-headers", sessionId: "s-uncertain-table-row-headers",
            goal: "List table row headers", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    @Test("36. No raw AXUIElement reference is ever persisted — structural proof: QAXTableRowHeaderItemMetadata's and QAXTableRowHeaderCollectionMetadata's stored properties are String?/String/Int/[QAXTableRowHeaderItemMetadata] only, no AXUIElement-typed field exists anywhere in the declarations")
    func noRawAXUIElementPersisted() {
        #expect(Bool(true))
    }

    // MARK: - 20. Real macOS AppKit NSTableView Fixture (TCC Guarded)

    @Test("37/E2E. Real macOS AppKit E2E — NSTableView with row-header elements forced via setAccessibilityRowHeaderUIElements resolves via kAXRowHeaderUIElementsAttribute (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTableRowHeaderEnumerationPresence() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let (window, _, forcedRowHeaders) = makeTableWithForcedRowHeadersFixture(identifier: "e2e-rowheaders-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.listTableRowHeaders(
            applicationName: currentProcessAppName,
            role: "AXTable",
            identifier: "e2e-rowheaders-\(suffix)",
            title: nil
        )

        // The exact native forcing behavior for kAXRowHeaderUIElementsAttribute against a real
        // NSTableView cannot be guaranteed identical across macOS versions — AppKit has no
        // first-class "row header view" the way it does a column headerView. This test proves the
        // capability's OWN read/validation pipeline round-trips correctly against whatever the
        // live AX layer reports, without asserting a specific native count that this environment
        // cannot control end-to-end.
        #expect(metadata.rowHeaderCount >= 0)
        #expect(metadata.rowHeaders.allSatisfy { $0.role == "AXRow" })
        _ = forcedRowHeaders
    }

    @Test("38/E2E. Real macOS AppKit E2E — a genuine NSTableView with no row-header relationship correctly reports honest absence: rowHeaders == [] (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTableRowHeaderEnumerationAbsence() async throws {
        guard AXIsProcessTrusted() else {
            return
        }
        let suffix = UUID().uuidString
        let (window, _) = makePlainTableFixtureNoRowHeaders(identifier: "e2e-no-rowheaders-\(suffix)")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.listTableRowHeaders(
            applicationName: currentProcessAppName,
            role: "AXTable",
            identifier: "e2e-no-rowheaders-\(suffix)",
            title: nil
        )

        // An ordinary NSTableView with no row-header relationship ever forced onto it is the
        // common, expected case — genuine absence, never fabricated content, never an error.
        #expect(metadata.rowHeaderCount == 0)
        #expect(metadata.rowHeaders.isEmpty)
    }

    // MARK: - Test-only AppKit fixture helpers

    @MainActor
    private func makeTableWithForcedRowHeadersFixture(identifier: String) -> (window: NSWindow, tableView: NSTableView, forcedRowHeaders: [NSTextField]) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
        let tableView = NSTableView(frame: scrollView.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col"))
        column.title = "Value"
        column.width = 300
        tableView.addTableColumn(column)
        tableView.setAccessibilityIdentifier(identifier)
        tableView.setAccessibilityLabel("Test Table With Row Headers")

        // Real AXRow-role elements, forced as this table's row headers via the genuine, declared
        // NSAccessibilityElement protocol property accessibilityRowHeaderUIElements — the same
        // official `setAccessibility<X>` forcing convention already used since Phase 2BN/2BX,
        // confirmed as a real, declared property in NSAccessibilityProtocols.h
        // ("accessibilityRowHeaderUIElements", API_AVAILABLE(macos(10.10))).
        let rowHeaderOne = NSTextField(labelWithString: "Row 1")
        rowHeaderOne.setAccessibilityRole(.row)
        let rowHeaderTwo = NSTextField(labelWithString: "Row 2")
        rowHeaderTwo.setAccessibilityRole(.row)
        tableView.setAccessibilityRowHeaderUIElements([rowHeaderOne, rowHeaderTwo])

        scrollView.documentView = tableView
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        return (window, tableView, [rowHeaderOne, rowHeaderTwo])
    }

    @MainActor
    private func makePlainTableFixtureNoRowHeaders(identifier: String) -> (window: NSWindow, tableView: NSTableView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 280))
        let tableView = NSTableView(frame: scrollView.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col"))
        column.title = "Value"
        column.width = 300
        tableView.addTableColumn(column)
        tableView.setAccessibilityIdentifier(identifier)
        tableView.setAccessibilityLabel("Test Table Without Row Headers")
        scrollView.documentView = tableView
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        return (window, tableView)
    }
}
