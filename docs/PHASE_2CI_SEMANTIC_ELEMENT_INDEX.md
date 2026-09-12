# Phase 2CI — Semantic Element Index Read (`ui.read_element_index`)

## Overview
- **Capability Identifier**: `ui.read_element_index`
- **Capability Number**: #83
- **Tool Family**: `ui` (the returned `index` integer is structural UI-hierarchy metadata — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `4e75da32f919a27c19a31b600f645dec361b381b` (Phase 2CH, `ui.list_visible_children`)
- **Pre-Phase Capability Count**: `82`
- **Post-Phase Capability Count**: `83`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent ask "which position does this specific row occupy" without first enumerating the entire container via `ui.list_outline_items`. Complements `ui.read_element_disclosure_level` (Phase 2CF — "how deeply nested") and `ui.read_element_expanded_state` (Phase 2CE — "is this row open") with a third piece of positional information. `kAXIndexAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the remaining unused, non-parameterized `kAX*Attribute` constants (152 total; 68 already in use as of Phase 2CH):
- **`kAXIndexAttribute`** — selected (see below).
- `kAXHeaderAttribute` — a real, declared accessor (`accessibilityHeader`, replacing the deprecated `accessibilityHeaderGroup`) exists for "the element serving as this table/outline's header row" — a genuinely distinct, real capability, but judged lower-value this phase: building a deterministic native fixture requires a full `NSTableView`/`NSOutlineView` setup (more fixture complexity) for a narrower real-world payoff than a general row-position read.
- `kAXTopLevelUIElementAttribute` — a real, declared accessor exists, but overlaps heavily with the already-used `kAXWindowAttribute` for ordinary (non-sheet/non-drawer) UI, making its incremental value low relative to the new policy/testing surface it would need.
- `kAXFocusedApplicationAttribute` — a system-wide (not per-application) attribute requiring a fundamentally different resolution shape (`AXUIElementCreateSystemWide()` rather than per-app target resolution) — a larger architectural departure than this phase's "minimal new policy surface" mandate; deferred rather than rushed.
- `kAXContentsAttribute`/`kAXDocumentAttribute` — `kAXDocumentAttribute` was rejected for the same reason as the already-rejected `kAXURLAttribute`/`kAXFilenameAttribute` (file-path/PII exposure risk); `kAXContentsAttribute` overlaps with the already-used `kAXChildrenAttribute`/already-implemented `ui.list_visible_children` territory without a clearly distinct semantic.
- `kAXInsertionPointLineNumberAttribute` — a real, declared accessor exists (`accessibilityInsertionPointLineNumber`) and is a plausible future candidate ("what line is the text caret on"), but is narrower in scope (text-editing only) than the row-position capability, which applies to both tables and outlines.
- `kAXAlternateUIVisibleAttribute`/`kAXOrderedByRowAttribute`/`kAXIsApplicationRunningAttribute`/`kAXElementBusyAttribute`/`kAXURLAttribute`/`kAXFilenameAttribute`/`kAXValueWrapsAttribute` — already rejected in Phase 2CG/2CH's own discovery passes; re-confirmed still true this phase.

`kAXIndexAttribute` is the clear highest-value pick: a real, declared AppKit accessor (`accessibilityIndex()`, via the dedicated `NSAccessibilityRow` protocol) enables genuine cross-validation, it directly extends the existing row-context trio, and it reuses `QAXOutlineRowRolePolicy` (Phase 2T) with zero new role-policy surface — the exact same choice `ui.read_element_disclosure_level` (Phase 2CF) already made for the identical `AXRow` target shape.

**Deliberately distinct from `ui.list_outline_items`'s own `index` field** (Phase 2AF): that field is a SYNTHETIC array-position computed during enumeration (`for (index, item) in items.enumerated()`), never a read of `kAXIndexAttribute` itself. This capability reads the real, AX-reported position of one already-resolved row directly, without first enumerating the whole container — genuinely new, non-redundant information (an app's reported index can differ from naive enumeration order for filtered, reordered, or virtualized lists).

---

## SDK Evidence
`kAXIndexAttribute` (`AXAttributeConstants.h`): `#define kAXIndexAttribute CFSTR("AXIndex")` — a plain HIServices macro. AppKit's own declared accessor: `- (NSInteger)accessibilityIndex;` (`NSAccessibilityProtocols.h`, doc: "Index of the current UIElement (row index for a row, column index for a column)"), declared as the sole `@required` method of the dedicated `NSAccessibilityRow` protocol (`NS_PROTOCOL_REQUIRES_EXPLICIT_IMPLEMENTATION`) — unlike `kAXExpandedAttribute`/`kAXEditedAttribute`, which are general per-element properties every `NSView` gets by default, `accessibilityIndex()` must be explicitly implemented by a conforming class. This confirms the attribute's narrower, row/column-specific applicability and justifies restricting the target role rather than using the generic `QAXElementReadRolePolicy` allowlist.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXOutlineRowRolePolicy`'s existing allowlist (`AXRow`) — reused completely unmodified, identical to `ui.read_element_disclosure_level` (Phase 2CF). Exactly like disclosure level, this read does NOT additionally require the `AXOutlineRow` subrole or an `AXOutline` parent context: a read of an ordinary `AXTableRow` simply, honestly reports its own real index — there is no fabrication risk the way there would be for a mutation.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_disclosure_level`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (anything but `AXRow`) | Fails closed — `disallowedOutlineRowRole` / `AX_DISALLOWED_OUTLINE_ROW_ROLE` (reused, unmodified, from Phase 2T) |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — `nil`, never an error, never downgraded to `0` |
| Any other non-`.success` `AXError` | Fails closed — `AX_ELEMENT_INDEX_READ_FAILED` |
| Returned value not a genuine integer `CFNumber` (including floating-point subtypes) | Fails closed — `AX_ELEMENT_INDEX_MALFORMED` |
| Returned integer negative, or overflows Swift `Int` | Fails closed — `AX_ELEMENT_INDEX_INVALID` |

Three new `QAXInteractionError` cases were added (`elementIndexReadFailed`, `elementIndexMalformed`, `elementIndexInvalid`) — the exact same shape as `elementDisclosureLevelReadFailed`/`elementDisclosureLevelMalformed`/`elementDisclosureLevelInvalid`, since both attributes share the identical non-negative-integer-with-optional-absence contract.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_disclosure_level`'s own resolution: role-policy check (`QAXOutlineRowRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXRow` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXIndexAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementIndexMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXElementDisclosureLevelMetadata`'s (Phase 2CF) 3-field shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role (`AXRow`). |
| `index` | `Int?` | `nil` = genuine absence (valid); a non-negative `Int` = a definite, directly-observed ordinal position, never conflated with `nil`. |

---

## Privacy Boundary
Only `index` (a single bounded, non-negative integer) plus non-sensitive targeting identity (`applicationName`, `role`) crosses the bridge. No field content, no document text, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXIndexAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementIndex` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXIndexAttribute` read + `CFNumber` decode: `resolveElementIndex(of:)` (`QBridgeAdapters.swift`), mirroring `resolveElementDisclosureLevel`'s exact integer-subtype validation, `sInt64Type` extraction, non-negativity check, and overflow-safe `Int(exactly:)` conversion
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.elementIndexReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveElementIndex(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementIndexReadSucceeded(applicationName:role:hasIndex:indexRaw:)`. Like `elementDisclosureLevelReadSucceeded`, this strategy carries the **raw claimed string** (not a pre-parsed `Int`) specifically so `evaluate` can perform its own independent parse-and-bounds-check re-validation — a fabricated success claiming a non-numeric or negative index is still correctly rejected (proven directly in the test suite, tests 29/29b/29c). This performs **no additional AX read** — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_index` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementIndexReadTests.swift` — 36 focused tests, mirroring `ui.read_element_disclosure_level`'s test structure adapted for `kAXIndexAttribute`'s get-only, protocol-required (rather than settable-property) accessor shape (registration, permission gate/denial, target validation via `QAXOutlineRowRolePolicy`, missing/wrong-application/missing/ambiguous target, stale-target structural note, happy-path non-zero and zero index, genuine-absence-never-fabricated-as-zero, malformed/invalid/genuine-AXError diagnostics, security disjoint-authorization proof, recovery, privacy — durable-evidence and audit-record sentinel-content-free proofs, verification success/absence/failure/fabrication-rejection evidence (including the negative-value and non-numeric fabrication-rejection tests), `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `AXRow`-role fixture conforming to the genuine `NSAccessibilityRow` protocol, exercising both a non-zero and a zero index, cross-validated against the control's own `accessibilityIndex()` accessor.

All 15 pre-existing test files that hardcoded the total capability count at 82 were updated to 83 (same strict equality assertion, no weakening). The six most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`, `QSemanticElementEditedStateReadTests`, `QSemanticVisibleChildrenListTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `AXRow`-role fixture conforming to the genuine, declared `NSAccessibilityRow` protocol and implementing its `accessibilityIndex()` method is resolved via `kAXIndexAttribute` through the actual AX path — **cross-validated** against the same control's own `accessibilityIndex()` accessor read independently, never a mock. Both a non-zero (3) and a zero (first-position) index are exercised.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readElementIndex`/`resolveElementIndex` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXIndexAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_index` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability, and proven disjoint from `ui.select_outline_row`'s own Level 2 approval requirement.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXIndexAttribute` — confirmed via direct source inspection, `resolveElementIndex(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementIndexMetadata`'s boundary. Returned data is the bounded `index` integer plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CI defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF/2CG/2CH.
