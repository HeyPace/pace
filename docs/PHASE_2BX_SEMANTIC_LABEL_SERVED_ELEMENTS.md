# Phase 2BX — Semantic Label Served-Elements Read (`ui.list_label_served_elements`)

## Overview
- **Capability Identifier**: `ui.list_label_served_elements`
- **Capability Number**: #72
- **Tool Family**: `ui` (the returned field is a bounded array of identity-only structs, never content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `e8ec77f`
- **Pre-Phase Capability Count**: `71`
- **Post-Phase Capability Count**: `72`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.read_element_title_reference` (Phase 2BN) reads the *forward* relationship — an element → the element that titles it (`kAXTitleUIElementAttribute`). No capability read the *reverse* relationship — a label → the elements it serves as the title for (`kAXServesAsTitleForUIElementsAttribute`). This capability closes that gap, completing bidirectional label/control relationship coverage.

---

## SDK Evidence
`kAXServesAsTitleForUIElementsAttribute` (`AXAttributeConstants.h:1204`, raw string `"AXServesAsTitleForUIElements"`) — grouped in the generic relationship-attribute list alongside `kAXTitleUIElementAttribute`, its exact structural inverse. Modern accessor: `NSAccessibilityProtocols.h`, `@property (nullable, copy) NSArray *accessibilityServesAsTitleForUIElements API_AVAILABLE(macos(10.10))` — real, declared, settable, confirmed compiled correctly on the first build attempt (`label.setAccessibilityServesAsTitleForUIElements([...])`/`label.accessibilityServesAsTitleForUIElements()`).

---

## Semantic Contract & Target Role Policy
Target roles are restricted to `QAXElementReadRolePolicy` — reused **completely unmodified**, the identical allowlist `ui.read_element_value`/`ui.read_element_title_reference` already use for their own source elements, applied here to BOTH the source label element AND every individually-validated served element (mirroring `resolveElementTitleReference`'s (2BN) discipline of independently re-validating a returned reference's own role against the same allowlist — the mere existence of a reference is never sufficient). `AXSecureTextField` is rejected before the general allowlist is ever consulted, and can never appear as a "safe" served element either.

This is a **bounded relationship query**, never generic extraction: exactly one AX attribute read on the resolved source element, then only bounded identity reads (role/title/identifier) on each already-enumerated served element — never a recursive descent into a served element's own children, never a second relationship hop, and `kAXValueAttribute` is never read anywhere in this capability.

---

## Absence vs. Empty — the Optional-Reference Pattern
`kAXServesAsTitleForUIElementsAttribute` carries no "required for all elements of this role"-style documentation — most elements serve as the title for nothing at all:

| Condition | Treatment |
|---|---|
| `kAXServesAsTitleForUIElementsAttribute` absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Whole result `nil` — genuine, expected absence |
| Attribute present, array has 0 entries | Valid, non-nil result with `servedElements == []` |
| Any other `AXError` | Fails closed — `AX_SERVED_ELEMENTS_READ_FAILED` |
| Wrong outer CFType (not a `CFArray`) | Fails closed — `AX_SERVED_ELEMENTS_MALFORMED` |
| Array exceeds `maxServedElementsCount` (32) | Fails closed — `AX_SERVED_ELEMENTS_EXCEEDS_SAFE_BOUND`, checked BEFORE any per-element extraction |
| Any element not a genuine `AXUIElement` | Fails the WHOLE array closed — `AX_SERVED_ELEMENTS_ELEMENT_MALFORMED` |
| Any served element's own role not on `QAXElementReadRolePolicy` | Fails the WHOLE array closed — `AX_SERVED_ELEMENTS_ELEMENT_DISALLOWED_ROLE` (an unreadable role reads as `"none"`, itself never on the allowlist, so it fails the same way) |
| Any served element's title/identifier exceeds `maxServedElementMetadataLength` (256) | Fails the WHOLE array closed — `AX_SERVED_ELEMENTS_ELEMENT_METADATA_EXCEEDS_SAFE_LENGTH` |

**Atomic array discipline** (mirroring `ui.read_element_allowed_values`, Phase 2BV): a single malformed, unreadable, or disallowed-role served element fails the WHOLE array closed — invalid entries are never silently dropped, and the array is never truncated.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_element_value`/`ui.read_element_title_reference`: secure-field check → role-policy check → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift.

---

## Result Contract
`QAXLabelServedElementsMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The caller-supplied, policy-validated source role. |
| `elementIdentifier` | `String?` | The resolved source element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved source element's own title, if any. |
| `servedElements` | `[QAXServedElementReference]` | Bounded, fully-validated array — may legitimately be empty. |

`QAXServedElementReference` (identical shape to `QAXElementTitleReference`, Phase 2BN): `role: String`, `title: String?`, `identifier: String?`. No `AXUIElement`, no coordinates, no raw CF object, and — critically — never `kAXValueAttribute`'s own content ever appears in either type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.labelServedElementsReadSucceeded(applicationName:role:hasServedElements:servedElementCount:)`
- **Evaluation**: independently re-validates `servedElementCount >= 0` — never trusts the executor's own `success` flag alone. Genuine absence (`hasServedElements == false`) is its own valid, distinct verified outcome — never conflated with a present-but-empty relationship.
- **Deliberately conservative evidence**: unlike `elementAllowedValuesReadSucceeded`/`tableDimensionsReadSucceeded` (which include the actual bounded numeric facts), this strategy mirrors `elementTitleReferenceReadSucceeded`'s (Phase 2BN) identical conservative-evidence discipline for the structurally symmetric forward relationship — carrying only application identity, source role, presence, and a bounded **count**; never any individual served element's own title/identifier, which are potentially user-visible strings this capability deliberately never duplicates into durable evidence or audit.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`. Observing this relationship grants zero authorization for any mutation against either the source label or any served element.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — no served-element data is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1` (source); `maxAXAttributesRead = 1` primary relationship read (`kAXServesAsTitleForUIElementsAttribute`) + bounded per-served-element identity reads (role/title/identifier), never unbounded; `maxTraversalDepth = 0`; served elements' own children are never enumerated.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous relationship read.
  - `maxReturnedRecords = 1`; `maxServedElementsCount = 32` (checked before extraction, never truncated); `maxServedElementMetadataLength = 256` per served-element title/identifier.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `role`, source `elementIdentifier`/`elementTitle`, and the bounded `servedElements` array (role/title/identifier per element) — never `kAXValueAttribute` content, never any content beyond bounded identity.
- **Classification**: bounded identity-only metadata — cannot expose credentials, OTPs, or payment data by construction; secure fields are excluded from both source and served-element roles via the reused role policy.
- **Verification evidence deliberately conservative**: durable `verifiedEvidence` and audit `executionSummary` carry only application/role identity, presence, and a count — never any served element's own title/identifier (proven against distinctive sentinel served-field identifiers in the test suite, tests 29/30).
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, and never reads `kAXValueAttribute`** — proven both structurally (0 matches in the forbidden-API audit) and by a real fixture's own fields remaining unmutated after the read (test 34).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, AppleScript, shell, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticLabelServedElementsReadTests.swift`)
45 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 72); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXElementReadRolePolicy` roles accepted unmodified, `AXSecureTextField` rejection proven both structurally and against a real fixture, wrong role rejected, missing-identity rejection, wrong-application-never-falls-back, missing/ambiguous target, stale target); AX read (single primary relationship read, no traversal, never `kAXValueAttribute` — structural); value validation (non-empty array, genuinely empty array as its own distinct valid state, absence-vs-empty distinction); malformed/invalid values (wrong outer CFType, non-`AXUIElement` element, disallowed-role served element, unreadable-role treated identically, oversized served-element metadata, genuine AXError failure, mixed valid/invalid array — all atomic, whole-array-closed); resource bounds (array exactly at the 32 maximum accepted, array above the maximum fails closed, no silent truncation, structural bound proof); privacy (durable evidence and audit records proven to carry ONLY conservative count/presence metadata, using distinctive sentinel served-field identifiers that never appear in evidence or audit); security (no mutation authority, disjoint authorization from `ui.set_text_value`, no approval state modified, `QResourceGuard` applies generically); verification (successful evidence, absence evidence, failure on unsuccessful result, independent rejection of a fabricated negative count); recovery (uncertain step fails closed to pending, no replay authorization); duplicate/identity (exact target identity enforced, no ambiguity acceptance); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; resource-bound/no-side-effect repeated-invocation test; real macOS AppKit E2E (TCC-guarded, real `NSTextField` label/input pair, forced deterministic relationship via the genuine `setAccessibilityServesAsTitleForUIElements` accessor round-tripping exactly, plus a second unattached fixture proving honest absence).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 45 constructs a real `NSTextField` label and a real `NSTextField` input (the structural inverse of `ui.read_element_title_reference`'s own established fixture) and forces a deterministic relationship via the real, declared `label.setAccessibilityServesAsTitleForUIElements([input])` — confirmed to round-trip correctly at the AppKit level even before any AX dispatch. A second, unattached fixture in the same test proves genuine absence is honestly reported (never a fabricated empty array conflated with "no relationship at all").

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented for the live `AXUIElementCopyAttributeValue` round-trip — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the live AX round-trip confirming `kAXServesAsTitleForUIElementsAttribute` reflects the forced AppKit-level relationship when read through the real Accessibility API. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test (test 43) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticLabelServedElementsReadTests`): 45/45 passed — first build attempt succeeded with no compile errors.
- **Related suites**: `QSemanticElementTitleReferenceReadTests`, `QSemanticElementValueDescriptionReadTests`, `QApplicationResolutionHardeningTests`, `QPersistenceSecurityTests`, `QPermissionGateTests`, `QActionVerificationTests`, `QPlanExecutionTests`, `QExecutionServiceTests`, `QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests` — combined 365/365, all green, zero regressions.
- **Stale hardcoded capability-count fix**: the first related-suite run failed on `QSemanticElementValueDescriptionReadTests.capabilityRegistrationAcceptsUIReadElementValueDescription()` — a **real regression**, not environmental: that Phase 2BW test hardcoded the total capability count at 71, now stale at 72. While fixing it, four other already-stale instances of the same issue were found (`QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, all hardcoded at 71) — all five updated to 72 (same strict equality assertion, no weakening). Verified in isolation (365/365) before retrying.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3759/3759 passed — clean, first try.
  - **Run 2**: 3759/3759 passed — clean, first try.
  - **Run 3**: initial attempt failed on `QSemanticApplicationHiddenStateTests.alreadyDesiredStateIsNoOpBothDirections()` (×2). **Classified ENVIRONMENTAL, not a regression**: file not touched anywhere in this phase's diff; isolated suite passed cleanly (31/31) immediately after, corroborated by `avconferenced` actively running (a real audio/video call on the shared dev machine) and elevated system load — the same root cause diagnosed in every prior phase since 2BO. Retry passed cleanly: 3759/3759.
  - No failure was ever converted to PASS by weakening; the one real regression found (stale capability-count literals) was fixed at its root cause, and the one environmental failure was diagnosed with concrete isolation + system-load evidence before being classified and retried.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact behavior of a live `AXUIElementCopyAttributeValue` round-trip against the forced `setAccessibilityServesAsTitleForUIElements` relationship could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level accessor round-trip was provable without TCC.
- A genuine `AXError` failure, a malformed (non-`CFArray`) returned value, an oversized array, a non-`AXUIElement` entry, a disallowed-role served element, or an oversized served-element metadata string cannot be constructed from any real, standard AppKit `NSTextField` pair — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
