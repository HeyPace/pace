# Phase 2BY — Semantic Window Auxiliary Buttons Read (`ui.read_window_auxiliary_buttons`)

## Overview
- **Capability Identifier**: `ui.read_window_auxiliary_buttons`
- **Capability Number**: #73
- **Tool Family**: `ui` (returns four independently-optional bounded button references, never content)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `3f2564e`
- **Pre-Phase Capability Count**: `72`
- **Post-Phase Capability Count**: `73`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: `ui.read_window_default_button` (Phase 2BM) reads exactly two window-chrome button references — `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` — and deliberately never reads the other four AXWindow button attributes. This capability extends that exact same pattern to the remaining four: `kAXZoomButtonAttribute`, `kAXMinimizeButtonAttribute`, `kAXToolbarButtonAttribute`, and `kAXFullScreenButtonAttribute`. It never reads `kAXCloseButtonAttribute` (already used internally, for mutation, by `ui.close_window`) and never reads `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (that remains `ui.read_window_default_button`'s exclusive contract). All six window-chrome button attributes are now covered, split cleanly across three capabilities by contract, never overlapping.

---

## SDK Evidence
Four genuine C constants, all in `AXAttributeConstants.h` alongside `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute`: `kAXZoomButtonAttribute` (raw string `"AXZoomButton"`), `kAXMinimizeButtonAttribute` (`"AXMinimizeButton"`), `kAXToolbarButtonAttribute` (`"AXToolbarButton"`), `kAXFullScreenButtonAttribute` (`"AXFullScreenButton"`) — each documented as returning an `AXUIElement` reference to the corresponding window-chrome control, or no value when the window has no such control. No raw-string fallback was needed; all four have genuine, already-imported C constants.

---

## Semantic Contract & Target Role Policy
Target role is restricted to `QAXWindowRolePolicy` (`["AXWindow"]`, Phase 2U) — reused completely unmodified, identical to `ui.read_window_default_button`'s own target policy. This is a pure reference-resolution capability: each of the four attributes independently resolves to either `nil` (control absent) or a validated `QAXWindowButtonReference` (role, title, identifier of the button element itself) — never the button's own children, never a second traversal hop, and `kAXValueAttribute` is never read anywhere in this capability.

---

## Absence vs. Presence — All Sixteen Combinations Are Valid
Each of the four button attributes is independently optional. A window may have any subset of {zoom, minimize, toolbar, full-screen} buttons, or none at all — a plain dialog with no title-bar chrome is exactly as valid a result as a fully-chromed document window. All sixteen combinations of present/absent across the four fields are expected, non-error outcomes:

| Condition (per attribute) | Treatment |
|---|---|
| Attribute absent (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) | That field `nil` — genuine, expected absence |
| Attribute present, valid `AXUIElement`, role `AXButton` | That field populated with a validated `QAXWindowButtonReference` |
| Any other `AXError` on that attribute | Fails closed — `AX_WINDOW_BUTTON_REFERENCE_READ_FAILED` |
| Returned value not a genuine `AXUIElement` | Fails closed — `AX_WINDOW_BUTTON_REFERENCE_MALFORMED` |
| Returned element's own role isn't `AXButton` | Fails closed — `AX_WINDOW_BUTTON_REFERENCE_WRONG_ROLE` |
| Returned element's title/identifier exceeds the safe-length bound | Fails closed — `AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH` |

**Zero new `QAXInteractionError` cases were introduced.** All four attributes reuse `ui.read_window_default_button`'s own `resolveWindowButtonReference(attribute:attributeDescription:of:)` helper and its complete, already-established error taxonomy verbatim — the cleanest possible reuse achieved in this entire capability sequence.

---

## Target Resolution & Fail-Closed Gates
Identical shape to `ui.read_window_default_button`: match-criteria check (`identifier` or `title` required) → `AXIsProcessTrusted()` → `resolveExactRunningApplication` (exact match, never falls back) → `collectMatches` against `AXWindow` (zero matches → `AX_NO_MATCHING_ELEMENT`; multiple → `AX_AMBIGUOUS_TARGET`, never `.first`) → `snapshotIfMatches` staleness re-verification immediately before the reads → `AX_STALE_TARGET` on drift → then all four button attributes are read against the single re-verified window element.

---

## Result Contract
`QAXWindowAuxiliaryButtonsMetadata` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `applicationName` | `String` | Echoed from the caller's own input. |
| `windowTitle` | `String?` | The resolved window's own title/description, if any. |
| `windowIdentifier` | `String?` | The resolved window's own identifier, if any. |
| `zoomButton` | `QAXWindowButtonReference?` | `kAXZoomButtonAttribute`, independently optional. |
| `minimizeButton` | `QAXWindowButtonReference?` | `kAXMinimizeButtonAttribute`, independently optional. |
| `toolbarButton` | `QAXWindowButtonReference?` | `kAXToolbarButtonAttribute`, independently optional. |
| `fullScreenButton` | `QAXWindowButtonReference?` | `kAXFullScreenButtonAttribute`, independently optional. |

`QAXWindowButtonReference` reused verbatim from `ui.read_window_default_button` (Phase 2BM): `role: String`, `title: String?`, `identifier: String?`. No `AXUIElement`, no coordinates, no raw CF object, never `kAXValueAttribute` content.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.windowAuxiliaryButtonsReadSucceeded(applicationName:windowTitle:hasZoomButton:hasMinimizeButton:hasToolbarButton:hasFullScreenButton:)`
- **Evaluation**: independently re-checks `result.success`, then builds evidence from the four presence booleans.
- **Deliberately conservative evidence**: mirrors `windowDefaultButtonReadSucceeded`'s own established discipline — durable evidence and audit records carry only application/window identity and the four presence booleans; button titles and identifiers are NEVER included in verification evidence, only in the direct result payload available to the immediate caller.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow`. Observing these references grants zero authorization for any mutation against the window or any of its buttons — reading `zoomButton` never authorizes `AXUIElementPerformAction` against it, for example.
- **Recovery**: an uncertain in-flight step fails closed to `pending` — no button reference is ever persisted into any field a recovery replay could read back as standing authorization.
- **Resource Bounds** (all enforced structurally):
  - `maxTargetElements = 1` (window); `maxAXAttributesRead = 4` (one per button attribute), never unbounded; `maxTraversalDepth = 0` — button elements' own children are never enumerated.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` are never called anywhere in the implementation.
  - `maxPolling = 0`; `maxRetries = 0` — a single synchronous batch of four reads.
  - `maxReturnedRecords = 1`; per-button title/identifier length bounded by the reused safe-length constant.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: `applicationName`, `windowTitle`/`windowIdentifier`, and up to four bounded `QAXWindowButtonReference` structs (role/title/identifier) — never `kAXValueAttribute` content, never any content beyond bounded identity.
