# Phase 2U — Semantic Window Minimized State (`ui.set_window_minimized`)

Q's fourteenth controlled UI-interaction capability, and its first at the **window level** —
every prior capability (Phase 2H through 2T) targets a control *inside* a window; this is the
first to target the window itself.

## Exact macOS AX semantics — confirmed against the authoritative SDK headers

Confirmed directly against `AXAttributeConstants.h`:

| Symbol | Documented semantics (verbatim from the header) | Role in this capability |
| --- | --- | --- |
| `kAXWindowRole` | — | The target's own base role — `QAXWindowRolePolicy`'s only allowed role. |
| `kAXMinimizedAttribute` | *"Whether a window is currently minimized to the dock. Value: A CFBooleanRef. True means minimized. **Writable? Yes.**"* | The authoritative mutation and verification target — read AND written directly. |

Unlike every prior row/tab/disclosure capability (`ui.select_tab`, `ui.toggle_disclosure`,
`ui.select_table_row`, `ui.select_outline_row`), no press is used: `kAXMinimizedAttribute` is
documented as directly writable, the same "attribute IS the authoritative state" reasoning
`ui.set_slider_value` already established for `kAXValueAttribute`, applied here instead.

**Deliberately not used, and why:** `kAXRaiseAction` (`"AXRaise"`) is a real, defined AX action
constant, but Apple's own `AXActionConstants.h` ships its `@discussion` block **entirely empty** —
no documented behavior exists for it. This capability never uses it. `kAXMinimizeButtonAttribute`
is a real, defined, but explicitly *read-only* convenience reference to the titlebar minimize
button (`"Writable? No."`) — this capability never presses it, and never resolves it as a target.

## Scope: exactly one window, minimized state only, no bundled operations

No close, raise, resize, move, fullscreen, activation, or focus is bundled into this capability.
`AXUIElementCreateApplication` — the same primitive every prior capability already uses to
resolve its target — is a pure AX object-reference constructor with no activation side effect;
this capability never calls `NSRunningApplication.activate()`, never writes
`kAXFocusedAttribute`, and never invokes any window-ordering action. The operation remains
independently scoped exactly as required.

## Capability contract

Registered as `"ui.set_window_minimized": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXWindow` — the only allowed role. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present (identifier-preferred). |
| `title` | one of `identifier`/`title` | Matched against the window's title, only when `identifier` is absent. |
| `desiredMinimized` | yes | Must be exactly `"true"` or `"false"` — **both directions are fully supported**. |

No coordinate, index, or fuzzy-matching parameter exists, and none is structurally reachable.

### Genuinely bidirectional — a deliberate departure from Phase 2S/2T

`ui.select_table_row` and `ui.select_outline_row` both restrict `desiredSelected` to `"true"`
only, refusing `"false"` categorically. This capability does **not** carry that restriction:
`kAXMinimizedAttribute` write is symmetric and equally well-defined in both directions (unlike
row/tab deselection, which AX provides no reliable mechanism for), so both `true` and `false` are
fully supported, idempotent, independently-verified target states.

### Target identity: title uniqueness is the primary new risk

Windows rarely carry a meaningful `AXIdentifier` in practice (unlike buttons/rows, which commonly
do), so title is expected to be the primary match path for this capability more often than for any
prior one. The identical exact-match/ambiguity-fails-closed discipline applies unchanged: if
multiple windows share a title and no identifier disambiguates them, resolution reports
`ambiguousTarget(count: 2+)` and is refused — **never** the first/last/frontmost window, **never**
window order/index as a fallback, **never** an invented identifier. This reuses the exact same
`collectMatches`/`snapshotIfMatches` helpers every prior capability already uses, unmodified.

## Why Level 2

Consistent with every other per-element/per-target AX mutation capability. A window's minimized
state is not downgraded to Level 1 merely because minimizing sounds visually harmless — it is a
genuine, user-visible state change with the same approval discipline every prior L2 capability
already carries.

## Mutation: the proven `ui.set_slider_value` direct-write mechanism, applied to a boolean

`AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, kCFBooleanTrue/kCFBooleanFalse)`
only — never `AXUIElementPerformAction` (unlike every row/tab/disclosure capability), never the
read-only `kAXMinimizeButtonAttribute` convenience reference, never `kAXRaiseAction`, never
NSWindow API mutation, CGEvent, keyboard, mouse, coordinate, AppleScript, or shell interaction.

## Idempotency and verification (both directions)

