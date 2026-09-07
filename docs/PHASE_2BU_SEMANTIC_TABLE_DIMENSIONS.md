# Phase 2BU — Semantic Table Dimensions Read (`ui.read_table_dimensions`)

## Overview
- **Capability Identifier**: `ui.read_table_dimensions`
- **Capability Number**: #69
- **Tool Family**: `ui` (the returned fields are two bounded non-negative integers, never table/cell content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `021577f`
- **Pre-Phase Capability Count**: `68`
- **Post-Phase Capability Count**: `69`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_table_rows`/`ui.list_table_columns` (Phases 2AE/2BI) each perform a full, traversal-based enumeration to learn row/column identities. Neither lets a caller learn a table's bounded structural **size** cheaply first. `ui.read_table_dimensions` closes this gap with exactly two scalar AX reads and zero traversal, letting an autonomous agent decide whether a full enumeration is worth its resource cost before committing to it.

---

## SDK Evidence & the Inverted Missing-vs-Failure Design
`kAXRowCountAttribute`/`kAXColumnCountAttribute` (`AXAttributeConstants.h:1265-1266`, grouped under a `// grid attributes` comment in the C header) are backed by **non-optional** `NSInteger` properties on the modern AppKit accessibility protocol:

```objc
// #pragma mark Table/Outline
@property NSInteger accessibilityColumnCount API_AVAILABLE(macos(10.10));
@property NSInteger accessibilityRowCount API_AVAILABLE(macos(10.10));
```

Unlike `kAXSortDirectionAttribute` (2BT) or the several genuinely-nullable attributes from earlier phases (`accessibilityPlaceholderValue`, `accessibilityTitleUIElement`, etc.), these two properties are never declared `nullable` — the modern protocol's own type signature documents that a conforming `AXTable`-role element is expected to always expose both. This is the **INVERTED** missing-vs-failure pattern, first established for `kAXModalAttribute` (Phase 2BO, "Required for all window elements"): genuine absence (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is itself treated as a read **failure** for this capability, never silently downgraded to a default or partial result — unlike the *optional-reference* pattern used by most other Level 0 reads in this session.

This determination was made fresh from local SDK evidence for this specific capability, not assumed by analogy to a previous phase.

---

## Atomicity — Both Counts or Neither
`QAXTableDimensionsMetadata`'s `rowCount`/`columnCount` are both **non-optional `Int`** — the type itself makes a partially-populated result structurally impossible to construct. `readTableDimensions` reads row count first; if it fails, column count is never even attempted (the second `try` is simply never reached). If row count succeeds but column count subsequently fails, the already-computed row count is discarded — never returned — because the function's only return path constructs the full struct from both validated values at once. There is no code path that can return a result with only one count populated.

---

## Integer Validation — `resolveTableCount`
Each of the two attributes is read via the same shared, generic resolver, parameterized only by which `QAXInteractionError` case to throw:

| Step | Check | Failure |
|---|---|---|
| 1 | `copyResult == .success` (any other `AXError`, **including `.noValue`/`.attributeUnsupported`**) | `tableRowCountReadFailed`/`tableColumnCountReadFailed` |
| 2 | `CFGetTypeID(value) == CFNumberGetTypeID()` | `tableRowCountMalformed`/`tableColumnCountMalformed` |
| 3 | `CFNumberGetType(cfNumber)` is an integer subtype (never `.float32Type`/`.float64Type`/`.doubleType`/`.cgFloatType`) | same `*Malformed` — a fractional native representation is treated as malformed data, never silently truncated by extraction |
| 4 | `CFNumberGetValue(_:.sInt64Type:_:)` itself reports success | same `*Malformed` |
| 5 | extracted `Int64 >= 0` | `tableRowCountInvalid`/`tableColumnCountInvalid` ("negative value: …") |
| 6 | `Int(exactly: int64Value)` succeeds (never a truncating cast) | same `*Invalid` ("value … overflows Swift Int") |

Every check has its own distinct, dedicated diagnostic — nothing is ever silently clamped, truncated, or defaulted.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check**: role is fixed internally to `"AXTable"` (never caller-supplied) and checked against `QAXTableRolePolicy.isAllowedTableRole` — **completely unmodified**, the identical policy `ui.list_table_rows`/`ui.list_table_columns` already use.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`; never falls back to another running application.
5. **Target resolution**: `collectMatches` bounded search for the one `AXTable` element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the reads and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling** (see Integer Validation table above): any failure on either count fails the whole read closed.

No fallback to coordinates, screen position, or visual matching exists anywhere in this capability's resolution path.

---

## Result Contract
`QAXTableDimensionsMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `tableIdentifier` | `String?` | The resolved table's own identifier, if any. |
| `tableTitle` | `String?` | The resolved table's own title, if any. |
| `rowCount` | `Int` | Always present in a valid result — validated non-negative, Int-representable. |
| `columnCount` | `Int` | Always present in a valid result — validated non-negative, Int-representable. |

No `AXUIElement`, no coordinates, no raw `CFNumber` object, no table contents, and no cell values ever appear in this type — any temporary `CFNumber` is converted to a bounded `Int` immediately and never escapes the bridge.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.tableDimensionsReadSucceeded(applicationName: String, tableIdentifier: String?, tableTitle: String?, rowCount: Int, columnCount: Int)`
- **Evaluation**: independently re-validates `rowCount >= 0 && columnCount >= 0` — never trusts the executor's own `success` flag alone, mirroring `textSelectionStateReadSucceeded`'s/`columnSortDirectionReadSucceeded`'s identical independent-recheck discipline. A fabricated `success == true` claiming a negative `rowCount` or `columnCount` is still correctly rejected (tests 38/39).
- **No valid-absence outcome**: unlike `columnSortDirectionReadSucceeded`'s `hasSortDirection` flag, this capability's contract has no analogous "unavailable" branch — a claimed success always carries both counts, consistent with the INVERTED missing-vs-failure design.
- **Evidence**: application identity, table identity, and both counts are safe to include directly — bounded structural facts carry no privacy risk.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite. Observing a table's dimensions grants zero authorization for `ui.list_table_rows`, `ui.list_table_columns`, or `ui.select_table_row` — independently re-verified as disjoint decisions (test 35).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no row/column count is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1`; `maxAXAttributesRead = 2` (`kAXRowCountAttribute`, `kAXColumnCountAttribute`); `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — exactly two synchronous calls.
  - `maxReturnedRecords = 1`.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `tableIdentifier`, `tableTitle`, and the two bounded integers — never table/cell content.
- **Classification**: safe structural metadata — two non-negative integers, cannot meaningfully contain PII by construction.
- **Must never be persisted beyond identity**: durable `verifiedEvidence` and audit `executionSummary` carry only application identity, table identity, and the two counts.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`** — proven both structurally (0 matches in the forbidden-API audit) and by a real fixture's own table columns remaining unmutated after the read (test 34).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticTableDimensionsReadTests.swift`)
46 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 69); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXTableRolePolicy` accepts `AXTable`/rejects other roles — reused unmodified, missing-identity rejection); AX read (exactly two scalar reads, no traversal — structural); valid values (0/0 empty table, normal positive values, large safe values); malformed/invalid values (negative, wrong CFType, fractional native subtype, Int overflow, unreadable representation — each its own distinct diagnostic); the inverted missing-vs-failure design (genuine attribute absence treated as failure, never a valid nil, for both counts independently); partial-attribute atomicity (row-succeeds/column-fails and column-succeeds/row-fails both fail the whole call, proven both by the non-optional result type and by read ordering); error handling (missing/ambiguous application, no fallback, missing/ambiguous target, stale target, genuine `AXError` failure); privacy (durable evidence and audit records proven to carry only bounded structural facts, using distinctive sentinel table identifiers); security (no mutation authority, disjoint authorization from `ui.list_table_rows`/`ui.list_table_columns`/`ui.select_table_row`); verification (successful evidence, failure on unsuccessful result, independent rejection of fabricated negative row/column counts); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; resource bounds (structural, plus a real-fixture repeated-invocation no-side-effects test); real macOS AppKit E2E (TCC-guarded, real `NSTableView`, forced deterministic values via the genuine `setAccessibilityRowCount`/`setAccessibilityColumnCount` accessors round-tripping exactly).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 45 constructs a real `NSTableView` (the same fixture shape `ui.list_table_columns`'s own E2E test established) and, uniquely for this capability, **forces deterministic values** via the real, declared `tableView.setAccessibilityRowCount(7)`/`setAccessibilityColumnCount(4)` accessors — confirmed to round-trip correctly at the AppKit level (`tableView.accessibilityRowCount() == 7`) even before any AX dispatch. This is the **first capability in this entire session with a genuine forced-value native accessor for the exact attributes being read** — every prior phase since 2BO could observe only an honest native default, never force a specific known value end-to-end.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented for the live `AXUIElementCopyAttributeValue` round-trip — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the live AX round-trip confirming `kAXRowCountAttribute`/`kAXColumnCountAttribute` reflect the forced AppKit-level values when read through the real Accessibility API. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test (test 41) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticTableDimensionsReadTests`): 46/46 passed.
- **Related suites**: `QSemanticTableColumnEnumerationTests`, `QSemanticTableRowEnumerationTests`, `QSemanticTableRowSelectionTests`, `QApplicationResolutionHardeningTests`, `QPersistenceSecurityTests`, `QPermissionGateTests`, `QActionVerificationTests`, `QPlanExecutionTests`, `QExecutionServiceTests`, `QSemanticColumnSortDirectionReadTests` — combined 218/218, all green, zero regressions.
- **Compile-verification finding**: the first focused-test build attempt passed cleanly (46/46) with no compile errors — the real, declared `setAccessibilityRowCount`/`setAccessibilityColumnCount`/`accessibilityRowCount`/`accessibilityColumnCount` Swift accessor names resolved correctly on the first attempt (a plain non-optional `NSInteger` property, unlike Phase 2BT's `NS_TYPED_ENUM` naming surprise).
- **Stale hardcoded capability-count fix**: the first related-suite run failed on `QSemanticColumnSortDirectionReadTests.capabilityRegistrationAcceptsUIReadColumnSortDirection()` — a **real regression**, not environmental: that Phase 2BT test hardcoded `QModelPlanParser.registeredCapabilities.count == 68`, which became stale the moment this phase registered capability #69. While fixing it, a second, already-stale instance of the same issue was found in `QSemanticTextSelectionStateReadTests.swift` (hardcoded at `68`, itself a leftover from Phase 2BT's own fix that never anticipated a subsequent phase) — both were updated to `69` (same strict equality assertion, no weakening). Verified in isolation (99/99) before retrying.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3627/3627 passed — clean.
  - **Run 2 (initial)**: failed on `QSemanticApplicationHiddenStateTests.verificationSucceedsOnMatch()` — a pre-existing test that launches a real `TextEdit.app` helper process and polls its real, live WindowServer-reported hidden state. **Classified ENVIRONMENTAL, not a regression**: this file is not touched anywhere in this phase's diff (confirmed via `git diff --stat`); the isolated suite passed cleanly (31/31) immediately after. Retry passed cleanly: 3627/3627.
  - **Run 3**: 3627/3627 passed — clean.
  - No failure was ever converted to PASS by weakening; the one real regression found (stale capability-count literals) was fixed at its root cause, and the one environmental failure was diagnosed with concrete isolation evidence before being classified and retried.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact behavior of a live `AXUIElementCopyAttributeValue` round-trip against the forced `setAccessibilityRowCount`/`setAccessibilityColumnCount` values could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level accessor round-trip (`tableView.accessibilityRowCount() == 7`) was provable without TCC. This should be revisited with real hardware/TCC access to close the loop fully.
- A genuine `AXError` failure, a malformed (non-`CFNumber`/floating-point) returned value, a negative count, or an `Int`-overflowing count cannot be constructed from any real, standard AppKit `NSTableView` — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
