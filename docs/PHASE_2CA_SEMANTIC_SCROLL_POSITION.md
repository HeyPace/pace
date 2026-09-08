# Phase 2CA — Semantic Scroll Position Read (`ui.read_scroll_position`)

## Overview
- **Capability Identifier**: `ui.read_scroll_position`
- **Capability Number**: #75
- **Tool Family**: `ui` (returns a single bounded numeric position, never any element content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `9c356a3`
- **Pre-Phase Capability Count**: `74`
- **Post-Phase Capability Count**: `75`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.set_scroll_position` (Phase 2W) can move a scroll bar to an absolute position but has no read-only counterpart — an agent must already know (or guess) the current position before deciding whether/how far to scroll. This capability reuses `ui.set_scroll_position`'s exact, completely unmodified target-resolution chain (`QAXScrollAreaRolePolicy`, the orientation convenience-reference, the scroll bar's own role re-validation) and reads exactly one attribute, `kAXValueAttribute`, exactly once.

---

## SDK Evidence
`kAXValueAttribute`'s own discussion block in `AXAttributeConstants.h` explicitly names scroll bars — "a `kAXScrollBar`'s `kAXValueAttribute` is writable because it allows an efficient way for the user to get to a specific position" — the same evidence `ui.set_scroll_position` (Phase 2W) already cites. `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute` (the documented, read-only convenience-reference attributes from `AXScrollArea` to its child `AXScrollBar`) and `kAXRoleAttribute`/`AXScrollBar`/`AXScrollArea` role constants are unchanged, reused verbatim from the existing implementation — no new SDK research was required; this capability's target-resolution architecture is a direct reuse of already-verified evidence.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXScrollAreaRolePolicy` (`["AXScrollArea"]`, Phase 2W) — reused completely unmodified, identical to `ui.set_scroll_position`'s own search-criterion role. The actual read target (a genuine `AXScrollBar`) is never searched for directly; it is resolved via the documented `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute` convenience reference from the resolved scroll area, selected by an explicit, never-inferred `orientation` argument (`"horizontal"` or `"vertical"` only — never guessed, never defaulted). The resolved scroll bar's own `kAXRoleAttribute` is independently re-validated as exactly `AXScrollBar` before ever being treated as genuine — the mere existence of the reference is never sufficient. This is a single bounded read: `kAXValueAttribute` is read exactly once against the resolved scroll bar — never arbitrary traversal, never `kAXMinValueAttribute`/`kAXMaxValueAttribute`, never any element's content.

### Contract note — `[0.0, 1.0]`, not `[minValue, maxValue]`
Unlike `ui.set_scroll_position`, which reads the scroll bar's own `kAXMinValueAttribute`/`kAXMaxValueAttribute` to validate a caller-supplied `desiredValue` against its actual reported range, this read-only capability's contract is fixed to the SDK-documented `[0.0, 1.0]` normalized bound alone — the same universal normalization every standard `AXScrollBar` reports, distinct from `AXSlider`'s arbitrary min/max range. This keeps the capability to its declared one-target/one-read resource budget: reading `kAXMinValueAttribute`/`kAXMaxValueAttribute` as well would be a second and third AX call this capability's contract does not authorize.

---

## Fail-Closed Semantics — No Valid Absence
Unlike `kAXAllowedValuesAttribute`/`kAXValueDescriptionAttribute` (optional-reference pattern, valid absence), a genuine `AXScrollBar`'s `kAXValueAttribute` has **no valid-absence case** — mirroring `ui.read_window_modal_state`'s (Phase 2BO) identical required-attribute reasoning. Every failure mode fails closed with its own dedicated diagnostic; nothing is ever silently defaulted, clamped, or guessed:

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed scroll-area role | Fails closed — `AX_SCROLL_AREA_ROLE_NOT_ALLOWED` |
| Missing/invalid `orientation` | Fails closed — `AX_INVALID_ORIENTATION` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Scroll-bar convenience reference unresolvable | Fails closed — `AX_SCROLL_BAR_REFERENCE_UNAVAILABLE` |
| Resolved reference's own role ≠ `AXScrollBar` | Fails closed — `AX_TARGET_NOT_A_SCROLL_BAR` |
| Any non-`.success` `AXError` reading `kAXValueAttribute` (including `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Fails closed — `AX_SCROLL_POSITION_READ_FAILED` |
| Returned value not a genuine `CFNumberRef` | Fails closed — `AX_SCROLL_POSITION_MALFORMED` |
| `CFNumberGetValue` extraction failure | Fails closed — `AX_SCROLL_POSITION_CONVERSION_FAILED` |
| Extracted value not `.isFinite` (NaN/±Infinity) | Fails closed — `AX_SCROLL_POSITION_NON_FINITE` |
| Extracted, finite value outside `[0.0, 1.0]` | Fails closed — `AX_SCROLL_POSITION_OUT_OF_RANGE` |

Five new `QAXInteractionError` cases were added (`scrollPositionReadFailed`, `scrollPositionMalformed`, `scrollPositionConversionFailed`, `scrollPositionNonFinite`, `scrollPositionOutOfRange`) — deliberately not reusing `ui.set_scroll_position`'s generic `valueReadFailed`, since this capability's contract requires differentiating "wrong CFType" from "extraction failure" from "non-finite" from "out-of-range" as distinct diagnostics. Every other failure mode (missing criteria, disallowed role, invalid orientation, permission denial, target resolution, staleness, missing scroll-bar reference, misqualified reference) reuses `ui.set_scroll_position`'s existing `QAXInteractionError` cases verbatim.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.set_scroll_position`: match-criteria check (`identifier` or `title` required) → role-policy check (`AXScrollArea` only) → orientation validation (`"horizontal"`/`"vertical"` only, mapped to the documented convenience-reference attribute name) → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXScrollArea` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the scroll-bar reference follow → `AX_STALE_TARGET` on drift → `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute` reference follow → the resolved reference's own `kAXRoleAttribute` re-validated as exactly `AXScrollBar` → the single `kAXValueAttribute` read against the re-verified, re-qualified scroll bar.

---

## Result Contract
`QAXScrollPositionReadMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved scroll area's own search role (`"AXScrollArea"`). |
| `elementIdentifier` | `String?` | The resolved scroll area's own identifier, if any. |
| `elementTitle` | `String?` | The resolved scroll area's own title/description, if any. |
| `orientation` | `String` | Echoed from the caller's own input (`"horizontal"`/`"vertical"`). |
| `position` | `Double` | Always a finite value in `[0.0, 1.0]`; never fabricated, clamped, or defaulted. |

This type has no valid-`nil` state — the bridge function either returns a fully-populated, validated instance or throws.

---

## Privacy Boundary
Only the bounded numeric `position` (plus non-sensitive targeting identity — application name, role, identifier/title, orientation) crosses the bridge. Never exposed: document text, page contents, arbitrary `AXValue` content, raw `AXUIElement`/CF objects, accessibility tree dumps, or descendant content. `QAXScrollPositionReadMetadata`'s stored properties are `String`/`String?`/`Double` only — no field of any kind could carry a raw AX reference or unrelated content. Verification evidence and durable persistence carry only the same bounded fields (see Verification/Recovery below).

---

## Resource Contract
- `maxTargetsResolved = 1` (the scroll area)
- `maxScrollBarReferenceFollows = 1` (the single documented orientation convenience-reference hop)
- `maxPrimaryAXReads = 1` (`kAXValueAttribute` on the resolved scroll bar — never `kAXMinValueAttribute`/`kAXMaxValueAttribute`, unlike `ui.set_scroll_position`)
- `maxTraversalDepth = 0` beyond the single documented reference hop
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1` (target-scoped, never a collection)

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readScrollPosition` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches`/`scrollBarConvenienceAttribute(forOrientation:)`/`scrollBarRole` — all pre-existing, shared with `ui.set_scroll_position`)
- Scroll-bar relationship read: `Self.axElementAttribute(scrollBarAttribute, of: scrollAreaElement)` inside `readScrollPosition`
- `kAXValueAttribute` read: `resolveScrollBarPosition(of:)` (`QBridgeAdapters.swift`)
- Numeric bounds enforcement: `resolveScrollBarPosition(of:)`'s five sequential guards (AXError → CFNumberRef type → `CFNumberGetValue` extraction → `.isFinite` → `[0.0, 1.0]`)
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Result construction: `readScrollPosition`'s trailing `QAXScrollPositionReadMetadata(...)` construction

---

## Verification
New `QVerificationStrategy` case: `.scrollPositionReadSucceeded(applicationName:role:orientation:position:)`. Unlike a bare single-scalar Level 0 read's verification, this strategy independently **re-validates** that the reconstructed `position` is `.isFinite` and within `[0.0, 1.0]`, and that `orientation` is exactly `"horizontal"`/`"vertical"` — never simply trusting the dispatch layer's own `success` flag — mirroring `elementParameterizedAttributeNamesReadSucceeded`'s/`textSelectionStateReadSucceeded`'s identical independent-bound-recheck discipline. This re-validation reuses the already-read value carried in the execution result's own output; it never performs a second AX read, staying within the declared one-read resource budget. A fabricated `success == true` claiming an out-of-range, non-finite, or malformed-orientation result is still correctly rejected.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_scroll_position` (identical to every other Level 0 read capability in this codebase): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticScrollPositionReadTests.swift` — 46 focused tests across the required categories: registration (capability count == 75, anti-downgrade/upgrade); arguments (missing/invalid orientation, missing match criteria, valid orientation values); target resolution (disallowed role, valid scroll area, horizontal vs. vertical orientation distinctness, missing scroll-bar relationship, non-existent application/target, ambiguous target, stale-target/TCC-denied structural notes, misqualified scroll-bar reference); AX value validation (0.0/0.5/1.0 boundaries, negative/above-1.0 out-of-range, NaN/±Infinity non-finite, malformed CFType, conversion failure, genuine AXError); fail-closed structural proof (no silent default/clamp); privacy (no arbitrary content exposure, verification evidence sentinel-content-free proof); resource (structural one-read/one-target bound proof, `QResourceGuard` generic application); security (`QPermissionGate` Level 0 allow, no approval state, no cross-authorization, forbidden-API structural audit); verification (independent bound recheck rejects fabricated out-of-range/non-finite/bad-orientation success, never a second AX read); recovery (uncertain step fails closed to pending, no raw `AXUIElement` persistence, durable snapshot omission proof); and full `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy. Plus two real macOS AppKit E2E tests (TCC-guarded).

All 8 pre-existing test files that hardcoded the total capability count at 74 (`QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticTableRowHeaderEnumerationTests`, `QSemanticWindowAuxiliaryButtonsReadTests`) were updated to 75 — same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CA. One pre-existing prose/assertion mismatch in `QSemanticTextSelectionStateReadTests` (comment said "grown to 73" while asserting `== 74`) was corrected while touching that exact line.

---

## Native E2E / TCC Status
Two real macOS AppKit E2E tests, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED`, never a fabricated pass):
1. A deterministic round-trip test: a real `NSScrollView`'s vertical position is set synchronously via the already-proven `QBridgeAccessibility.shared.setScrollPosition` bridge call (no animation, no polling), then independently read back via `ui.read_scroll_position`'s own `readScrollPosition`, asserting the two match within `sliderValuesAreEqual`'s existing tolerance.
2. A default-state test: a real `NSScrollView`'s untouched position is read and asserted to be a valid, finite, in-range value.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so both E2E tests correctly reported `BLOCKED` rather than a fabricated pass — consistent with every prior phase's identical environmental limitation (Accessibility trust cannot be assumed granted for an isolated, unsigned XCTest host).

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, keyboard/mouse simulation, coordinate clicking, `URLSession`, `curl`, `http://`/`https://` — **zero matches** anywhere in the new/modified production code. `readScrollPosition`/`resolveScrollBarPosition` call only `AXUIElementCopyAttributeValue` (read-only) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_scroll_position` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only `kAXValueAttribute` read in this capability's implementation is against the resolved `AXScrollBar` — never any text/content element. No raw `AXUIElement`/CF object crosses `QAXScrollPositionReadMetadata`'s boundary. Returned data is the bounded numeric `position` plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (non-fat, confirmed via `lipo -info`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches)

---

## Known Environmental Limitations
- Both real-AppKit E2E tests are TCC-blocked in this sandboxed test-runner environment (`AXIsProcessTrusted() == false`) — they correctly report `BLOCKED`, never a fabricated pass, mirroring every prior phase's identical finding.
- Full regression runs in this environment show intermittent, pre-existing single-test flakiness in unrelated live-`NSWindow`/AX-fixture capabilities (`ui.set_application_hidden`, `ui.set_window_main`, `ui.set_window_minimized`, `ui.open_app`) — a different unrelated test flaked on each of 3 consecutive full-suite runs, and every flaked test passed cleanly (0 failures) when re-run in isolation immediately afterward. None of the flakes touched any file this phase modified. This is consistent with known full-suite live-AX-fixture interaction flakiness in this test host, not a regression introduced by `ui.read_scroll_position`.
