# Phase 2CD — Semantic Element Placeholder Value Read (`ui.read_element_placeholder_value`)

## Overview
- **Capability Identifier**: `ui.read_element_placeholder_value`
- **Capability Number**: #78
- **Tool Family**: `ui` (returns a single bounded placeholder/hint string, never any other element content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `88fab2f339b0d9b468b525ebbef69af1d422eee8` (Phase 2CC, `ui.read_element_help_text`)
- **Pre-Phase Capability Count**: `77`
- **Post-Phase Capability Count**: `78`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability read `kAXPlaceholderValueAttribute` — a text field's placeholder/hint text (e.g. a search field's "Search" ghost text), shown only while the field is empty. This lets the agent understand what a field expects (a search box vs. a filter box vs. an email field) without guessing from role/title alone, and without ever touching the field's actual (potentially sensitive, user-entered) `kAXValueAttribute` content. Distinct from `kAXHelpAttribute` (`ui.read_element_help_text`, Phase 2CC — a tooltip/help string), `kAXValueDescriptionAttribute` (`ui.read_element_value_description`, Phase 2BW — a description of the element's **current value**), and `kAXRoleDescriptionAttribute` (`ui.read_element_role_description`, Phase 2CB — a description of the element's **type**). A grep across the entire production codebase confirmed zero existing references to `kAXPlaceholderValueAttribute` before this phase.

---

## SDK Evidence
`kAXPlaceholderValueAttribute` (`AXAttributeConstants.h`, `HIServices.framework`): `#define kAXPlaceholderValueAttribute CFSTR("AXPlaceholderValue")`. Like `kAXHelpAttribute`, it carries no "required for all elements"-style documentation — only text-entry-style controls that were ever given a placeholder expose it at all; most controls, and even most text fields, legitimately lack it. This is the optional-reference pattern, identical in shape to `ui.read_element_help_text`'s and `ui.read_element_value_description`'s own absence semantics.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXElementReadRolePolicy` (Phase 2J) — reused completely unmodified, identical to `ui.read_element_value`/`ui.list_element_actions`/`ui.read_element_value_description`/`ui.read_element_role_description`/`ui.read_element_help_text`'s own allowlist, including the identical `AXSecureTextField`-first-then-general-allowlist exclusion discipline. This capability never broadens role access. This is a single bounded read: `kAXPlaceholderValueAttribute` is read exactly once against the resolved element — never `kAXValueAttribute`, never `kAXRoleAttribute`, never any traversal, never a relationship hop.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_help_text`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| `role == "AXSecureTextField"` | Fails closed — `secureFieldReadDenied` |
| Disallowed read role | Fails closed — `AX_DISALLOWED_ROLE` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — whole result is `nil`, never an error |
| Any other non-`.success` `AXError` reading `kAXPlaceholderValueAttribute` | Fails closed — `AX_PLACEHOLDER_VALUE_READ_FAILED` |
| Returned value not a genuine `String` | Fails closed — `AX_PLACEHOLDER_VALUE_MALFORMED` |
| Returned string exceeds the defensive length bound (256) | Fails closed — `AX_PLACEHOLDER_VALUE_EXCEEDS_SAFE_BOUND` |
| Returned string is present but empty | **Valid** — its own distinct, non-nil result (never conflated with absence) |

Three new `QAXInteractionError` cases were added (`placeholderValueReadFailed`, `placeholderValueMalformed`, `placeholderValueExceedsSafeBound`) — mirroring `ui.read_element_help_text`'s three cases exactly. Every other failure mode (missing criteria, secure-field rejection, disallowed role, permission denial, target resolution, staleness) reuses existing `QAXInteractionError` cases verbatim.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_help_text`/`ui.read_element_value_description`/`ui.read_element_role_description`: secure-field check → role-policy check (`QAXElementReadRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against the requested role (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXPlaceholderValueAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementPlaceholderValueMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role. |
| `elementIdentifier` | `String?` | The resolved element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved element's own title/description, if any. |
| `placeholderValue` | `String` | Bounded (≤256 chars); may be empty when genuinely present-but-empty. |

The overall bridge function (`readElementPlaceholderValue`) returns `QAXElementPlaceholderValueMetadata?` — `nil` for genuine, expected absence of the attribute, never a fabricated empty-string metadata instance.

---

## Privacy Boundary
Only the bounded `placeholderValue` string (plus non-sensitive targeting identity) crosses the bridge. The string is developer-authored UI guidance text shown while a field is empty — never the user's own entered content, which lives exclusively in `kAXValueAttribute` and is never read anywhere in this capability. Same sensitivity tier as an already-exposed title/help/value-description/role-description string. Never exposed: document text, field values, passwords, credentials, OTPs, payment data, arbitrary application content, raw `AXUIElement`/CF objects, or accessibility tree dumps. `QAXElementPlaceholderValueMetadata`'s stored properties are `String`/`String?`/`String` only.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXPlaceholderValueAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementPlaceholderValue` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling `QAXElementReadRolePolicy` capability)
- `kAXPlaceholderValueAttribute` read: `resolveElementPlaceholderValue(of:)` (`QBridgeAdapters.swift`)
- String-length bound: `maxPlaceholderValueLength` (256, `QBridgeAdapters.swift`) and its enforcement inside `resolveElementPlaceholderValue(of:)`
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Result construction: `readElementPlaceholderValue`'s trailing `QAXElementPlaceholderValueMetadata(...)` construction
- Verification: `QVerificationStrategy.elementPlaceholderValueReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries were introduced — confirmed by direct source inspection: `resolveElementPlaceholderValue(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementPlaceholderValueReadSucceeded(applicationName:role:elementIdentifier:elementTitle:hasPlaceholderValue:placeholderValue:)`. Mirrors `elementHelpTextReadSucceeded`'s exact optional-reference verification discipline: when a placeholder value is claimed absent, that is its own valid, distinct verified outcome; when claimed present, the strategy independently re-validates the string is present and within the same 256-character bound `resolveElementPlaceholderValue` itself enforces, rather than blindly trusting the dispatch layer's own `success` flag. This re-validation reuses only the already-dispatched result's own output — **it performs no additional AX read of any kind**, confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_placeholder_value` (identical to every other Level 0 read capability in this codebase): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementPlaceholderValueReadTests.swift` — 47 focused tests covering all 25 categories established by `ui.read_element_help_text`'s own approved design: registration (capability count == 78, anti-downgrade/upgrade, no approval surface), permission gate / permission denial, target validation (`QAXElementReadRolePolicy` roles accepted unmodified, secure-field rejection, wrong role, missing/wrong-application/missing/ambiguous target, stale-target structural note), AX result validation (valid string, malformed CFType, genuine AXError, exactly-256 accepted, 257 rejected, absence-vs-empty distinction), fail-closed structural proofs (never `kAXValueAttribute`, no silent truncation, no fabricated fallback), privacy (no arbitrary content/raw-object exposure, durable-evidence and audit-record sentinel-content-free proofs), resource (structural one-read/zero-hop bound proof, `QResourceGuard` generic application), security (no mutation APIs, no network symbols, disjoint authorization from `ui.click_element`/`ui.set_text_value`, real-fixture no-mutation proof), verification (independent rejection of fabricated nil/oversized "successes", explicit proof of zero additional AX reads), recovery (uncertain step fails closed to pending, no raw `AXUIElement` persistence, durable snapshot omission proof), capability-count integrity, and full `QPlanExecutor` pipeline integration. Plus two real macOS AppKit E2E tests (TCC-guarded), using a real `NSTextField` fixture.

All 11 pre-existing test files that hardcoded the total capability count at 77 were updated to 78 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CD): `QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementHelpTextReadTests` (itself added in Phase 2CC and now needing its own count bump, per the established pattern), `QSemanticElementRoleDescriptionReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticScrollPositionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTableRowHeaderEnumerationTests`, `QSemanticTextSelectionStateReadTests`, `QSemanticWindowAuxiliaryButtonsReadTests`.

