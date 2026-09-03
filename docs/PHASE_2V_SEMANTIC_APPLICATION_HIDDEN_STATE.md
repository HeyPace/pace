# Phase 2V — Semantic Application Hidden State (`ui.set_application_hidden`)

Q's fifteenth controlled UI-interaction capability, and its first (after `ui.activate_application`,
Phase 2N) to deliberately bypass `AXUIElement` entirely in favor of a native, fully-documented
AppKit API.

## Native API, not AX — following the `ui.activate_application` precedent

Mutation uses `NSRunningApplication.hide()`/`.unhide()`; state is read via `.isHidden`. No
`AXUIElement`, `AXIsProcessTrusted()`, `CGEvent`, keyboard/mouse simulation, coordinates,
AppleScript, or shell automation anywhere in the implementation. This mirrors
`ui.activate_application`'s own architectural precedent for application-level operations exactly —
the same class of operation (application lifecycle/visibility), the same resolution primitive
(`NSWorkspace.shared.runningApplications`, exact `localizedName` match), and the same reason: these
operations have first-class, unambiguous AppKit APIs, so routing them through raw Accessibility
would be an unnecessary and less-documented indirection.

## Scope: exactly one application, one boolean visibility state

No blind toggle: `desiredHidden` must be exactly `"true"` or `"false"`. No activation, frontmost
change, focus, minimize, quit, window manipulation, or application enumeration is bundled into
this capability. Genuinely bidirectional (like `ui.set_window_minimized`, unlike
`ui.select_table_row`/`ui.select_outline_row`'s selection-only restriction) — both directions are
fully supported, symmetric, idempotent target states.

## Capability contract

Registered as `"ui.set_application_hidden": ("app", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to resolve, matched EXACTLY against `localizedName`. |
| `desiredHidden` | yes | Must be exactly `"true"` or `"false"` — both directions supported. |

### Target resolution — identical discipline to `ui.activate_application`

`NSWorkspace.shared.runningApplications.filter { $0.localizedName == requestedName }` — exact
match only, never substring/prefix/suffix/fuzzy/case-insensitive. Zero matches fails closed
(`APP_NOT_RUNNING`); more than one exact match fails closed (`APP_AMBIGUOUS_MATCH`) rather than
guessing which instance was intended — the identical resolution helper `executeActivateApplication`
already established, reused with the same discipline rather than duplicated with weaker checks.

## Why Level 2 (not Level 1, despite `ui.activate_application`'s precedent)

Hiding affects **every** window of the target application simultaneously — a broader blast radius
than a single-window mutation (`ui.set_window_minimized` is also Level 2) or a frontmost-ordering
change (`ui.activate_application`'s Level 1, which changes nothing about any window's own state).
Never downgraded merely because the operation looks visually harmless.

## Mutation and idempotency (both directions)

`target.hide()`/`target.unhide()` only. Before any mutation, `target.isHidden` is read; if it
already equals `desiredHidden` — in **either** direction — no method call is made at all, and no
approval is consumed for a mutation that was never needed. A bounded ~1s poll (10×100ms, mirroring
`executeActivateApplication`'s/`executeAppQuit`'s identical pattern) gives the OS time to actually
apply the change before returning; this poll is a UX/timing convenience only, never itself treated
as proof of success.

## Independent verification — pid-anchored, never trusts the mutation call

A new `QVerificationStrategy.applicationHiddenStateMatchesDesired` re-resolves the application by
its **stable `processIdentifier`** (never `localizedName` again — a same-named replacement process
launched after the original quit must never be misread as the original target) and independently
re-reads `.isHidden` fresh, comparing it against `desiredHidden`. Structurally identical to
`.processIsFrontmost`'s own pid-anchored model. If the process can no longer be found by that pid,
verification is `.failed` — a process disappearing after a hide/unhide request is never
automatically interpreted as success.

## Recovery: observation-first, bidirectional, no blind replay

`QTaskRecoveryManager` gained a `case "ui.set_application_hidden":` branch. Unlike verification
(which has a persisted pid available via `outputData`), recovery only has the dispatch-time
`arguments` (`applicationName`), so — identical to `ui.activate_application`'s own recovery
discipline — it performs a **fresh, unambiguous name resolution** (`exactMatches.count == 1`)
rather than reconstructing a stale pid. If the target already reports the desired hidden state,
the step is recognized complete via genuine observation. Otherwise the step resets to `pending` —
never a blind replay of `hide()`/`unhide()` — and a resumed execution requires both a brand-new
`QExecutionIdentity` and a genuinely fresh Level 2 approval grant. No directional filter is
applied (unlike `ui.select_outline_row`'s one-way-only recovery) since both directions are
equally valid, resumable target states.

## Provenance & privacy

Registered under `toolFamily: "app"` — the same family `ui.activate_application`/`app.quit`
already use, no new provenance taxonomy invented. Only a boolean hidden state + application
name/pid ever crosses into audit/durable-state/HUD — never window contents, AX descendants, screen
contents, or document contents (this capability never reads any of those in the first place, since
it never touches `AXUIElement`).

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QExecutionService.swift` — `executeSetApplicationHidden` dispatch + implementation, mirroring
  `executeActivateApplication`'s structure line-for-line where the operations are analogous
  (resolution, ambiguity handling, bounded poll) and diverging only where the semantics genuinely
  differ (read-before-mutate against `isHidden` instead of `frontmostApplication`, bidirectional
  `hide()`/`unhide()` instead of one-way `activate()`).
- `QActionVerification.swift` — `.applicationHiddenStateMatchesDesired` strategy + verification,
  structurally mirroring `.processIsFrontmost`.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first, bidirectional recovery branch.
- `leanring-buddyTests/QSemanticApplicationHiddenStateTests.swift` — new focused suite (31 tests).

**`QBridgeAdapters.swift` was NOT touched** — the first UI-family capability in this codebase that
required zero changes to the AX bridge layer, since it uses no Accessibility API at all.
`ui.activate_application` (the only other native-API capability) is unmodified.

## Real macOS E2E — result, and an honestly investigated session limitation

`QSemanticApplicationHiddenStateTests.realMacOSE2ESetApplicationHidden` launches TextEdit as a
real, distinct, harmless helper application — the exact same fixture
`QSemanticApplicationActivationTests` (Phase 2N) already uses — and, unlike every AX-based
capability in this codebase, is **not** gated on `AXIsProcessTrusted()`.

**Investigated finding**: in this isolated test-runner session, `NSRunningApplication.hide()` was
observed to return `accepted=false` — the OS explicitly **rejects** the hide request — when called
from a process with no real `NSApplication`/activation-policy context. An out-of-process probe
(a standalone `swift` script, run independently of both XCTest and this capability's own
implementation, to rule out any test-harness-specific cause) confirmed
`NSRunningApplication.current.activationPolicy` reads `-1` (not a valid `.regular`/`.accessory`/
`.prohibited` value) in this session, and that `hide()` genuinely never changes `isHidden` when
called under these conditions — `unhide()` carries the identical limitation. This is a
session/calling-process limitation, not a defect in `executeSetApplicationHidden`: its own
independent, fresh re-verification correctly reports `.failed` rather than fabricating success
whenever the underlying OS call does not actually change state — exactly the fail-closed behavior
this architecture is designed to guarantee. Every test that depends on a real mutation taking
effect uses a dedicated capability probe (`realHideUnhideMutationIsFunctional`) and honestly
no-ops when this limitation is detected, the same convention every `AXIsProcessTrusted()`-gated
test in this codebase already establishes, generalized to this capability's own (non-AX) OS-level
permission dependency. **Real AX E2E was therefore NOT exercised with a genuine state transition
in this session** — but this is the first capability whose E2E path does not depend on
Accessibility Trust at all, and the limitation encountered is well-isolated, independently
reproduced outside the test harness, and does not implicate the implementation's correctness in
any way. Every deterministic, non-mutation-dependent test (31/31 in this phase's suite) ran for
real and passed, including the full schema/registration, input-validation, approval lifecycle
(grant/deny/single-use/cross-authorization/persisted-non-authorization/budget-exhaustion),
bidirectional recovery (with a nonexistent application, which needs no real OS mutation), and
structural forbidden-API/no-hidden-activation checks.

## Known limitations

1. **`hide()`/`unhide()` are confirmed non-functional from this specific isolated test-runner
   session** (see above) — real-hardware validation on a genuinely interactive, properly-signed
   application context (e.g. the actual Pace.app run via Xcode with a normal activation policy)
   remains required before this capability's real-world mutation behavior is empirically proven.
2. Application-name uniqueness in real-world usage carries the same class of open question already
   flagged for window titles in Phase 2U — the capability fails closed correctly on ambiguity, but
   this affects real-world applicability, not correctness.
3. The bounded ~1s post-mutation poll's timing assumption (mirrored from
   `executeActivateApplication`) is unconfirmed for `hide()`/`unhide()` specifically on real
   hardware, pending the same validation gap noted in (1).
