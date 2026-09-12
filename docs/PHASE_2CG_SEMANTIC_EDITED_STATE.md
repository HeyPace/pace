# Phase 2CG — Semantic Element Edited State Read (`ui.read_element_edited_state`)

## Overview
- **Capability Identifier**: `ui.read_element_edited_state`
- **Capability Number**: #81
- **Tool Family**: `ui` (the returned `isEdited` Boolean is structural UI-state metadata — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `be82c744d0ba321713e7ab567821878c3bb0873a` (Phase 2CF, `ui.read_element_disclosure_level`)
- **Pre-Phase Capability Count**: `80`
- **Post-Phase Capability Count**: `81`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent check whether a document, text field, or other editable element currently has unsaved changes ("is dirty") before deciding whether to warn the user, save, or discard when closing a window or moving on to another task. Complements the existing observational-read family (`ui.read_element_expanded_state`, `ui.read_element_required_state`, `ui.read_element_disclosure_level`) with the same optional-Boolean discipline. `kAXEditedAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the full unused-attribute sweep of `AXAttributeConstants.h` (152 total `kAX*Attribute` constants; 66 already in use as of Phase 2CF), restricted to non-parameterized attributes only (parameterized attributes — `*ForRange`/`*ForIndex`/`*ForPosition` — require a fundamentally different `AXUIElementCopyParameterizedAttributeValue` call shape and were out of scope for this phase):
- **`kAXEditedAttribute`** — selected (see below).
- `kAXAlternateUIVisibleAttribute` — a real, declared accessor (`isAccessibilityAlternateUIVisible`) exists, but the underlying semantic (menu-extra/scroll-bar "alternate UI" toggle) is narrow and rarely meaningful to an agent's own decision-making.
- `kAXOrderedByRowAttribute` — a real, declared accessor (`isAccessibilityOrderedByRow`) exists, but is scoped to `AXGrid`-role elements only — narrower applicability than `kAXEditedAttribute`'s general per-element relevance.
- `kAXIsApplicationRunningAttribute` — no declared AppKit accessor found in `NSAccessibilityProtocols.h`; redundant with the existing `resolveExactRunningApplication`/`NSRunningApplication` application-resolution machinery every capability already relies on.
- `kAXElementBusyAttribute` — already rejected in Phase 2CF's own discovery pass (no declared AppKit accessor found, weaker native-E2E feasibility); re-confirmed still true this phase.
- `kAXURLAttribute`/`kAXFilenameAttribute` — already rejected in Phase 2CF's own discovery pass (session-token/PII exposure risk); re-confirmed still true this phase.
- `kAXSelectedChildrenAttribute`/`kAXSelectedCellsAttribute`/`kAXSelectedColumnsAttribute`/`kAXVisibleRowsAttribute`/`kAXVisibleColumnsAttribute`/`kAXVisibleCellsAttribute`/`kAXVisibleChildrenAttribute`/`kAXHandlesAttribute` — all return **collections of element references**, not a scalar value; a correct, minimal-footprint design for any of these needs its own bounded-array-of-element-identity contract (mirroring `ui.list_label_served_elements`'s own atomic-array discipline) — a larger design surface than this phase's "one clear, safe, highest-value capability" mandate, and deferred rather than rushed.
- `kAXDisclosedByRowAttribute`/`kAXDisclosedRowsAttribute` — return **element references** (not scalars) tied to the outline/disclosure relationship family already partially covered by `ui.read_element_disclosure_level`/`ui.read_element_expanded_state`; a reference-returning capability needs the same relationship-query design as `ui.list_label_served_elements`, deferred for the same reason as above.

`kAXEditedAttribute` is the clear highest-value pick among the remaining scalar, non-parameterized, non-reference candidates: broadly applicable (any document/text-editing-style element, not restricted to one role), genuinely useful for agent decision-making, has a real declared AppKit accessor for native-E2E feasibility, and carries zero privacy risk (a structural dirty-flag, not content).

---

## SDK Evidence
`kAXEditedAttribute` (`AXAttributeConstants.h`): `#define kAXEditedAttribute CFSTR("AXEdited")` — a plain HIServices macro. AppKit's own declared accessor pair: `setAccessibilityEdited(_:)`/`isAccessibilityEdited()` (getter) (`NSAccessibilityProtocols.h`, `API_AVAILABLE(macos(10.10))`, doc: "Returns YES if the UIElement has been edited"). This property sits in the **same generic per-element property cluster** as `accessibilityExpanded`/`accessibilityEnabled`/`accessibilityIdentifier` in the header — i.e. it is a general property available to any AX-conforming element via AppKit's blanket `NSAccessibilityElement` conformance, not restricted to one specialized role, unlike `kAXDisclosureLevelAttribute`'s outline-row-specific scoping. Like `kAXExpandedAttribute`, the HIServices header carries no dedicated per-attribute doc-comment beyond the one-line AppKit accessor comment — absence semantics rely on the general SDK convention plus AppKit's own accessor documentation.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy`'s existing allowlist (`AXTextField`, `AXTextArea`, `AXStaticText`, `AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXMenuItem`, `AXComboBox`, `AXSlider`, `AXStepper`, `AXLink`, `AXTab`, `AXDisclosureTriangle`) — reused completely unmodified, identical to `ui.read_element_expanded_state`/`ui.read_element_help_text`/`ui.read_element_placeholder_value`/`ui.read_element_role_description`. `AXSecureTextField` is rejected first, before the general allowlist is even consulted — the same belt-and-suspenders discipline every prior read capability in this family already applies.

This is a deliberate departure from `ui.read_element_disclosure_level`'s choice of the dedicated `QAXOutlineRowRolePolicy`: `kAXEditedAttribute` is a general per-element property (per the SDK evidence above), not an outline/row-specific one, so the shared generic allowlist — not a new, parallel role mechanism — is the architecturally correct, minimal-footprint choice.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_expanded_state`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (not on `QAXElementReadRolePolicy`'s allowlist) | Fails closed — `disallowedReadRole` / `AX_DISALLOWED_READ_ROLE` |
| `AXSecureTextField` role | Fails closed — `secureFieldReadDenied` / `AX_SECURE_FIELD_READ_DENIED` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — `nil`, never an error, never downgraded to `false` |
| Any other non-`.success` `AXError` | Fails closed — `AX_ELEMENT_EDITED_STATE_READ_FAILED` |
| Returned value not a genuine `Bool` | Fails closed — `AX_ELEMENT_EDITED_STATE_MALFORMED` |