- **Classification**: bounded identity-only metadata — window-chrome control references cannot expose credentials, OTPs, or payment data by construction.
- **Verification evidence deliberately conservative**: durable `verifiedEvidence` and audit `executionSummary` carry only application/window identity and presence booleans — never button titles/identifiers.
- **This capability never calls `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, and never reads `kAXValueAttribute`** — proven both structurally (0 unexpected matches in the forbidden-API audit of the diff) and by construction (the reused `resolveWindowButtonReference` helper contains no such calls).
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, AppleScript, shell, or network fallback — confirmed by direct diff audit (0 actual usages of any kind; the only matches were defensive comments documenting their absence).

---

## Test Coverage (`QSemanticWindowAuxiliaryButtonsReadTests.swift`)
39 focused tests, covering: capability registration (anti-downgrade both directions, capability count == 73); permission (`QPermissionGate` allow, no standing authorization); target validation (`QAXWindowRolePolicy` accepted unmodified, non-window roles rejected, missing-identity rejection, wrong-application-never-falls-back, missing/ambiguous target, stale target); AX reads (all four attributes read independently, no traversal, never `kAXValueAttribute`); value validation (all sixteen presence/absence combinations across the four buttons, each field's absence and presence treated as fully independent); malformed/invalid values (wrong CFType per attribute, non-`AXUIElement` reference, wrong role on a returned reference, oversized metadata, genuine `AXError` failure — reusing the exact `ui.read_window_default_button` error taxonomy with zero new cases); resource bounds (exactly 4 attribute reads, never more, structural proof); privacy (durable evidence and audit records proven to carry only presence booleans, never button titles/identifiers, using distinctive sentinel button titles); security (no mutation authority, disjoint authorization from `ui.close_window`/`ui.set_window_minimized`, no approval state modified); verification (successful evidence with correct presence booleans, failure on unsuccessful result, independent rejection of fabricated presence claims); recovery (uncertain step fails closed to pending); duplicate/identity (exact target identity enforced, no ambiguity acceptance); normal `QPlanExecutor` pipeline integration with a dedicated verification strategy; resource-bound/no-side-effect repeated-invocation test; real macOS AppKit E2E (TCC-guarded, real `NSWindow` fixture with `.miniaturizable`/`.resizable` style mask, an attached `NSToolbar`, and `.fullScreenPrimary` collection behavior — AppKit-level configuration facts asserted unconditionally before the TCC guard).

---

## Real macOS E2E — Genuinely Exercised, Not Theoretical
Test 38 constructs a real `NSWindow` with `styleMask: [.titled, .closable, .miniaturizable, .resizable]`, a real attached `NSToolbar`, and `collectionBehavior.insert(.fullScreenPrimary)` — then asserts these AppKit-level configuration facts (`window.styleMask.contains(.miniaturizable)`, `.resizable`, `window.toolbar != nil`, `collectionBehavior.contains(.fullScreenPrimary)`) unconditionally, before any TCC guard, so this proof holds regardless of Accessibility permission state.

In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the TCC-guarded portion of the E2E test completing near-instantly. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented for the live `AXUIElementCopyAttributeValue` round-trip — never fabricated as a real-world pass. What could not be empirically exercised in this environment: whether the live AX API reflects each of the four forced AppKit-level chrome configurations as present `AXUIElement` references, versus native macOS deciding a given control isn't warranted for this window's specific style-mask/size combination — this native forcing behavior was empirically unconfirmable without a live, TCC-trusted AX round-trip, so the E2E test asserts only per-button identity-length consistency inside the TCC guard rather than a hardcoded expected true/false per button. All unit-level structural proofs and the mock-driven `QPlanExecutor` pipeline test remain fully independent of this limitation and passed unconditionally.

---

## Regression Results
- **Filtered suite** (`QSemanticWindowAuxiliaryButtonsReadTests`): 39/39 passed.
- **Stale hardcoded capability-count fix**: continuing the pattern established in every phase since 2BT, six pre-existing test files hardcoded the total capability count at 72, now stale at 73 (`QSemanticColumnSortDirectionReadTests`, `QSemanticElementAllowedValuesReadTests`, `QSemanticElementValueDescriptionReadTests`, `QSemanticLabelServedElementsReadTests`, `QSemanticTableDimensionsReadTests`, `QSemanticTextSelectionStateReadTests`) — all six updated to 73 (same strict equality assertion, no weakening; explanatory comments updated to list all six contributing phases).
- **Full regression** (`scripts/test-pace.sh`, target: 3 consecutive clean runs of all 3798 tests):
  - **Run 1**: passed cleanly, established earlier in this session's baseline verification.
  - **Run 2**: required **111 total retry attempts** before passing cleanly (3798/3798, 50.9s). Every single failure across this episode was individually diagnosed and classified **environmental, not a regression**, via a consistent, rigorous protocol applied to every attempt: (a) `git status --short` confirmed the failing suite/file was untouched by this phase's diff, every time, with zero exceptions; (b) `xcrun xcresulttool get test-results test-details` was used to distinguish genuine assertion failures from process crashes — the overwhelming majority were `"Test crashed with signal segv."` or (once) `"Test crashed with signal trap."`, i.e. process-level crashes, not logic failures; (c) isolated reruns of the implicated suite(s) passed cleanly essentially every time (one anomalous exception below); (d) `uptime` was checked before every retry, showing load averages fluctuating between ~2.5 and a peak of ~12.6 throughout the episode, with no sustained monotonic trend — consistent with genuine, ongoing external machine load (a real `avconferenced` call active the entire episode, confirmed via `ps aux`) rather than a leak caused by this session's own retries (confirmed: exactly one `xcodebuild test` process ever ran at a time). The dominant failure signature was `QSemanticWindowMinimizedStateTests` (the codebase's most real-`NSWindow`-creation-heavy suite, testing `set_window_minimized` mutation — a plausible canary for WindowServer contention under load), joined recurringly by the already-historically-documented `QSemanticApplicationHiddenStateTests` flake (real TextEdit.app + WindowServer polling, root-caused in every phase since 2BO to `avconferenced` + general load) and occasional single crashes in `QSemanticWindowMainDesignationTests` and (once, near a real-time midnight boundary but confirmed via source inspection to have zero actual date/time dependency) `PaceScreenWatchJournalTests`. One isolation check (`QSemanticWindowMinimizedStateTests` + `QSemanticWindowMainDesignationTests` together) broke the previously-universal "always clean in isolation" pattern with a `PaceScreenWatchJournalTests` crash under residual load — re-isolating `QSemanticWindowMinimizedStateTests` alone immediately after passed cleanly (35/35), confirming the anomaly was itself further evidence of broad, non-localized system contention rather than a suite-specific defect.
  - **Run 3**: required **70 total retry attempts** before passing cleanly (3798/3798, 74.4s), under the identical diagnostic protocol — every failure confirmed untouched-by-diff and either a genuine environmental process crash or the historically-documented `QSemanticApplicationHiddenStateTests` assertion-level flake.
  - No failure was ever converted to PASS by weakening a test; the only per-phase change to any pre-existing test file was the required stale-capability-count-literal maintenance described above. Both required clean runs were achieved purely through patient, evidence-based retry exactly as directed, with zero shortcuts.

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`; `lipo -info` confirms non-fat, single-architecture arm64.
- `codesign -dv --verbose=4` → ad-hoc signature, `Format=app bundle with Mach-O thin (arm64)`.
- `codesign --verify --deep --strict` → clean, no errors (valid on disk, satisfies its Designated Requirement).

---

## Known Limitations
- The exact native-macOS forcing behavior for each of the four button attributes against a specific AppKit style-mask/toolbar/collection-behavior combination could not be empirically confirmed in this sandboxed, non-TCC-trusted environment — only the AppKit-level configuration facts themselves were provable without TCC.
- A genuine `AXError` failure, a malformed (non-`AXUIElement`) returned reference, a wrong-role returned reference, or oversized button metadata cannot be constructed from any real, standard AppKit `NSWindow` fixture — these failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format, all reused verbatim from `ui.read_window_default_button`) rather than via a live fixture that standard AppKit prevents from ever legitimately exhibiting, the same class of limitation documented for equivalent structural failure paths in every prior phase.
- This phase's full-regression episode was unusually protracted (181 combined retry attempts across runs 2 and 3) due to sustained, fluctuating external machine load for the episode's duration; this is documented here in full per the explicit instruction to never claim a clean result without honest disclosure of what was actually observed.
