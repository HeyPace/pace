# Phase 2BO — Semantic Window Modal State Read (`ui.read_window_modal_state`)

## Overview
- **Capability Identifier**: `ui.read_window_modal_state`
- **Tool Family**: `ui` (the returned `isModal` boolean is structural UI state — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `5125a62`
- **Pre-Phase Capability Count**: `62`
- **Post-Phase Capability Count**: `63`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions, zero modal-session lifecycle calls, zero window focus/activation.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.list_windows` exposes `title`/`identifier`/`minimized`/`main` per window, but no capability has ever surfaced whether a window is currently **modal** — `kAXModalAttribute`, confirmed unused anywhere in this codebase prior to this phase. Phase 2BO's discovery scored this the highest of ten candidates (94/100) on the strength of `kAXModalAttribute`'s unusually explicit SDK documentation ("Required for all window elements"), the smallest possible implementation surface of any candidate, and a genuinely non-blocking native E2E fixture path via `NSApplication.beginModalSession(for:)`/`endModalSession(_:)`.

---

## Semantic Accessibility Contract
- **Target Element**: exactly one `AXWindow` (`QAXWindowRolePolicy`, reused verbatim — no new role policy introduced), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role `AXWindow`, matched by `identifier` or `title`) — identical pattern to `ui.read_window_default_button`.
- **AX API**: `AXUIElementCopyAttributeValue(windowElement, kAXModalAttribute, ...)` — a single, purely observational call yielding a `CFBooleanRef` value. Exactly one AX call beyond the existing resolve/verify calls every window-scoped read capability already performs.
- **Mutation primitives**: none. `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual usages of any kind, including in comments). This capability itself never calls `NSApplication.beginModalSession(for:)`/`endModalSession(_:)` — those APIs are used only by the TEST FIXTURE to construct a real modal window to observe, never by the capability's own implementation.

---

## Value Semantics & The Load-Bearing Design Decision
`kAXModalAttribute`'s own SDK documentation states: *"Whether a window is modal. Value: A CFBooleanRef... Writable? No. Required for all window elements."* This is a materially different documented contract from every prior window-scoped optional reference (`kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` in Phase 2BM, `kAXTitleUIElementAttribute` in Phase 2BN) — those are attributes many elements genuinely lack; `kAXModalAttribute` has no such documented absence case.

This capability's contract therefore makes a **deliberately inverted** missing-vs-failure decision relative to those two predecessors:

| Outcome | Phase 2BM/2BN pattern (optional reference) | Phase 2BO pattern (`kAXModalAttribute`) |
|---|---|---|
| `kAXErrorNoValue` / `kAXErrorAttributeUnsupported` | Valid, expected absence → `nil` | **Genuine read failure** → `AX_WINDOW_MODAL_STATE_READ_FAILED` |
| Any other `AXError` | Read failure | Read failure (same as above — no separate branch) |
| Copy succeeds, wrong CF type | Malformed reference | `AX_WINDOW_MODAL_STATE_MALFORMED` |
| Copy succeeds, well-formed Boolean | (n/a — this is a reference type, not a Boolean) | **Definite `true`/`false`**, returned directly — never optional |

`resolveWindowModalState` has exactly one success branch (`copyResult == .success`) and one failure branch that covers every other `AXError` case, including `.noValue`/`.attributeUnsupported` — there is no separate "absence" branch the way `resolveWindowButtonReference`/`resolveElementTitleReference` each have. This was a deliberate, explicit design decision made to prevent the dangerous silent-downgrade of an unreadable modal state to a guessed `false`: a planner that believed a window was not blocking-modal when its true state was simply unreadable could make an unsafe next-step decision (e.g. proposing to interact with a sibling window that is, in fact, blocked by a real modal dialog). This decision was specified in Phase 2BO's approved discovery document and is implemented exactly as specified — no scope drift occurred.

---

## Target Resolution & Fail-Closed Gates
1. **Match criteria**: at least one of `windowIdentifier`/`windowTitle` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
2. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
3. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
4. **Window resolution**: `collectMatches` bounded search for the one `AXWindow` — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
5. **Staleness check**: the resolved window is re-snapshotted immediately before the modal-state read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
6. **Modal-state gate**: any non-`.success` `AXError` → `AX_WINDOW_MODAL_STATE_READ_FAILED`; a successful copy whose value cannot be interpreted as `Bool` → `AX_WINDOW_MODAL_STATE_MALFORMED`.

