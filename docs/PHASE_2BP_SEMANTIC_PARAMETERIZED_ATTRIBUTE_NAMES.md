# Phase 2BP — Semantic Element Parameterized Attribute Name Enumeration (`ui.list_element_parameterized_attribute_names`)

## Overview
- **Capability Identifier**: `ui.list_element_parameterized_attribute_names`
- **Tool Family**: `ui` (parameterized attribute names are a near-fixed, short structural vocabulary defined by Apple's own AX API — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `a126a2d`
- **Pre-Phase Capability Count**: `63`
- **Post-Phase Capability Count**: `64`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions, zero parameterized-attribute VALUE invocations.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_element_actions` (Phase 2BK) reads an element's supported ACTION names via `AXUIElementCopyActionNames`; `ui.list_element_attributes` (Phase 2BL) reads its supported plain ATTRIBUTE names via `AXUIElementCopyAttributeNames`. This capability is the third and final sibling in that "what can I ask this element" enumeration family — it reads an element's supported PARAMETERIZED attribute names (queries requiring a parameter, e.g. `AXCellForColumnAndRow` on a table, `AXLineForIndex` on a text element) via the parallel `AXUIElementCopyParameterizedAttributeNames`. Confirmed by direct grep: zero usage of this function anywhere in the codebase prior to this phase, despite being available and documented since macOS 10.3.

---

## Security-Critical Invariant — Data, Not Authorization
**Discovered parameterized attribute names are DATA, not AUTHORIZATION.** This capability never invokes any parameterized attribute merely because its name was discovered — it calls only `AXUIElementCopyParameterizedAttributeNames`, never `AXUIElementCopyParameterizedAttributeValue` for any of the returned names, never `AXUIElementSetAttributeValue`, never `AXUIElementPerformAction`. Discovering that `"AXLineForIndex"` is a supported parameterized attribute name never itself grants any capability, approval, or standing authority to invoke it. Any future capability that actually invokes a parameterized attribute must independently pass its own full capability/risk/approval/execution-identity pipeline, completely unaffected by `ui.list_element_parameterized_attribute_names` ever having been called — no such invocation capability exists yet in this codebase.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, Phase 2J — no broader, arbitrary-role allowlist was introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.list_element_attributes`/`ui.list_element_actions`.
- **AX API**: `AXUIElementCopyParameterizedAttributeNames(targetElement, &parameterizedAttributeNamesValue)` — a single, purely observational call.
- **Mutation primitives**: none. `AXUIElementCopyParameterizedAttributeValue` (for any discovered name), `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual non-comment usages).
- **Duplicate handling**: the returned array is passed through exactly as the OS reports it — never deduplicated, matching `ui.list_element_attributes`'s identical discipline.
- **Result contract field naming**: deliberately matches the established `role` field name used by `QAXElementActionsMetadata`/`QAXElementAttributeNamesMetadata` (not `elementRole`) — architecture-consistency was prioritized over the discovery-preview's originally-sketched field name, per the approved implementation instruction to check existing architecture first and not introduce inconsistency.

---

## Bound Reuse — A Deliberate Non-Duplication Decision
Per the approved implementation contract, this capability reuses `maxElementAttributesCount` (32) and `maxAttributeNameLength` (256) verbatim from `ui.list_element_attributes` rather than minting new, duplicate constants — parameterized attribute names are a sibling enumeration surface to plain attribute names (both drawn from the same conceptual "how many names can an AX element reasonably report" question), not a distinct category warranting its own bound. This was an explicit instruction ("إذا كان هناك حد مناسب موجود، أعد استخدامه. لا تضف duplicate constant بدون سبب") and is documented here as a deliberate architectural decision, not an oversight.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the parameterized-attribute-name read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **AXError handling** (see the dedicated section below for the full rationale): `kAXErrorAttributeUnsupported`/`kAXErrorParameterizedAttributeUnsupported`/`kAXErrorNotImplemented` → a valid, expected EMPTY result; any other `AXError` → `AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED`.
8. **Malformed-collection check**: a successful copy result that fails to cast to `[String]` → `AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED` (the same error case that non-success `AXError`s map to — both represent "the collection could not be trusted").
9. **Bound enforcement**: the returned collection's size is checked against `maxElementAttributesCount` (32) *before* returning — exceeding it → `AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND`, never silently truncated. Each individual name is checked against `maxAttributeNameLength` (256 characters) — exceeding it → `AX_PARAMETERIZED_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH`, whose error carries only the offending *length*, never the string content itself.

---

## AX Error Semantics — Unsupported Is Valid, Never Silently Confused With Failure
Unlike `ui.list_element_actions`/`ui.list_element_attributes` (which treat any non-success `AXError` from their respective copy calls as `...CollectionMalformed`), this capability makes a deliberately different, explicitly-specified choice: `AXUIElementCopyParameterizedAttributeNames`'s own SDK documentation lists `kAXErrorAttributeUnsupported or kAXErrorParameterizedAttributeUnsupported` together as one semantic outcome (the element does not support the requested parameterized-attribute query), and the approved implementation contract additionally named `kAXErrorNotImplemented` as an equivalent case. All three are handled identically: **a valid, expected EMPTY result** (`success == true`, `parameterizedAttributeNames == []`) — many elements (a plain `NSButton`, for instance) genuinely support zero parameterized attributes, and this is never an error.

| `AXError` | Meaning | Treatment |
|---|---|---|
| `kAXErrorAttributeUnsupported` | Named explicitly in the approved contract | **Valid, expected empty result** |
| `kAXErrorParameterizedAttributeUnsupported` | The SDK's own doc block for this function groups it with `kAXErrorAttributeUnsupported` as the same semantic outcome | **Valid, expected empty result** (included per the SDK's own documented equivalence — a deliberate, documented inclusion beyond the contract's literal two names, not a silent scope expansion) |
| `kAXErrorNotImplemented` | Named explicitly in the approved contract | **Valid, expected empty result** |
| Anything else (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`, `kAXErrorIllegalArgument`, `kAXErrorAPIDisabled`, ...) | A genuine communication/API failure | **Fails closed** with `AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED` — never silently converted into an empty result |

