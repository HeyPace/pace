# Phase 2BJ — Semantic Element Range Read (`ui.read_element_range`)

## Overview
- **Capability Identifier**: `ui.read_element_range`
- **Tool Family**: `ui` (matching `ui.read_element_value`'s own family — every returned field is a bounded `Double`, never free-form content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `c609f17`
- **Pre-Phase Capability Count**: `57`
- **Post-Phase Capability Count**: `58`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.set_slider_value`, `ui.step_incrementor`, and `ui.set_splitter_position` all read `kAXMinValueAttribute`/`kAXMaxValueAttribute` internally, before ever proposing a mutation — but none of that validated range was ever exposed to the model ahead of the Level 2 approval prompt. This capability lets the model learn valid bounds *before* requesting a value be set, reducing wasted approval round-trips on out-of-range guesses.

---

## Supported SDK Roles — Verified, Not Copied
`QAXRangeReadRolePolicy.allowedRoles = ["AXSlider", "AXIncrementor", "AXSplitter"]` — every role independently re-verified against the live SDK at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`'s `AXRoleConstants.h` at implementation time:

```
$ grep -n '"AXSlider"' AXRoleConstants.h      → kAXSliderRole      (present)
$ grep -n '"AXIncrementor"' AXRoleConstants.h → kAXIncrementorRole (present)
$ grep -n '"AXSplitter"' AXRoleConstants.h    → kAXSplitterRole    (present)
$ grep -n "AXStepper" AXRoleConstants.h       → (zero matches)
```

**`QAXSliderRolePolicy`'s historical `"AXStepper"` string was deliberately NOT carried forward.** No role constant of that name exists anywhere in `AXRoleConstants.h` — a real `NSStepper`'s AX role is `AXIncrementor`, already covered by this policy. Per the approved implementation contract's explicit instruction ("Do NOT blindly copy the historical inert 'AXStepper' string... If a role cannot be represented authoritatively by the SDK, do not silently treat the string as authoritative. Fail closed."), this policy fails closed on `"AXStepper"` exactly like any other unverified role string — proven directly in the test suite (test 8: `QAXRangeReadRolePolicy.isAllowedRangeReadRole("AXStepper") == false`, alongside a real `NSStepper` fixture resolved successfully under its *actual* role, `"AXIncrementor"`).

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXRangeReadRolePolicy`'s allowlist, resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.read_element_value`.
- **AX API / attributes** (direct, non-recursive, on the one resolved element only):
  - `kAXMinValueAttribute`, `kAXMaxValueAttribute` — **both required**. Either unreadable → the whole read fails closed (`AX_RANGE_READ_FAILED`), reusing `QAXInteractionError.rangeReadFailed` verbatim from `ui.set_slider_value`'s (Phase 2M) own identical pre-mutation guard — not duplicated with different semantics.
  - `kAXValueAttribute` — current value, **required**. Unreadable → `AX_VALUE_READ_FAILED`, reusing `QAXInteractionError.valueReadFailed` verbatim.
  - `kAXValueIncrementAttribute` — **optional**, per its own SDK documentation ("Recommended for `kAXIncrementorRole` and other similar elements" — never "required"). A missing/unreadable increment is a valid, honestly-reported `nil`, never a fabricated default.
- **AX action(s)**: none. **Mutation**: none.
- **Numeric validation** (mirrors `ui.set_slider_value`'s own identical pre-mutation sequence, reused not duplicated): `minValue <= maxValue` (else `AX_INVALID_RANGE`, reusing `QAXInteractionError.invalidRange` verbatim), and `minValue <= currentValue <= maxValue` (else `AX_INVALID_RANGE`). **Never clamped, never repaired, never substituted with a default** — an inconsistent range fails the whole read closed.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check**: `role` must be on `QAXRangeReadRolePolicy.allowedRoles` — checked before any AX call. Disallowed role → `AX_RANGE_READ_ROLE_NOT_ALLOWED`.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the range read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **Numeric validation gates**: as detailed above — unreadable range/value or an internally-inconsistent range all fail closed with no fallback.

---

## Output Contract
`QAXElementRangeMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input — not element content. |
| `role` | `String` | Echoed from the caller's own input. |
| `minValue` | `Double` | Always present when the read succeeds. |
| `maxValue` | `Double` | Always present when the read succeeds. |
| `currentValue` | `Double` | Always present when the read succeeds. |
| `valueIncrement` | `Double?` | Optional, honestly `nil` when absent — never defaulted. |

**No identifier, title, label, or any other identity field is included.** The caller already supplied the identifier/title used to resolve this exact element — echoing it back would expose a "label" this capability's approved contract does not require, so it is deliberately omitted (a stricter reading than `ui.read_element_value`'s own output, which does echo an identifier — a deliberate, approved-contract-driven difference, not an oversight). No raw `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementRangeReadSucceeded(applicationName: String, role: String)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readElementRange` (exact application/target resolution, a successfully-read and internally-consistent numeric range), already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }` bypass.
- **Evidence**: `application=<name> role=<role> status=verified` (or `status=failed`) — never the numeric bounds themselves, a deliberately more conservative choice than `ui.list_incrementors`' own precedent (which does include min/max in its per-item `outputData`), matching the stricter evidence-privacy pattern `ui.read_focused_element`/`ui.read_application_state` already established instead.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects.
- **Resource Bounds** (all enforced structurally):
  - `maxElementsTouched = 1` — the one resolved element only.
  - `maxTraversalDepth = 0` — no descent beyond the resolved element; `kAXChildrenAttribute` is never read.
  - `maxChildren = 0`.
  - `maxActions = 0` — no `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` call exists anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous attribute reads; no loop, no `Task.sleep`.
  - `maxTextValueSize` — not applicable; every returned field beyond identity echo is a numeric scalar (`Double`), never free-form text.

---

## Privacy & Security Architecture
- **Exposed surface, exhaustively**: `role`, `minValue`, `maxValue`, `currentValue`, `valueIncrement` — all numeric or a short structural role string. No text, no labels beyond the caller's own echoed input, no cell contents, no arbitrary AX attributes, no screenshots, no OCR, no user-entered text, no credentials, no URLs, no personal information.
- **No new privacy mechanism introduced**: reuses the exact numeric-metadata precedent `ui.list_incrementors`/`ui.list_progress_indicators`/`ui.list_level_indicators` already established for exposing min/max in their own enumerations; this capability's evidence string is deliberately *more* conservative than those precedents (identity only, never the numbers).
- **No durable pointer/content leaks**: `QAXElementRangeMetadata`'s stored properties are `String`/`String`/`Double`/`Double`/`Double`/`Double?` only — no `AXUIElement`-typed field exists anywhere in its declaration (proven both by source inspection and a compile-time-enforced test).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages across the entire production diff; the one string match in the diff is an unchanged, pre-existing documentation comment from an unrelated method's own doc block, not something added this phase).

---

## Test Coverage (`QSemanticElementRangeReadTests.swift`)
31 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero application matches; ambiguous application resolution (generic resolver precedent); exact target resolution (by identifier and by title); zero/ambiguous target matches; `AXSlider` role accepted; `AXIncrementor` accepted with `"AXStepper"` explicitly proven rejected (real `NSStepper` fixture resolves under its true role); `AXSplitter` role accepted; unsupported roles rejected; min/max/current value all read correctly from a real fixture; `valueIncrement` honestly `nil` when absent; missing required min/max fails closed (structural, mirrors `ui.set_slider_value`'s identical guard); malformed current value fails closed; `minValue > maxValue` fails closed; current value outside range fails closed; no traversal; no mutation (real fixture's value provably unchanged); no actions; no polling; resource bound (single-element output type); privacy boundary (compile-time field-type proof); evidence-based verification contents and failure-propagation; `QPermissionGate` never requires approval; normal `QPlanExecutor` pipeline execution with dedicated (non-bypassed) verification; forbidden API audit; uncertain in-flight recovery; no sensitive data persisted; real macOS E2E (TCC-guarded, with independent re-read verification).

---

## Real macOS E2E — Known Environmental Limitation
Test 30 builds a real `NSWindow` + `NSSlider` with `minValue = 0`, `maxValue = 200`, `value = 42`, and dispatches through `QBridgeAccessibility.shared.readElementRange` end-to-end — twice, independently re-resolving and re-reading the second time rather than trusting the first call's own return value. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created a window and performed a real AX round-trip. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BI) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementRangeReadTests`): 31/31 passed.
- **Related suites**: `QSemanticSliderValueTests` 32/32, `QSemanticIncrementorEnumerationTests` 19/19, `QSemanticIncrementorStepTests` 32/32, `QSemanticSplitterPositionTests` 27/27, `QSemanticElementReadTests` 18/18, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3196/3196, 3196/3196, 3196/3196 — no flakes, no regressions, no environmental failures.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- `ui.set_scroll_position` also reads `kAXMinValueAttribute`/`kAXMaxValueAttribute` internally, but on an `AXScrollBar` resolved via a convenience-reference attribute from an `AXScrollArea` — a different target-resolution shape than the four directly-role-searchable roles this capability covers. Deliberately excluded from this phase's scope per the approved discovery document; a future phase could add scroll-bar range support with its own resolution branch if needed.
- A malformed/inconsistent range (unreadable attributes, `min > max`, or current value out of bounds) cannot be constructed from any real, standard AppKit `AXSlider`/`AXIncrementor`/`AXSplitter` fixture — `NSSlider`/`NSStepper` enforce `min <= max` at construction, and their own reported current value is always internally consistent. These failure paths are proven at the error-contract level (exact `QAXInteractionError` case and message format, verbatim-reused from `ui.set_slider_value`'s own identical checks) rather than via a live fixture that standard AppKit prevents from ever legitimately existing.
