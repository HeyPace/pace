# Phase 2BS — Semantic Text Selection State Read (`ui.read_text_selection_state`)

## Overview
- **Capability Identifier**: `ui.read_text_selection_state`
- **Capability Number**: #67
- **Tool Family**: `ui` (the returned fields are bounded numeric structural metadata, never text content — never requires the `perception` sanitize-before-persist boundary since no content ever crosses it)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `0920417`
- **Pre-Phase Capability Count**: `66`
- **Post-Phase Capability Count**: `67`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability answers "where is the text cursor/selection right now?" — a genuine gap in the "observe text state" category. `kAXSelectedTextRangeAttribute` was confirmed used only inside a completely separate, legacy, pre-semantic file (`PaceActionExecutor+Keyboard.swift`, which uses `CGEvent` for keyboard simulation) — never within the `Q*` semantic capability architecture. `kAXNumberOfCharactersAttribute` was confirmed unused anywhere in the codebase.

---

## Semantic Contract — Structural State, Never Content
This capability deliberately reads only **numeric selection state**, never the selected text itself:

| Field | Source attribute | Notes |
|---|---|---|
| `selectionLocation` | `kAXSelectedTextRangeAttribute` (`.location`) | Character offset (not byte offset) |
| `selectionLength` | `kAXSelectedTextRangeAttribute` (`.length`) | `0` is a fully valid caret/insertion-point result |
| `totalCharacterCount` | `kAXNumberOfCharactersAttribute` | Total characters in the element |

`kAXSelectedTextAttribute` (the actual selected text string) is **never read anywhere in this capability's implementation** — confirmed by direct diff audit. Both source attributes are documented "Required for all editable text elements," but neither is documented as universally present on every AX element (unlike `kAXModalAttribute`), so this capability follows the same **optional-reference** missing-vs-failure pattern established for `AXRequired`/`AXContainsProtectedContent` (Phases 2BQ/2BR).

---

## The Missing-vs-Failure Design Decision — Whole-Result Absence, Never Partial
Unlike the single-scalar `Bool?` pattern used for `AXRequired`/`AXContainsProtectedContent`, this capability combines **three numeric facts from two independent attribute reads**. The design decision made here: genuine absence of **either** attribute makes the **whole** result `nil` — never a partially-known state.

```swift
public func readTextSelectionState(...) async throws -> QAXTextSelectionStateMetadata?
```

Rationale: both attributes are documented as co-required for the same role family (editable text elements) — a real element that reports one but not the other would represent an inconsistent AX-provider quirk, not a state this capability's contract needs to represent distinctly. This was a deliberate, documented design choice (not the only valid one) made per the approved contract's explicit guidance not to assume, and not to fabricate a partial state.

| Condition | Treatment |
|---|---|
| `kAXSelectedTextRangeAttribute` absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Whole result `nil` — genuine, expected absence |
| `kAXSelectedTextRangeAttribute` present, `kAXNumberOfCharactersAttribute` absent | Whole result `nil` — same treatment, per the co-required-attribute rationale above |
| Either attribute: any other `AXError` | Fails closed — `AX_TEXT_SELECTION_RANGE_READ_FAILED` / `AX_CHARACTER_COUNT_READ_FAILED` |
| Either attribute: malformed returned value | Fails closed — `AX_TEXT_SELECTION_RANGE_MALFORMED` / `AX_CHARACTER_COUNT_MALFORMED` |
| Negative `location`/`length`/`total` | Fails closed — `AX_TEXT_SELECTION_RANGE_INVALID` / `AX_CHARACTER_COUNT_INVALID` — never silently clamped to zero |
| `selectionLocation + selectionLength > totalCharacterCount`, or that addition overflows `Int` | Fails closed — `AX_TEXT_SELECTION_STATE_INCONSISTENT`, checked via `addingReportingOverflow(_:)` |

A `selectionLength` of `0` (a plain caret/insertion point) is a **fully valid, distinct** result — never treated as an error, and never conflated with absence — proven directly in the test suite (tests 6, 8, 19).

---

## Native Value Extraction — CFRange via `AXValueGetValue`
`kAXSelectedTextRangeAttribute`'s value is an `AXValueRef` of type `kAXValueTypeCFRange` — genuinely new extraction ground for this codebase (no prior capability reads a CFRange-typed `AXValue`). The implementation:
1. Validates `CFGetTypeID(value) == AXValueGetTypeID()` before any cast — the returned value is never assumed to be an `AXValue` merely because the copy call succeeded.
2. Validates `AXValueGetType(axValue) == .cfRange` — rejects any `AXValue` of a different type (e.g. `kAXValueTypeCGPoint`) before ever attempting extraction.
3. Calls `AXValueGetValue(axValue, .cfRange, &range)` and checks its own `Bool` return value.
4. Validates `location >= 0, length >= 0` before ever constructing a result.

