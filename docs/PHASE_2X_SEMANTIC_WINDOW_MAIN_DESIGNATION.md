# Phase 2X — Semantic Window Main Designation (`ui.set_window_main`)

Q's seventeenth controlled UI-interaction capability. Designates exactly one
semantically-identified window as its application's **main** window — `kAXMainAttribute == true`
— and nothing else. **Select-only**: `desiredMain` must be `true`; `desiredMain: false` is
explicitly, deterministically rejected before any Accessibility call, never implemented as a
deselection or blind toggle.

## Exact macOS AX semantics — confirmed against the authoritative SDK header

Confirmed directly against `AXAttributeConstants.h`
(`/Applications/Xcode.app/.../ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXAttributeConstants.h`):

> `kAXMainAttribute` — *"Whether a window is the main document window of an application... Main
> does not necessarily imply that the window has key focus... Writable? Yes."*

This is the same class of directly-settable boolean window attribute as `kAXMinimizedAttribute`
(Phase 2U), reusing that phase's exact shape — but with one structurally important difference the
documentation itself calls out: **main is explicitly decoupled from key focus.** This capability
makes no claim whatsoever about activation, focus, raise, or frontmost-ness. It only requests
"make this exact window main" and observes only that exact window's resulting `kAXMainAttribute`
value.

## Why select-only

`kAXMainAttribute`, like `kAXSelectedAttribute` on a tab/row, has no reliable
AX-documented mechanism for cleanly "un-maining" a window without designating a replacement — by
direct analogy to `ui.select_tab` (Phase 2R) and `ui.select_outline_row`/`ui.select_table_row`
(Phases 2S/2T), `desiredMain: false` is refused deterministically, in both
`QBridgeAccessibility.setWindowMain` and `QExecutionService.executeSetWindowMain`, before any
Accessibility Trust check, application resolution, or AX call of any kind.

## Capability contract

