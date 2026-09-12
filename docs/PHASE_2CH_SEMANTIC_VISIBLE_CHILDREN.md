# Phase 2CH — Semantic Visible Children List (`ui.list_visible_children`)

## Overview
- **Capability Identifier**: `ui.list_visible_children`
- **Capability Number**: #82
- **Tool Family**: `ui` (returned `visibleChildren` are bounded identity-only references — role/title/identifier — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `d60210dbef91ab14783010363e76332615c5b554` (Phase 2CG, `ui.read_element_edited_state`)
- **Pre-Phase Capability Count**: `81`
- **Post-Phase Capability Count**: `82`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent see what content is actually rendered/visible inside a scrollable container without either reading raw coordinates (forbidden) or recursively walking the full, potentially very large children tree itself. Complements `ui.read_scroll_position` (Phase 2W/2CA — "where is the scroll thumb") with "what content is that scroll position currently showing". `kAXVisibleChildrenAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the remaining unused, non-parameterized `kAX*Attribute` constants (152 total; 67 already in use as of Phase 2CG):
- **`kAXVisibleChildrenAttribute`** — selected (see below).
- `kAXSelectedChildrenAttribute` — a real, declared accessor (`accessibilitySelectedChildren`) exists and is a plausible generic complement to the already-used `kAXSelectedRowsAttribute`, but was judged lower-value than visible-children: selection state is already partially covered (`kAXSelectedRowsAttribute`), whereas "what's on screen right now" has zero existing coverage and pairs directly with the existing scroll-position capability.
- `kAXLinkedUIElementsAttribute`/`kAXLabelUIElementsAttribute`/`kAXSharedFocusElementsAttribute` — all have real declared accessors, but their semantics are vaguer/more app-specific (no standard AppKit control reliably populates them in a way a deterministic test fixture can force), and `kAXLabelUIElementsAttribute` overlaps significantly with the already-fully-covered title/served-elements pair (`kAXTitleUIElementAttribute`, Phase 2BN; `kAXServesAsTitleForUIElementsAttribute`, Phase 2BX).
- `kAXAlternateUIVisibleAttribute`/`kAXOrderedByRowAttribute`/`kAXIsApplicationRunningAttribute`/`kAXElementBusyAttribute` — already rejected in Phase 2CG's own discovery pass (narrow applicability, no declared accessor, or redundant with existing app-resolution machinery); re-confirmed still true this phase.
- `kAXURLAttribute`/`kAXFilenameAttribute`/`kAXValueWrapsAttribute` — already rejected in earlier phases (PII risk / narrow applicability); re-confirmed still true this phase.
- Parameterized attributes (`*ForRange`/`*ForIndex`/`*ForPosition`) — out of scope; they require `AXUIElementCopyParameterizedAttributeValue`, a fundamentally different call shape than every existing read capability in this codebase.

`kAXVisibleChildrenAttribute` is the clear highest-value pick: a real, declared AppKit accessor (`accessibilityVisibleChildren`) exists (enabling genuine cross-validation), it directly complements an existing capability (`ui.read_scroll_position`) rather than duplicating one, it is naturally bounded (a viewport can only show so much at once), and it required no new role policy — `QAXScrollAreaRolePolicy` (Phase 2W) already exists and is the architecturally correct target.

---

## SDK Evidence
`kAXVisibleChildrenAttribute` (`AXAttributeConstants.h`): `#define kAXVisibleChildrenAttribute CFSTR("AXVisibleChildren")` — a plain HIServices macro. AppKit's own declared accessor: `accessibilityVisibleChildren` (nullable, copy `NSArray`) (`NSAccessibilityProtocols.h`, `API_AVAILABLE(macos(10.10))`, doc: "Array of child UIElement which are visible"). Like every other attribute in this general per-element property cluster, the HIServices header carries no dedicated per-attribute doc-comment beyond the one-line AppKit accessor comment — absence semantics rely on the general SDK convention plus AppKit's own accessor documentation.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXScrollAreaRolePolicy`'s existing allowlist (`AXScrollArea`) — reused completely unmodified from `ui.read_scroll_position`/`ui.set_scroll_position` (Phase 2W/2CA). "Visible children" is fundamentally a viewport-relative concept, and `AXScrollArea` is the one role in this codebase's existing policy set with a genuinely well-defined, bounded visible viewport.

**Deliberate departure from `ui.list_label_served_elements`'s (Phase 2BX) discipline**: each visible child's own role is checked against ONLY the single privacy-sensitive exclusion — `AXSecureTextField` — never the narrower `QAXElementReadRolePolicy` allowlist. A served element stands in for a label's own text content and so is held to the same allowlist the label itself must satisfy; a scroll area's visible children are legitimately varied (table rows, outline rows, cells, groups, nested tables/outlines, arbitrary content) and restricting them to `QAXElementReadRolePolicy`'s narrow leaf-control allowlist would make this capability nearly useless for its actual purpose. The one non-negotiable exclusion — never surfacing a secure field, even as identity-only metadata — is preserved via the same, already-established `QAXInteractionError.secureFieldReadDenied` diagnostic every other capability's secure-field check already uses.

---

## Fail-Closed Semantics — Optional-Reference, Atomic-Array Pattern (Identical to `ui.list_label_served_elements`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (anything but `AXScrollArea`) | Fails closed — `disallowedScrollAreaRole` / `AX_DISALLOWED_SCROLL_AREA_ROLE` (reused, unmodified, from Phase 2W) |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — whole result `nil`, never an error, never downgraded to an empty array |
| Any other non-`.success` `AXError` | Fails closed — `AX_VISIBLE_CHILDREN_READ_FAILED` |
| Returned value not a genuine `CFArray` | Fails closed — `AX_VISIBLE_CHILDREN_MALFORMED` |
| Array exceeds `maxVisibleChildrenCount` (32) | Fails closed — `AX_VISIBLE_CHILDREN_EXCEEDS_SAFE_BOUND` (checked before any per-element extraction) |
| Any array entry not `AXUIElement`-compatible | Fails closed (whole array) — `AX_VISIBLE_CHILDREN_ELEMENT_MALFORMED` |
| Any visible child's role is exactly `AXSecureTextField` | Fails closed (whole array) — reuses `AX_SECURE_FIELD_READ_DENIED` |
| Any visible child's title/identifier exceeds `maxVisibleChildMetadataLength` (256) | Fails closed (whole array) — `AX_VISIBLE_CHILDREN_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH` |

Four new `QAXInteractionError` cases were added (`visibleChildrenReadFailed`, `visibleChildrenMalformed`, `visibleChildrenExceedsSafeBound`, `visibleChildrenElementMalformed`, `visibleChildrenElementMetadataExceedsSafeLength` — five, not four; see Security Audit below) — the atomic-array discipline mirrors `ui.list_label_served_elements`'s (Phase 2BX) exactly. The per-child secure-field check deliberately reuses the pre-existing `secureFieldReadDenied` diagnostic rather than inventing a redundant new case.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.list_label_served_elements`'s own resolution: role-policy check (`QAXScrollAreaRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXScrollArea` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXVisibleChildrenAttribute` read against the re-verified element → per-entry bounded identity extraction (role/title/identifier only).

---

## Result Contract
`QAXVisibleChildrenMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXLabelServedElementsMetadata`'s (Phase 2BX) shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved scroll area's own search role (`AXScrollArea`). |
| `elementIdentifier` | `String?` | The resolved scroll area's own identifier, if any. |
| `elementTitle` | `String?` | The resolved scroll area's own title/description, if any. |
| `visibleChildren` | `[QAXVisibleChildReference]` | Bounded array (≤32) of `{role, title, identifier}` — never `AXValue`, never a raw `AXUIElement`. May legitimately be empty (present, nothing currently visible) — distinct from the whole result being `nil` (attribute genuinely absent). |

---

## Privacy Boundary
Only `applicationName`, `role`, `elementIdentifier`, `elementTitle`, and each visible child's bounded `{role, title, identifier}` cross the bridge. No field/document content, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability, on either the scroll area or any visible child.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0` beyond the bounded visible-child identity reads (never a second hop, never a descent into a visible child's own children)
- `maxPrimaryAXReads = 1` (`kAXVisibleChildrenAttribute` only)
- `maxVisibleChildrenCount = 32`
- `maxVisibleChildMetadataLength = 256` (per visible child's title/identifier)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1` (the whole metadata object; the bounded array inside it is not itself a separate "record")

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.listVisibleChildren` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXVisibleChildrenAttribute` read + atomic array decode: `resolveVisibleChildren(of:)` (`QBridgeAdapters.swift`), mirroring `resolveServedElements`'s exact atomic-array discipline
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.visibleChildrenListSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveVisibleChildren(of:)` makes exactly one `AXUIElementCopyAttributeValue` call for the array itself, then only bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads per already-enumerated entry, never a loop over an unbounded or re-fetched collection.

---

## Verification
New `QVerificationStrategy` case: `.visibleChildrenListSucceeded(applicationName:role:hasVisibleChildren:visibleChildrenCount:)`. Mirrors `labelServedElementsReadSucceeded`'s (Phase 2BX) exact discipline: checks `result.success` as a genuine, meaningful assertion, then independently re-validates `visibleChildrenCount >= 0` — a fabricated success claiming a negative count is rejected even though `result.success == true` (proven directly in the test suite, test 39). Evidence is deliberately conservative — application identity, role, presence, and a bounded COUNT only, never any individual visible child's own title/identifier. This performs NO additional AX read — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.list_visible_children` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticVisibleChildrenListTests.swift` — 44 focused tests, mirroring `ui.list_label_served_elements`'s test structure adapted for the `AXScrollArea` target and the deliberately-permissive per-child role check (registration, permission gate/denial, target validation via `QAXScrollAreaRolePolicy`, missing/wrong-application/missing/ambiguous target, stale-target structural note, exactly-one-read structural note, model-level valid/empty-array states, genuine-absence-never-fabricated-as-empty-array, malformed/oversized/genuine-AXError diagnostics, the deliberate design-difference proof that an unreadable-role child is ACCEPTED (unlike served elements) while a secure-field child is atomically rejected, mixed-array atomicity, resource bounds, privacy — durable-evidence and audit-record sentinel-content-free proofs, recovery, security disjoint-authorization proof, verification success/absence/failure/fabrication-rejection evidence, `QPlanExecutor` pipeline integration, forbidden-API structural proof, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `NSScrollView`/`NSButton` fixture, cross-validated against the identical control's own direct `accessibilityVisibleChildren()` accessor call.

All 15 pre-existing test files that hardcoded the total capability count at 81 were updated to 82 (same strict equality assertion, no weakening). The five most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`, `QSemanticElementEditedStateReadTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSScrollView` with real `NSButton` children placed inside its document view (scrolled to the top so they fall within the initial visible viewport) is resolved via `kAXVisibleChildrenAttribute` through the actual AX path — **cross-validated** against the identical control's own direct `accessibilityVisibleChildren()` accessor call (the same generic AppKit accessor category `isAccessibilityExpanded()`/`isAccessibilityEdited()` were called through in Phase 2CE/2CG), never a mock. Neither the scroll view nor any button's own state is ever mutated.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `listVisibleChildren`/`resolveVisibleChildren` call only `AXUIElementCopyAttributeValue` (read-only) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.list_visible_children` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability. Five new `QAXInteractionError` cases were added (`visibleChildrenReadFailed`, `visibleChildrenMalformed`, `visibleChildrenExceedsSafeBound`, `visibleChildrenElementMalformed`, `visibleChildrenElementMetadataExceedsSafeLength`); the per-child secure-field exclusion reuses the pre-existing `secureFieldReadDenied` case rather than introducing a sixth.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXVisibleChildrenAttribute` on the scroll area, plus bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads on each already-enumerated visible child — confirmed via direct source inspection. `kAXValueAttribute` is never read, on either the scroll area or any visible child. No raw `AXUIElement`/CF object crosses `QAXVisibleChildrenMetadata`'s boundary. Returned data is the bounded `visibleChildren` array plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CH defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF/2CG.
