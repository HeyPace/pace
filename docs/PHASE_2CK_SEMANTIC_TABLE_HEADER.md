# Phase 2CK — Semantic Table Header Reference Read (`ui.read_table_header`)

## Overview
- **Capability Identifier**: `ui.read_table_header`
- **Capability Number**: #85
- **Tool Family**: `ui` (returned header reference is a bounded identity-only descriptor — role/title/identifier — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `4fb8c64107badc370c48f8edfbf839642d45357f` (Phase 2CJ, `ui.read_element_insertion_point_line_number`)
- **Pre-Phase Capability Count**: `84`
- **Post-Phase Capability Count**: `85`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent identify the single, overall element that serves as a table's header row. `ui.list_table_row_headers` (Phase 2BZ) covers the distinct per-row/per-column header relationship; this is the whole-table header reference. `kAXHeaderAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the remaining unused, non-parameterized `kAX*Attribute` constants (152 total; 70 already in use as of Phase 2CJ):
- **`kAXHeaderAttribute`** — selected (see below), previously deferred twice (Phase 2CI, Phase 2CJ discovery passes) in favor of simpler candidates.
- `kAXSelectedChildrenAttribute` — real accessor, but unclear/arbitrary target role scoping (deferred a third time; no clean existing role policy fits "generic container with selectable children" the way `AXScrollArea`/`AXTable` cleanly fit their own capabilities).
- `kAXTopLevelUIElementAttribute`/`kAXFocusedApplicationAttribute`/`kAXContentsAttribute`/`kAXDocumentAttribute` — already rejected in Phase 2CI's discovery pass (overlap with `kAXWindowAttribute`, system-wide resolution shape, overlap with `ui.list_visible_children`, file-path/PII risk respectively); re-confirmed still true this phase.
- `kAXInsertionPointLineNumberAttribute` — already implemented this session (Phase 2CJ).
- Earlier-rejected attributes (`kAXAlternateUIVisibleAttribute`, `kAXOrderedByRowAttribute`, `kAXIsApplicationRunningAttribute`, `kAXElementBusyAttribute`, `kAXURLAttribute`, `kAXFilenameAttribute`, `kAXValueWrapsAttribute`) — re-confirmed still rejected.

`kAXHeaderAttribute` is the clear pick this phase: a real, declared AppKit accessor (`accessibilityHeader`) exists, it directly reuses `QAXTableRolePolicy` (Phase 2AE) — the same dedicated role policy `ui.read_table_dimensions`/`ui.list_table_row_headers` already established — with zero new target-role-policy surface, and it mirrors the already-proven single-reference read shape (`ui.read_element_title_reference`, Phase 2BN) exactly.

---

## SDK Evidence
`kAXHeaderAttribute` (`AXAttributeConstants.h`): `#define kAXHeaderAttribute CFSTR("AXHeader")` — a plain HIServices macro. AppKit's own declared accessor: `@property (nullable, strong) id accessibilityHeader` (`NSAccessibilityProtocols.h`, "Table/Outline" pragma section, doc: "UIElement for header") — a plain, general property (not gated behind any specialized protocol), applicable in principle to both `AXTable` and `AXOutline`.

**Design decision on the referenced header element's own role check**: unlike `ui.read_element_title_reference` (Phase 2BN), which validates its referenced title element against `QAXElementReadRolePolicy`'s leaf-control allowlist, this capability checks the referenced header element against ONLY the single privacy-sensitive exclusion (`AXSecureTextField`) — mirroring `ui.list_visible_children`'s (Phase 2CH) identical, deliberate design difference. A table's header view is a structural/compound element (a genuine `NSTableHeaderView` reports a generic container role, never one of `QAXElementReadRolePolicy`'s leaf-control roles such as `AXStaticText`/`AXButton`), so holding it to that narrower allowlist would make the capability fail closed on the ordinary, default AppKit case — the wrong outcome for a capability whose entire purpose is identifying that structural element. This mirrors the exact reasoning Phase 2CH already established for `ui.list_visible_children`'s visible children.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXTableRolePolicy`'s existing allowlist (`AXTable`) — reused completely unmodified, identical to `ui.read_table_dimensions`/`ui.list_table_row_headers` (Phase 2AE/2BZ). `kAXHeaderAttribute`'s own AppKit doc-comment sits under a shared "Table/Outline" pragma implying it could also apply to `AXOutline`, but scoping this phase to `AXTable` only (mirroring the existing table-level capability family exactly) is the correct, minimal-footprint choice — extending to `AXOutline` is a natural, independently-decidable future capability, not invented here.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_title_reference`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (anything but `AXTable`) | Fails closed — `disallowedTableRole` / `AX_DISALLOWED_TABLE_ROLE` (reused, unmodified, from Phase 2AE) |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — whole result `nil`, never an error |
| Any other non-`.success` `AXError` | Fails closed — `AX_TABLE_HEADER_READ_FAILED` |
| Returned value not a genuine `AXUIElement` | Fails closed — `AX_TABLE_HEADER_MALFORMED` |
| Header reference's role is `AXSecureTextField` | Fails closed — reuses `AX_SECURE_FIELD_READ_DENIED` |
| Header reference's title/identifier exceeds `maxTableHeaderMetadataLength` (256) | Fails closed — `AX_TABLE_HEADER_METADATA_EXCEEDS_SAFE_LENGTH` |

Two new `QAXInteractionError` cases were added (`tableHeaderReadFailed`, `tableHeaderMalformed`, `tableHeaderMetadataExceedsSafeLength` — three, mirroring `titleReferenceReadFailed`/`titleReferenceMalformed`/`titleReferenceMetadataExceedsSafeLength`). No dedicated "disallowed role" case was introduced for the referenced header element — the shared `secureFieldReadDenied` diagnostic is reused instead, since the only role-based exclusion is the single privacy-sensitive one.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_title_reference`'s own resolution: role-policy check (`QAXTableRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXTable` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXHeaderAttribute` read against the re-verified table → bounded identity extraction (role/title/identifier only) on the referenced header element.

---

## Result Contract
`QAXTableHeaderReference` (new type, `QBridgeAdapters.swift`), modeled on `QAXElementTitleReference`'s (Phase 2BN)/`QAXServedElementReference`'s (Phase 2BX)/`QAXVisibleChildReference`'s (Phase 2CH) identical minimal shape:

| Field | Type | Notes |
|---|---|---|
| `role` | `String` | The referenced header element's own AX role. |
| `title` | `String?` | The referenced header element's own title, if any. |
| `identifier` | `String?` | The referenced header element's own identifier, if any. |

The bridge function `readTableHeader` returns `QAXTableHeaderReference?` directly (no outer wrapper struct), mirroring `readElementTitleReference`'s exact return shape — `nil` = genuine absence.

---

## Privacy Boundary
Only the header reference's bounded `{role, title, identifier}` plus non-sensitive targeting identity (`applicationName`, `role` of the source table) cross the bridge. No field/document/cell content, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability, on either the source table or the header reference.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0` beyond the single bounded header-reference identity read
- `maxPrimaryAXReads = 1` (`kAXHeaderAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readTableHeader` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXHeaderAttribute` read + reference validation: `resolveTableHeader(of:)` (`QBridgeAdapters.swift`), mirroring `resolveElementTitleReference`'s exact atomic reference-validation discipline
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.tableHeaderReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveTableHeader(of:)` makes exactly one `AXUIElementCopyAttributeValue` call for the reference itself, then only bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads on the already-resolved reference — never a descent into the referenced element's own children.

---

## Verification
New `QVerificationStrategy` case: `.tableHeaderReadSucceeded(applicationName:role:hasTableHeader:Bool)`. Mirrors `elementTitleReferenceReadSucceeded`'s (Phase 2BN) exact conservative-evidence discipline: checks `result.success` as a genuine, meaningful assertion, carrying only application identity, source role, and a presence boolean — never the referenced header element's own title/identifier, which are potentially user-visible strings this capability deliberately never duplicates into durable evidence or audit. This performs **no additional AX read** — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_table_header` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticTableHeaderReadTests.swift` — 37 focused tests, mirroring `ui.read_element_title_reference`'s test structure adapted for `QAXTableRolePolicy`'s allowlist and the corrected secure-field-only reference-role check (registration, resolution — exact/zero/ambiguous application and target, source-role gating, relationship exists/absent/read-failure/malformed, reference role validation — the deliberate design-difference proof that a non-leaf-control reference role is ACCEPTED (unlike title reference) while a secure-field reference is atomically rejected, metadata bounds, security disjoint-authorization proof, privacy — durable-evidence and audit-record sentinel-content-free proofs, recovery, verification success/failure evidence, `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `NSTableView`/`NSTableHeaderView` fixture, cross-validated against the identical control's own `accessibilityHeader()` accessor.

All 15 pre-existing test files that hardcoded the total capability count at 84 were updated to 85 (same strict equality assertion, no weakening). The eight most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`, `QSemanticElementEditedStateReadTests`, `QSemanticVisibleChildrenListTests`, `QSemanticElementIndexReadTests`, `QSemanticElementInsertionPointLineReadTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSTableView` inside an `NSScrollView`, with a real `NSTableHeaderView` attached, is resolved via `kAXHeaderAttribute` through the actual AX path — **cross-validated** against the identical control's own `accessibilityHeader()` accessor call, never a mock. A second table with `headerView = nil` correctly reports genuine absence.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readTableHeader`/`resolveTableHeader` call only `AXUIElementCopyAttributeValue` (read-only) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_table_header` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXHeaderAttribute` on the table, plus bounded `kAXRoleAttribute`/`kAXTitleAttribute`/`AXIdentifier` reads on the already-resolved header reference — confirmed via direct source inspection. `kAXValueAttribute` is never read, on either the table or the header reference. No raw `AXUIElement`/CF object crosses the boundary. Returned data is the bounded `{role, title, identifier}` reference plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CK defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF/2CG/2CH/2CI/2CJ.
