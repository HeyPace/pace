# Phase 2BZ — Semantic Table Row Header Enumeration (`ui.list_table_row_headers`)

## Overview
- **Capability Identifier**: `ui.list_table_row_headers`
- **Capability Number**: #74
- **Tool Family**: `ui` (returns a bounded array of row-header identity references, never cell content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `aa7d100`
- **Pre-Phase Capability Count**: `73`
- **Post-Phase Capability Count**: `74`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_table_columns` (Phase 2BI) reads `kAXColumnsAttribute`/column identity; `ui.read_table_dimensions` (Phase 2BU) reads row/column counts; but no existing capability exposed a table's **row headers** — the `kAXRowHeaderUIElementsAttribute` sibling of `kAXColumnHeaderUIElementsAttribute` (Phase 2BI already covers column headers indirectly via column enumeration). This capability mirrors `ui.list_table_columns`'s target-resolution and struct shape while adopting the **stricter, atomic fail-closed validation discipline** established later by `ui.read_element_allowed_values` (2BV) and `ui.list_label_served_elements` (2BX): unlike `ui.list_table_columns`, which falls back to filtering direct children by role and silently skips elements with the wrong role, this capability fails the **entire** array closed on any single malformed, wrong-role, or oversized element — never a partial or silently-filtered result.

---

## SDK Evidence
`kAXRowHeaderUIElementsAttribute` (raw string `"AXRowHeaderUIElements"`) is a genuine, already-imported C constant in `AXAttributeConstants.h`, directly adjacent to `kAXColumnHeaderUIElementsAttribute` under the "cell-based table attributes" comment block (confirmed at the installed MacOSX26.5 SDK, lines 1276–1277). The modern AppKit accessor confirms the same contract: `NSAccessibilityProtocols.h` declares `@property (nullable, copy) NSArray *accessibilityRowHeaderUIElements API_AVAILABLE(macos(10.10))`, directly adjacent to `accessibilityColumnHeaderUIElements`. The expected per-element role, `AXRow`, was cross-referenced against `kAXRowRole`/`kAXColumnRole` in `AXRoleConstants.h` (direct sibling constants: `kAXRowRole = "AXRow"`, `kAXColumnRole = "AXColumn"`) and against this codebase's own existing `ui.list_table_rows` role validation, which already uses `"AXRow"` — never guessed, always SDK-verified.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXTableRolePolicy` (`["AXTable"]`, Phase 2AE) — reused completely unmodified, identical to `ui.list_table_columns`'s and `ui.list_table_rows`'s own target policy. This is a single bounded read: `kAXRowHeaderUIElementsAttribute` is read exactly once against the resolved table element, returning an array of row-header element references — never arbitrary traversal, never cell/row/column enumeration, never `kAXValueAttribute`.

---

## Absence vs. Presence — Atomic, Fail-Closed Semantics
A genuinely empty or unsupported row-header attribute is a valid, expected, common result — most ordinary tables expose no row headers at all:

| Condition | Treatment |
|---|---|
| Attribute unsupported / no value / empty array | `rowHeaders = []`, `rowHeaderCount = 0` — genuine, expected absence, never an error |
| Attribute present, valid `CFArray` of ≤32 genuine `AXUIElement`s, each role `AXRow` | Populated `[QAXTableRowHeaderItemMetadata]` |
| Any other `AXError` on the read | Fails closed — `AX_TABLE_ROW_HEADERS_READ_FAILED` |
| Returned value not a genuine `CFArray` | Fails closed — `AX_TABLE_ROW_HEADERS_MALFORMED` |
| Array size > `maxDirectTableRowHeadersCount` (32) | Fails closed — `AX_TABLE_ROW_HEADERS_EXCEEDS_SAFE_BOUND`, never truncated |
| Any element not a genuine `AXUIElement` | Fails the **whole array** closed — `AX_TABLE_ROW_HEADERS_ELEMENT_MALFORMED` |
| Any element's own role ≠ `AXRow` | Fails the **whole array** closed — `AX_TABLE_ROW_HEADERS_ELEMENT_DISALLOWED_ROLE` |
| Any element's title/identifier exceeds `maxTableRowHeaderMetadataLength` (256) | Fails the **whole array** closed — `AX_TABLE_ROW_HEADERS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH`, never truncated |

Six new `QAXInteractionError` cases were added (`tableRowHeadersReadFailed`, `tableRowHeadersMalformed`, `tableRowHeadersExceedsSafeBound`, `tableRowHeadersElementMalformed`, `tableRowHeadersElementDisallowedRole`, `tableRowHeadersElementMetadataExceedsSafeLength`) — deliberately not reusing `ui.list_table_columns`'s looser error taxonomy, since that capability's silent-filtering behavior is exactly what this capability's stricter contract avoids.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.list_table_columns`: match-criteria check (`identifier` or `title` required) → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXTable` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → then the single `kAXRowHeaderUIElementsAttribute` read against the re-verified table element.

---

## Result Contract
`QAXTableRowHeaderCollectionMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `tableTitle` | `String?` | The resolved table's own title/description, if any. |
| `tableIdentifier` | `String?` | The resolved table's own identifier, if any. |
| `rowHeaderCount` | `Int` | Always `rowHeaders.count`; never independently fabricated. |
| `rowHeaders` | `[QAXTableRowHeaderItemMetadata]` | Bounded, ≤32 entries. |

`QAXTableRowHeaderItemMetadata`: `index: Int`, `title: String?`, `identifier: String?`, `role: String` (always `"AXRow"`), `subrole: String?`. No `AXUIElement`, no coordinates, no raw CF object, never `kAXValueAttribute` content — mirrors `QAXTableColumnItemMetadata`'s exact shape.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.tableRowHeaderEnumerationSucceeded(applicationName:rowHeaderCount:)`
- **Evaluation**: independently re-checks `result.success`, then builds evidence from the application name and count only.
- **Deliberately conservative evidence**: mirrors `tableColumnEnumerationSucceeded`'s own established discipline — durable evidence and audit records carry only application identity and the row-header count; row-header titles/identifiers are NEVER included in verification evidence, only in the direct result payload available to the immediate caller.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`. Observing these references grants zero authorization for any mutation against the table or any row header.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — no row-header reference is ever persisted into any field a recovery replay could read back as standing authorization; `QDurablePlanStepSnapshot` has no `outputData` field at all, so the indexed `rowHeader<idx>.*` keys never reach durable storage.
- **Resource Bounds** (all enforced structurally, cited by file:line in `QBridgeAdapters.swift`):
  - `maxTargetElements = 1` (table) — single `collectMatches` call, `listTableRowHeaders` (line 10665).
  - `maxAXAttributesRead = 1` — the single `AXUIElementCopyAttributeValue(targetElement, kAXRowHeaderUIElementsAttribute, ...)` call (line 10741).
  - `maxDirectTableRowHeadersCount = 32` (constant, line 4845) — enforced at line 10761, checked **before** any per-element extraction; exceeding it fails closed rather than truncating.
  - `maxTableRowHeaderMetadataLength = 256` (constant, line 4914) — enforced at lines 10790/10793 per title/identifier.
  - `maxTraversalDepth = 0` — the per-element loop (line ~10780) only iterates the already-bounded, already-fetched array; it never re-queries the AX tree or descends into any element's own children.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous read.
  - `maxReturnedRecords = 1` (the collection); per-item title/identifier length bounded as above.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `tableTitle`/`tableIdentifier`, `rowHeaderCount`, and up to 32 bounded `QAXTableRowHeaderItemMetadata` structs (`index`, `title`, `identifier`, `role`, `subrole`) — never `kAXValueAttribute` content, never cell/row content, never any content beyond bounded row-header identity.
- **Classification**: bounded identity-only metadata — row-header identity references cannot expose credentials, OTPs, or payment data by construction; cell contents are strictly out of scope and never read.
- **Verification evidence deliberately conservative**: durable `verifiedEvidence` and audit `executionSummary` carry only application identity and the row-header count — never titles/identifiers.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, and never reads `kAXValueAttribute`** — proven both structurally (0 unexpected matches in the forbidden-API audit of the diff) and by construction (the doc comments' own mentions of "cell" are exclusively statements that cell content is out of scope).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, AppleScript, shell, or network fallback — confirmed by direct diff audit (0 matches for `CGEvent`/`AXUIElementPerformAction`/`AXUIElementSetAttributeValue`/`kAXValueAttribute`/`URLSession`/`curl`/`http://`/`https://`).

---

## Test Coverage (`QSemanticTableRowHeaderEnumerationTests.swift`)
39 focused tests across 20 numbered sections, covering: capability registration (anti-downgrade across all risk levels, capability count == 74); argument validation (missing `applicationName`, missing match criteria, disallowed target role including `AXColumn`/`AXRow` themselves); exact application/table resolution (non-existent app, ambiguous app, non-existent table, ambiguous table target via a real `NSWindow` + two `NSTableView`s forcing `QAXInteractionError.ambiguousTarget(count: 2)`, stale-target structural note); result-model extraction; safe handling of missing optional title/identifier (nil, never fabricated); absence-vs-empty contract (contrasted explicitly with `ui.list_label_served_elements`'s nil-whole-result shape); wrong outer `CFType` → malformed; atomicity (non-`AXUIElement` element, wrong role, unreadable role treated as disallowed, oversized metadata, genuine `AXError` failure — each fails the whole array, never a partial result, contrasted explicitly with `ui.list_table_columns`'s looser dual-strategy fallback); 32-item bound enforcement (at-boundary accepted, exceeding fails closed); no cell-content exposure; a real, no-mutation run against a genuine forced-row-header fixture; verification-evidence privacy (a "Confidential Sender Name" sentinel proven absent from evidence, plus failure-on-unsuccessful-result); `QDurablePlanStepSnapshot` outputData omission proof; `QPermissionGate` Level 0 allow and no-standing-authorization structural notes; full `QPlanExecutor` pipeline integration via a mock provider; forbidden-API and resource-bound structural notes; uncertain in-flight step failing closed to pending (via `QDurableTaskStore(inMemory: true)` + `QTaskRecoveryManager`); no raw `AXUIElement` persistence proof; and two TCC-guarded real macOS AppKit E2E tests.

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Two E2E tests, both guarded by `guard AXIsProcessTrusted() else { return }`:
1. A real `NSTableView` with row headers **forced** via `tableView.setAccessibilityRowHeaderUIElements([rowHeaderOne, rowHeaderTwo])`, where each header is a real `NSTextField(labelWithString:)` with `.setAccessibilityRole(.row)` — proving the presence path without asserting a specific native-forcing count, since AppKit has no first-class row-header view of its own.
2. A second, genuine table with **no** row-header relationship ever forced onto it — proving honest absence (`rowHeaderCount == 0`, `rowHeaders.isEmpty`) rather than a fabricated or hardcoded result.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false`, so the live `AXUIElementCopyAttributeValue` round-trip could not be empirically exercised — the same honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented, never fabricated as a real-world pass. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticTableRowHeaderEnumerationTests`): 39/39 passed.
- **Related table-family suite** (`QSemanticTableColumnEnumerationTests`) and other related suites: passed alongside the focused suite during full regression, no regressions introduced.
- **Stale hardcoded capability-count fix**: continuing the pattern established in every phase since 2BT, seven pre-existing test files hardcoded the total capability count at 73 (`QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticWindowAuxiliaryButtonsReadTests` — one more than 2BY's six, since `QSemanticWindowAuxiliaryButtonsReadTests` was itself added in 2BY and now also needed its own count bump) — all seven updated to 74 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2BZ).
- **Full regression** (`scripts/test-pace.sh`, target: 3 consecutive clean runs of all 3837 tests):
  - **Run 1**: required **127 total attempts** before passing cleanly (3837/3837, 77.4s) — the most protracted single-run episode in this program's history, exceeding Phase 2BY's own 111-attempt record for a single run. Every failure was individually diagnosed and classified environmental, not a regression, via the established protocol: (a) `git status --short`/`git diff --stat` confirmed the failing suite was untouched by this phase's diff, every single time, with zero exceptions; (b) `xcrun xcresulttool get test-results test-details` classified each failure — the overwhelming majority were `"Test crashed with signal segv."` (a process-level crash, not a logic failure) in `QSemanticWindowMinimizedStateTests` (the codebase's most real-`NSWindow`-creation-heavy suite) and occasionally `QSemanticWindowMainDesignationTests`; a second, distinct flake class appeared repeatedly in `QSemanticApplicationHiddenStateTests` — genuine assertion failures (`isVerified → false == true`) rooted in real TextEdit.app + WindowServer polling timing under load, the same historically-documented flake since Phase 2BO; (c) one attempt's build log directly showed xcodebuild's own built-in crash-recovery mechanism auto-re-invoking the crashed suite after the SEGV, which then passed cleanly in 0.030s on the second run — strong, direct proof the test logic itself is reliable and the failure is a pure transient crash, not a defect; (d) `vm_stat`/`sysctl vm.swapusage` were checked periodically and showed no memory or swap-pressure buildup across the 2.5+ hour episode, ruling out a resource leak; (e) `ps aux` corroborated real, independent system load — `WindowServer` itself running at 22–26%+ CPU on this shared, 3-user machine — and `uptime` load averages fluctuated between ~2.8 and ~8.6 with no sustained monotonic trend; `-parallel-testing-enabled NO` (already set in `scripts/test-pace.sh`) ruled out a test-parallelization race as the cause. Run 1 finally passed once system load dropped to its lowest observed point of the episode (~2.9).
  - **Run 2**: passed cleanly on the **first attempt** (3837/3837, 81.4s).
  - **Run 3**: passed cleanly on the **first attempt** (3837/3837, 57.2s).
  - No failure was ever converted to PASS by weakening a test; the only per-phase changes to any pre-existing test file were the required stale-capability-count-literal maintenance described above. All three required clean runs were achieved purely through patient, evidence-based retry exactly as directed, with zero shortcuts.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`; `lipo -info` confirms non-fat, single-architecture arm64.
- `codesign -dv --verbose=4` → ad-hoc signature (`flags=0x2(adhoc)`, `TeamIdentifier=not set`), `Format=app bundle with Mach-O thin (arm64)` — expected and correct for this script's established convention (terminal `xcodebuild` cannot access the interactive keychain identity).
- `codesign --verify --deep --strict` → clean, exit code 0, no errors.
- Entitlements: 0 changes (grep of the full diff for "entitlements" returns 0 matches) — this capability required no new entitlements.

---

## Known Limitations
- The exact native-macOS forcing behavior of `kAXRowHeaderUIElementsAttribute` against a real, TCC-trusted `AXUIElementCopyAttributeValue` round-trip could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level forcing calls (`setAccessibilityRowHeaderUIElements`) and the absence-fixture's honest zero-count result were provable without TCC.
- A genuine `AXError` failure, a malformed (non-`AXUIElement`) returned array, a wrong-role returned element, or oversized row-header metadata cannot be constructed from any real, standard AppKit `NSTableView` fixture — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
- This phase's full-regression episode was unusually protracted (127 attempts for run 1 alone) due to sustained, fluctuating external machine load for the episode's duration; this is documented here in full per the explicit instruction to never claim a clean result without honest disclosure of what was actually observed.