Registered as `"ui.set_window_main": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXWindow` — the only allowed search-criterion role, reusing `QAXWindowRolePolicy` unmodified from Phase 2U. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`, only when `identifier` is absent. |
| `desiredMain` | yes | Must be exactly `"true"` — `"false"` is a deterministic, structural rejection. |

No coordinate, index, or window-order parameter exists, and none is structurally reachable.

## Why Level 2

Consistent with every other per-element AX mutation capability. A window's main-document status is
a real, application-visible state change, not downgraded merely because it sounds passive or is
decoupled from focus.

## Mutation and idempotency

`AXUIElementSetAttributeValue(kAXMainAttribute, kCFBooleanTrue)` on the resolved window — the
literal `kCFBooleanTrue` constant is always used, since `desiredMain: false` never reaches this
call site at all. Never `AXUIElementPerformAction` — unlike every prior row/tab/disclosure
capability, this is a direct attribute write with no equivalent "press."

- Target resolution reuses `collectMatches`/`snapshotIfMatches` unmodified — exact-match only,
  identifier-preferred, fails closed on zero/ambiguous matches, never fuzzy/substring/positional.
- Read-twice-around-dispatch drift check: `kAXMainAttribute` is read once at resolution
  (`mainAtSearch`) and again immediately before dispatch (`mainAtVerify`), reusing the existing
  generic `QAXInteractionError.valueDriftDetected` case — no new case needed, unlike
  `ui.set_window_minimized`, which needed no such reuse because it defined its own drift semantics
  identically inline.
- **Idempotent no-op**: if `mainAtVerify == true` already, `changeKind: .alreadyDesired` is
  returned with **no** `AXUIElementSetAttributeValue` call — the branch is structurally
  mutually exclusive with the write path, so `.alreadyDesired` is itself the proof no mutation
  occurred. No approval is "wasted" on a mutation that was never needed.
- An unreadable `kAXMainAttribute` throws the new `QAXInteractionError.windowMainStateReadFailed`
  case — never defaulted to `false`.

## Verification — closed-loop, independent, and deliberately activation/focus-agnostic

`QVerificationStrategy.windowMainStateMatchesDesired` (no `desiredMain` field — the capability's
own contract already guarantees it is always `true`) re-resolves the target **fresh** via
`QBridgeAccessibility.observeWindowMainEvidence` — the exact same primitive `QTaskRecoveryManager`
reuses for recovery, never a parallel resolver — and re-reads `kAXMainAttribute` independently.
`.verified` only when `currentMain == true`; `.failed` on a resolved-but-false read, an unreadable
state, or an unresolvable/ambiguous target. A successful `AXUIElementSetAttributeValue` return
value is never itself treated as proof — this strategy is the sole source of truth.

Critically, per this capability's contract, verification makes **no** implicit claim about
activation, focus, raise, frontmost-ness, or any visual change — a window that becomes main but
remains visually non-frontmost still counts as full capability success.

## No agent-side exclusivity enforcement

`kAXMainAttribute` exclusivity (at most one window "main" per application, in practice) is owned
**entirely** by the OS/application AX subsystem. This capability never enumerates sibling windows,
never issues a second `AXUIElementSetAttributeValue(kAXMainAttribute, kCFBooleanFalse)` call on
any other window, and never selects multiple windows. `collectMatches` is invoked exactly once per
call, scoped to the caller-supplied criteria, which structurally resolve to exactly one element or
fail closed. The capability only ever requests "make this exact window main" and observes only
that exact window's resulting state.

## Recovery — observation-first, no directional filter needed

`QTaskRecoveryManager`'s `"ui.set_window_main"` branch reuses `observeWindowMainEvidence`
directly — the same primitive verification uses. Since the capability's contract guarantees
`desiredMain` is always `true` (a persisted `"false"` step argument would never have been
dispatched in the first place), there is only one completion condition to check:
`currentMain == true`. An unresolvable/ambiguous target or unreadable state falls through to
`verified = false` (`pending`), never a blind replay — a resumed retry requires both a fresh
`QExecutionIdentity` and a fresh, real `QApprovalCoordinator` grant.

## Provenance, budget, privacy

- `toolFamily: "ui"` — no new taxonomy.
- Reuses `QAgentBudget`/`QResourceGuard` generically; no per-tool wiring, no unbounded
  enumeration/retry, no window enumeration of any kind (see exclusivity section above).
- Only window identity metadata (already-permitted `applicationName`/`role`/`identifier`/`title`)
  plus the boolean main state and verification status ever cross persistence/audit/HUD/log
  boundaries — never window contents, document text, AX descendants, screenshots, or OCR.

## Real macOS AX E2E and the two-window exclusivity observation

`AXIsProcessTrusted() == false` was confirmed directly in this session's isolated XCTest runner
(via a temporary diagnostic print, removed before commit — the same protocol every prior phase's
E2E gating used), consistent with every phase since 2N. All `AXIsProcessTrusted()`-gated real-AX
tests in `QSemanticWindowMainDesignationTests.swift` therefore honestly no-op in this environment
rather than fabricate a pass — including
`realMacOSE2ETwoWindowExclusivityObservation`, which was written to create two real `NSWindow`
fixtures, designate one main via this capability, then independently re-observe **both** windows'
`kAXMainAttribute` and log (non-failing) whatever the OS/AppKit window server actually produced for
the previously-main window — never asserting a direction a priori, never manually forcing state,
never agent-side-clearing anything. Because Accessibility trust was unavailable, this specific
empirical observation could not be captured in this run; the mechanism is implemented and unit-test
covered, but the actual two-window exclusivity behavior remains unobserved pending a trusted
environment. This limitation is reported honestly rather than fabricated, per this session's
established discipline (`docs/knowledge/failed-approaches.md`-adjacent honesty convention).

## Forbidden mechanisms — explicitly absent

No `kAXRaiseAction`, no `kAXFocusedAttribute`/`kAXFocusedUIElementAttribute` write, no
`NSRunningApplication.activate()`, no `NSWindow.makeKeyAndOrderFront`/`orderFront`/`orderWindow`
call, no direct `NSWindow` mutation, no `CGEvent`/`NSEvent`/keyboard/mouse simulation, no
coordinates, no AppleScript, no shell, no network — verified via source-level review and a
grep-based forbidden-symbol audit of the full Phase 2X diff.
