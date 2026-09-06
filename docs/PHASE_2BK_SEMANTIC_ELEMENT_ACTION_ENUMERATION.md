# Phase 2BK — Semantic Element Action Enumeration (`ui.list_element_actions`)

## Overview
- **Capability Identifier**: `ui.list_element_actions`
- **Tool Family**: `ui` (action names are structural UI-affordance labels — the same class of content `identifier`/`title` metadata already carries under `ui` without redaction — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `fad56c1`
- **Pre-Phase Capability Count**: `58`
- **Post-Phase Capability Count**: `59`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions performed.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: every existing mutation capability hard-codes a specific action (`kAXPressAction`/`kAXIncrementAction`/`kAXDecrementAction`) chosen per-role by the implementation. No capability has ever asked an element what actions it *actually* supports — including app-defined custom actions (via `NSAccessibilityCustomAction`) no fixed role-based policy could anticipate. This capability observes, and only observes, an element's action vocabulary via `AXUIElementCopyActionNames` — a distinct C API this codebase has never used before.

---

## Security-Critical Invariant — Data, Not Authorization
**The returned action names are DATA, not AUTHORIZATION.** This capability never calls `AXUIElementPerformAction`. Discovering that an action name like `"AXPress"` or `"Reply"` exists never itself grants any capability, creates any approval, establishes any standing grant, or authorizes any future action. A subsequent request to actually perform an action (e.g., `ui.click_element`) must independently pass its own full capability/risk/approval/execution-identity pipeline through `QPermissionGate`, completely unaffected by `ui.list_element_actions` ever having been called. This is proven directly in the test suite (test 17): calling this capability and observing `"AXPress"` has zero effect on `ui.click_element`'s own, entirely separate `QPermissionGate` evaluation, which still requires approval exactly as before.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, Phase 2J — no broader, arbitrary-role allowlist was introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.read_element_value`.
- **AX API**: `AXUIElementCopyActionNames(targetElement, &actionNamesValue)` — a single, purely observational call. `AXUIElementCopyActionDescription` (localized action descriptions) is **deliberately excluded from this contract**, exactly as the approved discovery document proposed — action descriptions are potentially longer, app-authored free text with a materially different privacy profile than the short, fixed-vocabulary-or-custom-label action names themselves.
- **Mutation primitives**: none. `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual usages; every string match is a documentation comment explicitly disclaiming the API).

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders, identical to `ui.read_element_value`): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the action-name read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **Malformed-collection check**: `AXUIElementCopyActionNames`'s returned value is treated as untrusted external data — a successful copy result that fails to cast to `[String]` → `AX_ACTION_NAMES_COLLECTION_MALFORMED` (mirrors `ui.list_windows`'s own `windowsCollectionMalformed` discipline).
8. **Bound enforcement**: the returned collection's size is checked against `maxElementActionsCount` (16) *before* returning — exceeding it → `AX_ACTION_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND`, never silently truncated. Each individual action name is checked against `maxActionNameLength` (256 characters) — exceeding it → `AX_ACTION_NAME_EXCEEDS_SAFE_LENGTH`, whose error carries only the offending *length*, never the string content itself, so even the failure path cannot leak an oversized value.

---

## Output Contract
`QAXElementActionsMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | Echoed from the caller's own input. |
| `actionNames` | `[String]` | Bounded to at most 16 entries, each individually length-bounded. |

No `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type (proven by a compile-time-enforced test, mirroring every prior phase's identical proof technique).

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementActionsReadSucceeded(applicationName: String, role: String, actionCount: Int)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.listElementActions`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, **and additionally independently re-validates `actionCount` is within `[0, 16]`** — a defense-in-depth check that never blindly trusts the dispatch layer already enforced it, proven directly by test 25 (a fabricated `success: true` result carrying an out-of-bound count is still correctly rejected). Never a bare `{ true }`; never executes any discovered action as part of verifying the read.
- **Evidence**: `application=<name> role=<role> actionCount=<n> status=verified` (or `status=failed`) — never any individual action-name string.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite, and proven *independent* of `ui.click_element`'s own, entirely separate Level 2 approval requirement (test 17).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects; no individual action-name string is ever persisted into any field a recovery replay could read back (test 23).
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxElementsTouched = 1` — the one resolved element only.
  - `maxTraversalDepth = 0` — no descent beyond the resolved element; `kAXChildrenAttribute` is never read.
  - `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0` — a single synchronous call; no loop, no `Task.sleep`.
  - `maxReturnedRecords = 16` action-name strings, each individually capped at 256 characters.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary** (returned to the model for immediate use): the bounded list of action-name strings and an aggregate count — structural UI-affordance labels, never user-entered content, never typed values.
- **Must never be persisted beyond identity + count**: individual action-name strings are deliberately excluded from durable verification evidence, audit `executionSummary` text, memory, and recovery/replan state — proven directly in the test suite against a distinctively-named custom action string that would be unmistakable if it leaked (tests 21, 22, 23).
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing exclusion of `AXSecureTextField` verbatim — no secure field can ever be a valid target for this capability, exactly as for `ui.read_element_value`.
- **No durable pointer/content leaks**: `QAXElementActionsMetadata`'s stored properties are `String`/`String`/`[String]` only — no `AXUIElement`-typed field exists anywhere in its declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages; every string match across the entire diff is a documentation comment explicitly disclaiming the corresponding API, e.g. *"never `AXUIElementPerformAction`"*).

---

## Test Coverage (`QSemanticElementActionEnumerationTests.swift`)
33 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero/ambiguous application match; exact element match (by identifier and title); zero/ambiguous element match; unsupported role and secure-field rejection (`QAXElementReadRolePolicy` reused verbatim); successful enumeration of a standard `AXPress` action; zero supported actions is a valid empty result; multiple standard actions all reported distinctly; a real `NSAccessibilityCustomAction` ("Reply") observed alongside the standard `AXPress` action; malformed/unreadable collection fails closed (structural); action count at the 16-entry bound accepted; action count exceeding the bound fails closed, never truncated; per-action-name length bound enforced without leaking the oversized string into the error itself; **`AXUIElementPerformAction` is never called**, proven both structurally and via a real fixture whose press-counter target remains at zero after enumeration; discovered action names never authorize `ui.click_element`'s own, entirely separate approval requirement; `QPermissionGate` never requires approval for this capability; a full runtime submission completes without halting for approval; no persistent authorization is ever constructed; no raw `AXUIElement` escapes (compile-time proof); individual action names absent from durable-plan snapshots, audit records, and recovery/replan state (three dedicated tests against a distinctively-named custom action); evidence-based verification success/failure contents, including independent re-validation of the count bound even against a fabricated "successful" result; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural); no polling/traversal (structural); real macOS E2E (TCC-guarded, `NSButton` + `NSAccessibilityCustomAction`, with an independent flag proving the custom action's own handler was never invoked).

---

## Real macOS E2E — Known Environmental Limitation
Test 30 builds two real fixtures: a plain `NSButton` (expected to report `["AXPress"]`) and a second `NSButton` with a real `NSAccessibilityCustomAction` named `"Reply"` attached via `setAccessibilityCustomActions(_:)` (expected to report both `"AXPress"` and `"Reply"`) — with the custom action's own handler closure setting a local flag if ever invoked, independently proving no execution occurred. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created two windows and performed real AX round-trips. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BJ) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementActionEnumerationTests`): 33/33 passed.
- **Related suites**: `QSemanticElementReadTests` 18/18, `QSemanticFocusedElementReadTests` 33/33, `QApplicationResolutionHardeningTests` 27/27, `QSemanticElementRangeReadTests` 31/31 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3229/3229, 3229/3229, 3229/3229 — no flakes, no regressions, no environmental failures.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- `AXUIElementCopyActionDescription` (localized, human-readable action descriptions) is deliberately excluded from this v1 contract, exactly as the approved discovery document proposed — a future phase could add it as an enrichment if a real fixture confirms its content stays within an acceptable, structural-not-arbitrary privacy profile.
- An element reporting more than 16 actions, a malformed action-names collection, or an oversized individual action-name string cannot be constructed from any real, standard AppKit control — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting.
