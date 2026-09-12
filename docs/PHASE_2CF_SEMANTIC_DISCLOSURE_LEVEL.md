# Phase 2CF — Semantic Element Disclosure Level Read (`ui.read_element_disclosure_level`)

## Overview
- **Capability Identifier**: `ui.read_element_disclosure_level`
- **Capability Number**: #80
- **Tool Family**: `ui` (the returned `disclosureLevel` integer is structural UI-hierarchy metadata — never free-form typed content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `ac4fe5a2447db84895ff133edeef996c0ec93fd1` (Phase 2CE, `ui.read_element_expanded_state`)
- **Pre-Phase Capability Count**: `79`
- **Post-Phase Capability Count**: `80`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability lets an agent determine an outline row's nesting depth — a real, common need when navigating hierarchical UI (Finder's sidebar, Xcode's project navigator, any source list) without recursively walking `kAXParentAttribute` chains itself. Complements `ui.read_element_expanded_state` (Phase 2CE — "is this row currently open") and the existing `ui.list_outline_items`/`ui.select_outline_row` capabilities. `kAXDisclosureLevelAttribute` had zero references anywhere in production prior to this phase.

---

## Discovery — Candidates Compared
Seven candidates were evaluated against the full unused-attribute sweep of `AXAttributeConstants.h` (152 total `kAX*Attribute` constants, 61 already in use):
- **`kAXDisclosureLevelAttribute`** — selected (see below).
- `kAXElementBusyAttribute` — real semantic value (avoid acting on loading UI) but no declared AppKit accessor found, weaker native-E2E feasibility.
- `kAXValueWrapsAttribute` — narrow applicability (`AXIncrementor`/`AXStepper` only).
- `kAXIsEditableAttribute` — rejected outright: Apple's own SDK header lists it under `// obsolete/unknown attributes`.
- `kAXURLAttribute` — rejected: dynamic, user-navigated content can carry session tokens/auth material in query strings, the same privacy class already excluded for `kAXSelectedTextAttribute`.
- `kAXFilenameAttribute` — rejected: filesystem paths/filenames can embed personal/sensitive information.
- `kAXPositionAttribute`/`kAXSizeAttribute` — rejected outright: raw screen coordinates directly conflict with this codebase's foundational "coordinates are never accepted" doctrine.

---

## SDK Evidence
`kAXDisclosureLevelAttribute` (`AXAttributeConstants.h`): `#define kAXDisclosureLevelAttribute CFSTR("AXDisclosureLevel")` — a plain HIServices macro, part of the same disclosure/outline attribute cluster as `kAXDisclosingAttribute`/`kAXDisclosedRowsAttribute`/`kAXDisclosedByRowAttribute`. AppKit's own declared accessor pair: `setAccessibilityDisclosureLevel(_:)`/`accessibilityDisclosureLevel()` (`NSAccessibilityProtocols.h`, `API_AVAILABLE(macos(10.10))`, doc: "indentation level"). Like `kAXExpandedAttribute`, the HIServices header carries no dedicated per-attribute doc-comment — absence semantics rely on the general SDK convention plus AppKit's own accessor documentation.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXOutlineRowRolePolicy` (`AXRow`) — the **same** dedicated, narrow role policy `ui.select_outline_row` (Phase 2T) already established, reused completely unmodified. This is a deliberate departure from `ui.read_element_help_text`/`ui.read_element_placeholder_value`/`ui.read_element_expanded_state`'s shared `QAXElementReadRolePolicy`: `AXRow` was never on that allowlist (it's meaningful for leaf controls, not table/outline rows), so reusing the existing outline-row-specific policy — rather than inventing a new one or broadening the generic allowlist — is the architecturally correct, minimal-footprint choice.

**Deliberately unlike `ui.select_outline_row`**: this read does **not** additionally require the `AXOutlineRow` subrole or an `AXOutline` parent context. A mutation on the wrong kind of row would be real, silent misbehavior; a read of an ordinary `AXRow` that is not genuinely an outline row simply, honestly reports genuine attribute absence (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) — a valid, expected `nil`, never a fabricated depth. This mirrors the "let the real AX data honestly speak for itself" philosophy every other optional-reference read capability in this codebase already follows.

---

## Fail-Closed Semantics — Optional-Reference Pattern (Identical to `ui.read_element_expanded_state`)

| Condition | Treatment |
|---|---|
| Missing `identifier`/`title` | Fails closed — `AX_MISSING_MATCH_CRITERIA` |
| Disallowed role (anything but `AXRow`) | Fails closed — `disallowedOutlineRowRole` / `AX_DISALLOWED_OUTLINE_ROW_ROLE` |
| Accessibility permission not granted | Fails closed — `AX_PERMISSION_DENIED` |
| Zero/ambiguous application or target matches | Fails closed — `AX_APPLICATION_NOT_AVAILABLE` / `AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET` |
| Target identity drifts between search and read | Fails closed — `AX_STALE_TARGET` |
| Attribute genuinely absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | **Valid, expected** — `nil`, never an error, never downgraded to `0` |
| Any other non-`.success` `AXError` | Fails closed — `AX_ELEMENT_DISCLOSURE_LEVEL_READ_FAILED` |
| Returned value not a genuine integer `CFNumber` (including floating-point subtypes) | Fails closed — `AX_ELEMENT_DISCLOSURE_LEVEL_MALFORMED` |
| Returned integer negative, or overflows Swift `Int` | Fails closed — `AX_ELEMENT_DISCLOSURE_LEVEL_INVALID` |

Three new `QAXInteractionError` cases were added (`elementDisclosureLevelReadFailed`, `elementDisclosureLevelMalformed`, `elementDisclosureLevelInvalid`) — the `Malformed`/`Invalid` split mirrors `ui.read_table_dimensions`'s (`resolveTableCount`) exact rigor for decoding a `CFNumber` into a validated non-negative `Int`, combined with the optional-absence discipline every prior Phase 2CC/2CD/2CE capability establishes.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.select_outline_row`'s own pre-mutation resolution (minus the subrole/parent-context gates, per the design decision above): role-policy check (`QAXOutlineRowRolePolicy`) → match-criteria check → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXRow` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the read → `AX_STALE_TARGET` on drift → the single `kAXDisclosureLevelAttribute` read against the re-verified element.

---

## Result Contract
`QAXElementDisclosureLevelMetadata` (new type, `QBridgeAdapters.swift`), modeled on `QAXElementRequiredStateMetadata`'s/`QAXElementExpandedStateMetadata`'s 3-field shape:

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's own search role (`AXRow`). |
| `disclosureLevel` | `Int?` | `nil` = genuine absence (valid); a non-negative `Int` = a definite, directly-observed nesting depth, never conflated with `nil`. |

---

## Privacy Boundary
Only `disclosureLevel` (a single bounded, non-negative integer) plus non-sensitive targeting identity (`applicationName`, `role`) crosses the bridge. No field content, no document text, no coordinates, no raw `AXUIElement`. `kAXValueAttribute` is never read anywhere in this capability.

---

## Resource Contract
- `maxTargetsResolved = 1`
- `maxRelationshipHops = 0`
- `maxPrimaryAXReads = 1` (`kAXDisclosureLevelAttribute` only)
- `maxTraversalDepth = 0`
- `maxActionsPerformed = 0`
- `maxPolling = 0`, `maxRetries = 0`
- `maxReturnedRecords = 1`

**Exact implementation locations**:
- Target resolution: `QBridgeAccessibility.readElementDisclosureLevel` (`QBridgeAdapters.swift`, reuses `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` — all pre-existing, shared with every sibling capability)
- `kAXDisclosureLevelAttribute` read + `CFNumber` decode: `resolveElementDisclosureLevel(of:)` (`QBridgeAdapters.swift`), mirroring `resolveTableCount`'s exact integer-subtype validation, `sInt64Type` extraction, non-negativity check, and overflow-safe `Int(exactly:)` conversion
- Resource guard: generic `QResourceGuard.validate` at the top of `QExecutionService.executeAction` (applies uniformly; this capability sets no `targetResources`)
- Verification: `QVerificationStrategy.elementDisclosureLevelReadSucceeded` evaluate arm (`QActionVerification.swift`)

No hidden traversal, polling, or retries — confirmed by direct source inspection: `resolveElementDisclosureLevel(of:)` makes exactly one `AXUIElementCopyAttributeValue` call and never loops.

---

## Verification
New `QVerificationStrategy` case: `.elementDisclosureLevelReadSucceeded(applicationName:role:hasDisclosureLevel:disclosureLevelRaw:)`. Unlike the Boolean-typed `elementExpandedStateReadSucceeded`/`elementRequiredStateReadSucceeded` (which carry no independently-checkable invariant), this strategy carries the **raw claimed string** (not a pre-parsed `Int`) specifically so `evaluate` can perform its own independent parse-and-bounds-check re-validation — mirroring `elementHelpTextReadSucceeded`'s/`elementPlaceholderValueReadSucceeded`'s String-length-bound re-check discipline, applied to an integer's non-negativity instead. A fabricated success claiming a non-numeric or negative depth is still correctly rejected (proven directly in the test suite, tests 29/29b/29c). This performs **no additional AX read** — confirmed by direct source inspection of `determineVerificationStrategy` (`QPlanExecutor.swift`), which reconstructs the strategy's fields entirely from `action.arguments`/`result.outputData`.

---

## Recovery
Level 0, read-only — `QTaskRecoveryManager`'s uncertain-step switch has no special case for `ui.read_element_disclosure_level` (identical to every other Level 0 read capability): an uncertain in-flight step falls through to the generic `verified = false` branch and is marked `pending`, safely re-executable exactly once. No approval state, no standing authorization, no raw AX object is ever persisted — `QDurablePlanStepSnapshot` carries only `arguments`, never `outputData`.

---

## Tests
`leanring-buddyTests/QSemanticElementDisclosureLevelReadTests.swift` — 46 focused tests, mirroring `ui.read_element_required_state`'s/`ui.read_element_expanded_state`'s test structure adapted for the `AXRow` target and `Int?` type (registration, permission gate/denial, target validation via `QAXOutlineRowRolePolicy` including the explicit "ordinary row without outline context is still accepted at the role gate" proof, missing/wrong-application/missing/ambiguous target, stale-target structural note, happy-path non-zero and zero depths, genuine-absence-never-fabricated-as-zero, malformed/invalid/genuine-AXError diagnostics, security disjoint-authorization proof, recovery, privacy — durable-evidence and audit-record sentinel-content-free proofs, verification success/absence/failure/fabrication-rejection evidence (including the negative-value and non-numeric fabrication-rejection tests unique to this Int-typed capability), `QPlanExecutor` pipeline integration, forbidden-API/resource-bound structural proofs, and capability-count integrity). Plus one real macOS AppKit E2E test (TCC-guarded) using a real `AXRow`-role fixture built on `NSButton`, exercising both a non-zero and a zero disclosure level, cross-validated against the control's own `accessibilityDisclosureLevel()` accessor.

All 13 pre-existing test files that hardcoded the total capability count at 79 were updated to 80 (same strict equality assertion, no weakening; explanatory comments updated to list all contributing phases through 2CF).

---

## Native E2E / TCC Status
One real macOS AppKit E2E test, TCC-guarded exactly like every prior semantic E2E test in this codebase (`guard AXIsProcessTrusted() else { return }` — honest `BLOCKED BY ENVIRONMENT`, never a fabricated pass): a real `NSButton`-backed `AXRow`-role fixture's disclosure level is forced via the genuine, declared `setAccessibilityDisclosureLevel(_:)` AppKit accessor pair, then resolved via `kAXDisclosureLevelAttribute` through the actual AX path — **cross-validated** against the same control's own `accessibilityDisclosureLevel()` accessor read independently, never a mock. Both a non-zero (3) and a zero (top-level) depth are exercised.

In this sandboxed CI/test-runner environment, `AXIsProcessTrusted()` returned `false`, so the E2E test correctly reported **BLOCKED BY ENVIRONMENT** rather than a fabricated pass — consistent with every prior phase's identical environmental limitation.

---

## Security Audit
Diff inspected for forbidden APIs: `CGEvent`, `CGEventPost`, `CGEventCreateKeyboardEvent`, `CGEventCreateMouseEvent`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `kAXValueAttribute`, `URLSession`, `curl`, `http://`/`https://` — **zero actual invocations** anywhere in the new/modified production code (doc comments only ever mention these names to assert their absence). `readElementDisclosureLevel`/`resolveElementDisclosureLevel` call only `AXUIElementCopyAttributeValue` (read-only, targeting `kAXDisclosureLevelAttribute` exclusively) plus the pre-existing, unmodified shared resolution helpers. No new mutation authority, standing approval, or approval-state mechanism was introduced — `ui.read_element_disclosure_level` is routed through `QPermissionGate` as Level 0 default-allow, structurally identical to every other Level 0 read capability, and proven disjoint from `ui.select_outline_row`'s own Level 2 approval requirement.

## Privacy Audit
The only AX content read by this capability's implementation is `kAXDisclosureLevelAttribute` — confirmed via direct source inspection, `resolveElementDisclosureLevel(of:)` makes exactly one `AXUIElementCopyAttributeValue` call. `kAXValueAttribute` is never read. No raw `AXUIElement`/CF object crosses `QAXElementDisclosureLevelMetadata`'s boundary. Returned data is the bounded `disclosureLevel` integer plus non-sensitive targeting identity only.

---

## Build/Signing
`scripts/prepare-release.sh` — isolated Release build (ad-hoc signed, no version bump, no publishing):
- **BUILD SUCCEEDED**
- Mach-O architecture: `arm64` (confirmed via `file`)
- `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement
- Entitlements: unchanged (`git diff --stat -- '*.entitlements'` — zero matches, since the initial commit)

---

## Environmental Findings This Phase
- **Genuine deadlock encountered and resolved (not a Phase 2CF defect)**: one full-regression attempt hung for 3+ hours with `xcodebuild` and the `Pace` test-host both parked in `mach_msg`. Diagnosis (via `sample`) traced the test-host's main thread to a pathologically deep recursive deallocation inside Apple's private `TextToSpeech.framework`, reached through a `Combine`/`@Published` property setter's `deinit` cascade, following 159+ failed local TTS connection attempts (`http://127.0.0.1:*/v1/audio/speech` — the Kokoro/LM Studio sidecar correctly not running). The stuck call stack never entered any AX/outline/disclosure-level code. Only the hung process chain was terminated (`kill -9` on the test-host, `xcodebuild`, and the wrapper script); no code or test was modified in response. Root cause: `PaceLMStudioModelLoader.warmUpConfiguredModelsAsync()` (`leanring_buddyApp.swift:118`) fires unconditionally, before the existing `isRunningAsUnitTestHost` gate is even computed — a pre-existing gap in test-host isolation, not introduced by this phase and explicitly left unmodified per instruction not to invent a production behavior change to chase a test-environment issue.
- The already-documented pre-existing AppKit-teardown-race class (commit `bc6c5e2`) continued to surface intermittently across this phase's regression attempts, always in files this phase never touches (`QSemanticWindowCloseTests`, `QSemanticApplicationHiddenStateTests`) — each instance individually inspected and confirmed unrelated before retrying. No test was weakened, skipped, or modified to obtain a green result; three fully clean consecutive runs were eventually achieved through safe retries alone.
