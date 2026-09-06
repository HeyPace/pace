# Phase 2BH — Semantic Application State Read (`ui.read_application_state`)

## Overview
- **Capability Identifier**: `ui.read_application_state`
- **Tool Family**: `app` (the same application-scoped family as `ui.open_app`/`ui.activate_application`/`ui.set_application_hidden`/`app.quit` — never `ui`, which is element-scoped, or `perception`, since no free-form content is ever exposed)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `c4e346d`
- **Pre-Phase Capability Count**: `55`
- **Post-Phase Capability Count**: `56`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: every existing application-level capability is write-only (`ui.open_app`, `ui.activate_application`, `ui.set_application_hidden`, `app.quit`) or existence-only (`system.running_apps` reports names, nothing else). No capability let the model confirm an application's own current state before or after acting on it. This is the read counterpart none of those four had.

---

## Registration Rationale (`toolFamily: "app"`)
Registered under `app` — the identical family `ui.open_app`/`ui.activate_application`/`ui.set_application_hidden`/`app.quit` already use — because this capability's target is the application itself, not a UI element within it. Unlike `ui.read_element_value`/`ui.read_focused_element` (registered `perception` specifically because they expose a typed, potentially-sensitive `value` field, activating `QPlanExecutor`'s sanitize-before-persist boundary), this capability's entire output is two booleans and up to two window titles — the identical content-free structural-metadata class `ui.list_windows` already exposes under `ui` without any redaction boundary. No new persistence/redaction concern exists here, so no `perception` routing was needed.

---

## Semantic Accessibility Contract
- **Target Element**: the named application's own AX root element, via `AXUIElementCreateApplication(pid)` — the exact same primitive `ui.list_windows`/`ui.list_menu_items` already resolve, reused unmodified. A pure AX object-reference constructor: never activates, focuses, or raises the target application.
- **AX API / attributes read** (direct, non-recursive, on at most 3 elements total):
  - `kAXHiddenAttribute` (Bool, required) — read on the application root element.
  - `kAXFrontmostAttribute` (Bool, required) — read on the application root element.
  - `kAXMainWindowAttribute` (single-element reference, optional) — if present, the referenced window's own `kAXRoleAttribute` is independently re-validated as exactly `AXWindow` before its `kAXTitleAttribute`/`AXIdentifier` are read.
  - `kAXFocusedWindowAttribute` (single-element reference, optional) — same independent role re-validation and identity-only read as the main-window field.
- **AX action(s)**: none. **Mutation**: none.
- **Deliberate architectural choice**: reads the *native AX attributes* rather than `NSRunningApplication.isHidden`/`NSWorkspace.shared.frontmostApplication` — the very heuristics `ui.set_application_hidden`/`ui.activate_application` themselves use for their own mutation. This capability's whole purpose is the authoritative Accessibility-layer state, confirmed directly from the live SDK during discovery (`kAXHiddenAttribute`/`kAXFrontmostAttribute`/`kAXMainWindowAttribute`/`kAXFocusedWindowAttribute` are grouped together in `AXAttributeConstants.h` immediately after `kAXMenuBarAttribute`/`kAXWindowsAttribute`, which this codebase already reads on the identical element).

---

## Target Resolution & Fail-Closed Gates
1. **Accessibility trust**: `AXIsProcessTrusted()` checked first, before any other work — identical order to every other AX capability in this codebase. Absent trust → `AX_PERMISSION_DENIED`.
2. **Application resolution**: exact matching via `QBridgeAccessibility.resolveExactRunningApplication(named:)` (unmodified, unchanged) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; more than one match → `AX_AMBIGUOUS_TARGET`.
3. **Core state readability**: `kAXHiddenAttribute` and `kAXFrontmostAttribute` must both be readable as `Bool` — either failing → `AX_APPLICATION_STATE_READ_FAILED`. These are the two required, authoritative facts this capability exists to report; neither is ever defaulted to `false`.
4. **Optional window resolution**: `kAXMainWindowAttribute`/`kAXFocusedWindowAttribute` are each independently optional. A missing reference, or one whose referenced element's own `kAXRoleAttribute` is not exactly `AXWindow`, yields a valid `nil` for that field's title/identifier pair — never an error, mirroring `ui.list_windows`'s own "no windows is a legitimate empty state" precedent.

None of these gates ever fall back to a different application, a fabricated boolean, or an approximate match.

---

## Output Contract
`QAXApplicationStateSnapshot` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `isHidden` | `Bool` | `kAXHiddenAttribute`. Required — the read fails closed if unreadable. |
| `isFrontmost` | `Bool` | `kAXFrontmostAttribute`. Required — the read fails closed if unreadable. |
| `mainWindowTitle` | `String?` | `kAXTitleAttribute` of the referenced main window, when present and role-valid. |
| `mainWindowIdentifier` | `String?` | `AXIdentifier` of the referenced main window, when present and role-valid. |
| `focusedWindowTitle` | `String?` | `kAXTitleAttribute` of the referenced focused window, when present and role-valid. |
| `focusedWindowIdentifier` | `String?` | `AXIdentifier` of the referenced focused window, when present and role-valid. |

