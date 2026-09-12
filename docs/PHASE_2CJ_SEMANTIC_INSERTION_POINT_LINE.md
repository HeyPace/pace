# Phase 2CJ — Semantic Element Insertion Point Line Number Read (`ui.read_element_insertion_point_line_number`)

## Overview
- **Capability Identifier**: `ui.read_element_insertion_point_line_number`
- **Capability Number**: #84
- **Tool Family**: `ui` (the returned `lineNumber` integer is structural cursor-position metadata — never the field's own typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `812d6a99a11156f7f47c59cde70a4713f56a1087` (Phase 2CI, `ui.read_element_index`)
- **Pre-Phase Capability Count**: `83`
- **Post-Phase Capability Count**: `84`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent know which line the text caret currently sits on in a multi-line field, without ever reading the field's own typed content (`kAXValueAttribute`). Useful for cursor-navigation context (e.g. "what line am I currently editing"). `kAXInsertionPointLineNumberAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Candidates were evaluated against the remaining unused, non-parameterized `kAX*Attribute` constants (152 total; 69 already in use as of Phase 2CI):
- **`kAXInsertionPointLineNumberAttribute`** — selected (see below).
- `kAXSelectedChildrenAttribute` — a real, declared accessor exists (previously deferred in Phase 2CH's discovery), but choosing a correct, non-arbitrary target role policy for "generic container with selectable children" was unclear (unlike `kAXVisibleChildrenAttribute`'s natural fit to `AXScrollArea`) — would risk inventing an ad-hoc role scoping decision rather than reusing an established policy cleanly.
- `kAXHeaderAttribute` — a real, declared accessor exists (`accessibilityHeader`, previously deferred in Phase 2CI's discovery) for "the element serving as this table/outline's header row" — genuinely useful, but requires a heavier native `NSTableView`/`NSOutlineView` fixture and a role-scoping decision between `AXTable`/`AXOutline`; deferred again this phase in favor of the simpler, zero-new-policy-surface candidate.
- `kAXTopLevelUIElementAttribute`/`kAXFocusedApplicationAttribute`/`kAXContentsAttribute`/`kAXDocumentAttribute` — already rejected in Phase 2CI's own discovery pass (overlap with `kAXWindowAttribute`, system-wide resolution shape, overlap with `kAXChildrenAttribute`/`ui.list_visible_children`, file-path/PII risk respectively); re-confirmed still true this phase.
- `kAXAlternateUIVisibleAttribute`/`kAXOrderedByRowAttribute`/`kAXIsApplicationRunningAttribute`/`kAXElementBusyAttribute`/`kAXURLAttribute`/`kAXFilenameAttribute`/`kAXValueWrapsAttribute` — already rejected in earlier phases' discovery passes; re-confirmed still true this phase.

`kAXInsertionPointLineNumberAttribute` is the clear highest-value pick this phase: a real, declared AppKit accessor (`accessibilityInsertionPointLineNumber`) exists in the **general** "Text" property cluster of `NSAccessibilityProtocols.h` — unlike `ui.read_element_index`'s `accessibilityIndex` (Phase 2CI, gated behind the specialized `NSAccessibilityRow` protocol) — meaning it reuses `QAXElementReadRolePolicy` (Phase 2J), the same broad, already-established allowlist ten-plus prior capabilities already share. This is the **minimum possible new policy surface**: zero new role policies, and the exact same CFNumber-decoding rigor already proven correct by `ui.read_element_index`/`ui.read_element_disclosure_level`.

---

## SDK Evidence
`kAXInsertionPointLineNumberAttribute` (`AXAttributeConstants.h`): `#define kAXInsertionPointLineNumberAttribute CFSTR("AXInsertionPointLineNumber")` — a plain HIServices macro. AppKit's own declared accessor: `@property NSInteger accessibilityInsertionPointLineNumber` (`NSAccessibilityProtocols.h`, "Text" pragma section, doc: "Line number containing caret") — a plain, general per-element property (implicit `readwrite`, giving both a getter and a `setAccessibilityInsertionPointLineNumber(_:)` setter), not gated behind any specialized `NS_PROTOCOL_REQUIRES_EXPLICIT_IMPLEMENTATION` protocol — the same accessor shape `ui.read_element_disclosure_level`'s/`ui.read_element_edited_state`'s own fixtures already established as proven-working for forcing a deterministic AX state via the declared setter.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy`'s existing allowlist (`AXTextField`, `AXTextArea`, `AXStaticText`, `AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXMenuItem`, `AXComboBox`, `AXSlider`, `AXStepper`, `AXLink`, `AXTab`, `AXDisclosureTriangle`) — reused completely unmodified, identical to `ui.read_element_expanded_state`/`ui.read_element_edited_state`/`ui.read_element_help_text`/`ui.read_element_placeholder_value`. `AXSecureTextField` is rejected first, before the general allowlist is even consulted — the same belt-and-suspenders discipline every prior read capability in this family already applies.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_index`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (not on `QAXElementReadRolePolicy`'s allowlist) | Fails closed — `disallowedReadRole` / `AX_DISALLOWED_READ_ROLE` |
| `AXSecureTextField` role | Fails closed — `secureFieldReadDenied` / `AX_SECURE_FIELD_READ_DENIED` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — `nil`, never an error, never downgraded to `0` |
| Any other non-`.success` `AXError` | Fails closed — `AX_ELEMENT_INSERTION_POINT_LINE_READ_FAILED` |
| Returned value not a genuine integer `CFNumber` (including floating-point subtypes) | Fails closed — `AX_ELEMENT_INSERTION_POINT_LINE_MALFORMED` |
| Returned integer negative, or overflows Swift `Int` | Fails closed — `AX_ELEMENT_INSERTION_POINT_LINE_INVALID` |

Three new `QAXInteractionError` cases were added (`elementInsertionPointLineReadFailed`, `elementInsertionPointLineMalformed`, `elementInsertionPointLineInvalid`) — the exact same shape as `elementIndexReadFailed`/`elementIndexMalformed`/`elementIndexInvalid`, since both attributes share the identical non-negative-integer-with-optional-absence contract.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_expanded_state`'s own resolution: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the target role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXInsertionPointLineNumberAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementInsertionPointLineMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXElementIndexMetadata`'s (Phase 2CI) 3-field shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `lineNumber` | `Int?` | `nil` = genuine absence (valid); a non-negative `Int` = a definite, directly-observed caret line, never conflated with `nil`. |

---

## Privacy Boundary
Only `lineNumber` (a single bounded, non-negative integer) plus non-sensitive targeting identity (`applicationName`, `role`) crosses the bridge. No field content, no document text, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXInsertionPointLineNumberAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementInsertionPointLine` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXInsertionPointLineNumberAttribute` read + `CFNumber` decode: `resolveElementInsertionPointLine(of:)` (`QBridgeAdapters.swift`), mirroring `resolveElementIndex`'s exact integer-subtype validation, `sInt64Type` extraction, non-negativity check, and overflow-safe `Int(exactly:)` conversion
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.elementInsertionPointLineReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveElementInsertionPointLine(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementInsertionPointLineReadSucceeded(applicationName:role:hasLineNumber:lineNumberRaw:)`. Like `elementIndexReadSucceeded`, this strategy carries the **raw claimed string** (not a pre-parsed `Int`) specifically so `evaluate` can perform its own independent parse-and-bounds-check re-validation — a fabricated success claiming a non-numeric or negative line number is still correctly rejected (proven directly in the test suite, tests 29/29b/29c). This performs **no additional AX read** — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_insertion_point_line_number` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementInsertionPointLineReadTests.swift` — 36 focused tests, mirroring `ui.read_element_index`'s test structure adapted for `QAXElementReadRolePolicy`'s shared allowlist and the plain, general-property accessor shape (registration, permission gate/denial, target validation via `QAXElementReadRolePolicy` including secure-field rejection, missing/wrong-application/missing/ambiguous target, stale-target structural note, happy-path non-zero and zero line number, genuine-absence-never-fabricated-as-zero, malformed/invalid/genuine-AXError diagnostics, security disjoint-authorization proof, recovery, privacy — durable-evidence and audit-record sentinel-content-free proofs, verification success/absence/failure/fabrication-rejection evidence (including the negative-value and non-numeric fabrication-rejection tests), `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `NSTextField` fixture, exercising both a non-zero and a zero line number, cross-validated against the control's own `accessibilityInsertionPointLineNumber` accessor.

All 15 pre-existing test files that hardcoded the total capability count at 83 were updated to 84 (same strict equality assertion, no weakening). The seven most recently active phase-chain comments (`QSemanticElementHelpTextReadTests`, `QSemanticElementPlaceholderValueReadTests`, `QSemanticElementExpandedStateReadTests`, `QSemanticElementDisclosureLevelReadTests`, `QSemanticElementEditedStateReadTests`, `QSemanticVisibleChildrenListTests`, `QSemanticElementIndexReadTests`) were also updated to name this phase in their contributing-phases chain, consistent with the maintenance pattern those files have followed since Phase 2CC.

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSTextField`'s insertion-point line number is forced via the genuine, declared `setAccessibilityInsertionPointLineNumber(_:)` AppKit accessor pair, then resolved via `kAXInsertionPointLineNumberAttribute` through the actual AX path — **cross-validated** against the same control's own `accessibilityInsertionPointLineNumber` accessor read independently, never a mock. Both a non-zero (3) and a zero (first-line) value are exercised.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readElementInsertionPointLine`/`resolveElementInsertionPointLine` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXInsertionPointLineNumberAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_insertion_point_line_number` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXInsertionPointLineNumberAttribute` — confirmed via direct source inspection, `resolveElementInsertionPointLine(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementInsertionPointLineMetadata`'s boundary. Returned data is the bounded `lineNumber` integer plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
See the Full Regression / Environment section of the final report for this phase. Any genuine environmental issue encountered (distinct from a Phase 2CJ defect) is documented there with evidence, following the same honest-classification discipline established in Phase 2CF/2CG/2CH/2CI.
