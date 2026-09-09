# Phase 2CB — Semantic Element Role Description Read (`ui.read_element_role_description`)

## Overview
- **Capability Identifier**: `ui.read_element_role_description`
- **Capability Number**: #76
- **Tool Family**: `ui` (returns a single bounded, localized taxonomy string, never any element content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `cabf2022d081fa33acbb6dae52a62dd62913e623`
- **Pre-Phase Capability Count**: `75`
- **Post-Phase Capability Count**: `76`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability reads `kAXRoleDescriptionAttribute` — the SDK's own localized, human-readable explanation of an element's basic type or purpose (e.g. "push button", "checkbox", "text field"). This is distinct from **both** `kAXRoleAttribute` (the raw, non-localized internal role string, e.g. `"AXButton"` — never read by this capability) and `kAXValueDescriptionAttribute` (`ui.read_element_value_description`, Phase 2BW — a description of the element's **current value**, an entirely different semantic axis). It gives an agent a natural-language way to describe what kind of control it is looking at, without needing to interpret the internal AX role taxonomy.

---

## SDK Evidence
`kAXRoleDescriptionAttribute` (`AXAttributeConstants.h`) has its own dedicated `/*! @defined */` documentation block: "A localized, human-readable string that an assistive application can present to the user as an explanation of an element's basic type or purpose. Examples would be 'push button' or 'secure text field'... **Required for all elements**. Even in the worst case scenario where an element cannot figure out what its basic type is, it can still supply the value 'unknown'." — the same authority tier as `kAXModalAttribute` (this program's historically highest-scored capability, Phase 2BO). Confirmed via direct grep: zero references anywhere in this codebase before this phase.

During discovery, `kAXIsEditableAttribute` was also considered and explicitly rejected: it is found under the SDK header's own `// obsolete/unknown attributes` comment block, disqualifying it as first-class evidence.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy` (Phase 2J) — reused completely unmodified, identical to `ui.read_element_value`/`ui.list_element_actions`/`ui.read_element_value_description`'s own allowlist (`AXTextField`, `AXTextArea`, `AXStaticText`, `AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXMenuItem`, `AXComboBox`, `AXSlider`, `AXStepper`, `AXLink`, `AXTab`, `AXDisclosureTriangle`), including the identical `AXSecureTextField`-first-then-general-allowlist exclusion discipline — `AXSecureTextField` is rejected with a dedicated `secureFieldReadDenied` diagnostic before the general allowlist is ever consulted (belt and suspenders — `AXSecureTextField` is never listed in the allowlist either), even though the role description itself carries no content risk. This capability never broadens role access. This is a single bounded read: `kAXRoleDescriptionAttribute` is read exactly once against the resolved element — never `kAXValueAttribute`, never `kAXRoleAttribute`, never any traversal.

---

## Fail-Closed Semantics — No Valid Absence, No Valid Empty
Unlike `kAXValueDescriptionAttribute` (optional-reference pattern, valid absence and valid-empty-string), `kAXRoleDescriptionAttribute`'s SDK documentation states it is **"Required for all elements"** — mirroring `ui.read_window_modal_state`'s (Phase 2BO) and `ui.read_scroll_position`'s (Phase 2CA) identical required-attribute reasoning. Every failure mode fails closed with its own dedicated diagnostic; nothing is ever silently defaulted, derived from `kAXRoleAttribute`, or truncated:

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| `role == "AXSecureTextField"` | Fails closed — `secureFieldReadDenied` |
| Disallowed read role | Fails closed — `AX_DISALLOWED_ROLE` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Any non-`.success` `AXError` reading `kAXRoleDescriptionAttribute` (including `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Fails closed — `AX_ROLE_DESCRIPTION_READ_FAILED` |
| Returned value not a genuine `String` | Fails closed — `AX_ROLE_DESCRIPTION_MALFORMED` |
| Returned string is genuinely empty | Fails closed — `AX_ROLE_DESCRIPTION_EMPTY` |
| Returned string exceeds the defensive length bound | Fails closed — `AX_ROLE_DESCRIPTION_EXCEEDS_SAFE_BOUND` |

Four new `QAXInteractionError` cases were added (`roleDescriptionReadFailed`, `roleDescriptionMalformed`, `roleDescriptionEmpty`, `roleDescriptionExceedsSafeBound`). Every other failure mode (missing criteria, secure-field rejection, disallowed role, permission denial, target resolution, staleness) reuses `ui.read_element_value_description`'s existing `QAXInteractionError` cases verbatim.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_value_description`: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the requested role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXRoleDescriptionAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementRoleDescriptionMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `elementIdentifier` | `String?` | The resolved element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved element's own title/description, if any. |
| `roleDescription` | `String` | Always non-empty, always ≤256 characters; never fabricated, derived, or truncated. |

This type has no valid-`nil` state — the bridge function either returns a fully-populated, non-empty, bounded instance or throws.

---

## Privacy Boundary
Only the bounded `roleDescription` string (plus non-sensitive targeting identity) crosses the bridge. The string is OS/developer-authored taxonomy metadata, not arbitrary user/application content — safe even for the description of a secure field's own type (though `AXSecureTextField` is still excluded for consistency with every sibling capability's role policy). `kAXValueAttribute` is never read anywhere in this capability. Never exposed: document text, field values, passwords, credentials, OTPs, payment data, arbitrary application content, raw `AXUIElement`/CF objects, or accessibility tree dumps. `QAXElementRoleDescriptionMetadata`'s stored properties are `String`/`String?`/`String` only.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0` (no reference-follow, unlike `ui.read_scroll_position`'s single hop)
- `maxPrimaryAXReads = 1` (`kAXRoleDescriptionAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementRoleDescription` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling `QAXElementReadRolePolicy` capability)
- `QAXElementReadRolePolicy` reuse: the `guard role != "AXSecureTextField"` / `guard QAXElementReadRolePolicy.isAllowedReadRole(role)` pair at the top of `readElementRoleDescription`
- `kAXRoleDescriptionAttribute` read: `resolveElementRoleDescription(of:)` (`QBridgeAdapters.swift`)
- String-length bound: `maxRoleDescriptionLength` (256, `QBridgeAdapters.swift`) and its enforcement inside `resolveElementRoleDescription(of:)`
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Result construction: `readElementRoleDescription`'s trailing `QAXElementRoleDescriptionMetadata(...)` construction
- Verification: `QVerificationStrategy.elementRoleDescriptionReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal or retries were introduced — confirmed by direct source inspection: `resolveElementRoleDescription(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementRoleDescriptionReadSucceeded(applicationName:role:elementIdentifier:elementTitle:roleDescription:)`. Independently re-validates that `roleDescription` is non-empty and within the same 256-character bound `resolveElementRoleDescription` itself enforces, rather than blindly trusting the dispatch layer's own `success` flag — mirroring `elementValueDescriptionReadSucceeded`'s/`elementAllowedValuesReadSucceeded`'s identical independent-recheck discipline. Unlike `elementValueDescriptionReadSucceeded`'s optional-reference shape, this attribute has no valid-absence or valid-empty case, so a fabricated success claiming an empty or oversized string is still correctly rejected. This re-validation reuses only the already-dispatched result's own output; it never performs a second AX read.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_role_description` (identical to every other Level 0 read capability in this codebase): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementRoleDescriptionReadTests.swift` — 52 focused tests across the required categories: registration (capability count == 76, anti-downgrade/upgrade); arguments (missing applicationName/role, missing match criteria, valid criteria); target resolution (`QAXElementReadRolePolicy` roles accepted unmodified, real `NSButton`/`NSTextField`/`NSCheckBox` fixtures, secure-field rejection, wrong role, wrong/missing/ambiguous application or target, stale-target/TCC-denied structural notes); AX attribute validation (valid string, empty string fails closed, wrong CFType, genuine AXError, `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` both treated as failure — not absence, exact-boundary and one-above-boundary string length); fail-closed structural proof (no fallback from `kAXRoleAttribute`, no fabricated/default description, no truncation); privacy (never reads `kAXValueAttribute`, no arbitrary content/raw-object exposure, no title/value leakage into the returned description); resource (structural one-read/zero-hop bound proof, `QResourceGuard` generic application); security (`QPermissionGate` Level 0 allow, no approval state, disjoint authorization from `ui.click_element`, forbidden-API structural audit, real-fixture no-mutation proof); verification (independent rejection of fabricated empty/oversized "successes", never a second AX read); recovery (uncertain step fails closed to pending, no raw `AXUIElement` persistence, durable snapshot omission proof); full `QPlanExecutor` pipeline integration with a dedicated verification strategy; resource-bound/no-side-effect repeated-invocation test. Plus two real macOS AppKit E2E tests (TCC-guarded, cross-validated against AppKit's own `accessibilityRoleDescription()` accessor rather than a hardcoded literal).

All 9 pre-existing test files that hardcoded the total capability count at 75 were updated to 76 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CB): `QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticScrollPositionReadTests` (itself added in Phase 2CA and now needing its own count bump, per the established pattern), `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticWindowAuxiliaryButtonsReadTests`, `QSemanticTableRowHeaderEnumerationTests`.

---

## Native E2E / TCC Status
Two real macOS AppKit E2E tests, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED`, never a fabricated pass):
1. A real, plain `NSButton`'s `kAXRoleDescriptionAttribute` is read via genuine AX retrieval — **never manually injected** (per this phase's explicit instruction not to force a fake role description). Cross-validated against AppKit's own `accessibilityRoleDescription()` accessor called directly on the same control, rather than asserting a hardcoded, locale/OS-version-dependent literal string.
2. The identical technique applied to a real `NSTextField`, proving this capability is not hardcoded to a single role.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so both E2E tests correctly reported `BLOCKED` rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, keyboard/mouse simulation, coordinate clicking, `URLSession`, `curl`, `http://`/`https://` — **zero matches** anywhere in the new/modified production code. `readElementRoleDescription`/`resolveElementRoleDescription` call only `AXUIElementCopyAttributeValue` (read-only) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_role_description` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXRoleDescriptionAttribute` — confirmed via direct source inspection, `resolveElementRoleDescription(of:)` makes exactly one `AXUIElementCopyAttributeValue` call, targeting `kAXRoleDescriptionAttribute` only. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementRoleDescriptionMetadata`'s boundary. Returned data is the bounded `roleDescription` string plus non-sensitive targeting identity only.

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
- Full regression runs in this environment have historically shown intermittent, pre-existing single-test flakiness in unrelated live-`NSWindow`/AX-fixture capabilities (documented in Phase 2CA's own doc) — this phase's regression runs are recorded in the Phase 2CB implementation final report, with any such flakes classified the same way: reproduced in isolation before being ruled environmental.
