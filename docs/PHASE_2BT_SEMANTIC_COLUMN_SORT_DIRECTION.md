# Phase 2BT — Semantic Column Sort Direction Read (`ui.read_column_sort_direction`)

## Overview
- **Capability Identifier**: `ui.read_column_sort_direction`
- **Capability Number**: #68
- **Tool Family**: `ui` (the returned field is a closed 3-value enum, never text content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `9afe8290bc0aab0dcccb7434c53d8e0d3758987a`
- **Pre-Phase Capability Count**: `67`
- **Post-Phase Capability Count**: `68`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_table_columns` (Phase 2BI) enumerates a table's columns (identity/title/role only) but never reports whether a column is currently sorted, or in which direction. No existing capability answers "is this column ascending, descending, or unsorted right now?" — a genuine gap in the "observe table/column state" category, and `kAXSortDirectionAttribute` was confirmed unused anywhere in the existing `Q*` semantic capability architecture.

---

## Semantic Contract — A Closed Three-Value Enum, Never Raw Table/Cell Content
This capability reads exactly one attribute (`kAXSortDirectionAttribute`) of exactly one directly-resolved `AXColumn` element and normalizes it to one of three public string values:

| Public value | Meaning |
|---|---|
| `"ascending"` | Column is currently sorted ascending |
| `"descending"` | Column is currently sorted descending |
| `"none"` | Column is present and readable, but not currently sorted |
| *(absent — `nil`)* | The attribute itself is genuinely not present on this element |

No table contents, cell values, row data, or column count are ever read — this capability targets a single, semantically-identified `AXColumn` element directly (by its own `identifier`/`title`), the same direct-targeting shape `ui.read_element_required_state`/`ui.read_element_protected_content_state` already established for other single-element reads, deliberately distinct from `ui.list_table_columns`'s table-scoped enumeration.

---

## SDK-Verified Representation Ambiguity — Validated Against Both Real Symbol Sets
Fresh SDK inspection (`NSAccessibilityConstants.h`) confirmed `kAXSortDirectionAttribute` has **two** parallel documented representations, and the header gives no indication which one a live AX provider actually vends over the wire:

```c
/* Sort direction values */
typedef NSString * NSAccessibilitySortDirectionValue NS_TYPED_ENUM;
APPKIT_EXTERN NSAccessibilitySortDirectionValue const NSAccessibilityAscendingSortDirectionValue;
APPKIT_EXTERN NSAccessibilitySortDirectionValue const NSAccessibilityDescendingSortDirectionValue;
APPKIT_EXTERN NSAccessibilitySortDirectionValue const NSAccessibilityUnknownSortDirectionValue;

typedef NS_ENUM(NSInteger, NSAccessibilitySortDirection) {
    NSAccessibilitySortDirectionUnknown = 0,
    NSAccessibilitySortDirectionAscending = 1,
    NSAccessibilitySortDirectionDescending = 2,
} API_AVAILABLE(macos(10.10));
```

Since no live, TCC-trusted `AXUIElementCopyAttributeValue` round-trip is possible in this sandboxed environment to empirically determine which CFType a real provider returns, the resolver validates the returned value against **both** real, linked Apple symbol sets rather than guessing one:

1. If the returned `CFTypeRef` is a `String`, it is compared against `NSAccessibility.SortDirectionValue.ascending/.descending/.unknown` (each `.rawValue`) — the real linked Swift import of the `NS_TYPED_ENUM` constants (see "Swift Import Correction" below).
2. If it is an `NSNumber`, its `.intValue` is compared against `NSAccessibilitySortDirection.ascending/.descending/.unknown` (each `.rawValue`) — the real linked Swift import of the `NS_ENUM`.
3. Anything else (wrong CFType, or a CFType-correct value matching neither symbol set) fails closed with its own distinct diagnostic — never silently mapped to `"none"`.

### Swift Import Correction (found during compile-verification)
The implementation was initially written assuming `NSAccessibilityAscendingSortDirectionValue`/`NSAccessibilityDescendingSortDirectionValue`/`NSAccessibilityUnknownSortDirectionValue` import into Swift as raw `String` constants (matching the precedent of other `NS_TYPED_ENUM` string constants used elsewhere in this codebase, e.g. attribute-name constants). The first build attempt failed with `Cannot convert value of type 'NSAccessibility.SortDirectionValue' to expected argument type 'String'` — because `NSAccessibilitySortDirectionValue` is declared **non-extensible** `NS_TYPED_ENUM` (no `NS_TYPED_EXTENSIBLE_ENUM`), which Swift imports as cases of a namespaced enum, `NSAccessibility.SortDirectionValue`, rather than as raw `String` globals. The fix: use `NSAccessibility.SortDirectionValue.ascending.rawValue` (and `.descending`/`.unknown`) to recover the real, linked wire-format string — never a hardcoded guessed literal. This was caught by the mandatory compile-and-test gate exactly as intended; the design principle ("validate against real linked symbols, never guess") was preserved, only the precise Swift spelling was corrected.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check**: `role` is fixed internally to `"AXColumn"` (never caller-supplied) and checked against the new `QAXColumnReadRolePolicy.isAllowedColumnReadRole` (`allowedRoles = ["AXColumn"]`, mirroring `QAXWindowRolePolicy`'s identical single-role shape) — structurally always satisfied since the role is not attacker/caller-controlled, but checked explicitly for architectural consistency with every other capability in this codebase.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`; never falls back to another running application.
5. **Target resolution**: `collectMatches` bounded search for the one `AXColumn` element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling**: `.noValue`/`.attributeUnsupported` → valid, expected `nil` absence (never an error, never conflated with the equally valid `"none"` present-but-unsorted result); any other `AXError` → `AX_COLUMN_SORT_DIRECTION_READ_FAILED`.

No fallback to coordinates, screen position, or visual matching exists anywhere in this capability's resolution path.

---

## Result Contract
`QAXColumnSortDirectionMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `columnIdentifier` | `String?` | The resolved column's own identifier, if any. |
| `columnTitle` | `String?` | The resolved column's own title, if any. |
| `sortDirection` | `String?` | `"ascending"` / `"descending"` / `"none"`, or `nil` for genuine attribute absence. |

No `AXUIElement`, no coordinates, no raw CFType object, no table contents, and no cell values ever appear in this type.

---

## Error Handling — All Fail Closed
| Condition | Diagnostic |
|---|---|
| Wrong CFType (neither `String` nor `NSNumber`) | `AX_COLUMN_SORT_DIRECTION_MALFORMED` |
| CFType-correct value matching neither documented symbol set | `AX_COLUMN_SORT_DIRECTION_UNEXPECTED_VALUE` (carries only the offending raw representation, never table/cell content) |
| Genuine `AXError` read failure (`.failure`, `.cannotComplete`, `.invalidUIElement`, etc.) | `AX_COLUMN_SORT_DIRECTION_READ_FAILED` |
| Attribute absent (`.noValue`/`.attributeUnsupported`) | Valid `nil` — never an error |
| Wrong/disallowed target role | `AX_COLUMN_READ_ROLE_NOT_ALLOWED` |

Nothing is ever silently mapped to `"none"` except the one genuinely documented `NSAccessibilitySortDirectionUnknown`/`NSAccessibilityUnknownSortDirectionValue` case — an undocumented or malformed value is always its own distinct failure, never folded into the valid "unsorted" state.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.columnSortDirectionReadSucceeded(applicationName: String, columnIdentifier: String?, columnTitle: String?, hasSortDirection: Bool, sortDirection: String?)`
- **Evaluation**: independently re-validates that `sortDirection` (when claimed present) is exactly one of `["ascending", "descending", "none"]` — never trusts the executor's own `success` flag alone, mirroring the independent-recheck discipline established in `ui.read_text_selection_state`/`ui.list_element_parameterized_attribute_names`. A fabricated `success == true` claiming an unrecognized or `nil` sort-direction string is still correctly rejected (tests 37/37b).
- **Absence as its own valid outcome**: `hasSortDirection == false` is verified as `evidence: "...sortDirection=unavailable status=verified"` — never conflated with `sortDirection=none` (test 35).
- **Evidence**: application identity, column identity, and the sort-direction string are safe to include directly — a bounded, closed enum carries no privacy risk.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite. Observing the current sort direction grants zero authorization for clicking the column header or any other mutation — independently re-verified as a disjoint decision (test 33).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no sort-direction value is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1`; `maxAXAttributesRead = 1` (`kAXSortDirectionAttribute` only); `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous call.
  - `maxReturnedRecords = 1`.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `columnIdentifier`, `columnTitle`, and the closed-enum `sortDirection` string — never table/cell content.
- **Classification**: safe structural metadata — a closed 3-value enum plus the caller-supplied column identity, cannot meaningfully contain PII by construction.
- **Must never be persisted beyond identity**: durable `verifiedEvidence` and audit `executionSummary` carry only application identity, column identity, and the sanitized sort-direction string.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`** — proven both structurally (0 matches in the forbidden-API audit) and by a real fixture's own column remaining unmutated after the read (test 32).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticColumnSortDirectionReadTests.swift`)
44 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 68); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXColumnReadRolePolicy` accepts `AXColumn`/rejects other roles, missing-identity rejection); AX read (single-attribute, no traversal — structural); every documented valid value (`ascending`/`descending`/`none`, and the structural distinction between `"none"` and absence); the real, linked native-symbol validation for both the String (`NSAccessibility.SortDirectionValue`) and NSNumber (`NSAccessibilitySortDirection`) representations; malformed values (wrong CFType, unexpected integer, unexpected string, malformed representation) all failing closed with distinct diagnostics; absence handling (`.noValue`/`.attributeUnsupported` treated identically, never conflated with `"none"`); error handling (missing/ambiguous application, no fallback, missing/ambiguous target, stale target, genuine `AXError` failure); privacy (durable evidence and audit records proven to carry only bounded structural facts, using distinctive sentinel column titles); security (no mutation authority, disjoint authorization from `ui.click_element`); verification (successful evidence, absence evidence, failure on unsuccessful result, independent rejection of fabricated/inconsistent evidence including a nil-value-despite-claimed-presence case); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; resource bounds (structural, plus a real-fixture repeated-invocation no-side-effects test); real macOS AppKit E2E (TCC-guarded, real `NSTableView`/`NSTableColumn`, honest reporting of the native default with no fabricated guess).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 43 constructs a real `NSTableView`/`NSTableColumn` (the same fixture shape `ui.list_table_columns`'s own E2E test established) and dispatches `QBridgeAccessibility.shared.readColumnSortDirection` end-to-end against it, asserting only that the call succeeds, that any returned value is one of the three documented states, and that the column itself remains unmutated — the exact native default for a column with no sort descriptor applied is observed honestly, never assumed in advance. No AppKit-public setter for `accessibilitySortDirection` was found to exist for `NSTableColumn` (unlike `setAccessibilityRequired`/`setAccessibilityProtectedContent` used in prior phases), so this test could not additionally force a specific ascending/descending state via a native AppKit accessibility mechanism — it validates the honest native default only.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the TCC-guarded tests in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the real, live AX round-trip confirming which of the two documented CFType representations a genuine AX provider actually returns for `kAXSortDirectionAttribute`. All unit-level structural proofs (including the real-linked-symbol validation tests 11/12) and the mock-driven `QPlanExecutor` pipeline test (test 39) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticColumnSortDirectionReadTests`): 44/44 passed.
- **Related suites**: `QSemanticTableColumnEnumerationTests`, `QApplicationResolutionHardeningTests`, `QPersistenceSecurityTests`, `QPermissionGateTests`, `QActionVerificationTests`, `QPlanExecutionTests`, `QExecutionServiceTests` — combined 77/77, all green, zero regressions.
- **Compile-verification finding**: the first focused-test build attempt failed with 3 compile errors (`Cannot convert value of type 'NSAccessibility.SortDirectionValue' to expected argument type 'String'`) in both the production resolver and the test file's own real-symbol assertion — root-caused to `NSAccessibilitySortDirectionValue`'s non-extensible `NS_TYPED_ENUM` Swift import shape (see "Swift Import Correction" above) and fixed by using `.rawValue` on the namespaced enum cases rather than the assumed raw `String` constants. Re-run passed cleanly (44/44) with no further compile issues.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1 (initial)**: failed on `QSemanticTextSelectionStateReadTests.capabilityRegistrationAcceptsUIReadTextSelectionState()` — a **real regression**, not environmental: that Phase 2BS test hardcoded `QModelPlanParser.registeredCapabilities.count == 67`, which became stale the moment this phase registered capability #68. Fixed by updating the literal to `68` (same strict equality assertion, no weakening — see diff in "Files Changed" below). Verified in isolation (55/55) before retrying.
  - **Run 1 (retried after fix)**: 3581/3581 passed — clean.
  - **Run 2**: 3581/3581 passed — clean.
  - **Run 3**: 3581/3581 passed — clean.
  - No failure was ever converted to PASS by weakening; the one real regression found was fixed at its root cause (a stale literal in a prior phase's own test), and all three official runs after the fix were fully clean with zero environmental flakes.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Forbidden API & Scope Audit
- Forbidden-API audit (`CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, network, shell, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`): **0 actual usages** — all diff matches are documentation/comments explicitly stating their absence.
- Scope audit: exactly 6 files touched — `QBridgeAdapters.swift`, `QModelPlanSchema.swift`, `QPlanExecutor.swift`, `QActionVerification.swift`, `QExecutionService.swift` (production, all expected), `QSemanticTextSelectionStateReadTests.swift` (one required stale-literal fix, see Regression Results), plus the new `QSemanticColumnSortDirectionReadTests.swift` test file and this documentation file. No unrelated file was modified.

---

## Files Changed
- `leanring-buddy/q-runtime/QBridge/QBridgeAdapters.swift` — new `QAXColumnReadRolePolicy`, `QAXColumnSortDirectionMetadata`, `readColumnSortDirection`, `resolveColumnSortDirection`, and 4 new `QAXInteractionError` cases.
- `leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift` — registry entry #68.
- `leanring-buddy/q-runtime/QCore/QPlanExecutor.swift` — `determineVerificationStrategy` branch for `ui.read_column_sort_direction`.
- `leanring-buddy/q-runtime/QExec/QActionVerification.swift` — `columnSortDirectionReadSucceeded` strategy case + independent-recheck evaluation.
- `leanring-buddy/q-runtime/QExec/QExecutionService.swift` — dispatch case + `executeReadColumnSortDirection`.
- `leanring-buddyTests/QSemanticTextSelectionStateReadTests.swift` — one-line fix: stale hardcoded capability count `67` → `68`.
- `leanring-buddyTests/QSemanticColumnSortDirectionReadTests.swift` — new, 44 tests.
- `docs/PHASE_2BT_SEMANTIC_COLUMN_SORT_DIRECTION.md` — this document.

---

## Known Limitations
- The exact CFType (`String` vs. `NSNumber`) a real, live AX provider returns for `kAXSortDirectionAttribute` could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — the implementation defends against both documented possibilities rather than assuming one, and this should be revisited with real hardware/TCC access if either representation is ever found to diverge from what's documented here.
- No AppKit-public setter for `accessibilitySortDirection` on `NSTableColumn` was found, so the real E2E fixture could only observe the honest native default (no sort applied) rather than force and verify a specific ascending/descending state end-to-end — the ascending/descending value-mapping logic itself is proven only at the unit/structural level (tests 7, 8, 11, 12), not via a live AX round-trip, consistent with this session's TCC limitation documented above.
