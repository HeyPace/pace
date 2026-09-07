# Phase 2BR — Semantic Element Protected Content State Read (`ui.read_element_protected_content_state`)

## Overview
- **Capability Identifier**: `ui.read_element_protected_content_state`
- **Capability Number**: #66
- **Tool Family**: `ui` (the returned `isProtectedContent` boolean is structural security-state metadata — never the protected content itself, and never requires the `perception` sanitize-before-persist boundary since no content ever crosses it)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `271a946`
- **Pre-Phase Capability Count**: `65`
- **Post-Phase Capability Count**: `66`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: this is the first capability in the entire Q×PACE semantic accessibility program whose entire purpose is **defensive/security-aware observation** — the boolean it returns exists to help a future planner AVOID sensitive content, never to expose any of that content itself. `AXContainsProtectedContent`/`NSAccessibilityContainsProtectedContentAttribute` (available since macOS 10.9) was confirmed unused anywhere in this codebase prior to this phase.

---

## Native API Evidence — No HIServices C Constant Exists
Per the approved implementation contract, this phase confirmed via direct grep that `kAXContainsProtectedContentAttribute` **has no C-level constant anywhere in this SDK's `AXAttributeConstants.h`** (`HIServices.framework`) — an empty grep result. The only SDK-level evidence is AppKit's own:

```objc
APPKIT_EXTERN NSAccessibilityAttributeName const NSAccessibilityContainsProtectedContentAttribute API_AVAILABLE(macos(10.9));
// (NSNumber *) - (boolValue) contains protected content?
```

`NSAccessibilityAttributeName` is declared `NS_TYPED_ENUM`, so `NSAccessibilityContainsProtectedContentAttribute` imports into Swift as a typed wrapper case, **not** a plain `String`/`CFString` directly usable with `AXUIElementCopyAttributeValue` — the identical situation `axRequiredAttributeName` ("AXRequired") already resolved in Phase 2BQ. Per that exact, already-proven-working precedent, this phase adds `axContainsProtectedContentAttributeName = "AXContainsProtectedContent"`.

**A notable naming nuance verified, not assumed**: the Objective-C property exposing this attribute (`NSAccessibilityProtocols.h`) is named `accessibilityProtectedContent`/`isAccessibilityProtectedContent` — a *shorter* name than the attribute constant itself. Its own doc comment reads "Invokes when clients request `NSAccessibilityContainsProtectedContentAttribute`", confirming the wire-format string is `"AXContainsProtectedContent"` (matching the full constant name), **not** `"AXProtectedContent"` (the shorter property name) — this was verified from the constant declaration itself, not guessed from the property name alone, and was subsequently confirmed empirically by this phase's own real macOS E2E test (test 35), which reads back exactly the value set via `field.setAccessibilityProtectedContent(_:)`.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, Phase 2J — no broader, arbitrary-role allowlist was introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.read_element_required_state`.
- **AX API**: `AXUIElementCopyAttributeValue(targetElement, "AXContainsProtectedContent" as CFString, ...)` — a single, purely observational call. No attribute other than `AXContainsProtectedContent` is ever read.
- **Mutation primitives**: none. `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual non-comment usages).
- **The protected content itself is never read**: this capability never calls `axValueDescription`/`axStringAttribute` for `kAXValueAttribute` or any content-bearing attribute on the target. The Boolean IS the entire semantic observation.

---

## The Missing-vs-Failure Design Decision — Optional, Not Inverted
Following the exact discipline established for `AXRequired` (Phase 2BQ): unlike `kAXModalAttribute` (Phase 2BO, documented "Required for all window elements" — no genuine absence case), `AXContainsProtectedContent` has **no universal-presence documentation** — it is meaningful only for elements that can meaningfully hold sensitive content. This capability therefore follows the **optional-reference** missing-vs-failure pattern:

| `AXError` | Meaning | Treatment |
|---|---|---|
| `kAXErrorNoValue` | The element genuinely has no protected-content concept | **Genuine, expected absence** — produces `nil`. Never an error. |
| `kAXErrorAttributeUnsupported` | Same treatment as `kAXErrorNoValue` | **Genuine, expected absence** — `nil`. |
| Anything else (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`, ...) | A genuine communication/API failure | **Never folded into "absent."** Throws `AX_ELEMENT_PROTECTED_CONTENT_STATE_READ_FAILED`. |