- **Idempotency**: before any write, `kAXMinimizedAttribute` is read (once at resolution, once
  again immediately before any dispatch decision — a minimized-state-drift staleness check,
  refusing on mismatch via the existing generic `QAXInteractionError.valueDriftDetected`,
  mirroring `ui.set_slider_value`'s discipline). If it already equals `desiredMinimized` — in
  **either** direction — no write is performed at all, and no approval is consumed for a mutation
  that was never needed. `changeKind: .alreadyDesired` is itself the deterministic, structural
  proof.
- **Verification**: a new `QVerificationStrategy.axWindowMinimizedStateMatchesDesired`
  independently re-resolves the target and re-reads `kAXMinimizedAttribute` fresh, comparing it
  directly against `desiredMinimized`. A successful attribute-set call is never itself treated as
  proof of success. State is **never** inferred from window position, visibility, frontmost
  state, Dock appearance, or title — `kAXMinimizedAttribute` is the sole authoritative source. A
  window's disappearance after the request is never automatically interpreted as success.

## Recovery: observation-first, bidirectional, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.set_window_minimized":` branch
that reuses `observeWindowMinimizedStateEvidence` — the exact same independent, read-only
primitive verification uses, not a parallel resolver. Unlike `ui.select_outline_row`'s recovery
branch (which only ever resumes toward `desiredSelected=true`, since that is the only value the
capability ever accepts), this branch applies no directional filter: a persisted step targeting
either `true` or `false` is checked against genuine observation. If the target already reports the
requested state, the step is recognized complete. Otherwise, the step resets to `pending` — never
a blind replay — and a resumed execution requires both a brand-new `QExecutionIdentity` and a
genuinely fresh user approval grant.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior. A window's
minimized state is a UI-chrome STATE fact, not content. `QAXWindowMinimizedOutcome`/audit/
durable-state records carry only `targetIdentity`, `changeKind`, `previousMinimized`,
`currentMinimized`, and `desiredMinimized` — never the window's own content, never a descendant
AX tree dump, never a screenshot.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXWindowRolePolicy`, `QAXWindowMinimizedChangeKind`,
  `QAXWindowMinimizedOutcome`, `QAXWindowMinimizedEvidence`, `setWindowMinimizedState`,
  `observeWindowMinimizedStateEvidence`, and two new `QAXInteractionError` cases
  (`disallowedWindowRole`, `windowMinimizedStateReadFailed`) — every other error case
  (`missingMatchCriteria`, `noMatchingElement`, `ambiguousTarget`, `staleTarget`,
  `accessibilityPermissionDenied`, `applicationNotAvailable`, `valueDriftDetected`,
  `setValueFailed`) is reused from the existing enum, unmodified. A deliberate omission relative
  to every prior mutation capability: no `targetDisabled`/`isEnabled` gate — "enabled" is not a
  meaningful concept for a window itself the way it is for a control, and the approved Discovery
  contract names only role and `kAXMinimizedAttribute`, so no unapproved extra check was added.
- `QExecutionService.swift` — `executeSetWindowMinimized` dispatch + implementation.
- `QActionVerification.swift` — `.axWindowMinimizedStateMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first, bidirectional recovery branch.
- `leanring-buddyTests/QSemanticWindowMinimizedStateTests.swift` — new focused suite (35 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified. Every prior semantic
UI capability is unmodified.

## Real macOS AX E2E — result

`QSemanticWindowMinimizedStateTests.realMacOSE2ESetWindowMinimized` (and every other AX-trust-gated
test in the suite) uses a genuinely real, live `NSWindow` — unlike every custom-role-overriding
fixture Phase 2S/2T needed, **no override is required at all**: a real `NSWindow` is already a
genuine `AXWindow`-role AXUIElement via default AppKit Accessibility bridging, with
`kAXMinimizedAttribute` already wired to the window's own real miniaturized state. This capability
requires Accessibility permission, so every such test is gated on `AXIsProcessTrusted()`.

In the isolated test-runner environment used to validate this phase, `AXIsProcessTrusted()` was
directly confirmed to return `false` (verified via a temporary diagnostic print, executed once and
removed before the final commit) — the same finding independently documented for every prior AX
capability in this codebase (Phase 2H through 2T). **Real AX E2E was therefore NOT exercised in
this session** — every AX-trust-gated test no-op'd via its `guard AXIsProcessTrusted() else {
return }` rather than fabricating a pass. Every deterministic, non-AX-dependent test (35/35 in
this phase's suite) ran for real and passed, including the full schema/registration, role-policy
gate, approval lifecycle (grant/deny/single-use/cross-authorization/persisted-non-authorization/
budget-exhaustion), bidirectional recovery, verification-strategy independence, and structural
forbidden-API/no-hidden-activation checks — none of which depend on live AX role/attribute
reporting.

## Known limitations

1. **Whether `kAXMinimizedAttribute`'s documented "Writable? Yes" holds identically for every
   third-party application's windows (not just this session's own `NSWindow` fixture) is
   unconfirmed empirically** — the SDK documentation is unambiguous and this session's fixture
   requires no override at all (the strongest evidentiary position of any phase so far), but no
   live AX query was possible in this environment.
2. **Window-title uniqueness in real-world usage is unconfirmed** — many common apps (e.g.
   multiple "Untitled" documents) may produce genuinely ambiguous targets in practice; the
   capability fails closed correctly in that case, but this affects real-world applicability, not
   correctness.
3. `AXIdentifier` on real, production windows (as opposed to this session's fixture, which sets it
   explicitly) is unconfirmed to be reliably populated by third-party apps — the same class of
   open question already flagged for rows in Phase 2S/2T, inherited here for windows.
4. The identity/minimized-state observation-binding re-verify cannot protect against a mutation
   landing in the sub-millisecond window between its own two internal reads — the same documented,
   honest limitation every prior AX capability in this codebase already accepts.
5. No `isEnabled`/`targetDisabled` gate exists for this capability (see Files touched) — a
   deliberate scope decision, not an oversight, since "enabled" has no established meaning for a
   window in this codebase's existing AX vocabulary.