This is the mirror image of the missing-vs-failure discipline established for `ui.read_window_default_button`/`ui.read_element_title_reference` (where absence-vs-failure distinguishes two DIFFERENT outcomes for an optional *value*) — here, both "unsupported" and "genuine failure" collapse toward different ends of the same axis (empty-but-valid vs. thrown-and-invalid) for an *enumeration*, and the two must never be confused in either direction.

---

## Result Contract
`QAXElementParameterizedAttributeNamesMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | The resolved element's role (matches `QAXElementActionsMetadata`/`QAXElementAttributeNamesMetadata`'s field naming). |
| `parameterizedAttributeNames` | `[String]` | Bounded to 32 entries, each ≤256 characters. Never deduplicated. Empty is a fully valid result. |

No `AXUIElement`, no coordinates, and no parameterized-attribute VALUES of any kind ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementParameterizedAttributeNamesReadSucceeded(applicationName: String, role: String, parameterizedAttributeCount: Int)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.listElementParameterizedAttributeNames`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`, and independently re-validates the count against the permitted bound `[0, 32]` rather than blindly trusting the dispatch layer — proven directly in the test suite (test 31): a fabricated `success == true` result carrying an out-of-bound count (999) is still correctly rejected.
- **Evidence**: `application=<name> role=<role> parameterizedAttributeCount=<count> status=verified` (or `status=failed`) — never any individual parameterized-attribute-name string.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite. Discovering a parameterized attribute name grants no implicit permission to invoke it (no invocation capability exists yet in this codebase to grant permission over).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no individual parameterized-attribute-name string is ever persisted into any field a recovery replay could read back.
- **QResourceGuard applicability**: `QResourceGuard` is this codebase's filesystem path-jail/denylist mechanism (used by `fs.read`/`fs.write_sandbox`) — it has no bearing on AX enumeration capabilities. This capability's resource bounding is enforced entirely by the per-capability `max*Count`/`max*Length` static constants pattern already established for every `list_*` capability, reused verbatim here rather than introducing a parallel mechanism.
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxElementsTouched = 1`; `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxParameterizedAttributesInvoked = 0` — `AXUIElementCopyParameterizedAttributeValue` is never called anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous calls.
  - `maxReturnedNames = 32` (`maxElementAttributesCount`, reused); `maxNameLength = 256` (`maxAttributeNameLength`, reused).

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary (per-turn, transient)**: the full `[String]` list of parameterized attribute names, available in `outputData` for the current turn's reasoning/planning — proven in test 29.
- **Must never be persisted beyond aggregate identity**: `QDurablePlanStepSnapshot` has no `outputData` field at all (confirmed by direct grep elsewhere in this codebase) — per-item content structurally cannot reach durable storage regardless of this capability's own discipline. Durable `verifiedEvidence` and audit `executionSummary` carry only application name, role, and an aggregate count — proven directly against a distinctively-named parameterized-attribute string (`"AXStringForRange"`) in tests 26/27.
- **Classification**: safe structural metadata — names are Apple's own fixed AX API vocabulary, never user-typed content, never document/application data.
- **Model exposure**: the full list reaches the model/planner as ephemeral per-turn `outputData`; the verifier sees only an aggregate count; the replanner/recovery path sees neither (proven in test 28 — recovery's `arguments` dictionary contains no individual name). None of this ever becomes authorization, a persisted approval, durable evidence, a standing capability, or a hidden execution privilege.
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing allowlist verbatim, including its existing `AXSecureTextField` exclusion.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticElementParameterizedAttributeEnumerationTests.swift`)
38 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution and successful read; empty valid result (both a model-level construction and a real `NSButton` fixture); missing/unavailable application; ambiguous application (delegated to the shared resolver suite); exact target resolution by identifier and title; missing element (zero match); ambiguous element; wrong application never falling back; stale target (structural, shared discipline); execution identity mismatch (structural, shared discipline); allowed vs. disallowed role, including the dedicated secure-field diagnostic; the three-way `AXErrorAttributeUnsupported`/`AXErrorParameterizedAttributeUnsupported`/`AXErrorNotImplemented` → valid-empty-result discipline; any other `AXError` failing closed; malformed `CFArray` and non-string-member handling (both collapse to the same malformed error, proven as an all-or-nothing Swift cast); oversized list and oversized individual name each failing closed with their own distinct error code; the 32-name bound being inclusive; duplicate-name pass-through (never deduplicated); Level 0/no-approval via the real `QPermissionGate`; discovered names never authorizing any future invocation; no mutation proven via a real fixture's field remaining unchanged; no persistent authorization constructed; durable-plan-snapshot and audit-record content proven structural-only against a distinctively-named parameterized-attribute string; recovery/replan state proven to never persist individual names; the transient-vs-durable model/planner/verifier/replanner exposure boundary; evidence-based verification success/failure contents, including independent out-of-bound-count rejection even against a fabricated `success == true`; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural, confirmed zero matches of any kind for `AXUIElementCopyParameterizedAttributeValue`/`AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); an explicit fail-closed summary test asserting every malformed/unexpected path carries its own distinct `errorCode`; no polling/traversal (structural); real macOS E2E (TCC-guarded, a real `NSTextField` and a real `NSButton`, both bounded and well-formed, neither mutated nor having any parameterized attribute invoked).

