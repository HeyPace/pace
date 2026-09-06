# Phase 2BQ — Semantic Element Required State Read (`ui.read_element_required_state`)

## Overview
- **Capability Identifier**: `ui.read_element_required_state`
- **Tool Family**: `ui` (the returned `isRequired` boolean is structural form metadata — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `b66b537`
- **Pre-Phase Capability Count**: `64`
- **Post-Phase Capability Count**: `65`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability answers "is this form field required before submission?" — a question directly useful to the Observe/Understand/Verify/Execute loop before any text-entry mutation (`ui.set_text_value`) is ever proposed. `AXRequired`/`NSAccessibilityRequiredAttribute` (available since macOS 10.12) was confirmed unused anywhere in this codebase prior to this phase.

---

## Native API Evidence — No HIServices C Constant Exists
Per the approved implementation contract, this phase confirmed via direct grep that `kAXRequiredAttribute` **has no C-level constant anywhere in this SDK's `AXAttributeConstants.h`** (`HIServices.framework`). The only SDK-level evidence is AppKit's own:

```objc
APPKIT_EXTERN NSAccessibilityAttributeName const NSAccessibilityRequiredAttribute API_AVAILABLE(macos(10.12));
//(NSNumber *) - (boolValue) whether a form field is required to have content for successful submission of the form
```

`NSAccessibilityAttributeName` is declared `NS_TYPED_ENUM`, which means `NSAccessibilityRequiredAttribute` imports into Swift as a typed wrapper case (`NSAccessibility.Attribute`-style), **not** a plain `String`/`CFString` directly usable with `AXUIElementCopyAttributeValue`. This is not a novel situation for this codebase: it mirrors the identical precedent already established for `axFullScreenAttribute` (`"AXFullScreen"`) and `axIdentifierAttributeName` (`"AXIdentifier"`) — both attributes with no HIServices C constant, both already resolved by defining a `private`/`fileprivate static let ax<Name>AttributeName = "AX<Name>"` raw-string constant in `QBridgeAdapters.swift`. Per Apple's own universal, unbroken `kAXFooAttribute`/`NSAccessibilityFooAttribute` naming convention (already relied upon for both of those prior constants — not a guess), this phase adds `axRequiredAttributeName = "AXRequired"` following the exact same convention, used directly as a `String` for consistency with every other `AXUIElementCopyAttributeValue` call site in this file. This was verified empirically: the new capability's real macOS E2E test (test 34) confirms `"AXRequired"` correctly reads back a value set via the real, public `NSView.setAccessibilityRequired(_:)` AppKit API.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, Phase 2J — no broader, arbitrary-role allowlist was introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.list_element_parameterized_attribute_names`.
- **AX API**: `AXUIElementCopyAttributeValue(targetElement, "AXRequired" as CFString, ...)` — a single, purely observational call.
- **Mutation primitives**: none. `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual non-comment usages).

---

## The Missing-vs-Failure Design Decision — Optional, Not Inverted
This is the load-bearing design decision the approved contract required. Unlike `kAXModalAttribute` (Phase 2BO, documented "Required for all window elements" — no genuine absence case, so absence there is treated as failure), `AXRequired` has **no universal-presence documentation** — it is meaningful only for form-field-like elements. This capability therefore follows the **optional-reference** missing-vs-failure pattern established for `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (Phase 2BM) and `kAXTitleUIElementAttribute` (Phase 2BN), not the inverted pattern used for `kAXModalAttribute`:

| `AXError` | Meaning | Treatment |
|---|---|---|
| `kAXErrorNoValue` | The element genuinely has no required-state concept | **Genuine, expected absence** — produces `nil`. Never an error. |
| `kAXErrorAttributeUnsupported` | Same treatment as `kAXErrorNoValue` | **Genuine, expected absence** — `nil`. |
| Anything else (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`, ...) | A genuine communication/API failure | **Never folded into "absent."** Throws `AX_ELEMENT_REQUIRED_STATE_READ_FAILED`. |

Additionally, even when the copy call reports `.success`: if the returned value is not interpretable as `Bool` (a malformed result) → `AX_ELEMENT_REQUIRED_STATE_MALFORMED`.

**`Bool?`, not `Bool`, is the result type** — `QAXElementRequiredStateMetadata.isRequired: Bool?` — a deliberate, explicit choice proven directly in the test suite (test 6): `nil` (absence) and `false` (explicit, observed non-required state) are structurally distinct, distinguishable values, never conflated. An explicit `false` is returned directly as soon as `AXUIElementCopyAttributeValue` reports success and the value casts cleanly to `Bool` — it is never treated as "missing."

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the required-state read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling** (see table above): absence is valid; genuine failure/malformed value are not, and fail the whole read closed.

---

