# Phase 2BM — Semantic Window Default/Cancel Button Read (`ui.read_window_default_button`)

## Overview
- **Capability Identifier**: `ui.read_window_default_button`
- **Tool Family**: `ui` (button title/identifier are short structural labels — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `f50c302`
- **Pre-Phase Capability Count**: `60`
- **Post-Phase Capability Count**: `61`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions, zero button presses.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_windows` exposes title/identifier/minimized/main per window, but no capability has ever surfaced which button activates on Enter (`kAXDefaultButtonAttribute`) or Escape (`kAXCancelButtonAttribute`) — a genuinely orientational fact ("what happens if I press Enter here") independently re-identified as the strongest still-unimplemented gap across all seven discovery phases leading up to this one (2BG through 2BM).

---

## Semantic Accessibility Contract
- **Target Element**: exactly one `AXWindow` (`QAXWindowRolePolicy`, reused verbatim from Phase 2U — no broader role allowlist introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role `AXWindow`, matched by `identifier` or `title`) — identical pattern to `ui.set_window_main`/`ui.close_window`.
- **AX API**: `AXUIElementCopyAttributeValue(windowElement, kAXDefaultButtonAttribute, ...)` and the same for `kAXCancelButtonAttribute` — each a single, purely observational call yielding an `AXUIElementRef` reference (or absence), followed by exactly one further `kAXTitleAttribute`/`AXIdentifier` read on each referenced button — never descending into the button's own children.
- **Mutation primitives**: none. `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual usages of any kind, including in comments).

---

## The Missing-vs-Failure Design Decision
This is the load-bearing design decision the approved contract required. macOS's `AXError` distinguishes genuine attribute absence from an actual communication/API failure:

