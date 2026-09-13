# Phase 2CL — Semantic Linked Elements List (`ui.list_linked_elements`)

## Overview
- **Capability Identifier**: `ui.list_linked_elements`
- **Capability Number**: #86
- **Tool Family**: `ui` (returned linked elements are bounded identity-only references — role/title/identifier — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `59e7cd05dbe6a6a2b5ae8f5570edcf433369377d` (Phase 2CK, `ui.read_table_header`)
- **Pre-Phase Capability Count**: `85`
- **Post-Phase Capability Count**: `86`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability exposes Apple's generic "linked elements" relationship — a freeform annotation an app author can declare between any two elements (e.g. a control and the display it updates, a validation message and the field it describes, a pagination control and its content pane). Distinct from every existing relationship capability: not a title relationship (`ui.read_element_title_reference`/`ui.list_label_served_elements`), not a viewport relationship (`ui.list_visible_children`), not a table-header relationship (`ui.read_table_header`). `kAXLinkedUIElementsAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the remaining unused, non-parameterized `kAX*Attribute` constants (152 total; 71 already in use as of Phase 2CK):
- **`kAXLinkedUIElementsAttribute`** — selected (see below).
- `kAXSelectedChildrenAttribute` — deferred for a **fourth** consecutive phase (previously deferred in Phase 2CH, 2CI, 2CJ, 2CK discovery passes): a real, declared accessor exists (`accessibilitySelectedChildren`), but no existing role policy cleanly fits "generic container with selectable children" the way `AXScrollArea`/`AXTable` cleanly fit their own capabilities — inventing an ad-hoc role scoping decision was judged worse than choosing a candidate with a genuinely clean architectural fit. `kAXLinkedUIElementsAttribute`, by contrast, is a general per-element property requiring no new role policy at all — resolving the ambiguity by picking the cleaner candidate rather than forcing a decision on the harder one.
- `kAXTopLevelUIElementAttribute`/`kAXFocusedApplicationAttribute`/`kAXContentsAttribute`/`kAXDocumentAttribute` — already rejected in Phase 2CI's discovery pass; re-confirmed still true this phase.
- `kAXInsertionPointLineNumberAttribute`/`kAXHeaderAttribute` — already implemented this session (Phase 2CJ/2CK).
- Earlier-rejected attributes (`kAXAlternateUIVisibleAttribute`, `kAXOrderedByRowAttribute`, `kAXIsApplicationRunningAttribute`, `kAXElementBusyAttribute`, `kAXURLAttribute`, `kAXFilenameAttribute`, `kAXValueWrapsAttribute`, `kAXLabelUIElementsAttribute` — the latter overlapping the already-fully-covered title/served-elements pair) — re-confirmed still rejected.

`kAXLinkedUIElementsAttribute` is the clear pick this phase: a real, declared AppKit accessor (`accessibilityLinkedUIElements`) sits in the **general** per-element property category of `NSAccessibilityProtocols.h` (not gated behind any specialized role or protocol), so the SOURCE element reuses `QAXElementReadRolePolicy` (Phase 2J) — the same broad, already-established allowlist `ui.read_element_title_reference`/`ui.list_label_served_elements` already share — with **zero new role-policy surface**, and it mirrors the already-proven atomic bounded-array pattern (`ui.list_visible_children`, Phase 2CH) exactly.

---

## SDK Evidence
`kAXLinkedUIElementsAttribute` (`AXAttributeConstants.h`): `#define kAXLinkedUIElementsAttribute CFSTR("AXLinkedUIElements")` — a plain HIServices macro. AppKit's own declared accessor: `@property (nullable, copy) NSArray *accessibilityLinkedUIElements` (`NSAccessibilityProtocols.h`, doc comment: "Corresponding UIElements"), a plain, general property, applicable to any element.

**Design decision on each linked element's own role check**: mirroring `ui.list_visible_children`'s (Phase 2CH) and `ui.read_table_header`'s (Phase 2CK) identical, deliberate design difference from `ui.list_label_served_elements` (Phase 2BX): each linked element's role is checked against ONLY the single privacy-sensitive exclusion (`AXSecureTextField`) — never the narrower `QAXElementReadRolePolicy` leaf-control allowlist. A "linked" relationship is Apple's generic, freeform annotation mechanism (a control linked to the display it updates, a pagination control linked to its content pane, etc.) — not restricted to leaf/label semantics the way a title/served-element relationship is — so holding it to that narrower allowlist would incorrectly reject many genuine, safe linked-element relationships.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy`'s existing allowlist (`AXTextField`, `AXTextArea`, `AXStaticText`, `AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXMenuItem`, `AXComboBox`, `AXSlider`, `AXStepper`, `AXLink`, `AXTab`, `AXDisclosureTriangle`) — reused completely unmodified, identical to `ui.read_element_title_reference`/`ui.list_label_served_elements`. `AXSecureTextField` is rejected first, before the general allowlist is even consulted — the same belt-and-suspenders discipline every prior read capability in this family already applies.

---

## Fail-Closed Semantics — Optional-Reference, Atomic-Array Pattern (Identical to `ui.list_visible_children`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed source role | Fails closed — `disallowedReadRole` / `AX_DISALLOWED_READ_ROLE` |
| `AXSecureTextField` source role | Fails closed — `secureFieldReadDenied` / `AX_SECURE_FIELD_READ_DENIED` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — whole result `nil`, never an error, never downgraded to an empty array |
| Any other non-`.success` `AXError` | Fails closed — `AX_LINKED_ELEMENTS_READ_FAILED` |
| Returned value not a genuine `CFArray` | Fails closed — `AX_LINKED_ELEMENTS_MALFORMED` |
| Array exceeds `maxLinkedElementsCount` (32) | Fails closed — `AX_LINKED_ELEMENTS_EXCEEDS_SAFE_BOUND` (checked before any per-element extraction) |
| Any array entry not `AXUIElement`-compatible | Fails closed (whole array) — `AX_LINKED_ELEMENTS_ELEMENT_MALFORMED` |
| Any linked element's role is exactly `AXSecureTextField` | Fails closed (whole array) — reuses `AX_SECURE_FIELD_READ_DENIED` |
| Any linked element's title/identifier exceeds `maxLinkedElementMetadataLength` (256) | Fails closed (whole array) — `AX_LINKED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH` |

Five new `QAXInteractionError` cases were added (`linkedElementsReadFailed`, `linkedElementsMalformed`, `linkedElementsExceedsSafeBound`, `linkedElementsElementMalformed`, `linkedElementsElementMetadataExceedsSafeLength`) — the atomic-array discipline mirrors `ui.list_visible_children`'s (Phase 2CH) exactly. The per-element secure-field check deliberately reuses the pre-existing `secureFieldReadDenied` diagnostic rather than introducing a sixth case.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.list_visible_children`'s own resolution: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the target role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXLinkedUIElementsAttribute` read against the re-verified element → per-entry bounded identity extraction (role/title/identifier only).

---

## Result Contract
`QAXLinkedElementsMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXVisibleChildrenMetadata`'s (Phase 2CH) shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved source element's own search role. |
| `elementIdentifier` | `String?` | The resolved source element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved source element's own title/description, if any. |
| `linkedElements` | `[QAXLinkedElementReference]` | Bounded array (≤32) of `{role, title, identifier}` — never `AXValue`, never a raw `AXUIElement`. May legitimately be empty (present, linked to nothing) — distinct from the whole result being `nil` (attribute genuinely absent). |

---

## Privacy Boundary
Only `applicationName`, `role`, `elementIdentifier`, `elementTitle`, and each linked element's bounded `{role, title, identifier}` cross the bridge. No field/document content, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability, on either the source element or any linked element.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0` beyond the bounded linked-element identity reads (never a second hop, never a descent into a linked element's own children)
- `maxPrimaryAXReads = 1` (`kAXLinkedUIElementsAttribute` only)
- `maxLinkedElementsCount = 32`
- `maxLinkedElementMetadataLength = 256` (per linked element's title/identifier)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1` (the whole metadata object; the bounded array inside it is not itself a separate "record")

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.listLinkedElements` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXLinkedUIElementsAttribute` read + atomic array decode: `resolveLinkedElements(of:)` (`QBridgeAdapters.swift`), mirroring `resolveVisibleChildren`'s exact atomic-array discipline
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.linkedElementsListSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveLinkedElements(of:)` makes exactly one `AXUIElementCopyAttributeValue` call for the array itself, then only bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads per already-enumerated entry, never a loop over an unbounded or re-fetched collection.

---

## Verification
New `QVerificationStrategy` case: `.linkedElementsListSucceeded(applicationName:role:hasLinkedElements:linkedElementsCount:)`. Mirrors `visibleChildrenListSucceeded`'s (Phase 2CH) exact discipline: checks `result.success` as a genuine, meaningful assertion, then independently re-validates `linkedElementsCount >= 0` — a fabricated success claiming a negative count is rejected even though `result.success == true` (proven directly in the test suite, test 41). Evidence is deliberately conservative — application identity, role, presence, and a bounded COUNT only, never any individual linked element's own title/identifier. This performs NO additional AX read — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.list_linked_elements` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticLinkedElementsListTests.swift` — 46 focused tests, combining `ui.list_label_served_elements`' source-role-gating test structure with `ui.list_visible_children`'s atomic-array/design-difference test structure (registration, permission gate/denial, source-role validation via `QAXElementReadRolePolicy` including secure-field rejection, missing/wrong-application/missing/ambiguous target, stale-target structural note, exactly-one-read structural note, model-level valid/empty-array states, genuine-absence-never-fabricated-as-empty-array, malformed/oversized/genuine-AXError diagnostics, the deliberate design-difference proof that a non-leaf-control linked-element role is ACCEPTED (unlike served elements) while a secure-field linked element is atomically rejected, mixed-array atomicity, resource bounds, privacy — durable-evidence and audit-record sentinel-content-free proofs, recovery, security disjoint-authorization proof, verification success/absence/failure/fabrication-rejection evidence, `QPlanExecutor` pipeline integration, forbidden-API structural proof, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `NSButton`/`NSTextField` fixture wired via the genuine `setAccessibilityLinkedUIElements(_:)` accessor, cross-validated against the identical control's own `accessibilityLinkedUIElements()` accessor call.

All 15 pre-existing test files that hardcoded the total capability count at 85 were updated to 86 (same strict equality assertion, no weakening). The nine most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`, `QSemanticElementEditedStateReadTests`, `QSemanticVisibleChildrenListTests`, `QSemanticElementIndexReadTests`, `QSemanticElementInsertionPointLineReadTests`, `QSemanticTableHeaderReadTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSButton` linked to real `NSTextField`s via the genuine, declared `setAccessibilityLinkedUIElements(_:)` accessor is resolved via `kAXLinkedUIElementsAttribute` through the actual AX path — **cross-validated** against the same control's own `accessibilityLinkedUIElements()` accessor call, never a mock. An unlinked source is separately exercised for genuine absence.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `listLinkedElements`/`resolveLinkedElements` call only `AXUIElementCopyAttributeValue` (read-only) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.list_linked_elements` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXLinkedUIElementsAttribute` on the source element, plus bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads on each already-enumerated linked element — confirmed via direct source inspection. `kAXValueAttribute` is never read, on either the source element or any linked element. No raw `AXUIElement`/CF object crosses the boundary. Returned data is the bounded `linkedElements` array plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CL defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF/2CG/2CH/2CI/2CJ/2CK.