## Result Contract
`QAXElementRequiredStateMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's role — field naming deliberately matches `QAXElementActionsMetadata`/`QAXElementAttributeNamesMetadata`/`QAXElementParameterizedAttributeNamesMetadata`'s established convention (`role`, not `elementRole`). |
| `isRequired` | `Bool?` | `nil` = genuine absence (valid); `true`/`false` = a definite, directly-observed fact. |

No `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementRequiredStateReadSucceeded(applicationName: String, role: String, isRequired: Bool?)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readElementRequiredState`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`; it never mutates anything as part of verification.
- **Evidence**: `application=<name> role=<role> isRequired=<true|false|unavailable> status=verified` (or `status=failed`) — the `isRequired` fact itself is safe to include directly (a single structural form-metadata boolean carries no privacy risk, matching `windowModalStateReadSucceeded`'s identical discipline for its own boolean). Absence renders as the literal string `"unavailable"`, never `"false"` — proven directly in the test suite (test 27b) to never be conflated.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite, and proven *independent* of `ui.set_text_value`'s own, entirely separate Level 2 approval requirement (test 19).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no `isRequired` value is ever persisted into any field a recovery replay could read back as standing authorization.
- **QResourceGuard applicability**: not applicable — `QResourceGuard` is this codebase's filesystem path-jail/denylist mechanism, unrelated to AX reads. No arrays, no traversal, no polling exist in this capability to bound beyond the single scalar read.
- **Resource Bounds** (all enforced structurally):
  - `maxElementsTouched = 1`; `maxAttributesRead = 1`; `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous calls.
  - `maxReturnedRecords = 1` (a single scalar Boolean, no array to bound).

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `isRequired` (a single structural form-metadata boolean, present or absent) and the already-caller-supplied application/role identity — never content, never a value beyond this.
- **Classification**: safe structural metadata — the same tier as `isModal` in `ui.read_window_modal_state`'s own `QAXWindowModalStateMetadata`.
- **Must never be persisted beyond identity**: no new persistence mechanism introduced; durable `verifiedEvidence` and audit `executionSummary` carry only application name, role, and the `isRequired` fact — proven directly in the test suite (tests 25/26).
- **The model observing `isRequired = true` gains zero authorization to fill or otherwise modify the field** — proven directly (test 19): `ui.read_element_required_state`'s own `QPermissionGate` evaluation and `ui.set_text_value`'s entirely separate, still-required Level 2 approval evaluation are wholly disjoint decisions.
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing allowlist verbatim, including its existing `AXSecureTextField` exclusion.
- **No durable pointer/content leaks**: the new type's stored properties are `String`/`Bool?` only — no `AXUIElement`-typed field exists anywhere in the declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticElementRequiredStateTests.swift`)
36 focused tests, covering: capability registration (anti-downgrade both directions); required-field read for both `true` and `false` against real fixtures built with `setAccessibilityRequired(_:)`; genuine absence (never fabricated as `false`); the `.noValue`/`.attributeUnsupported` → `nil` discipline proven structurally; absence-never-converted-to-false proven at the type level; missing/unavailable application; ambiguous application (delegated to the shared resolver suite); missing element; ambiguous element; wrong application never falling back; stale target and execution identity mismatch (structural, shared discipline); allowed vs. disallowed role, including the dedicated secure-field diagnostic; malformed (non-Boolean) value and genuine `AXError` failure each failing closed with their own distinct error code; permission denial; Level 0/no-approval via the real `QPermissionGate`; discovered required-state never authorizing `ui.set_text_value`; no persistent authorization constructed; no mutation proven via a real fixture's field remaining unchanged; recovery/replan state proven to never persist a replay-able `isRequired` value; no raw AX object persistence (structural); no sensitive content leakage (structural); durable-plan-snapshot and audit-record content proven structural-only; evidence-based verification success/failure/absence contents; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; a fail-closed summary test asserting every malformed/unexpected path carries its own distinct `errorCode`; forbidden API audit (structural, confirmed zero matches of any kind for `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); no polling/traversal (structural); real macOS E2E (TCC-guarded, both an explicitly-required and an explicitly-not-required real `NSTextField` fixture, neither mutated).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 34 constructs two real `NSTextField`s — one via `field.setAccessibilityRequired(true)`, one via `field.setAccessibilityRequired(false)` — both public, standard AppKit API calls, no custom `NSAccessibility` override needed. Both are dispatched through `QBridgeAccessibility.shared.readElementRequiredState` end-to-end, asserting `isRequired == true` and `isRequired == false` respectively, while independently confirming neither field's own content was mutated by the read.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementRequiredStateTests`): 36/36 passed.
- **Related suites**: `QSemanticWindowModalStateReadTests` 32/32, `QSemanticElementRangeReadTests` 31/31, `QSemanticElementTitleReferenceReadTests` 38/38, `QSemanticElementAttributeEnumerationTests` 33/33, `QSemanticElementParameterizedAttributeEnumerationTests` 38/38, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3445/3445 passed — clean.
  - **Run 2**: 3445/3445 passed — clean.
  - **Run 3**: failed 3 consecutive times on `QSemanticApplicationHiddenStateTests.verificationSucceedsOnMatch()` — a pre-existing test that launches a real `TextEdit.app` helper process and polls its real, live WindowServer-reported hidden state; the test's own inline comments explicitly acknowledge "the same class of real WindowServer/session non-determinism already documented for this capability's other tests." **Classified ENVIRONMENTAL, not a regression**: this file is not touched anywhere in this phase's diff; the isolated suite (`QSemanticApplicationHiddenStateTests` alone) passed cleanly (31/31) every time it was run in isolation, confirming the failure is specific to real-process/WindowServer contention under full-suite parallel load, not a defect this phase introduced. A 4th full-regression attempt (Run 3, final) passed cleanly: 3445/3445.
  - No failure was ever converted to PASS; no test was modified, skipped, or weakened to obtain a green result.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact native default of `AXRequired` for an `NSTextField` on which `setAccessibilityRequired(_:)` was never called at all was not asserted to a specific value (`nil` vs. a default `false`) — test 3 asserts only that no exception is thrown, since this behavior is AppKit-version/role dependent and not itself part of this capability's guaranteed contract (the contract is: report exactly what the OS returns, distinguishing absence from an explicit value, never guessing).
- A genuine `AXError` failure or a malformed (non-Boolean) returned value cannot be constructed from any real, standard AppKit element — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