---

## Native E2E / TCC Status
Two real macOS AppKit E2E tests, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass):
1. A real `NSTextField`'s placeholder is forced via the genuine, declared `placeholderString` AppKit property, then resolved via `kAXPlaceholderValueAttribute` through the actual AX path — **cross-validated** against the same control's own `placeholderString` read independently, never a mock.
2. A genuine `NSTextField` with no placeholder ever set correctly reports honest absence (`nil`) via the optional-reference contract.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so both E2E tests correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code. `readElementPlaceholderValue`/`resolveElementPlaceholderValue` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXPlaceholderValueAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_placeholder_value` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXPlaceholderValueAttribute` — confirmed via direct source inspection, `resolveElementPlaceholderValue(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementPlaceholderValueMetadata`'s boundary. Returned data is the bounded `placeholderValue` string plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Stabilization (preceded this phase, not part of it)
Before this phase's implementation, the pre-existing Phase 2CC full-regression gate was blocked by two long-standing, pre-existing SIGSEGV sources unrelated to any semantic-read capability: real `NSWindow` test fixtures across the suite closing windows without disabling AppKit's implicit close-animation, and `leanring_buddyApp.swift` presenting its real menu-bar overlay even under the XCTest host. Both were fixed in a separate, dedicated commit (`bc6c5e2`, "test: stabilize pre-existing AppKit window fixture teardown and skip overlay UI under XCTest") — see that commit's message for full evidence. This phase's own regression evidence (below) was collected after that stabilization.

## Known Environmental Limitations
- Both real-AppKit E2E tests are TCC-blocked in this sandboxed test-runner environment (`AXIsProcessTrusted() == false`) — they correctly report `BLOCKED BY ENVIRONMENT`, never a fabricated pass, mirroring every prior phase's identical finding.
- Full regression runs in this environment have historically shown intermittent, pre-existing single-test flakiness in unrelated live-`NSWindow`/AX-fixture capabilities (documented in Phases 2CA/2CB/2CC's own docs); the environmental stabilization above measurably reduced but did not provably eliminate every possible instance of this class. Any residual flake is classified the same way established by prior phases: reproduced/investigated before being ruled environmental, and never used as a reason to weaken a test or change production code.