Two new `QAXInteractionError` cases were added (`elementEditedStateReadFailed`, `elementEditedStateMalformed`) — identical shape to `elementExpandedStateReadFailed`/`elementExpandedStateMalformed`, since both attributes share the same Boolean-optional-reference contract.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_expanded_state`'s own resolution: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the target role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXEditedAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementEditedStateMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXElementExpandedStateMetadata`'s 3-field shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `isEdited` | `Bool?` | `nil` = genuine absence (valid); a `Bool` = a definite, directly-observed unsaved-changes state, never conflated with `nil`. |

---

## Privacy Boundary
Only `isEdited` (a single structural Boolean) plus non-sensitive targeting identity (`applicationName`, `role`) crosses the bridge. No field content, no document text, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXEditedAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementEditedState` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXEditedAttribute` read + `Bool` decode: `resolveElementEditedState(of:)` (`QBridgeAdapters.swift`), mirroring `resolveElementExpandedState`'s exact absence-vs-failure branching and non-force-cast discipline
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.elementEditedStateReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveElementEditedState(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementEditedStateReadSucceeded(applicationName:role:isEdited:)`. Like `elementExpandedStateReadSucceeded`/`elementRequiredStateReadSucceeded` (both Boolean-typed, carrying no independently-checkable invariant beyond the type itself), this strategy checks the execution result's own `success` flag as a genuine, meaningful assertion — never a bare `{ true }` bypass — and never performs an additional AX read. This is confirmed directly by source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_edited_state` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementEditedStateReadTests.swift` — 34 focused tests, mirroring `ui.read_element_expanded_state`'s test structure adapted for the generic `QAXElementReadRolePolicy` target and the "edited" semantic (registration, permission gate/denial, target validation, missing/wrong-application/missing/ambiguous target, stale-target structural note, happy-path true and false, genuine-absence-never-fabricated-as-false, malformed/genuine-AXError diagnostics, security disjoint-authorization proof, recovery, privacy — durable-evidence and audit-record sentinel-content-free proofs, verification success/absence/failure/fabrication-rejection evidence, `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `AXTextField`-role fixture built on `NSTextField`, exercising both an edited and a not-edited state, cross-validated against the control's own `isAccessibilityEdited()` accessor.

All 15 pre-existing test files that hardcoded the total capability count at 80 were updated to 81 (same strict equality assertion, no weakening). The four most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those four files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSTextField`-backed `AXTextField`-role fixture's edited state is forced via the genuine, declared `setAccessibilityEdited(_:)` AppKit accessor pair, then resolved via `kAXEditedAttribute` through the actual AX path — **cross-validated** against the same control's own `isAccessibilityEdited()` accessor read independently, never a mock. Both an edited (`true`) and a not-edited (`false`) state are exercised.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readElementEditedState`/`resolveElementEditedState` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXEditedAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_edited_state` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXEditedAttribute` — confirmed via direct source inspection, `resolveElementEditedState(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementEditedStateMetadata`'s boundary. Returned data is the bounded `isEdited` Boolean plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CG defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF.
