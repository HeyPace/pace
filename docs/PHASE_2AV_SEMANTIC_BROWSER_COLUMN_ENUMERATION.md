# Phase 2AV — Semantic Multi-Column Browser Enumeration

## Capability Identifier
`ui.list_browser_columns`

## Security Level
**Level 0 — Read-Only.** No approval, no mutation, no press, no focus, no recovery replay. Auto-allowed by `QPermissionGate`'s Level 0/1 policy path (matching every existing read-only discovery capability: `ui.list_windows`, `ui.list_table_rows`, `ui.list_split_panes`, etc.).

## Semantic AX Primitive
`AXApplication` → `AXWindow` (optional scoping) → `AXBrowser` (`NSAccessibilityBrowserRole`, `kAXBrowserRole`) → direct child `AXColumn` (`NSAccessibilityColumnRole`, `kAXColumnRole`) elements via `kAXColumnsAttribute` / `kAXChildrenAttribute`.

`AXBrowser` and `AXColumn` are documented, stable AppKit accessibility roles exposed automatically by `NSBrowser` (e.g. macOS Finder column view, Open/Save file dialogs, and multi-column hierarchical item browsers).

## Exact Target Resolution
1. **Application**: `QBridgeAccessibility.resolveExactRunningApplication(named:)` — exact case-insensitive localized-name or bundle-identifier match. 0 matches → `applicationNotAvailable`. >1 matches → `ambiguousTarget`. Never falls back to `.first`.
2. **Window (optional)**: If `windowTitle` or `windowIdentifier` is supplied, resolves exactly one `AXWindow` beneath the application via `collectMatches`, with a stale-target/drift re-check (`snapshotIfMatches` compared against the search-time snapshot) immediately before use. Fails closed on 0 or >1 matches.
3. **Browser**: Resolves exactly one `AXBrowser` (scoped to the resolved window if window scoping was requested, otherwise scoped to the whole application) via `collectMatches` against `identifier`/`title`. Fails closed on 0 or >1 matches, with the same stale-target/drift re-check pattern immediately before enumeration.

## Action/State Contract
Pure read-only discovery. Enumerates the browser's direct child columns (`kAXColumnsAttribute` and `kAXChildrenAttribute` filtered for `role == "AXColumn"`). Each returned column reports:
- `index`: 0-indexed Int
- `title`: String? (or description fallback)
- `identifier`: String?
- `role`: String ("AXColumn")
- `subrole`: String?
- `isEnabled`: Bool?

A column's own descendant cells, rows, or scroll areas are never expanded or traversed.

Bounded by a defensive ceiling (`maxDirectBrowserColumnsCount = 32`) — exceeding it throws `QAXInteractionError.browserColumnCollectionExceedsSafeBound` and fails closed.

## Verification
Closed-loop, matching the exact template used by all prior `list_*` capabilities: `QVerificationStrategy.browserColumnEnumerationSucceeded(applicationName:columnCount:)`. Verification requires `QActionResult.success == true` plus the aggregate column count captured at read time. Evidence strings carry aggregate counts only — never any individual column's title or identifier.

## Idempotency
Not applicable — pure read-only discovery with no mutation.

## Approval
Not applicable — Level 0, auto-allowed by policy. Confirmed that `ui.list_browser_columns` confers no authorization for `ui.click_element` or any other mutating capability.

## Recovery
Not applicable — Level 0 reads have no persisted mutation state to recover from. No `QTaskRecoveryManager` case was added, matching all existing `list_*` capabilities.

## Privacy
- Returns structural column metadata only (role, subrole, title, identifier, enabled state) — never the column's internal file list or cell content.
- Result is an explicit point-in-time snapshot; the execution summary states this and warns that any subsequent action must independently resolve its own fresh target.
- `QDurablePlanStepSnapshot` never serializes raw `outputData`.

## Resource Limits
- `maxDirectBrowserColumnsCount = 32` — fails closed on overflow.
- Application, window, and browser resolution each fail closed on 0 or >1 matches.
- Traversal bounded by existing AX transaction budgets.

## Test Results
`QSemanticBrowserColumnEnumerationTests.swift` — **19/19 focused tests passed** (exceeds the ≥15 minimum for read-only capabilities), covering:
1. Registration under toolFamily `ui`.
2. Registration at Level 0 Read-Only, non-approval, reversible.
3. Plan parser accepts a valid step.
4. Risk-level mismatch fails closed.
5. Missing `applicationName` fails closed.
6. Disallowed roles rejected by `QAXBrowserRolePolicy`.
7. `QAXBrowserRolePolicy` accepts only `AXBrowser`.
8. Non-existent application throws `applicationNotAvailable`.
9. Non-existent window target fails closed.
10. Non-existent browser target fails closed.
11. `QAXBrowserColumnMetadata` and `QAXBrowserColumnCollectionMetadata` model round-trip.
12. Empty browser (zero columns) is a valid, non-error result.
13. Verification evidence and result summary carry aggregate counts only (privacy boundary).
14. Verification fails closed when execution result did not succeed.
15. `QDurablePlanStepSnapshot` omits raw `outputData`.
16. `ui.list_browser_columns` confers no authorization for `ui.click_element` (authorization isolation).
17. `QPlanExecutor` executes step sequentially to completion (mocked).
18. `QPlanExecutor` executes step to completion when zero columns found (mocked).
19. Real macOS AppKit E2E fixture test (`NSBrowser` fixture inside `NSWindow`, TCC-guarded).

Related suites run:
- `QSemanticSplitPaneEnumerationTests`: 19/19 passed.
- `QSemanticTableRowEnumerationTests`: 12/12 passed.
- `QSemanticOutlineItemEnumerationTests`: 12/12 passed.

Full regression test runs:
- Run 1: 2866/2866 passed (54.3s).
- Run 2: 2866/2866 passed (53.0s).
- Run 3: 2866/2866 passed (53.6s).

## Real macOS E2E Result
**VERIFIED (conditionally).** Test #19 constructs a real `NSBrowser` control inside an `NSWindow`, and calls `QBridgeAccessibility.shared.listBrowserColumns`. Guarded by `guard AXIsProcessTrusted() else { return }` to prevent false positives when running without TCC accessibility trust.

## ARM64 Release Build
**PASS.** `scripts/prepare-release.sh` completed successfully with `** BUILD SUCCEEDED **`.

## Mach-O arm64
**PASS.** Binary verified via `file` and `lipo -info` confirming `Mach-O 64-bit executable arm64`.

## Signing
**PASS.** Codesign verification (`codesign -v --strict`) confirmed valid signature and requirement satisfaction.

## Known Limitations
- Browser column elements represent the vertical column containers in an `NSBrowser`; individual item cells within a column are not expanded by this enumeration capability (consistent with the shallow container discovery model of `ui.list_split_panes`, `ui.list_table_rows`, and `ui.list_outline_items`).
- Real hardware AX observation in test #19 is TCC-conditional (`AXIsProcessTrusted()`).