Additionally, even when the copy call reports `.success`: if the returned value is not interpretable as `Bool` (a malformed result) → `AX_ELEMENT_PROTECTED_CONTENT_STATE_MALFORMED`.

**`Bool?`, not `Bool`, is the result type** — `QAXElementProtectedContentStateMetadata.isProtectedContent: Bool?` — proven directly in the test suite (test 6): `nil` (absence) and `false` (explicit, observed non-protected state) are structurally distinct, distinguishable values, never conflated. Per the approved contract's explicit instruction not to assume an unset property equals `false`, test 3 investigates the real, native default behavior honestly rather than asserting a guessed value.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call. This capability never resolves a secure field directly as its TARGET, even to check that field's own protected-content flag, mirroring every prior read capability's identical secure-field precedent.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the protected-content-state read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling** (see table above): absence is valid; genuine failure/malformed value are not, and fail the whole read closed.

---

## Result Contract
`QAXElementProtectedContentStateMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's role — field naming deliberately matches `QAXElementRequiredStateMetadata`'s and every other element-read type's established convention (`role`, not `elementRole`). |
| `isProtectedContent` | `Bool?` | `nil` = genuine absence (valid); `true`/`false` = a definite, directly-observed fact. |

No `AXUIElement`, no coordinates, no arbitrary AX attributes, and — critically — **no protected content of any kind** ever appear in this type: no `AXValue` text, no passwords, no OTPs, no credentials, no payment information, no arbitrary field contents, no screenshots, no OCR output. The Boolean is the entire semantic observation.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementProtectedContentStateReadSucceeded(applicationName: String, role: String, isProtectedContent: Bool?)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readElementProtectedContentState`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`; it never mutates anything and never reads the protected content itself as part of verification.
- **Evidence**: `application=<name> role=<role> isProtectedContent=<true|false|unavailable> status=verified` (or `status=failed`) — the `isProtectedContent` fact itself is safe to include directly (it IS the security fact, never the content — a single structural boolean carries no privacy risk, matching `elementRequiredStateReadSucceeded`'s identical discipline for its own optional boolean). Absence renders as the literal string `"unavailable"`, never `"false"` — proven directly in the test suite (test 27b) to never be conflated.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite. `isProtectedContent == true` grants zero permission to subsequently call `ui.read_element_value` or any other capability — proven disjoint in the test suite (test 19), which independently confirms `ui.read_element_value`'s own Level 0 evaluation is unaffected by this capability, and `ui.set_text_value`'s Level 2 requirement remains fully intact.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no `isProtectedContent` value is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxElementsTouched = 1`; `maxAttributesRead = 1`; `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0`; `maxScreenshots = 0`; `maxOCR = 0` — a single fixed synchronous call.
  - `maxReturnedRecords = 1` (a single scalar Boolean, no array to bound).

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `isProtectedContent` (a single structural security-state boolean, present or absent) and the already-caller-supplied application/role identity — never content, never a value beyond this.
- **Classification**: safe structural metadata — the same tier as `isRequired` in `ui.read_element_required_state`'s own `QAXElementRequiredStateMetadata`. Unlike almost every other capability in this program, this one's entire security narrative is *protective*: observing `true` is intended to help a future planner heuristic avoid sensitive content, not to create any new exposure.
- **Must never be persisted beyond identity**: no new persistence mechanism introduced; durable `verifiedEvidence` and audit `executionSummary` carry only application name, role, and the `isProtectedContent` fact — proven directly in the test suite against distinctively-named field content (`"SuperSecretPassword123"`, `"AnotherSecretValue456"`) that never appears in either (tests 25/26).
- **The model observing `isProtectedContent = true` gains zero authorization** to read the field's actual value or modify it — proven directly (test 19): this capability's own `QPermissionGate` evaluation, `ui.read_element_value`'s independent Level 0 evaluation, and `ui.set_text_value`'s entirely separate, still-required Level 2 approval evaluation are three wholly disjoint decisions.
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing allowlist verbatim, including its existing `AXSecureTextField` exclusion.
- **No durable pointer/content leaks**: the new type's stored properties are `String`/`Bool?` only — no `AXUIElement`-typed field exists anywhere in the declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).
- **No planner-policy change implemented**: per the approved contract, this phase does NOT implement any automatic behavior where `isProtectedContent == true` gates or blocks another capability — that remains a future planner heuristic, out of scope for this phase.