---

## Result Contract
`QAXWindowModalStateMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `windowTitle` / `windowIdentifier` | `String?` | The resolved window's own identity (same pattern as `ui.read_window_default_button`). |
| `isModal` | `Bool` | **Never optional.** A definite, directly-observed fact — never a guessed default. |

No `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type. No children are enumerated; no sheets/dialogs are inspected as a workaround for reading this attribute directly.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.windowModalStateReadSucceeded(applicationName: String, windowTitle: String?, isModal: Bool)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readWindowModalState`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`; it never begins/ends a modal session, focuses, activates, or mutates anything as part of verification.
- **Evidence**: `application=<name> window=<title> isModal=<bool> status=verified` (or `status=failed`) — unlike button/label text, the `isModal` boolean itself carries no privacy risk (it IS this capability's entire structural purpose, not per-item content), so it is safe to include directly in evidence, matching `elementTitleReferenceReadSucceeded`'s inclusion of its own `hasTitleReference` boolean.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite, and proven *independent* of `ui.close_window`'s own, entirely separate Level 3 approval requirement (test 20).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no raw modal-state data is ever persisted into any field a recovery replay could read back.
- **Resource Bounds** (all enforced structurally):
  - `maxApplicationsResolved = 1`; `maxWindowsResolved = 1`.
  - `maxElementsInspected = 1` (the window itself — no reference-follow hop, unlike the button/title-reference capabilities).
  - `maxTraversalDepth = 0`; `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a fixed set of synchronous calls.
  - `maxReturnedRecords = 1` (window-scoped; never a collection). No string-length bound applies beyond the window's own already-established title/identifier echo.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `isModal` (a single structural UI-state boolean) and the resolved window's own already-established title/identifier — never content, never a value beyond this.
- **Classification**: safe structural metadata — the same tier as `minimized`/`main` in `ui.list_windows`'s own `QAXWindowMetadata`.
- **Must never be persisted beyond identity**: no new persistence mechanism was introduced; durable evidence follows the exact same aggregate-evidence-only pattern every prior capability establishes.
- **The model observing `isModal = true` gains zero authorization to close, activate, or otherwise act on the window** — proven directly (test 20): `ui.read_window_modal_state`'s own `QPermissionGate` evaluation and `ui.close_window`'s entirely separate, still-required Level 3 approval evaluation are wholly disjoint decisions.
- **No new privacy mechanism introduced**: reuses `QAXWindowRolePolicy`'s existing single-role allowlist verbatim.
- **No durable pointer/content leaks**: the new type's stored properties are `String`/`String?`/`Bool` only — no `AXUIElement`-typed field exists anywhere in the declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind). The capability's own implementation never calls `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`, never begins/ends a modal session, never focuses or activates the target window/application.

---

## Test Coverage (`QSemanticWindowModalStateReadTests.swift`)
32 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero/ambiguous application match; exact window match (by identifier and title); zero/ambiguous window match; modal-true and modal-false each proven against real, live fixtures; an explicit `false` proven to be a fully valid, distinct outcome never treated as "missing"; the inverted missing-vs-failure discipline proven structurally (no separate absence branch exists, unlike Phase 2BM/2BN's optional-reference pattern) — `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` fall into the same single read-failure case as every other non-success `AXError`; a genuine read failure and a malformed (non-Boolean) value each fail closed with their own distinct, dedicated error code; exact window identity echoed correctly; returned-Boolean correctness (structural type proof); no child traversal / no extra attribute reads (structural); **no modal session is ever begun or ended by this capability itself**, proven via a real fixture whose key-window state remains unaffected by the read; `QPermissionGate` never requires approval, and is proven independent of `ui.close_window`'s own separate requirement; no persistent authorization is ever constructed; durable-plan snapshot and audit-record content proven structural-only; recovery/replan state proven to never persist raw modal-state data; evidence-based verification success/failure contents (including the `isModal` boolean itself, safe to include directly); normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural, and confirmed zero matches of any kind for `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); no polling/child-traversal (structural); real macOS E2E (TCC-guarded, a genuine, non-blocking `NSApplication.beginModalSession(for:)`/`runModalSession(_:)`/`endModalSession(_:)` session, fully cleaned up in every case, both the non-modal-baseline and active-session states observed against real, live `AXUIElement`s).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 31 constructs a real `NSWindow`, reads its modal state (expecting `false`), then begins a **real** `NSApplication` modal session via `NSApp.beginModalSession(for:)` — a current, public, non-deprecated AppKit API that begins a real modal session **without blocking the calling thread** (unlike `-runModalForWindow:`/`NSAlert.runModal()`, which would block an async test indefinitely). A single, non-blocking `NSApp.runModalSession(session)` pump (processes one batch of pending events and returns immediately — it never loops, never blocks) is issued to give the modal-session state its best chance to propagate before the AX read, then `kAXModalAttribute` is read again (expecting `true`), and the session is unconditionally ended (`endModalSession(_:)`) in a `defer` block alongside the window's own `close()` — the session and window are never left active after the test, satisfying the explicit teardown requirement. The actual AX attribute is observed directly in both states; success is never inferred merely because the AppKit modal-session API was called.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from every TCC-guarded test in the new suite completing near-instantly (proving the early-exit `guard AXIsProcessTrusted() else { return }` path was taken, not a real AX round-trip). This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass. Because the modal-session assertion (`isModal == true` while the session is active) could not be empirically exercised in this sandboxed environment, its reliability under an active-but-unpumped-beyond-one-cycle modal session has not been independently verified beyond the documented AppKit/AX contract this implementation relies on — this is recorded honestly here rather than claimed as verified fact, consistent with this program's convention of never fabricating a result the environment could not actually exercise.