No coordinates, no raw `AXUIElement`, no descendant tree, no arbitrary application content, ever appear in this type or cross into any persisted structure. At most 2 window records can ever be represented — enforced structurally by the type itself (two fixed field pairs, no collection field of any kind), never a runtime-checked collection that could theoretically grow.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.applicationStateReadSucceeded(applicationName: String)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readApplicationState`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }` bypass.
- **Evidence**: `application=<name> status=verified` (or `status=failed`) — never the booleans or window titles themselves.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`, by policy — proven directly in the test suite.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe since a read has no side effects.
- **Resource Bounds** (all enforced structurally):
  - `maxTraversalDepth = 0` — no children of the application or of either referenced window are ever read; `kAXChildrenAttribute` is never called.
  - `maxNodeCount = 3` — the application root plus at most 2 directly-referenced windows (main, focused).
  - `maxChildrenEnumerated = 0`.
  - `maxActions = 0` — no `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` call exists anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous attribute reads; no loop, no `Task.sleep`.
  - `maxReturnedWindows = 2` — structurally enforced by the output type (two fixed field pairs, never a collection).

---

## Privacy & Security Architecture
- **Exposed surface, exhaustively**: two booleans (`isHidden`, `isFrontmost`) and up to two window title/identifier pairs (`mainWindow*`, `focusedWindow*`) — no element values, no arbitrary text, no user-entered content of any kind.
- **No new exposure class**: window titles are already exposed by the shipped `ui.list_windows`; this introduces no new privacy surface, only a more direct route to the same class of fact.
- **No sensitive-role encounter possible**: the target is always the application root element itself, never a leaf control; the two referenced windows are read for identity (title/identifier) only, the same content-free fields every other window-identity read already exposes.
- **No durable pointer/content leaks**: `QAXApplicationStateSnapshot`'s stored properties are `Bool`/`Bool`/`String?` × 4 only — no `AXUIElement`-typed field exists anywhere in its declaration (proven both by source inspection and a compile-time-enforced test).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, `AppleScript`/`osascript`, `Process(`, or shell fallback — confirmed by direct diff audit (0 actual usages; the only string matches across the entire diff are a documentation comment disclaiming screenshots and a test's own name).

---

## Test Coverage (`QSemanticApplicationStateReadTests.swift`)
28 focused tests, covering:
1. Capability registration (Level 0, `app` family, anti-downgrade in both directions)
2. Zero application matches fails closed
3. Ambiguous application resolution (generic resolver behavior, covered by `QApplicationResolutionHardeningTests`)
4/5. Wrong/missing `applicationName` fails closed
6/7. Authoritative hidden/frontmost booleans read correctly
8/9. `kAXMainWindowAttribute` correctly resolves to the real fixture window made main
10/11. Window title and identifier both returned when available
12. Missing optional window metadata handled safely (honest `nil`, never fabricated)
13. Missing AX trust fails closed with `AX_PERMISSION_DENIED`
14. Unavailable required attribute fails closed (structural proof — never defaults to `false`)
15. Malformed/wrong-role window reference excluded, never exposed
16. No descendant traversal occurs (structural proof)
17. Maximum window bound enforced by the output type itself
18. No mutation occurs (fixture window's own state provably unchanged)
19. No polling occurs (structural proof)
20. Output contract bounded to exactly six scalar fields
21. Arbitrary content never exposed (privacy)
22. No raw `AXUIElement` pointer ever crosses into the result type (compile-time proof)
23. A real run leaves no sensitive content in durable state/audit
24/24b. Normal `QExecutionService` → verification pipeline used; `QPermissionGate` never requires approval
25. Forbidden API audit (structural)
26. Uncertain in-flight step recovery fails closed to pending
27. Idempotency: repeated reads return the same result with zero side effects
28/E2E. Real macOS AppKit E2E (`NSWindow` + `makeMain()`, TCC-guarded)
29/29b. Verification strategy evidence contents and failure-propagation

---

## Real macOS E2E — Known Environmental Limitation
Test 28 builds a real `NSWindow`, calls `makeKeyAndOrderFront`/`makeMain()`, and dispatches through `QBridgeAccessibility.shared.readApplicationState` end-to-end, asserting `mainWindowTitle` matches the live fixture exactly. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in `0.001s`, far too fast to have created a window and performed a real AX round-trip. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented (most recently Phase 2BG) — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticApplicationStateReadTests`): 28/28 passed.
- **Related suites**: `QSemanticElementFocusTests` 28/28, `QSemanticFocusedElementReadTests` 33/33, `QApplicationResolutionHardeningTests` 27/27 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive runs): 3138/3138, 3138/3138, 3138/3138 — no flakes, no regressions.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- `isHidden`/`isFrontmost` are also obtainable via `NSRunningApplication.isHidden`/`NSWorkspace.shared.frontmostApplication` — included here for completeness and zero extra resolution cost (they sit on the same already-resolved AX element), not because they are uniquely new information. `mainWindowTitle` is similarly derivable today by enumerating `ui.list_windows` and filtering for `main == true` — this capability offers a more direct, single-call route to the same fact. `focusedWindowTitle` is the one field with no existing equivalent in this codebase at all.
- A window without an `AXIdentifier` (the common case for a plain `NSWindow` with no explicit `setAccessibilityIdentifier` call) correctly yields `nil` for that field — a valid, honest result, not an error.