| `AXError` | Meaning | Treatment |
|---|---|---|
| `kAXErrorNoValue` | The attribute conceptually applies but currently has no value | **Genuine, expected absence** — this window has no such button. Produces `nil` for that field. Never an error. |
| `kAXErrorAttributeUnsupported` | The element does not support this attribute at all | **Genuine, expected absence** — same treatment as `kAXErrorNoValue`. |
| Anything else (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`, `kAXErrorIllegalArgument`, `kAXErrorNotImplemented`, `kAXErrorAPIDisabled`, ...) | A genuine communication/API failure | **Never folded into "absent."** Throws `AX_WINDOW_BUTTON_REFERENCE_READ_FAILED`, carrying which button and the underlying `AXError`. |

Additionally, even when the copy call itself reports `.success`:
- If the returned value is not an `AXUIElement` (a malformed result) → `AX_WINDOW_BUTTON_REFERENCE_MALFORMED`.
- If the referenced element's own `kAXRoleAttribute` is not exactly `"AXButton"` (the mere existence of a reference is never sufficient — mirroring `ui.close_window`'s identical `targetNotACloseButton` discipline) → `AX_WINDOW_BUTTON_REFERENCE_WRONG_ROLE`.

**Deliberate scope decision**: any of these three non-absence problems — for *either* button — fails the **whole** read closed, rather than degrading only that one field to `nil`. This is a stricter, simpler contract than a partial-success design: it guarantees the caller never receives a result that silently mixes one reliable field with one unreliable field it has no way to distinguish. This refinement was made at implementation time (the discovery document had not fully specified this cross-field behavior) and is documented here explicitly per this program's convention of never silently expanding scope without recording the decision.

---

## Target Resolution & Fail-Closed Gates
1. **Match criteria**: at least one of `windowIdentifier`/`windowTitle` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
2. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
3. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
4. **Window resolution**: `collectMatches` bounded search for the one `AXWindow` — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
5. **Staleness check**: the resolved window is re-snapshotted immediately before the button read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
6. **Per-button gates** (see table above): absence is valid; failure/malformed/wrong-role are not, and fail the whole read closed.
7. **Bound enforcement**: each button's title/identifier is checked against `maxWindowButtonMetadataLength` (256 characters) — exceeding it → `AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH`, never silently truncated.

---

## Output Contract
`QAXWindowDefaultButtonMetadata` / `QAXWindowButtonReference` (new types, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `windowTitle` / `windowIdentifier` | `String?` | The resolved window's own identity. |
| `defaultButton` / `cancelButton` | `QAXWindowButtonReference?` | Each independently `nil` (genuine absence) or `{title: String?, identifier: String?}`. |

No `AXUIElement`, no coordinates, no button *values*, ever appear in either type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.windowDefaultButtonReadSucceeded(applicationName: String, windowTitle: String?)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readWindowDefaultButton`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`; it never presses either button or mutates anything as part of verification.
- **Evidence**: `application=<name> window=<title> status=verified` (or `status=failed`) — never the button titles/identifiers themselves.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite, and proven *independent* of `ui.click_element`'s own, entirely separate Level 2 approval requirement (test 28).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no raw button metadata is ever persisted into any field a recovery replay could read back.
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxWindowsResolved = 1`.
  - `maxElementsInspected = 3` (the window + its default button + its cancel button).
  - `maxReferencedButtons = 2`.
  - `maxTraversalDepth = 0` beyond the two direct reference follows — no descent into either button's own children.
  - `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous calls.
  - `maxReturnedRecords = 1` (window-scoped; never a collection); `maxStringLength = 256` per title/identifier.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: button title/identifier (structural UI labels like `"OK"`/`"Cancel"`) and presence/absence — never content, never a value.
- **Must never be persisted beyond identity**: individual button title/identifier strings are deliberately excluded from durable verification evidence, audit `executionSummary` text, memory, and recovery/replan state — proven directly in the test suite against distinctively-named button labels (tests 30, 31, 32).
- **The model observing `defaultButton = "OK"` gains zero authorization to press "OK"** — proven directly (test 28): `ui.read_window_default_button`'s own `QPermissionGate` evaluation and `ui.click_element`'s entirely separate, still-required Level 2 approval evaluation are wholly disjoint decisions.
- **No new privacy mechanism introduced**: reuses `QAXWindowRolePolicy`'s existing single-role allowlist verbatim.
- **No durable pointer/content leaks**: both new types' stored properties are `String`/`String?` only — no `AXUIElement`-typed field exists anywhere in either declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticWindowDefaultButtonReadTests.swift`)
39 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero/ambiguous application match; exact window match (by identifier and title); zero/ambiguous window match; all four default/cancel presence combinations (default-only and neither proven via real fixtures; cancel-only and both-present proven at the model level — see Known Limitations); valid `AXButton` reference accepted; wrong-role/malformed/inaccessible references each fail closed with their own distinct, dedicated error code; button title/identifier extraction; missing title/identifier handled safely; 256-character metadata accepted (bound inclusive); 257-character metadata fails closed, never truncated; the missing-vs-failure distinction proven never confused in either direction; **no button is ever pressed**, proven via a real fixture whose press-counter target remains at zero; `QPermissionGate` never requires approval, and is proven independent of `ui.click_element`'s own separate requirement; no persistent authorization is ever constructed; no application activation occurs; individual button metadata absent from durable-plan snapshots, audit records, and recovery/replan state (three dedicated tests against distinctively-named button labels); evidence-based verification success/failure contents; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural, and confirmed zero matches of any kind for `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); no polling/child-traversal (structural); real macOS E2E (TCC-guarded, `NSWindow` + `NSButton` via `defaultButtonCell`, with an honest genuine-absence proof for the cancel button).

---

## Real macOS E2E — Known Environmental Limitation
Test 39 builds a real `NSWindow` with an `NSButton` assigned via `window.defaultButtonCell`, and dispatches through `QBridgeAccessibility.shared.readWindowDefaultButton` end-to-end, asserting the returned default-button title/identifier match the fixture exactly while independently confirming the button's own title remains unchanged (never pressed). In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created a window and performed a real AX round-trip. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BL) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticWindowDefaultButtonReadTests`): 39/39 passed.
- **Related suites**: `QSemanticWindowMainDesignationTests` 41/41, `QSemanticWindowCloseTests` 48/48, `QSemanticWindowEnumerationTests` 33/33, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3301/3301, 3301/3301, 3301/3301 — no flakes, no regressions, no environmental failures.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- **No live cancel-button fixture**: unlike `kAXDefaultButtonAttribute`, which maps directly to the public `NSWindow.defaultButtonCell` property, `kAXCancelButtonAttribute` has no equivalent first-class `NSWindow` property in standard AppKit — apps that expose one typically do so via a custom `NSAccessibility` override (e.g. implementing `accessibilityCancelButton()`), which a plain `NSWindow`/`NSButton` fixture does not provide. The "cancel-only" and "both-present" combinations are therefore proven at the model/contract level (direct `QAXWindowDefaultButtonMetadata` construction) rather than via a genuine live fixture; the "default-only" and "neither" combinations, and the missing-vs-failure distinction itself, are all proven against real, live `AXUIElement`s.
- A malformed reference, a wrong-role reference, or a genuine `AXError` read failure cannot be constructed from any real, standard AppKit window/button pair — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting.
