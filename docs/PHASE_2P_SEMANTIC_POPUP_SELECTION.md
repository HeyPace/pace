# Phase 2P — Semantic Popup Item Selection (`ui.select_popup_item`)

Q's ninth controlled UI-interaction capability — the third to use the two-press
open-then-select-atomically pattern (after Phase 2L's menu-bar selection), and the fifth to
compare an AX value directly (after Phase 2I's text entry, Phase 2K's state change, and Phase
2M's slider value). Resolves a single `AXPopUpButton` and — unless it already shows the desired
item — opens it and selects one item from it.

## Capability contract

Registered as `"ui.select_popup_item": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXPopUpButton` — a fail-closed allowlist, not a denylist. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`. |
| `itemTitle` | yes | The exact visible label of the item to select. |

No coordinate, index, or fuzzy-matching parameter exists.

## Why this closes a real, previously-unreachable gap

`ui.click_element` applies no role allowlist at all — any role, including `AXPopUpButton`, is
already a valid click target today. What it *cannot* do is **select a specific item** from a
popup: pressing the popup only opens it, and choosing an item requires a second, coordinated
press against a child that only exists once the popup is open. Two separately-approved
`ui.click_element` steps cannot reliably do this — the approval HUD appearing between them is
itself a focus-stealing event, and native popups (like native menus) dismiss on focus loss. This
is the exact architectural reasoning Phase 2L used to justify `ui.select_menu_item`'s existence,
and it applies identically here. Before this phase, selecting a popup option was the one common
AppKit form-control interaction with no reachable path at all in this codebase.

## Why Level 2

Consistent with every other per-element AX mutation capability (click/text-entry/state-change/
slider/menu-select/focus) — `ui.activate_application`'s Level 1 is the one deliberate exception,
reserved for application-level activation with no element target. Popup selection is squarely
element-level AX interaction with an app-defined, unbounded actual effect, so per-action human
approval — not content filtering — remains the safety mechanism, the same reasoning `ui.select_
menu_item` already established.

## Role allowlist — `AXPopUpButton` only, `AXComboBox` deliberately excluded

```swift
public enum QAXPopupRolePolicy {
    public static let allowedRoles: Set<String> = ["AXPopUpButton"]
}
```

`AXComboBox` is a materially different, hybrid text-entry-plus-selection control whose correct
interaction model has not been evaluated in this codebase — including it here would silently
expand this phase's scope rather than deliberately scoping a future one for it. This is an
explicit, deliberate exclusion, not an oversight.

## Mutation: the proven `ui.select_menu_item` mechanism, reused verbatim

`AXUIElementPerformAction(kAXPressAction)` to open the popup, a bounded poll for the target
`AXMenuItem` to become resolvable as a direct child of the popup's own opened `AXMenu`, then
`AXUIElementPerformAction(kAXPressAction)` to select it. The poll reuses `ui.select_menu_item`'s
exact constants (`maxMenuOpenPollAttempts = 10` × `menuOpenPollIntervalNanoseconds = 50ms` =
500ms total, never unbounded) rather than duplicating them with new values. Never
`AXUIElementSetAttributeValue` on the popup itself — press-driven only, matching standard AX
automation practice for this control type (unlike sliders, whose `AXValue` genuinely is a
directly-settable, range-bounded number).

## Idempotency and verification — stronger than `ui.select_menu_item`'s model

A genuine architectural improvement made possible by a fact `ui.select_menu_item` couldn't rely
on: unlike a momentary menu-bar command, an `AXPopUpButton` is a **persistent value-holding
control** whose `kAXValueAttribute` already reports its currently-selected label (`AXPopUpButton`
has been on `QAXElementReadRolePolicy`'s allowlist since Phase 2J). This lets both idempotency and
closed-loop verification compare the popup's own current value **directly** against the requested
item title:

- **Idempotency**: before any press, `kAXValueAttribute` is read (once at resolution, once again
  immediately before any dispatch decision — a value-drift staleness check, refusing on mismatch,
  mirroring `ui.set_element_state`'s/`ui.set_slider_value`'s discipline). If it already equals
  `itemTitle`, no press is performed at all — `changeKind: .alreadySelected` is itself the
  deterministic, structural proof that no mutation occurred (the only code path that returns
  without an intervening press sequence).
- **Verification**: a new `QVerificationStrategy.axPopupValueMatchesDesired` independently
  re-resolves the popup and re-reads its `kAXValueAttribute` fresh, comparing it directly against
  `requestedItemTitle`. Unlike `axMenuItemSelectionEvidence`'s indirect "item disappeared"
  heuristic (the strongest signal AX alone can generically provide for a momentary command), this
  is a direct, unambiguous comparison. A successful press sequence is never itself treated as
  proof of success — independent re-observation is the sole source of truth.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.select_popup_item":` branch that
reuses `observePopupValueEvidence` — the exact same independent, read-only primitive verification
uses, not a parallel resolver. If the popup already shows the requested item, the step is
recognized complete via genuine observation. Otherwise (unresolvable, or simply showing something
else), the step resets to `pending` — never a blind replay of the open+select press sequence. A
resumed execution requires both a brand-new `QExecutionIdentity` (minted fresh by `QPlanExecutor`
for every step) and a genuinely fresh user approval grant, since `QApprovalCoordinator`'s one-time
grants are in-memory only and never survive a crash/restart.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior. Popup item
labels are not inherently secret — the same class already exposed by `ui.click_element`'s and
`ui.select_menu_item`'s targeting metadata. `QAXPopupSelectionOutcome`/audit/durable-state records
carry only `targetIdentity`, `changeKind`, `previousValue`, and `requestedItemTitle` — no full
popup/menu hierarchy dump, no screenshot, no secure-field value, and no attribute beyond what is
needed for identity/status/evidence.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXPopupRolePolicy`, `QAXPopupSelectionChangeKind`,
  `QAXPopupSelectionOutcome`, `QAXPopupValueEvidence`, `selectPopupItem`,
  `observePopupValueEvidence`, and one new `QAXInteractionError` case
  (`disallowedPopupRole`) — every other error case is reused from the existing enum.
- `QExecutionService.swift` — `executeSelectPopupItem` dispatch + implementation.
- `QActionVerification.swift` — `.axPopupValueMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticPopupSelectionTests.swift` — new focused suite (34 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified.
`ui.focus_element`, `ui.activate_application`, `ui.open_app`, and `ui.select_menu_item` are all
unmodified — this phase reuses `ui.select_menu_item`'s proven mechanism without broadening it.

## Real macOS AX E2E — result

`QSemanticPopupSelectionTests.realMacOSE2ESelectPopupItem` uses a real, live `NSPopUpButton`
AppKit fixture with several known items, drives the full `ui.select_popup_item` plan through
`QCoreRuntime.submitIntent` + approval, and independently re-reads `kAXValueAttribute` afterward
to confirm the requested item was genuinely selected. This capability requires Accessibility
permission (`AXPopUpButton` interaction is definitionally an AX operation), so the test is gated
on `AXIsProcessTrusted()`. In the isolated test-runner environment used to validate this phase,
`AXIsProcessTrusted()` was directly confirmed to return `false` (verified via a temporary
diagnostic print, removed before commit) — the same finding independently documented for every
prior AX capability in this codebase (Phase 2H through 2O) in this identical environment. Real AX
E2E is therefore **blocked by Accessibility trust unavailability**, not by any defect in this
implementation. Every deterministic, non-AX-dependent test (34/34) ran for real and passed,
including the full approval lifecycle, recovery (both branches), verification independence, and
provenance/budget/privacy checks.

## Known limitations

1. `AXComboBox` is explicitly out of scope for this phase (see Role allowlist above) — a distinct,
   materially different control deserving its own future phase.
2. Exact item-label matching only — no substring/prefix/suffix/fuzzy fallback, consistent with
   every prior AX capability in this codebase.
3. Duplicate item labels within one popup are rejected as ambiguous, never guessed.
4. Real, interactive-hardware validation of the AX open+select press sequence and the direct
   `kAXValueAttribute` comparison is outstanding pending `AXIsProcessTrusted()` availability (see
   E2E section above), joining Phase 2K/2L/2M/2O's own still-outstanding AX-trust
   hardware-validation notes.
5. The identity/value observation-binding re-verify (resolve → re-verify snapshot/value,
   back-to-back inside one synchronous closure with no `await` between them) covers the gap
   between resolution and dispatch within a single call; it does not, and structurally cannot
   without an artificial delay seam in production code, protect against a mutation landing in the
   sub-millisecond window between the two reads themselves — the same documented, honest,
   non-deterministically-testable limitation every prior AX capability in this codebase already
   accepts.
6. `ui.select_menu_item`, `ui.focus_element`, `ui.activate_application`, and `ui.open_app` are
   unchanged; this phase does not broaden any of them.