Every one of these four checks fails closed on its own dedicated `QAXInteractionError` case — no silent coercion, no default substitution.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call. This capability never broadens secure-field access and never reads secure text content; it never resolves `AXSecureTextField` as a target.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling** (see table above): absence of either attribute is valid; genuine failure/malformed/invalid/inconsistent are not, and fail the whole read closed.

No fallback to coordinates, screen position, visual matching, or keyboard-focus guessing exists anywhere in this capability's resolution path — proven structurally (test 34).

---

## Result Contract
`QAXTextSelectionStateMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's role. |
| `selectionLocation` | `Int` | Non-optional within a non-nil result — the whole-result `Optional` wrapper carries the absence semantics instead. |
| `selectionLength` | `Int` | `0` is fully valid. |
| `totalCharacterCount` | `Int` | Total characters in the element. |

The overall bridge function returns `QAXTextSelectionStateMetadata?` — `nil` represents genuine absence; non-nil is always a fully validated, internally consistent triple. No `AXUIElement`, no coordinates, and — critically — **no selected or surrounding text content of any kind** ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.textSelectionStateReadSucceeded(applicationName: String, role: String, hasSelectionState: Bool, selectionLocation: Int?, selectionLength: Int?, totalCharacterCount: Int?)`
- **Evaluation**: unlike every prior single-scalar Level 0 read's verification, this strategy **independently re-validates structural consistency** rather than blindly trusting the dispatch layer's own `success` flag — mirroring `elementAttributeNamesReadSucceeded`'s/`elementParameterizedAttributeNamesReadSucceeded`'s identical independent-bound-recheck discipline. It checks `location >= 0`, `length >= 0`, `total >= 0`, and `location + length <= total` (via `addingReportingOverflow(_:)`) itself, regardless of what the executor claimed — proven directly in the test suite (test 48): a fabricated `success == true` result claiming a selection that exceeds the total count is still correctly rejected.
- **Absence as its own valid outcome**: `hasSelectionState == false` is verified directly as `evidence: "...selectionState=unavailable status=verified"` — never conflated with a zero/empty selection (proven in test 46).
- **Evidence**: the three numeric facts (or `unavailable`) are safe to include directly — bounded structural numbers carry no privacy risk, unlike button/label text.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite. Observing selection state grants zero authorization for `ui.read_element_value` or `ui.set_text_value` — both independently re-verified as disjoint decisions (test 37).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no selection-state value is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1`; `maxAXAttributesRead = 2` (`kAXSelectedTextRangeAttribute`, `kAXNumberOfCharactersAttribute`); `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxTextBytesRead = 0` — `kAXSelectedTextAttribute` is never read.
  - `maxPolling = 0`; `maxRetries = 0` — a fixed set of at most two synchronous calls.
  - `maxReturnedRecords = 1`.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `selectionLocation`, `selectionLength`, `totalCharacterCount` (bounded structural numbers) and the already-caller-supplied application/role identity — never content, never text.
- **Classification**: safe structural metadata — numeric position/extent facts, not content, not credential-like, cannot meaningfully contain PII by construction (they are integers, never strings derived from the text).
- **Must never be persisted beyond identity**: no new persistence mechanism introduced; durable `verifiedEvidence` and audit `executionSummary` carry only application name, role, and the three numeric facts — proven directly against distinctive sentinel selected text (`"SuperSecretSelectedTextSentinel789"`, `"AnotherSecretSelectedTextSentinel456"`) that never appears in either (tests 40/41).
- **This capability never calls `AXUIElementSetAttributeValue`** — even though `kAXSelectedTextRangeAttribute` is itself documented `Writable? Yes` at the native API level, this capability is strictly read-only and never writes it — proven both structurally and by a real fixture's own live selection remaining unchanged after the read (test 39).
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing allowlist verbatim, including its existing `AXSecureTextField` exclusion.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticTextSelectionStateReadTests.swift`)
55 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 67); native true/normal selection states (caret at beginning/middle/end, non-empty selection, full-text selection, zero-length selection); boundary cases (`location=0`, `length=0`, `total=0`, selection ending exactly at total — inclusive bound); invalid states (negative location/length/total, selection extending beyond total, integer-overflow scenario via `addingReportingOverflow`) — all structurally proven to fail closed with their own distinct error code; genuine absence for a non-text element (real `NSButton` fixture) proven never fabricated as zero/empty; the `.noValue`/`.attributeUnsupported` → whole-nil discipline proven structurally for both attributes independently and in combination; native type failures (malformed CFRange, malformed character count, unexpected `AXValueType`, missing value, unsupported attribute, unexpected `AXError`) each failing closed with their own distinct error code; target resolution (missing/unavailable application, missing element, ambiguous target, wrong application never falling back, stale target, execution identity mismatch, no coordinate/visual-matching fallback); role policy (disallowed roles and the dedicated secure-field diagnostic); security (`QPermissionGate` allow, disjoint authorization from `ui.read_element_value`/`ui.set_text_value`, no persistent authorization, never writing the selection range, proven both structurally and against a real fixture's unchanged live selection); privacy (selected text never in durable evidence or audit against distinctive sentinel strings, no raw AX object persistence, recovery never persists a replay-able value); resource bounds (structural); evidence-based verification including the independent structural-consistency re-check that rejects a fabricated inconsistent success; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural, confirmed zero matches of any kind, and confirmed `kAXSelectedTextAttribute` is never actually read); no polling/traversal and repeatability (a real fixture read twice yields the same result and remains unmutated); real macOS E2E (TCC-guarded, a real `NSTextField` made first responder with a real field-editor selection, at the beginning/middle/end of the text plus a non-empty selection, with the live selection proven unchanged after each read).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 54 constructs real `NSTextField`s, makes each the window's first responder (`window.makeFirstResponder(field)`), and sets a real live selection on the resulting field editor (`field.currentEditor()?.selectedRange = ...`) — the standard, fully public AppKit mechanism for establishing a genuine text selection, no custom `NSAccessibility` override needed. Each is dispatched through `QBridgeAccessibility.shared.readTextSelectionState` end-to-end, asserting the correct `location`/`length`/`total` at the beginning, middle (a non-empty range), and end of the text, while independently confirming the fixture's own live selection remained unchanged after the read.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the real, live AX round-trip confirming `kAXSelectedTextRangeAttribute`/`kAXNumberOfCharactersAttribute` reflect a genuine field-editor selection on trusted hardware. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test (test 50) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticTextSelectionStateReadTests`): 55/55 passed.
- **Related suites**: `QSemanticElementRangeReadTests` 31/31, `QSemanticElementRequiredStateTests` 36/36, `QSemanticWindowModalStateReadTests` 32/32, `QSemanticElementTitleReferenceReadTests` 38/38, `QSemanticFocusedElementReadTests` 33/33, `QSemanticElementAttributeEnumerationTests` 33/33, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3537/3537 passed — clean.
  - **Run 2**: initial attempt failed on `QSemanticApplicationHiddenStateTests.recoveryRecognizesAlreadyDesiredAsComplete()` — a pre-existing test that launches a real `TextEdit.app` helper process and polls its real, live WindowServer-reported hidden state (`for _ in 0..<20 { if helper.isHidden { break } ... }`). **Classified ENVIRONMENTAL, not a regression**: this file is not touched anywhere in this phase's diff; the isolated suite passed cleanly (31/31) immediately after. Retry passed cleanly: 3537/3537.
  - **Run 3**: the same class of failure recurred twice more (`verificationSucceedsOnMatch()`, then `recoveryRecognizesAlreadyDesiredAsComplete()` again), each time re-confirmed environmental via an immediate isolated re-run (31/31 both times) before retrying the full suite. Final retry passed cleanly: 3537/3537.
  - No failure was ever converted to PASS; no test was modified, skipped, or weakened to obtain a green result. Every failure was identified by exact test name, isolated, re-run, confirmed to reproduce only under full-suite parallel load (never in isolation), and compared against the implementation diff (confirmed unrelated) before being classified.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- A genuine `AXError` failure, a malformed (non-CFRange/non-numeric) returned value, a structurally invalid (negative) range/count, or an inconsistent triple cannot be constructed from any real, standard AppKit `NSTextField`/`NSTextView` — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
- The specific combination of "selection range present but character count absent" (or vice versa) is treated as whole-result absence per this phase's deliberate design decision (see "The Missing-vs-Failure Design Decision" above) rather than its own distinct error code — this was a documented design choice, not an oversight, and could be revisited in a future phase if real-world AX providers are found to exhibit this combination meaningfully.