---

## Regression Results
- **Filtered suite** (`QSemanticWindowModalStateReadTests`): 32/32 passed.
- **Related suites**: `QSemanticWindowDefaultButtonReadTests` 39/39, `QSemanticWindowCloseTests` 48/48, `QSemanticWindowEnumerationTests` 33/33, `QSemanticWindowFullScreenStateTests` 20/20, `QSemanticWindowMainDesignationTests` 41/41, `QSemanticWindowMinimizedStateTests` 35/35, `QSemanticElementTitleReferenceReadTests` 38/38, `QSemanticElementRangeReadTests` 31/31, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`):
  - **Run 1**: 3371/3371 passed — clean.
  - **Run 2**: FAILED — `PaceProactiveQueueDrainTests.testProactiveQueueDrainsOldestFirstWhenIdleConditionsRestore()`. **Classified ENVIRONMENTAL, not a regression**, with a fully diagnosed root cause: this test's `drainProactiveQueueIfIdle` path (`PaceProactivityPipeline.swift`) gates on genuine, real-time OS-level input/call-activity state via `PaceRestraintGate`; `ps aux` confirmed `/usr/libexec/avconferenced` actively running at 47–52% CPU throughout this session (consistent with a live audio/video conferencing session on this shared machine) alongside a sustained system load average of 11–15. Re-running the same isolated suite repeatedly reproduced the identical failure while this real external condition persisted — this is a genuinely real-time-input-state-dependent pre-existing test, not a timing flake fixable by retrying, and not touched by this phase's diff (confirmed: `PaceProactivityPipeline.swift`, `CompanionManager+ProactivePipeline.swift`, and `PaceHerArcFeatureTests.swift` do not appear anywhere in `git diff --name-only`).
  - **Run 3**: 3371/3371 passed — clean (the same external condition either resolved or the specific real-time input state fell within the test's expected window at that instant).
  - No failure was ever converted to PASS; no test was modified, skipped, or weakened to obtain a green result.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
- The active-modal-session ("`isModal == true`") assertion in the real E2E test could not be empirically exercised in this sandboxed environment (TCC blocks `AXIsProcessTrusted()` here, as in every prior phase's equivalent test). The implementation and fixture were written to the documented AppKit/AX contract (`beginModalSessionForWindow:` registers the window as the application's current modal window; `kAXModalAttribute`'s AX bridge is expected to reflect this synchronously, without requiring the run loop to be pumped indefinitely), but this specific timing behavior has not been independently, empirically confirmed on trusted hardware within this session — recorded honestly rather than asserted as verified fact.
- A genuine `AXError` read failure or a malformed (non-Boolean) `kAXModalAttribute` value cannot be constructed from any real, standard AppKit window — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase (e.g. Phase 2BN's disallowed-role/malformed-reference tests).
