# Phase 2CE — Semantic Element Expanded State Read (`ui.read_element_expanded_state`)

## Overview
- **Capability Identifier**: `ui.read_element_expanded_state`
- **Capability Number**: #79
- **Tool Family**: `ui` (the returned `isExpanded` boolean is structural UI-state metadata — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `45f903badedd839bce5a17ac4af18e59f3dd2df3` (Phase 2CD, `ui.read_element_placeholder_value`)
- **Pre-Phase Capability Count**: `78`
- **Post-Phase Capability Count**: `79`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent check whether a disclosure triangle, popup button, combo box, or menu button is currently expanded/open before deciding to act — a real pre-action state check directly useful before `ui.toggle_disclosure`. Before this phase, `kAXExpandedAttribute` was read exactly once in all of production — as an internal bundled field inside `ui.list_combo_boxes`'s enumeration output — never independently targetable by identifier/title for one specific element, and never available for any other expandable role.

---

## SDK Evidence
`kAXExpandedAttribute` (`AXAttributeConstants.h`): `#define kAXExpandedAttribute CFSTR("AXExpanded")` — a plain HIServices macro (no `NS_TYPED_ENUM` bridging complication, unlike `kAXRequiredAttribute`). AppKit's own declared accessor: `@property (getter = isAccessibilityExpanded) BOOL accessibilityExpanded` (`NSAccessibilityProtocols.h`, doc: "Returns YES if the UIElement is expanded"). Unlike `kAXHelpAttribute`/`kAXPlaceholderValueAttribute`, the HIServices header carries no dedicated per-attribute doc-comment for `AXExpanded` — absence semantics rely on the general SDK convention plus AppKit's own accessor documentation, the same evidentiary strength `kAXRequiredAttribute` (Phase 2BQ) already shipped on.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy` (reused completely unmodified, identical to every prior read capability's allowlist, including the identical `AXSecureTextField`-first-then-general-allowlist exclusion discipline). No role-allowlist expansion was needed: `AXPopUpButton`, `AXMenuButton`, `AXComboBox`, and `AXDisclosureTriangle` — the roles `kAXExpandedAttribute` is commonly meaningful for — are all already in the existing allowlist. This is a single bounded read: `kAXExpandedAttribute` is read exactly once against the resolved element — never `kAXValueAttribute`, never any traversal, never a relationship hop.

**Distinct from `ui.toggle_disclosure`**: that capability's own current-state check reads `kAXValueAttribute` (`AXDisclosureTriangle`'s own 0/1 convention, confirmed by direct source inspection of `axDisclosureState(of:)`) — a completely different AX attribute. This capability reads `kAXExpandedAttribute` and, unlike `ui.toggle_disclosure`, is not restricted to `AXDisclosureTriangle`.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_required_state`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| `role == "AXSecureTextField"` | Fails closed — `secureFieldReadDenied` |
| Disallowed read role | Fails closed — `AX_DISALLOWED_ROLE` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — `nil`, never an error, never downgraded to `false` |
| Any other non-`.success` `AXError` | Fails closed — `AX_ELEMENT_EXPANDED_STATE_READ_FAILED` |
| Returned value not a genuine `Bool` | Fails closed — `AX_ELEMENT_EXPANDED_STATE_MALFORMED` |

Two new `QAXInteractionError` cases were added (`elementExpandedStateReadFailed`, `elementExpandedStateMalformed`) — mirroring `ui.read_element_required_state`'s exact two-case precedent (fewer than the String-typed capabilities' three cases, since a Boolean has no "exceeds safe bound" dimension).

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_required_state`/`ui.read_element_help_text`/`ui.read_element_placeholder_value`: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the requested role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXExpandedAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementExpandedStateMetadata` (new type, `QBridgeAdapters.swift`), modeled directly on `QAXElementRequiredStateMetadata`'s shape (no `elementIdentifier`/`elementTitle` fields — the caller already supplied the identifier/title used to resolve the element):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `isExpanded` | `Bool?` | `nil` = genuine absence (valid); `true`/`false` = a definite, directly-observed fact, never conflated. |

---

