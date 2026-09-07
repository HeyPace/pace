# Phase 2BV — Semantic Element Allowed Values Read (`ui.read_element_allowed_values`)

## Overview
- **Capability Identifier**: `ui.read_element_allowed_values`
- **Capability Number**: #70
- **Tool Family**: `ui` (the returned array is bounded, validated numeric control metadata, never text/credential/user content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `b1456f5`
- **Pre-Phase Capability Count**: `69`
- **Post-Phase Capability Count**: `70`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.read_element_range` (Phase 2BJ) describes a control's continuous bound (`minValue`/`maxValue`/`currentValue`/`valueIncrement`), but never whether the control is additionally restricted to a small, discrete subset of values within that bound. `ui.read_element_allowed_values` closes this gap, letting a caller learn exactly which values `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position` may safely target before ever attempting a mutation.

---

## SDK Evidence
`kAXAllowedValuesAttribute` (`AXAttributeConstants.h`, full doc block: "An array of the allowed values for a slider or other widget that displays a large value range, but which can only be set to a small subset of values within that range." `Value: A CFArrayRef of whatever type the element uses for its kAXValueAttribute.` `Writable? No.` "Recommended for sliders or other elements that can only be set to a small set of values."). Modern accessor: `NSAccessibilityProtocols.h`, `@property (nullable, copy) NSArray<NSNumber *> *accessibilityAllowedValues` — real, declared, settable, confirmed compiled correctly on the first build attempt (`slider.setAccessibilityAllowedValues([...])`/`slider.accessibilityAllowedValues()`).

---

## Semantic Contract & Target Role Policy
Target roles are restricted to `QAXRangeReadRolePolicy` (`AXSlider`/`AXIncrementor`/`AXSplitter`) — reused **completely unmodified**, the identical policy `ui.read_element_range` already uses, per the SDK's own documented scope ("Recommended for sliders or other elements..."). No new role policy was introduced, and the caller supplies the exact target `role` (mirroring `ui.read_element_range`'s existing signature shape) rather than the role being fixed internally, since `QAXRangeReadRolePolicy` legitimately spans three distinct roles.

---

## Absence vs. Empty — the Optional-Reference Pattern
`kAXAllowedValuesAttribute` carries no "required for all elements of this role"-style documentation — the doc explicitly scopes it to elements "that can only be set to a small subset of values," implying most sliders legitimately lack it entirely. This is therefore the **OPTIONAL-REFERENCE** pattern (matching `kAXTitleUIElementAttribute`/`AXRequired`/`AXContainsProtectedContent`), not the inverted pattern used by `ui.read_table_dimensions` (Phase 2BU):

| Condition | Treatment |
|---|---|
| `kAXAllowedValuesAttribute` absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Whole result `nil` — genuine, expected absence |
| `kAXAllowedValuesAttribute` present, array has 0 entries | Valid, non-nil result with `allowedValues == []` — never converted to failure or absence merely because it's unusual |
| Any other `AXError` | Fails closed — `AX_ALLOWED_VALUES_READ_FAILED` |
| Wrong outer CFType (not a `CFArray`) | Fails closed — `AX_ALLOWED_VALUES_MALFORMED` |
| Array exceeds `maxAllowedValuesCount` (128) | Fails closed — `AX_ALLOWED_VALUES_EXCEEDS_SAFE_BOUND`, checked BEFORE any per-element extraction, never truncated |
| Any array element not NSNumber-compatible | Fails the WHOLE array closed — `AX_ALLOWED_VALUES_ELEMENT_MALFORMED`, never silently dropped |
| Any array element is NaN or ±Infinity | Fails the WHOLE array closed — `AX_ALLOWED_VALUES_ELEMENT_INVALID` |
| Any integer array element that cannot be represented exactly as `Double` | Fails the WHOLE array closed — `AX_ALLOWED_VALUES_ELEMENT_INVALID`, via an exact `Int64<->Double` round-trip check, never a silent lossy cast |

A genuinely present but empty array is a fully valid, distinct result — proven directly in the test suite (tests 13, 18).

---

## Numeric Value Extraction — `resolveAllowedValues`
1. `AXUIElementCopyAttributeValue` for `kAXAllowedValuesAttribute`; `.noValue`/`.attributeUnsupported` → `nil` (absence); any other non-`.success` → `allowedValuesReadFailed`.
2. `CFGetTypeID(value) == CFArrayGetTypeID()` — else `allowedValuesMalformed`.
3. `CFArrayGetCount(cfArray) <= maxAllowedValuesCount` — else `allowedValuesExceedsSafeBound`, checked before any element is ever touched.
4. `value as? [NSNumber]` — this Swift bridging cast fails **atomically** (returns `nil`) if even one element in the underlying `CFArray` is not `NSNumber`-compatible, giving exactly the desired "mixed valid/invalid array fails the whole thing closed" behavior with no manual per-element CFType probing needed for this step. Failure → `allowedValuesElementMalformed`.
5. Each `NSNumber`'s own `CFNumberGetType` determines its validation path:
   - **Integer subtype** (`sInt8Type`...`nsIntegerType`): extracted via `CFNumberGetValue(_:.sInt64Type:_:)`, then round-tripped (`Int64(exactly: Double(int64Value)) == int64Value`) to reject any value that cannot be represented **exactly** as the result's `Double` — never a silent truncating cast.
   - **Floating-point subtype** (`float32Type`...`cgFloatType`): extracted via `CFNumberGetValue(_:.doubleType:_:)`, then validated `.isFinite` — rejecting NaN and ±Infinity.
   - Any other/unrecognized `CFNumberType`, or an extraction failure → `allowedValuesElementMalformed`.

---

## Target Resolution & Fail-Closed Gates
Identical shape to every prior Level 0 read: role-policy check → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift.

---

## Result Contract
`QAXElementAllowedValuesMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The caller-supplied, policy-validated target role. |
| `elementIdentifier` | `String?` | The resolved element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved element's own title, if any. |
| `allowedValues` | `[Double]` | Bounded, fully-validated array — may legitimately be empty. |

The overall bridge function returns `QAXElementAllowedValuesMetadata?` — `nil` represents genuine attribute absence; non-nil is always a fully validated array (possibly empty). No `AXUIElement`, no coordinates, no raw `CFArray`/`CFNumber` object, and no unrelated attribute ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementAllowedValuesReadSucceeded(applicationName:role:elementIdentifier:elementTitle:hasAllowedValues:allowedValues:)`
- **Evaluation**: independently re-validates every claimed value is `.isFinite` — never trusts the executor's own `success` flag alone, mirroring `textSelectionStateReadSucceeded`'s/`columnSortDirectionReadSucceeded`'s/`tableDimensionsReadSucceeded`'s identical independent-recheck discipline. A fabricated `success == true` claiming a NaN or infinite value among the "validated" array is still correctly rejected (tests 42/42b).
- **Absence as its own valid outcome**: `hasAllowedValues == false` is verified directly as `evidence: "...allowedValues=unavailable status=verified"` — never conflated with a present-but-empty array.
- **Evidence**: application identity, element identity, and the allowed values themselves are safe to include directly — bounded numeric control metadata carries no privacy risk.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`. Observing allowed values grants zero authorization for `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position` — independently re-verified as disjoint decisions (test 37).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — no allowed-values array is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1`; `maxAXAttributesRead = 1` (`kAXAllowedValuesAttribute` only); `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous call.
  - `maxReturnedRecords = 1`; `maxAllowedValuesCount = 128` (the returned array itself, checked before extraction, never silently truncated).

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `role`, `elementIdentifier`, `elementTitle`, and the bounded, validated `[Double]` array — never table/cell/text/credential content.
- **Classification**: safe structural metadata — a bounded numeric array describing a control's own permitted settings, cannot meaningfully contain PII, credentials, OTPs, or payment information by construction.
- **Must never be persisted beyond identity**: durable `verifiedEvidence` and audit `executionSummary` carry only application identity, element identity, and the bounded numeric array.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`** — proven both structurally (0 matches in the forbidden-API audit) and by a real fixture's own slider value remaining unmutated after the read (test 36).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, AppleScript, shell, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticElementAllowedValuesReadTests.swift`)
47 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 70); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXRangeReadRolePolicy` accepted roles reused unmodified, wrong role rejected both structurally and against a real fixture, missing-identity rejection, wrong-application-never-falls-back, missing/ambiguous target, stale target); AX read (single-attribute, no traversal — structural); value validation (non-empty array, genuinely empty array as its own distinct valid state, integer-valued and floating-point-valued elements, absence vs. empty distinction); malformed/invalid values (wrong outer CFType, non-numeric element failing the whole array, mixed valid/invalid array, NaN, +Infinity, -Infinity, integer overflow via the exact round-trip check, genuine AXError failure); resource bounds (array exactly at the 128 maximum accepted, array above the maximum fails closed, no silent truncation, structural 1-target/1-read bound); privacy (durable evidence and audit records proven to carry only bounded numeric metadata, using distinctive sentinel slider identifiers); security (no mutation authority, disjoint authorization from `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position`, no approval state modified); verification (successful evidence, absence evidence, failure on unsuccessful result, independent rejection of fabricated NaN/Infinity values); recovery (uncertain step fails closed to pending, no replay authorization); duplicate/identity (exact target identity enforced, no ambiguity acceptance); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; resource-bound/no-side-effect repeated-invocation test; real macOS AppKit E2E (TCC-guarded, real `NSSlider`, forced deterministic values via the genuine `setAccessibilityAllowedValues` accessor round-tripping exactly).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 46 constructs a real `NSSlider` (the same fixture shape `ui.read_element_range`'s own E2E test established) and forces deterministic values via the real, declared `slider.setAccessibilityAllowedValues([NSNumber(0), NSNumber(25), NSNumber(50)])` — confirmed to round-trip correctly at the AppKit level (`slider.accessibilityAllowedValues()`) even before any AX dispatch. This is the **second capability this session with a genuine forced-value native accessor for the exact attribute being read** (after `ui.read_table_dimensions`, Phase 2BU).

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented for the live `AXUIElementCopyAttributeValue` round-trip — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the live AX round-trip confirming `kAXAllowedValuesAttribute` reflects the forced AppKit-level array when read through the real Accessibility API. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test (test 44) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticElementAllowedValuesReadTests`): 47/47 passed (one compile-fix needed: a `@MainActor` annotation missing from one real-fixture test, caught and fixed by the mandatory compile-and-test gate before the suite ever ran successfully).
- **Related suites**: `QSemanticElementRangeReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticColumnSortDirectionReadTests`, `QSemanticTextSelectionStateReadTests`, `QApplicationResolutionHardeningTests`, `QPersistenceSecurityTests`, `QPermissionGateTests`, `QActionVerificationTests`, `QPlanExecutionTests`, `QExecutionServiceTests`, `QSemanticSliderValueTests` — combined 305/305, all green, zero regressions.
- **Stale hardcoded capability-count fix**: the first related-suite run failed on three prior phases' registration tests (`QSemanticColumnSortDirectionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`), each hardcoding the total capability count at its own phase's post-registration value (68/69/69 respectively), all now stale at 70. All three fixed with the same strict equality assertion (no weakening). Verified in isolation (305/305) before retrying.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: initial attempt failed on `QSemanticApplicationHiddenStateTests.recoveryRecognizesAlreadyDesiredAsComplete()` (×4). **Classified ENVIRONMENTAL, not a regression**: file not touched anywhere in this phase's diff; system load confirmed elevated (`uptime` load averages 8.15/6.48/4.73) with `avconferenced` actively running (a real audio/video call on the shared dev machine — the same root cause diagnosed in Phases 2BO/2BQ/2BS/2BU); isolated suite passed cleanly (31/31) immediately after. Retry passed cleanly: 3674/3674.
  - **Run 2**: 3674/3674 passed — clean.
  - **Run 3**: failed twice on the same `QSemanticApplicationHiddenStateTests` flake class (`recoveryRecognizesAlreadyDesiredAsComplete()` then `verificationSucceedsOnMatch()`), each re-confirmed environmental via an immediate isolated re-run (31/31 both times) and corroborated by continued elevated system load/`avconferenced` activity, before retrying the full suite. A separate, unrelated console-only network-connection-refused message (`http://127.0.0.1:59997/v1/models`) was also observed but confirmed NOT to correspond to any actual failing test in the reported failure list — noise from an unrelated local service, not a test result. Final retry passed cleanly: 3674/3674.
  - No failure was ever converted to PASS by weakening; every environmental classification was backed by concrete evidence (isolated re-run + system load/process corroboration) before being retried.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact behavior of a live `AXUIElementCopyAttributeValue` round-trip against the forced `setAccessibilityAllowedValues` array could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level accessor round-trip was provable without TCC.
- A genuine `AXError` failure, a malformed (non-`CFArray`) returned value, an oversized array, a non-numeric element, or a NaN/Infinite/overflowing element cannot be constructed from any real, standard AppKit `NSSlider` — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
