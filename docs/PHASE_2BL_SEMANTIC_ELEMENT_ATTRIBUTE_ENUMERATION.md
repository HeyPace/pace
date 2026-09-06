# Phase 2BL — Semantic Element Attribute Enumeration (`ui.list_element_attributes`)

## Overview
- **Capability Identifier**: `ui.list_element_attributes`
- **Tool Family**: `ui` (attribute names are a near-fixed, short structural vocabulary — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `d18174b`
- **Pre-Phase Capability Count**: `59`
- **Post-Phase Capability Count**: `60`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions, zero attribute VALUE reads.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_element_actions` (Phase 2BK) reads an element's supported ACTION names via `AXUIElementCopyActionNames`. This capability is its direct sibling — it reads an element's supported ATTRIBUTE names via the parallel `AXUIElementCopyAttributeNames`. Where the former answers "what can this element **do**?", this one answers "what can I **ask** this element?" Every existing read capability (`ui.read_element_value`, `ui.read_element_range`, etc.) assumes a fixed, hard-coded attribute per role, written by this program's own implementers. No capability has ever asked an element to self-report its actual supported attribute vocabulary.

---

## Security-Critical Invariant — Data, Not Authorization
**Discovered attribute names are DATA, not AUTHORIZATION.** This capability never reads any attribute's actual VALUE merely because its name was discovered — it calls only `AXUIElementCopyAttributeNames`, never `AXUIElementCopyAttributeValue` for any of the returned names, never `AXUIElementSetAttributeValue`, never `AXUIElementPerformAction`. Discovering that `"AXValue"` is a supported attribute name never itself grants any capability, approval, or standing authority to read that value. A subsequent request to actually read an attribute's value must independently go through an existing, approved semantic read capability (e.g. `ui.read_element_value`) and that capability's own full role/privacy/security policy, completely unaffected by `ui.list_element_attributes` ever having been called. Proven directly in the test suite (test 19): `ui.read_element_value`'s own `QAXElementReadRolePolicy` evaluation still fails closed for a secure field regardless of what attribute names were "discovered" for that same role elsewhere.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, Phase 2J — no broader, arbitrary-role allowlist was introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role + `identifier` or `title`) — identical pattern to `ui.list_element_actions`.
- **AX API**: `AXUIElementCopyAttributeNames(targetElement, &attributeNamesValue)` — a single, purely observational call.
- **Mutation primitives**: none. `AXUIElementCopyAttributeValue` (for any discovered name), `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual non-comment usages).
- **Duplicate handling**: the returned array is passed through **exactly as the OS reports it — never deduplicated**. Deduplicating would silently alter the authoritative result; this capability's contract is to report, not interpret.
- **Custom/nonstandard names**: treated identically to any other string — no special-casing, no rejection based on naming convention alone.

---

## Target Resolution & Fail-Closed Gates
1. **Role policy check** (secure field first, then general allowlist — belt and suspenders): `role` must not be `AXSecureTextField` (→ `AX_SECURE_FIELD_READ_DENIED`) and must be on `QAXElementReadRolePolicy.allowedRoles` (→ `AX_READ_ROLE_NOT_ALLOWED` otherwise) — checked before any AX call.
2. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved element is re-snapshotted immediately before the attribute-name read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **Malformed-collection check**: `AXUIElementCopyAttributeNames`'s returned value is treated as untrusted external data — a successful copy result that fails to cast to `[String]` → `AX_ATTRIBUTE_NAMES_COLLECTION_MALFORMED`.
8. **Bound enforcement**: the returned collection's size is checked against `maxElementAttributesCount` (32) *before* returning — exceeding it → `AX_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND`, never silently truncated. Each individual attribute name is checked against `maxAttributeNameLength` (256 characters) — exceeding it → `AX_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH`, whose error carries only the offending *length*, never the string content itself.

---

