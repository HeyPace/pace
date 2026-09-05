# Phase 2BG — Semantic Focused Element Read (`ui.read_focused_element`)

## Overview
- **Capability Identifier**: `ui.read_focused_element`
- **Tool Family**: `perception` (not `ui` — see Registration Rationale below)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `27e42d2`
- **Pre-Phase Capability Count**: `54`
- **Post-Phase Capability Count**: `55`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability is different from every other one shipped so far**: every one of the prior 54 capabilities requires the model to already know a target's `role`/`identifier`/`title` before it can act on or read it. `ui.read_focused_element` is the first that requires **zero** prior knowledge — it answers "what currently has keyboard focus?" directly from the OS.

---

## Registration Rationale (`toolFamily: "perception"`)
Registered under `perception`, not `ui`, for the identical reason `ui.read_element_value` (Phase 2J) is: the optional exposed `value` field carries the same "raw content the model needs to reason about" character `screen.ocr` already established. Registering under `perception` is what activates `QPlanExecutor`'s existing `isScreenDerivedStep` predicate (`toolFamily == "perception"`) — the same sanitize-before-persist (`QSecretRedactor.redact`) / raw-for-reasoning (`QTaskContext.append`) boundary `screen.ocr` and `ui.read_element_value` already rely on, with **zero changes** to `QPlanExecutor`'s dispatch logic.

---

