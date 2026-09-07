# Phase 2BW — Semantic Element Value Description Read (`ui.read_element_value_description`)

## Overview
- **Capability Identifier**: `ui.read_element_value_description`
- **Capability Number**: #71
- **Tool Family**: `ui` (the returned field is a bounded semantic UI-metadata string, never arbitrary text content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `55f6a1d`
- **Pre-Phase Capability Count**: `70`
- **Post-Phase Capability Count**: `71`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.read_element_value` (Phase 2J/2K) reads a control's raw `kAXValueAttribute`, but that raw value is frequently uninterpretable on its own — the SDK's own canonical example is a color slider whose numeric position cannot be understood without its accompanying description ("Deep Blue"). `ui.read_element_value_description` closes this gap by reading exactly `kAXValueDescriptionAttribute`, never `kAXValueAttribute` itself.

---

## SDK Evidence
`kAXValueDescriptionAttribute` (`AXAttributeConstants.h`, full doc block: "Used to supplement kAXValueAttribute. This attribute returns a string description that best describes the current value... As an example, a color slider that adjusts thru various colors cannot be well-described by the numeric value... Value: A localized, human-readable CFStringRef. Writable? No. Recommended for elements that support kAXValueAttribute."). Modern accessor: `NSAccessibilityProtocols.h`, `@property (nullable, copy) NSString *accessibilityValueDescription API_AVAILABLE(macos(10.10))` — real, declared, settable, confirmed compiled correctly on the first build attempt (`slider.setAccessibilityValueDescription("Deep Blue")`/`slider.accessibilityValueDescription()`).

---

## Semantic Contract & Target Role Policy
Target roles are restricted to `QAXElementReadRolePolicy` — reused **completely unmodified**, the identical allowlist `ui.read_element_value`/`ui.list_element_actions` already use, including the identical secure-field-first-then-general-allowlist discipline: `AXSecureTextField` is rejected with a dedicated `secureFieldReadDenied` diagnostic before the general allowlist is ever consulted (belt and suspenders — `AXSecureTextField` is never listed in the allowlist either). This capability never broadens role access and never reads secure-field content.

**Naming note**: the resolver is deliberately named `resolveElementValueDescription` — **not** `axValueDescription`, which is a pre-existing, unrelated, polymorphic `kAXValueAttribute` reader already used internally by `ui.read_element_value` (found during fresh architecture inspection at implementation time). The two are never confused: `axValueDescription` reads the raw *value* as a display string; this capability reads the SDK's own distinct, dedicated *description-of-the-value* attribute.

---

## Absence vs. Empty — the Optional-Reference Pattern
`kAXValueDescriptionAttribute` carries no "required for all elements of this role"-style documentation — the doc says only "Recommended for elements that support kAXValueAttribute," implying many value-bearing controls legitimately lack it:

| Condition | Treatment |
|---|---|
| `kAXValueDescriptionAttribute` absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | Whole result `nil` — genuine, expected absence |
| `kAXValueDescriptionAttribute` present, string has 0 characters | Valid, non-nil result with `valueDescription == ""` — never converted to failure or absence merely because it's unusual |
| Any other `AXError` | Fails closed — `AX_VALUE_DESCRIPTION_READ_FAILED` |
| Wrong CFType (not a `String`) | Fails closed — `AX_VALUE_DESCRIPTION_MALFORMED` — the returned value is never force-cast |
| String exceeds `maxValueDescriptionLength` (256) | Fails closed — `AX_VALUE_DESCRIPTION_EXCEEDS_SAFE_BOUND`, never silently truncated |

A genuinely present but empty string is a fully valid, distinct result — proven directly in the test suite (tests 14, 17).

---

## Target Resolution & Fail-Closed Gates
Identical shape to every prior Level 0 read: secure-field check → role-policy check → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift.

---

## Result Contract
`QAXElementValueDescriptionMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The caller-supplied, policy-validated target role. |
| `elementIdentifier` | `String?` | The resolved element's own identifier, if any. |
| `elementTitle` | `String?` | The resolved element's own title, if any. |
| `valueDescription` | `String` | Bounded, validated string — may legitimately be empty. |

The overall bridge function returns `QAXElementValueDescriptionMetadata?` — `nil` represents genuine attribute absence; non-nil is always a fully validated string (possibly empty). No `AXUIElement`, no coordinates, no raw CF object, no unrelated attribute, and — critically — **never `kAXValueAttribute`'s own content** ever appears in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementValueDescriptionReadSucceeded(applicationName:role:elementIdentifier:elementTitle:hasValueDescription:valueDescription:)`
- **Evaluation**: independently re-validates the claimed string is present and within the same 256-character bound `resolveElementValueDescription` itself enforces — never trusts the executor's own `success` flag alone, mirroring `tableDimensionsReadSucceeded`'s/`elementAllowedValuesReadSucceeded`'s identical independent-recheck discipline. A fabricated `success == true` claiming a nil or oversized value description is still correctly rejected (tests 35/36).
- **Absence as its own valid outcome**: `hasValueDescription == false` is verified directly as `evidence: "...valueDescription=unavailable status=verified"` — never conflated with a present-but-empty string.
- **Evidence**: application identity, element identity, and the value-description string itself are safe to include directly — bounded semantic UI metadata, the same sensitivity class as an already-exposed title/help string, per this capability's own explicit privacy contract (unlike, e.g., `ui.read_element_title_reference`'s more conservative identity-only evidence design, which concerned an *arbitrary referenced element's* content rather than a bounded, SDK-documented value supplement).

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`. Observing a value description grants zero authorization for `ui.set_text_value`/`ui.set_slider_value`/`ui.step_incrementor`/`ui.set_element_state` — independently re-verified as disjoint decisions (test 30).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — no value-description string is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1`; `maxAXAttributesRead = 1` (`kAXValueDescriptionAttribute` only — never `kAXValueAttribute`); `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous call.
  - `maxReturnedRecords = 1`; `maxValueDescriptionLength = 256` (a distinct constant from `maxActionNameLength`/`maxAttributeNameLength`/`maxWindowButtonMetadataLength`, per this codebase's existing convention of not sharing bound constants across unrelated capabilities even when the numeric value is identical).

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `role`, `elementIdentifier`, `elementTitle`, and the bounded `valueDescription` string — never `kAXValueAttribute` content, never table/cell/credential content.
- **Classification**: bounded semantic UI metadata, the same sensitivity class as an already-exposed title/help string — not arbitrary text extraction. Cannot expose credentials, OTPs, or payment data by construction, since secure fields are excluded via the reused role policy and this attribute is SDK-scoped to short descriptive labels, never free-form user-entered content.
- **Must never be persisted beyond identity**: durable `verifiedEvidence` and audit `executionSummary` carry only application identity, element identity, and the bounded string.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, and never reads `kAXValueAttribute`** — proven both structurally (0 matches in the forbidden-API audit) and by a real fixture's own slider value remaining unmutated after the read (test 29).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, AppleScript, shell, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticElementValueDescriptionReadTests.swift`)
40 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 71); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXElementReadRolePolicy` roles accepted unmodified, `AXSecureTextField` rejection proven both structurally and against a real fixture, wrong role rejected, missing-identity rejection, wrong-application-never-falls-back, missing/ambiguous target, stale target); AX read (single-attribute, no traversal, never `kAXValueAttribute` — structural); value validation (non-empty string, genuinely empty string as its own distinct valid state, absence-vs-empty distinction); malformed/invalid values (wrong CFType never force-cast, genuine AXError failure); string bound (exactly-at-maximum accepted, one-above-maximum fails closed, no silent truncation); privacy (durable evidence and audit records proven to carry only bounded semantic metadata, using distinctive sentinel slider identifiers); security (no mutation authority, disjoint authorization from `ui.set_text_value`/`ui.set_slider_value`/`ui.step_incrementor`/`ui.set_element_state`, no approval state modified); verification (successful evidence, absence evidence, failure on unsuccessful result, independent rejection of fabricated nil/oversized values); recovery (uncertain step fails closed to pending, no replay authorization); duplicate/identity (exact target identity enforced, no ambiguity acceptance); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; resource-bound/no-side-effect repeated-invocation test; real macOS AppKit E2E (TCC-guarded, real `NSSlider`, forced deterministic value via the genuine `setAccessibilityValueDescription` accessor round-tripping exactly).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 40 constructs a real `NSSlider` (the same fixture shape `ui.read_element_range`'s/`ui.read_element_allowed_values`'s own E2E tests established) and forces a deterministic value via the real, declared `slider.setAccessibilityValueDescription("Deep Blue")` — confirmed to round-trip correctly at the AppKit level (`slider.accessibilityValueDescription() == "Deep Blue"`) even before any AX dispatch. This is the **third capability this session with a genuine forced-value native accessor for the exact attribute being read** (after `ui.read_table_dimensions`, Phase 2BU, and `ui.read_element_allowed_values`, Phase 2BV).

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented for the live `AXUIElementCopyAttributeValue` round-trip — never fabricated as a real-world pass. What could not be empirically exercised in this environment: the live AX round-trip confirming `kAXValueDescriptionAttribute` reflects the forced AppKit-level string when read through the real Accessibility API. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test (test 38) remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticElementValueDescriptionReadTests`): 40/40 passed — first build attempt succeeded with no compile errors (the plain `NSString`-backed `accessibilityValueDescription` property, unlike Phase 2BT's `NS_TYPED_ENUM` naming surprise, resolved correctly on the first try).
- **Related suites**: `QSemanticElementRangeReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementTitleReferenceReadTests`, `QSemanticElementRequiredStateTests`, `QSemanticElementProtectedContentStateReadTests`, `QApplicationResolutionHardeningTests`, `QPermissionGateTests`, `QPersistenceSecurityTests`, `QActionVerificationTests`, `QPlanExecutionTests`, `QExecutionServiceTests`, `QSemanticColumnSortDirectionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests` — combined 424/424, all green, zero regressions.
- **Stale hardcoded capability-count fix**: the first related-suite run failed on `QSemanticElementAllowedValuesReadTests.capabilityRegistrationAcceptsUIReadElementAllowedValues()` — a **real regression**, not environmental: that Phase 2BV test hardcoded the total capability count at 70, now stale at 71. While fixing it, three other already-stale instances of the same issue were found (`QSemanticColumnSortDirectionReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`, each hardcoded at 70) — all four updated to 71 (same strict equality assertion, no weakening). Verified in isolation (424/424) before retrying.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3714/3714 passed — clean, first try.
  - **Run 2**: initial attempt failed on `QSemanticApplicationHiddenStateTests.recoveryRecognizesAlreadyDesiredAsComplete()` (×4). **Classified ENVIRONMENTAL, not a regression**: file not touched anywhere in this phase's diff; isolated suite passed cleanly (31/31) immediately after, corroborated by `avconferenced` actively running (a real audio/video call on the shared dev machine) and elevated system load — the same root cause diagnosed in Phases 2BO/2BQ/2BS/2BU/2BV. Retry passed cleanly: 3714/3714.
  - **Run 3**: 3714/3714 passed — clean.
  - No failure was ever converted to PASS by weakening; the one real regression found (stale capability-count literals) was fixed at its root cause, and the one environmental failure was diagnosed with concrete isolation + system-load evidence before being classified and retried.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact behavior of a live `AXUIElementCopyAttributeValue` round-trip against the forced `setAccessibilityValueDescription` string could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level accessor round-trip was provable without TCC.
- A genuine `AXError` failure, a malformed (non-`String`) returned value, or an oversized (>256 character) value description cannot be constructed from any real, standard AppKit `NSSlider` — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