## Output Contract
`QAXElementAttributeNamesMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `role` | `String` | Echoed from the caller's own input. |
| `attributeNames` | `[String]` | Bounded to at most 32 entries, each individually length-bounded, never deduplicated. |

No `AXUIElement`, no coordinates, no arbitrary attribute *values*, ever appear in this type (proven by a compile-time-enforced test, mirroring `ui.list_element_actions`'s identical proof technique).

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementAttributeNamesReadSucceeded(applicationName: String, role: String, attributeCount: Int)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.listElementAttributes`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, **and additionally independently re-validates `attributeCount` is within `[0, 32]`** — a defense-in-depth check that never blindly trusts the dispatch layer already enforced it, proven directly by test 26 (a fabricated `success: true` result carrying an out-of-bound count is still correctly rejected). Never a bare `{ true }`; never reads any attribute's actual value as part of verifying the read; never mutates anything.
- **Evidence**: `application=<name> role=<role> attributeCount=<n> status=verified` (or `status=failed`) — never any individual attribute-name string.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects; no individual attribute-name string is ever persisted into any field a recovery replay could read back (test 24).
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxElementsTouched = 1` — the one resolved element only.
  - `maxTraversalDepth = 0` — no descent beyond the resolved element; `kAXChildrenAttribute` is never read.
  - `maxChildren = 0`.
  - `maxActionsPerformed = 0` — no attribute value is ever read, no action is ever performed.
  - `maxPolling = 0` — a single synchronous call; no loop, no `Task.sleep`.
  - `maxReturnedRecords = 32` attribute-name strings, each individually capped at 256 characters.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary** (returned to the model for immediate use): the bounded list of attribute-name strings and an aggregate count — a near-fixed, Apple-defined vocabulary, never attribute *values*, never user-entered content.
- **Must never be persisted beyond identity + count**: individual attribute-name strings are deliberately excluded from durable verification evidence, audit `executionSummary` text, memory, and recovery/replan state — proven directly in the test suite (tests 22, 23, 24).
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing exclusion of `AXSecureTextField` verbatim — no secure field can ever be a valid target for this capability, exactly as for `ui.read_element_value`/`ui.list_element_actions`.
- **No durable pointer/content leaks**: `QAXElementAttributeNamesMetadata`'s stored properties are `String`/`String`/`[String]` only — no `AXUIElement`-typed field exists anywhere in its declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual non-comment usages; every string match across the entire diff is a documentation comment explicitly disclaiming the corresponding API).

---

## Test Coverage (`QSemanticElementAttributeEnumerationTests.swift`)
33 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero/ambiguous application match; exact element match (by identifier and title); zero/ambiguous element match; unsupported role and secure-field rejection (`QAXElementReadRolePolicy` reused verbatim, not broadened); successful enumeration of a real `NSButton`'s standard attributes (`AXRole` confirmed present); zero attributes is a valid empty result; one attribute preserved exactly; multiple attributes all reported distinctly; exactly 32 attributes accepted (bound is inclusive); 33 attributes fails closed, never truncated; malformed/unreadable collection fails closed (structural); per-attribute-name length bound enforced without leaking the oversized string into the error itself; duplicate names passed through unchanged, never deduplicated; a nonstandard/custom-looking attribute name treated identically to any other string; **no mutation occurs**, proven via a real fixture whose field value remains provably unchanged after enumeration; discovered attribute names never authorize `ui.read_element_value`'s own, entirely separate role-policy evaluation; `QPermissionGate` never requires approval; no persistent authorization is ever constructed; no raw `AXUIElement` escapes (compile-time proof); individual attribute names absent from durable-plan snapshots, audit records, and recovery/replan state (three dedicated tests); evidence-based verification success/failure contents, including independent re-validation of the count bound even against a fabricated "successful" result; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural); no polling/traversal (structural); real macOS E2E (TCC-guarded, `NSButton` + `NSTextField`, each proving a distinct, real attribute-name set with zero mutation).

---

## Real macOS E2E — Known Environmental Limitation
Test 31 builds two real fixtures — a plain `NSButton` and a plain `NSTextField` — and dispatches through `QBridgeAccessibility.shared.listElementAttributes` end-to-end for each, asserting `"AXRole"` appears in both results while independently confirming neither fixture's own state (button title, field string value) was altered as a side effect. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created two windows and performed real AX round-trips. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BK) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementAttributeEnumerationTests`): 33/33 passed.
- **Related suites**: `QSemanticElementActionEnumerationTests` 33/33, `QSemanticElementReadTests` 18/18, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3262/3262, 3262/3262, 3262/3262 — no flakes, no regressions, no environmental failures.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- A truly custom, app-defined attribute name (as opposed to the near-universal fixed `kAX*Attribute` vocabulary) is uncommon in practice — no standard AppKit public API equivalent to `NSAccessibilityCustomAction` exists for exposing custom *attributes*, so the "custom/nonstandard attribute name" test path is exercised at the model/contract level (constructing `QAXElementAttributeNamesMetadata` directly) rather than via a genuine live custom-attribute fixture, which standard AppKit does not provide a simple way to construct.
- An element reporting more than 32 attributes, a malformed attribute-names collection, or an oversized individual attribute-name string cannot be constructed from any real, standard AppKit control — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting.