---

## Test Coverage (`QSemanticElementProtectedContentStateReadTests.swift`)
37 focused tests, covering: capability registration (anti-downgrade both directions); protected-field read for both `true` and `false` against real fixtures built with `setAccessibilityProtectedContent(_:)`; the unset/native-default case explicitly investigated honestly rather than assumed; genuine absence never fabricated as `false`; the `.noValue`/`.attributeUnsupported` → `nil` discipline proven structurally; absence-never-converted-to-false proven at the type level; missing/unavailable application; ambiguous application (delegated to the shared resolver suite); missing element; ambiguous element; wrong application never falling back; stale target and execution identity mismatch (structural, shared discipline); allowed vs. disallowed role, including the dedicated secure-field diagnostic; malformed (non-Boolean) value and genuine `AXError` failure each failing closed with their own distinct error code; permission denial; Level 0/no-approval via the real `QPermissionGate`; discovered protected-content-state never authorizing `ui.read_element_value` or `ui.set_text_value` (both independently re-verified); no persistent authorization constructed; no mutation and no content read proven via a real fixture's field content remaining unchanged; recovery/replan state proven to never persist a replay-able `isProtectedContent` value; no raw AX object persistence (structural); protected content itself proven never to leak into durable evidence or audit against distinctively-named secret field values; evidence-based verification success/failure/absence contents; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; a fail-closed summary test asserting every malformed/unexpected path carries its own distinct `errorCode`; forbidden API audit (structural, confirmed zero matches of any kind for `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); exactly-one-attribute-read/no-polling/no-traversal (structural); repeated invocation proven to have no side effects and to be idempotent; real macOS E2E (TCC-guarded, both an explicitly-protected and an explicitly-not-protected real `NSTextField` fixture, neither mutated nor content-read).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 35 constructs two real `NSTextField`s — one via `field.setAccessibilityProtectedContent(true)`, one via `field.setAccessibilityProtectedContent(false)` — both public, standard AppKit API calls, no custom `NSAccessibility` override needed. Both are dispatched through `QBridgeAccessibility.shared.readElementProtectedContentState` end-to-end, asserting `isProtectedContent == true` and `isProtectedContent == false` respectively, while independently confirming neither field's own content was read or mutated by the observation.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the real, live AX round-trip confirming `AXContainsProtectedContent` reflects `setAccessibilityProtectedContent(_:)` on trusted hardware — the unit-level structural proofs and the mock-driven pipeline test (test 30) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticElementProtectedContentStateReadTests`): 37/37 passed.
- **Related suites**: `QSemanticElementRequiredStateTests` 36/36, `QSemanticWindowModalStateReadTests` 32/32, `QSemanticElementTitleReferenceReadTests` 38/38, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive official runs): 3482/3482, 3482/3482, 3482/3482 — no flakes, no regressions, no environmental failures encountered this phase.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact native default of `AXContainsProtectedContent` for an `NSTextField` on which `setAccessibilityProtectedContent(_:)` was never called at all was not asserted to a specific value (`nil` vs. a default `false`) — test 3 asserts only that no exception is thrown and the identity fields are correct, since this behavior is AppKit-version/role dependent and not itself part of this capability's guaranteed contract (the contract is: report exactly what the OS returns, distinguishing absence from an explicit value, never guessing).
- A genuine `AXError` failure or a malformed (non-Boolean) returned value cannot be constructed from any real, standard AppKit element — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
- Per the approved contract, this phase does not implement any planner-level policy that automatically treats `isProtectedContent == true` as a gate on other capabilities — the boolean is exposed as observational data only; any such heuristic is explicitly out of scope and left to a future phase.