---

## Real macOS E2E — TCC Status
Test 36 constructs a real `NSTextField` and a real `NSButton`, dispatches each through `QBridgeAccessibility.shared.listElementParameterizedAttributeNames` end-to-end, and asserts the returned list is bounded (`≤ 32`) and well-formed for both — deliberately asserting the *contract* (bounded, no exception) rather than a specific parameterized-attribute name, since the exact set AppKit reports is OS/AppKit-version dependent and not itself part of this capability's guaranteed behavior. Both fixtures' own content (`field.stringValue`/`button.title`) are independently confirmed unchanged after the read, proving no mutation and no parameterized-attribute invocation occurred.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementParameterizedAttributeEnumerationTests`): 38/38 passed.
- **Related suites**: `QSemanticElementActionEnumerationTests` 33/33, `QSemanticElementAttributeEnumerationTests` 33/33, `QSemanticElementRangeReadTests` 31/31, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`):
  - A pre-official-run attempt showed a transient failure in `QSemanticApplicationHiddenStateTests.recoveryRecognizesAlreadyDesiredAsComplete()` under a sustained system load average of 11–15 (consistent with the same class of environmental flake root-caused in Phase 2BO's own regression report — this specific suite's tests gate on real-time OS input/call-activity state). Re-running the same isolated suite immediately after load dropped to ~4.9 passed cleanly (31/31), confirming the environmental diagnosis; this file is not touched anywhere in this phase's diff.
  - **Run 1**: 3409/3409 passed — clean.
  - **Run 2**: 3409/3409 passed — clean.
  - **Run 3**: 3409/3409 passed — clean.
  - No failure was ever converted to PASS; no test was modified, skipped, or weakened to obtain a green result.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or entitlement change).

---

## Known Limitations
- The exact set of parameterized attribute names a given `NSTextField`/`NSButton` reports is AppKit/OS-version dependent and was not asserted as a specific fixed list in the real E2E test — only the contract (bounded count, well-formed strings, no exception, no mutation, no invocation) was asserted, consistent with this capability's own "report exactly what the OS returns, never interpret or assume" design principle.
- A genuine `AXError` failure (as opposed to `kAXErrorAttributeUnsupported`/`kAXErrorParameterizedAttributeUnsupported`/`kAXErrorNotImplemented`) or a malformed (non-`[String]`-castable) collection cannot be constructed from any real, standard AppKit element — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
