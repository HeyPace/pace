# Phase 2CC — Semantic Element Help Text Read (`ui.read_element_help_text`)

## Overview
- **Capability Identifier**: `ui.read_element_help_text`
- **Capability Number**: #77
- **Tool Family**: `ui` (returns a single bounded, localized help/tooltip string, never any other element content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `e8b5126a498f92093ef1046af7cce64c28d55740`
- **Pre-Phase Capability Count**: `76`
- **Post-Phase Capability Count**: `77`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability reads `kAXHelpAttribute` — the SDK's own localized, human-readable help/tooltip content for an element ("often the same information that would be provided in a help tag for the element"). This is distinct from both `kAXRoleDescriptionAttribute` (`ui.read_element_role_description`, Phase 2CB — a description of the element's **type**) and `kAXValueDescriptionAttribute` (`ui.read_element_value_description`, Phase 2BW — a description of the element's **current value**). `kAXHelpAttribute` is already read internally as a fallback field inside two shipped capabilities (`ui.list_sheet_actions`, `ui.list_combo_boxes`), confirming it populates reliably in this exact codebase — but it was never exposed as its own first-class, independently-verifiable capability until now.

---

## SDK Evidence
`kAXHelpAttribute` (`AXAttributeConstants.h`) has its own dedicated `/*! @define */` documentation block: "A localized, human-readable CFStringRef that offers help content for an element... This is often the same information that would be provided in a help tag for the element... **Recommended for any element that has help data available**." Unlike `kAXRoleDescriptionAttribute`'s "Required for all elements" language, this is the optional-reference pattern — most controls legitimately lack help data. Confirmed via direct grep: the attribute constant is already used internally (as a fallback field, never its own queryable capability) at two call sites in `QBridgeAdapters.swift` before this phase; zero references to it as a standalone registered capability.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy` (Phase 2J) — reused completely unmodified, identical to `ui.read_element_value`/`ui.list_element_actions`/`ui.read_element_value_description`/`ui.read_element_role_description`'s own allowlist, including the identical `AXSecureTextField`-first-then-general-allowlist exclusion discipline. This capability never broadens role access. This is a single bounded read: `kAXHelpAttribute` is read exactly once against the resolved element — never `kAXValueAttribute`, never `kAXRoleAttribute`, never any traversal, never a relationship hop.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_value_description`)
Unlike `kAXRoleDescriptionAttribute` (required-for-all-elements, no valid absence), `kAXHelpAttribute`'s SDK documentation only says "Recommended for any element that has help data available" — genuine absence is therefore a **valid, expected** outcome, not a failure:

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| `role == "AXSecureTextField"` | Fails closed — `secureFieldReadDenied` |
| Disallowed read role | Fails closed — `AX_DISALLOWED_ROLE` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — whole result is `nil`, never an error |
| Any other non-`.success` `AXError` reading `kAXHelpAttribute` | Fails closed — `AX_HELP_TEXT_READ_FAILED` |
| Returned value not a genuine `String` | Fails closed — `AX_HELP_TEXT_MALFORMED` |
| Returned string exceeds the defensive length bound (256) | Fails closed — `AX_HELP_TEXT_EXCEEDS_SAFE_BOUND` |
| Returned string is present but empty | **Valid** — its own distinct, non-nil result (never conflated with absence) |

Three new `QAXInteractionError` cases were added (`helpTextReadFailed`, `helpTextMalformed`, `helpTextExceedsSafeBound`) — deliberately fewer than `ui.read_element_role_description`'s four, since help text has no "empty is invalid" case to diagnose. Every other failure mode (missing criteria, secure-field rejection, disallowed role, permission denial, target resolution, staleness) reuses `ui.read_element_value_description`'s existing `QAXInteractionError` cases verbatim.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_value_description`/`ui.read_element_role_description`: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the requested role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXHelpAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementHelpTextMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `elementIdentifier` | `String?` | The resolved element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved element's own title/description, if any. |
| `helpText` | `String` | Bounded (≤256 chars); may be empty when genuinely present-but-empty. |

The overall bridge function (`readElementHelpText`) returns `QAXElementHelpTextMetadata?` — `nil` for genuine, expected absence of the attribute, never a fabricated empty-string metadata instance.

---

## Privacy Boundary
Only the bounded `helpText` string (plus non-sensitive targeting identity) crosses the bridge. The string is developer-authored UI guidance/tooltip content — the same sensitivity tier as an already-exposed title/value-description/role-description string, not user-entered content. `kAXValueAttribute` is never read anywhere in this capability. Never exposed: document text, field values, passwords, credentials, OTPs, payment data, arbitrary application content, raw `AXUIElement`/CF objects, or accessibility tree dumps. `QAXElementHelpTextMetadata`'s stored properties are `String`/`String?`/`String` only.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXHelpAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementHelpText` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling `QAXElementReadRolePolicy` capability)
- `kAXHelpAttribute` read: `resolveElementHelpText(of:)` (`QBridgeAdapters.swift`)
- String-length bound: `maxHelpTextLength` (256, `QBridgeAdapters.swift`) and its enforcement inside `resolveElementHelpText(of:)`
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Result construction: `readElementHelpText`'s trailing `QAXElementHelpTextMetadata(...)` construction
- Verification: `QVerificationStrategy.elementHelpTextReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries were introduced — confirmed by direct source inspection: `resolveElementHelpText(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementHelpTextReadSucceeded(applicationName:role:elementIdentifier:elementTitle:hasHelpText:helpText:)`. Mirrors `elementValueDescriptionReadSucceeded`'s exact optional-reference verification discipline: when help text is claimed absent, that is its own valid, distinct verified outcome; when claimed present, the strategy independently re-validates the string is present and within the same 256-character bound `resolveElementHelpText` itself enforces, rather than blindly trusting the dispatch layer's own `success` flag. This re-validation reuses only the already-dispatched result's own output — **it performs no additional AX read of any kind**, confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_help_text` (identical to every other Level 0 read capability in this codebase): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementHelpTextReadTests.swift` — 47 focused tests covering all 25 categories required by this phase's approved design: registration (capability count == 77, anti-downgrade/upgrade, no approval surface), permission gate / permission denial, target validation (`QAXElementReadRolePolicy` roles accepted unmodified, secure-field rejection, wrong role, missing/wrong-application/missing/ambiguous target, stale-target structural note), AX result validation (valid string, malformed CFType, genuine AXError, exactly-256 accepted, 257 rejected, absence-vs-empty distinction), fail-closed structural proofs (never `kAXValueAttribute`, no silent truncation, no fabricated fallback), privacy (no arbitrary content/raw-object exposure, durable-evidence and audit-record sentinel-content-free proofs), resource (structural one-read/zero-hop bound proof, `QResourceGuard` generic application), security (no mutation APIs, no network symbols, disjoint authorization from `ui.click_element`, real-fixture no-mutation proof), verification (independent rejection of fabricated nil/oversized "successes", explicit proof of zero additional AX reads), recovery (uncertain step fails closed to pending, no raw `AXUIElement` persistence, durable snapshot omission proof), capability-count integrity, and full `QPlanExecutor` pipeline integration. Plus two real macOS AppKit E2E tests (TCC-guarded).

All 10 pre-existing test files that hardcoded the total capability count at 76 were updated to 77 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CC): `QSemanticElementAllowedValuesReadTests`, `QSemanticColumnSortDirectionReadTests`, `QSemanticElementRoleDescriptionReadTests` (itself added in Phase 2CB and now needing its own count bump, per the established pattern), `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticScrollPositionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticTableRowHeaderEnumerationTests`, `QSemanticWindowAuxiliaryButtonsReadTests`.

---

## Native E2E / TCC Status
Two real macOS AppKit E2E tests, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass):
1. A real `NSButton`'s help text is forced via the genuine, declared `setAccessibilityHelp(_:)` AppKit accessor, then resolved via `kAXHelpAttribute` through the actual AX path — **cross-validated** against AppKit's own `accessibilityHelp()` accessor called independently on the same control, never a mock.
2. A genuine `NSButton` with no help text ever set correctly reports honest absence (`nil`) via the optional-reference contract.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so both E2E tests correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readElementHelpText`/`resolveElementHelpText` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXHelpAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_help_text` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXHelpAttribute` — confirmed via direct source inspection, `resolveElementHelpText(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementHelpTextMetadata`'s boundary. Returned data is the bounded `helpText` string plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (non-fat, confirmed via `lipo -info`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches)

---

## Known Environmental Limitations
- Both real-AppKit E2E tests are TCC-blocked in this sandboxed test-runner environment (`AXIsProcessTrusted() == false`) — they correctly report `BLOCKED BY ENVIRONMENT`, never a fabricated pass, mirroring every prior phase's identical finding.
- Full regression runs in this environment have historically shown intermittent, pre-existing single-test flakiness in unrelated live-`NSWindow`/AX-fixture capabilities (documented in Phases 2CA/2CB's own docs) — this phase's regression runs are recorded in the Phase 2CC implementation final report, with any such flakes classified the same way: reproduced in isolation before being ruled environmental, and never used as a reason to weaken a test or change production code.