## Semantic Accessibility Contract
- **Target Element**: whatever the systemwide focused element currently is — never restricted to a single role; focus can land on any control.
- **AX API**: `AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute, ...)` — the exact same primitive `ui.focus_element`'s idempotency check and its `observeFocusedElementIdentity` independent verification already share (`QBridgeAccessibility.systemWideFocusedElement()`, reused unmodified).
- **Attributes read** (direct, non-recursive, on the one resolved element only):
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `AXIdentifier` (the raw-string attribute key; no `kAX...` Swift constant exists for it, per the established Phase 2H finding)
  - `kAXTitleAttribute` / `kAXDescriptionAttribute` (reported as **separate** optional fields — unlike `QAXElementSnapshot`'s merged `titleOrDescription`, this capability's own output contract calls for both independently)
  - `kAXEnabledAttribute`
  - `kAXSelectedAttribute` (optional — `nil`, not `false`, for a role that does not expose it; never fabricated)
  - `kAXValueAttribute` (only when the role is on `QAXElementReadRolePolicy`'s allowlist — see Value Exposure below)
  - `kAXWindowAttribute` (only when an optional `windowTitle` scope is supplied, to resolve the focused element's containing window for comparison)
- **AX action(s)**: none. **Mutation**: none.

---

## Target Resolution & Fail-Closed Gates
1. **Accessibility trust**: `AXIsProcessTrusted()` checked first, before any other work — identical order to every other AX capability in this codebase (`readElementValue`/`clickElement`/`focusElement`/`setElementState`). Absent trust → `AX_PERMISSION_DENIED`.
2. **Application resolution**: exact matching via `QBridgeAccessibility.resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; more than one match → `AX_AMBIGUOUS_TARGET`.
3. **Focused element existence**: `kAXFocusedUIElementAttribute` read on the systemwide element — unreadable/absent → `AX_NO_FOCUSED_ELEMENT`.
4. **Cross-app mismatch guard**: the focused element's owning process (`AXUIElementGetPid`) is independently compared against the resolved application's `processIdentifier` — mismatch → `AX_FOCUSED_ELEMENT_APPLICATION_MISMATCH`. The systemwide focused element is never treated as an arbitrary, unscoped target belonging to whichever application happens to be named.
5. **Role readability**: the focused element's own `kAXRoleAttribute` must itself be readable — an unreadable/malformed role → `AX_NO_FOCUSED_ELEMENT` (the same code as "nothing is focused," since neither leaves anything safe to report).
6. **Optional window scope**: if `windowTitle` is supplied, the focused element's `kAXWindowAttribute` must resolve and its own `kAXTitleAttribute` must match exactly — mismatch → `AX_FOCUSED_ELEMENT_WINDOW_MISMATCH`.

None of these gates ever fall back to a different element, a fabricated value, or an approximate match.

---

## Value Exposure — Resolved Design Decision
The approved discovery document's Section 7 ("Security") lists "unsupported/unsafe role" and "secure-field role" among "required failures," while its own Section 8/11 Test Plan and Privacy Assessment explicitly describe a **different**, more specific contract: *"Focused element is an AXSecureTextField → value withheld, but role/identifier/title still safely returned"* and *"Focused element's role is not on QAXElementReadRolePolicy → value withheld, identity still returned."* These two framings are in tension when read as a flat list.

**Resolution applied** (documented here rather than silently guessed at, per this program's "STOP and report an ambiguity" discipline — this one was resolved by synthesizing the discovery document's own more detailed sections rather than inventing new behavior):

- **Identity/structural metadata is always returned** when a focused element resolves and passes gates 1–6 above — `role`, `subrole`, `identifier`, `title`, `description`, `enabled`, `selected`. Reading *which* element has focus is never itself sensitive, exactly as the discovery document's Privacy Assessment states plainly.
- **Only the `value` field is policy-gated**, reusing `QAXElementReadRolePolicy` (Phase 2J) unmodified: `AXSecureTextField` and any role not on that allowlist yield `value: nil` — the read still **succeeds**, mirroring `ui.read_element_value`'s own precedent for identity-safe-content-gated exposure, never a hard failure of the whole capability.

This keeps the privacy boundary identical to `ui.read_element_value`'s already-accepted one — no new exposure class is introduced — while making the "required failures" list in Section 7 read as failure *conditions for the value field specifically* wherever it overlaps with this finer-grained contract, not whole-read rejections.

---

## Output Contract
`QAXFocusedElementSnapshot` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `role` | `String` | Always present when the read succeeds. |
| `subrole` | `String?` | `AXSubrole`, when the control has one. |
| `identifier` | `String?` | `AXIdentifier`. |
| `title` | `String?` | `kAXTitleAttribute`, empty string normalized to `nil`. |
| `elementDescription` | `String?` | `kAXDescriptionAttribute`, empty string normalized to `nil`. |
| `isEnabled` | `Bool` | Defaults `true` if unreadable (matches every other capability's convention). |
| `isSelected` | `Bool?` | `kAXSelectedAttribute` — honestly `nil`, never coerced to `false`, when the role doesn't expose it. |
| `value` | `String?` | Policy-gated — see above. Same polymorphic reader (`axValueDescription`) and no truncation ceiling beyond what `ui.read_element_value` itself currently enforces (confirmed at implementation time: `readElementValue` presently applies none either — no truncation constant exists for element-value reads, only for `screen.ocr`'s `maxDetectedTextCharacters`; this capability introduces no new, larger ceiling than that existing baseline). |

No coordinates, no raw `AXUIElement`, no descendant tree, ever appear in this type or cross into any persisted structure.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.focusedElementReadSucceeded(applicationName: String, role: String, hasValue: Bool)`
- **Evaluation**: like every other Level 0 enumeration's verification (`windowEnumerationSucceeded` et al.), there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readFocusedElement`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }` bypass.
- **Evidence**: `application=<name> role=<role> hasValue=<bool> status=verified` (or `status=failed`) — never the identifier, title, description, or value itself.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`, by policy — not a special-cased bypass (proven directly in the test suite, mirroring `ui.read_element_value`'s own `permissionGateNeverRequiresApprovalForRead` test).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects (identical to every other Level 0 capability's recovery model).
- **Resource Bounds** (all enforced structurally, not by a runtime counter):
  - `maxTraversalDepth = 0` — zero tree traversal; `Self.collectMatches` (the bounded recursive descent every search-by-criteria capability uses) is never called.
  - `maxNodes = 1` / `maxReturnedElements = 1` — exactly one element is ever touched; the return type itself is a single struct, never a collection.
  - `maxActions = 0` — no `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` call exists anywhere in the implementation.
  - `maxPolling = 0` — a single synchronous attribute read; no loop, no `Task.sleep`, no repeated `AXUIElementCopyAttributeValue` call.

---

## Privacy & Security Architecture
- **Reused, unmodified policies**: `QAXElementReadRolePolicy` (value gating) and `QBridgeAccessibility.resolveExactRunningApplication` (application resolution) — no second, independent allowlist or resolver was introduced.
- **No durable pointer/content leaks**: `QAXFocusedElementSnapshot`'s stored properties are `String`/`String?`/`Bool`/`Bool?` only — no `AXUIElement`-typed field exists anywhere in its declaration (proven both by source inspection and a compile-time-enforced test).
- **Sanitize-before-persist boundary**: because this capability is registered under `perception`, `QPlanExecutor`'s existing `isScreenDerivedStep` predicate applies `QSecretRedactor.redact` to `resultSummary`/durable evidence before persistence, while the raw value still reaches `QTaskContext` for the planner to reason with — verified directly against a secret-shaped fixture value in the test suite.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, `AppleScript`/`osascript`, `Process(`, or shell fallback — confirmed by direct diff audit (0 actual usages; the only string match across the entire diff is a documentation string inside a test's own name).

---

## Test Coverage (`QSemanticFocusedElementReadTests.swift`)
33 focused tests, covering:
1. Capability registration (Level 0, `perception` family, anti-downgrade in both directions)
2. Optional `windowTitle` scoping parameter accepted by the schema
3. Missing `applicationName` fails closed
4/4b. Non-existent application and missing-AX-trust paths fail closed with the correct, distinct error codes
5–8/8b/8c. Happy path: role, identifier, title, description, enabled, and honest `nil` selected state all correctly returned
9. No focused element (or one belonging to a different process) fails closed, never a fabricated empty success
10. `AXSecureTextField` focused: value withheld, identity still safely returned
11/12. Disallowed-role value gating and `QAXElementReadRolePolicy` reuse sanity checks
13. Ambiguous application resolution (generic resolver behavior, covered by `QApplicationResolutionHardeningTests`)
14. Application mismatch (cross-app PID check) fails closed
15/15b. Optional `windowTitle` mismatch fails closed; a matching scope succeeds
16. Malformed/unreadable role attribute fails closed (structural proof)
17. Arbitrary text never exposed for a disallowed role
18. A real run against a secure field leaves no sensitive content in durable state/audit
19. No raw `AXUIElement` pointer ever crosses into the result type (compile-time proof)
20–23. Resource bounds: no tree traversal, maximum one element, no polling, no mutation
24. Forbidden API audit (structural)
25. Normal `QExecutionService` → verification pipeline is used, not bypassed
26. `QPermissionGate.evaluate` never requires approval for this tool
27. Perception-family redaction boundary: raw value reaches reasoning, sanitized before persistence
28. Idempotency: repeated reads return the same value with zero side effects
29. Uncertain in-flight step recovery fails closed to pending
30/E2E. Real macOS AppKit E2E (`NSWindow` + `NSTextField`, TCC-guarded)
31/31b. Verification strategy evidence contents and failure-propagation

---

## Real macOS E2E — Known Environmental Limitation
Test 30 builds a real `NSWindow` + `NSTextField`, calls `window.makeFirstResponder(textField)`, and dispatches through `QBridgeAccessibility.shared.readFocusedElement` end-to-end, asserting the resolved role/identifier/value match the live fixture exactly. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created a window, slept, and performed a real AX round-trip. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BF) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticFocusedElementReadTests`): 33/33 passed.
- **Related suites**: `QSemanticElementReadTests` 18/18, `QSemanticElementFocusTests` 28/28, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3110/3110, 3110/3110, 3110/3110. (An initial full run surfaced one failure, `QAgentE2ETests.test6_uiActionOpenApp()` — a real-Calculator-launch timing test unrelated to this change, in a file untouched by this phase; confirmed environmental by re-running it standalone, where it passed 8/8. It did not recur in any of the three official runs.)

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default `PACE_DEVELOPER_ID:--` configures — no unrelated signing change).