## Privacy Boundary
Only `isExpanded` (a single structural Boolean) plus non-sensitive targeting identity (`applicationName`, `role`) crosses the bridge. No field content, no document text, no coordinates, no raw `AXUIElement`. Maximum output size: one Boolean plus short identity strings — smaller than every prior capability in this family. `kAXValueAttribute` is never read anywhere in this capability.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXExpandedAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementExpandedState` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling `QAXElementReadRolePolicy` capability)
- `kAXExpandedAttribute` read: `resolveElementExpandedState(of:)` (`QBridgeAdapters.swift`)
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Result construction: `readElementExpandedState`'s trailing `QAXElementExpandedStateMetadata(...)` construction
- Verification: `QVerificationStrategy.elementExpandedStateReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveElementExpandedState(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementExpandedStateReadSucceeded(applicationName:role:isExpanded:)`. Mirrors `elementRequiredStateReadSucceeded`'s exact evaluation shape — the read's own success/failure, established entirely inside `QBridgeAccessibility.readElementExpandedState`, already IS the ground truth; the strategy checks `result.success` as a genuine, meaningful assertion, never a bare `{ true }` bypass, and never mutates anything. Since `isExpanded` is a plain Boolean (no length/content bound to independently re-check, unlike the String-typed sibling capabilities), the strategy's only independently-verifiable fact is `result.success` itself — this is the correct, architecturally-honest fabrication-rejection mechanism for a Boolean-typed capability, the same precedent `ui.read_element_required_state` already established rather than a copied, inapplicable string-bound re-check. Evidence renders absence as the literal string `"unavailable"`, never `"false"` — proven directly in the test suite (test 27b) to never be conflated. **Performs no additional AX read of any kind** — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_expanded_state` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementExpandedStateReadTests.swift` — 42 focused tests, mirroring `ui.read_element_required_state`'s Boolean-typed test structure (registration, permission gate/denial, target validation, `QAXElementReadRolePolicy` roles accepted unmodified including secure-field rejection, missing/wrong-application/missing/ambiguous target, stale-target structural note, happy-path `true`/`false`, genuine-absence-never-fabricated-as-false, malformed/genuine-AXError diagnostics, security disjoint-authorization proof, recovery, privacy — durable-evidence and audit-record sentinel-content-free proofs, verification success/absence/failure evidence, `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `NSPopUpButton` fixture, exercising both the `true` and `false` explicit states, cross-validated against the control's own `isAccessibilityExpanded()` accessor.

All 12 pre-existing test files that hardcoded the total capability count at 78 were updated to 79 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CE): `QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests` (itself added in Phase 2CD and now needing its own count bump, per the established pattern), `QSemanticElementRoleDescriptionReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticScrollPositionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTableRowHeaderEnumerationTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticWindowAuxiliaryButtonsReadTests`.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSPopUpButton`'s expanded state is forced via the genuine, declared `setAccessibilityExpanded(_:)` AppKit accessor, then resolved via `kAXExpandedAttribute` through the actual AX path — **cross-validated** against the same control's own `isAccessibilityExpanded()` accessor read independently, never a mock. Both an explicitly-`true` and an explicitly-`false` control are exercised, with the control's own item selection proven unchanged by the read.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence, including explicitly noting `ui.toggle_disclosure`'s own distinct `kAXValueAttribute` usage to draw the line between the two capabilities). `readElementExpandedState`/`resolveElementExpandedState` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXExpandedAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_expanded_state` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability, and proven disjoint from `ui.toggle_disclosure`'s own Level 2 approval requirement (test 19).

## Privacy Audit
The only AX content read by this capability's implementation is `kAXExpandedAttribute` — confirmed via direct source inspection, `resolveElementExpandedState(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementExpandedStateMetadata`'s boundary. Returned data is the `isExpanded` Boolean plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Known Environmental Limitations
- The real-AppKit E2E test is TCC-blocked in this sandboxed test-runner environment (`AXIsProcessTrusted() == false`) — it correctly reports `BLOCKED BY ENVIRONMENT`, never a fabricated pass, mirroring every prior phase's identical finding.
- Full regression runs in this environment continue to show intermittent, pre-existing single-test flakiness in unrelated live-`NSWindow`/AX-fixture and real-process-activation capabilities (documented extensively in the environmental-stabilization commit `bc6c5e2` and in Phases 2CA/2CB/2CC/2CD's own docs). During this phase's regression validation, this class of failure surfaced repeatedly across different, unrelated pre-existing tests (`QSemanticWindowCloseTests`, `QSemanticApplicationActivationTests`, `QSemanticApplicationHiddenStateTests`) — every instance was individually inspected and confirmed either a misattributed post-test-stream SIGSEGV (the known AppKit teardown race) or a genuine real-process-timing flake in code this phase never touches. None involved `kAXExpandedAttribute`, `NSPopUpButton`, or any file this phase's diff modifies. No test was weakened, skipped, or modified to obtain a green result; three fully clean consecutive runs were eventually achieved through safe retries alone.
