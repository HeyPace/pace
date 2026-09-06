# Phase 2BI — Semantic Table Column Enumeration (`ui.list_table_columns`)

## Overview
- **Capability Identifier**: `ui.list_table_columns`
- **Tool Family**: `ui` (matching `ui.list_table_rows`'s own family — column header titles carry no free-form content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `83d6d37`
- **Pre-Phase Capability Count**: `56`
- **Post-Phase Capability Count**: `57`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_table_rows` (Phase 2AE) enumerates a table's rows but never surfaces what each column *means* — a model that can enumerate rows but never learn a column's header cannot reliably distinguish a "Date" column from an "Amount" column before reading cell values. This exact asymmetry was independently identified as the strongest still-unimplemented candidate across three consecutive discovery phases (2BG, 2BH, 2BI).

---

## Semantic Accessibility Contract
- **Target Element**: exactly one `AXTable`, resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role `AXTable`, matched by `identifier` or `title`) — reusing `QAXTableRolePolicy` (Phase 2AE) verbatim, no new role policy introduced.
- **AX API / attribute**: `kAXColumnHeaderUIElementsAttribute` — the OS's own authoritative list of a table's header elements, read directly on the resolved `AXTable`. Falls back to filtering the table's own direct children for `kAXRoleAttribute == "AXColumn"` only if the header attribute itself is absent/unreadable — the identical dual-strategy robustness `ui.list_table_rows`/`ui.list_browser_columns` already apply for their own analogous collections.
- **Per-column reads** (direct, non-recursive, on each already-resolved column element only): `kAXTitleAttribute` (falling back to `kAXDescriptionAttribute`), `AXIdentifier`, `kAXSubroleAttribute`. Every candidate's own `kAXRoleAttribute` is independently re-validated as exactly `"AXColumn"` before being trusted — the returned collection is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded.
- **AX action(s)**: none. **Mutation**: none. **Cell contents**: never read — only the column *header's* own identity is ever touched; `kAXRowsAttribute` (or any row/cell-shaped attribute) is never referenced by this capability.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check**: `role` must be on `QAXTableRolePolicy.allowedRoles` (`AXTable` only) — checked before any AX call. Disallowed role → `AX_DISALLOWED_ROLE`.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Table resolution**: `collectMatches` bounded search for the one `AXTable` — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved table is re-snapshotted immediately before enumeration and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **Bound enforcement**: the valid column collection's size is checked against `maxDirectTableColumnsCount` (32) *before* any per-column metadata read — exceeding it → `AX_TABLE_COLUMN_COLLECTION_EXCEEDS_SAFE_BOUND`, never silently truncated to the first 32.

None of these gates ever fall back to a different table, a fabricated column, or an approximate match.

---

## Output Contract
`QAXTableColumnCollectionMetadata` / `QAXTableColumnItemMetadata` (new types, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the input. |
| `tableTitle` / `tableIdentifier` | `String?` | The resolved table's own identity. |
| `columnCount` | `Int` | Aggregate count. |
| `columns` | `[QAXTableColumnItemMetadata]` | Per-column: `index: Int`, `title: String?`, `identifier: String?`, `role: String` (always `"AXColumn"`), `subrole: String?`. |

No coordinates, no raw `AXUIElement`, no cell content, no row data, ever appear in this type or cross into any persisted structure. Missing optional fields are honestly `nil`, never fabricated as an empty string or placeholder.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.tableColumnEnumerationSucceeded(applicationName: String, columnCount: Int)`
- **Evaluation**: like every other Level 0 enumeration's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.listTableColumns`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }` bypass.
- **Evidence**: `application=<name> tableRole=AXTable columnCount=<n> status=verified` (or `status=failed`) — never any individual column's title or identifier.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects.
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxTraversalDepth = 1` — the resolved table's direct column-header children only; never descends into a column's own contents.
  - `maxNodes = 33` — the table (1) plus at most 32 columns.
  - `maxChildrenEnumerated (beyond returned columns) = 0`.
  - `maxReturnedElements = 32` (`maxDirectTableColumnsCount`).
  - `maxActions = 0` — no `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` call exists anywhere in the implementation.
  - `maxPolling = 0` — a single synchronous enumeration; no loop, no `Task.sleep`.

---

## Privacy & Security Architecture
- **Exposed surface, exhaustively**: column header titles/identifiers (e.g. "Name", "Date Modified") and the table's own title/identifier — structural metadata, the same low-risk class every other `list_*` capability's title fields already carry. No cell content, no row data, no user-entered content of any kind.
- **No new privacy mechanism introduced**: reuses the exact structural-metadata precedent every prior `list_*` capability already establishes; no new allowlist or redaction boundary was needed.
- **No durable pointer/content leaks**: `QAXTableColumnItemMetadata`/`QAXTableColumnCollectionMetadata`'s stored properties are `Int`/`String?`/`String` only — no `AXUIElement`-typed field exists anywhere in either declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages across the entire production diff; the only test-file match is a documentation string inside a test's own name).

---

## Test Coverage (`QSemanticTableColumnEnumerationTests.swift`)
27 focused tests, covering:
1. Capability registration (Level 0, `ui` family, anti-downgrade in both directions)
2/3. Missing `applicationName`/match-criteria fails closed
4. Disallowed role rejected before any tree walk (`QAXTableRolePolicy` reused verbatim)
5/6. Zero/ambiguous application resolution fails closed
7/8. Zero/ambiguous table target resolution fails closed (real two-table fixture proves ambiguity)
9. `QAXTableColumnItemMetadata`/`QAXTableColumnCollectionMetadata` model extraction
10. Missing optional title/identifier handled safely, never fabricated
11. 32-column bound enforcement (never silently truncated)
12. Bounded traversal (structural — no descent into a column's own children)
13. No cell-content exposure (privacy)
14. Malformed candidate element (wrong role) silently excluded, never fabricated as a column
15. Unavailable header attribute falls back to direct-children filtering safely
16. Empty column collection is a valid, honest result
17. No mutation occurs (real fixture's own columns provably unchanged)
18. No polling occurs
19. No actions performed
20/20b. Evidence-based verification contents and failure-propagation (never bare `{ true }`)
21. Durable persistence boundary (aggregate-only)
22. `QPermissionGate` never requires approval
23. Normal `QPlanExecutor` pipeline execution, dedicated verification strategy confirmed (not the generic bypass)
24. Forbidden API audit (structural)
25. Uncertain in-flight step recovery fails closed to pending
26/E2E. Real macOS AppKit E2E (`NSTableView` + 2 distinct-titled `NSTableColumn`s, TCC-guarded)

---

## Real macOS E2E — Known Environmental Limitation
Test 26 builds a real `NSWindow` + `NSScrollView` + `NSTableView` with two `NSTableColumn`s titled "Name" and "Date Modified", and dispatches through `QBridgeAccessibility.shared.listTableColumns` end-to-end, asserting the returned column titles match exactly and in order. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created a window and performed a real AX round-trip. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BH) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticTableColumnEnumerationTests`): 27/27 passed.
- **Related suites**: `QSemanticTableRowEnumerationTests` 12/12, `QSemanticBrowserColumnEnumerationTests` 19/19, `QSemanticTableRowSelectionTests` 39/39, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3165/3165, 3165/3165, 3165/3165 — no flakes, no regressions.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- `kAXSortDirectionAttribute` (per-column sort indicator) was considered during discovery but omitted from this implementation's output contract — its reliability across third-party (non-Apple) `NSTableView` usages was not empirically verified, and the approved implementation contract specified only title/identifier/role/subrole. A future phase could add it as an enrichment if a real fixture confirms it behaves consistently.
- A table with genuinely zero columns (no header row at all) yields a valid, honestly-reported empty collection — not every real-world table configuration will have `NSTableColumn`s with distinct titles, and this is not treated as an error.
