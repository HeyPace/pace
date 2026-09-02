# Phase 2Q — Semantic Disclosure Triangle Toggle (`ui.toggle_disclosure`)

Q's tenth controlled UI-interaction capability — the fourth to use direct, explicit desired-state
semantics with a single-press mutation and direct value verification (after Phase 2K's checkbox/
radio state, Phase 2M's slider value, and Phase 2P's popup selection). Requests an explicit
expand/collapse state for exactly one semantically-identified `AXDisclosureTriangle`.

## Capability contract

Registered as `"ui.toggle_disclosure": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXDisclosureTriangle` — a fail-closed allowlist, not a denylist. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`. |
| `desiredState` | yes | Exactly `"expanded"` or `"collapsed"` — never a blind toggle. |

No coordinate, index, recursive-expand, or expand-all/collapse-all parameter exists.

## Why explicit desired state, never a blind toggle

A capability whose result depends on an unknown prior state is unsafe to resume after a
crash — recovery could not distinguish "already correct" from "needs replay" without first
observing the current state anyway, so the API is designed around that observation from the
start. The caller always states the desired FINAL state; the operation is a true idempotent no-op
if the target already reports it (see Idempotency below). This is the same discipline
`ui.set_element_state`'s `desiredState` parameter already established for checkbox/radio.

## Why Level 2

Consistent with every other per-element AX mutation capability (click/text-entry/state-change/
slider/menu-select/focus/popup-select) — `ui.activate_application`'s Level 1 is the one
deliberate exception, reserved for application-level activation with no element target.
Expand/collapse is element-level AX interaction with a real, visible UI effect, so per-action
human approval remains the safety mechanism, the same reasoning every prior Level 2 capability
already established.

## Role allowlist — `AXDisclosureTriangle` only

```swift
public enum QAXDisclosureRolePolicy {
    public static let allowedRoles: Set<String> = ["AXDisclosureTriangle"]
}
```

The narrowest write-capable policy in this codebase alongside `QAXPopupRolePolicy`.
`AXButton`/`AXCheckBox`/`AXRadioButton`/`AXPopUpButton`/`AXComboBox`/`AXGroup`/`AXStaticText`/
`AXOutline` are never listed — this capability is scoped to the one AX role whose entire purpose
is expand/collapse disclosure, never broadened to a generic press-based toggle. A control that
merely *looks* like a disclosure triangle but reports a different role is refused, not silently
accepted.

## Mutation: the proven `ui.set_element_state` mechanism, applied to a new role

`AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`, since a
disclosure triangle (like a checkbox) only runs its real expand/collapse handling in response to a
genuine press, not a raw value write. This is structurally the identical interaction shape
`ui.set_element_state` already established for checkbox/radio's binary state; only the target
role and the resulting state's vocabulary (`expanded`/`collapsed` rather than `on`/`off`) differ.

## State reading: the proven `axCheckboxRadioState` shape, reused for a new role

```swift
fileprivate nonisolated static func axDisclosureState(of element: AXUIElement) -> QAXDisclosureState? {
    // kAXValueAttribute: 0 -> .collapsed, 1 -> .expanded, anything else -> nil (never guessed)
}
```

Directly mirrors `axCheckboxRadioState`'s 0/1 interpretation discipline for checkbox/radio's
tri-state "mixed" value: an indeterminate or non-numeric `kAXValueAttribute` is `nil`, never
coerced into a default state. Idempotency and verification both key off this single, canonical
read primitive.

## Idempotency and verification

- **Idempotency**: before any press, `kAXValueAttribute` is read (once at resolution, once again
  immediately before any dispatch decision — a state-drift staleness check, refusing on mismatch,
  mirroring `ui.set_element_state`'s/`ui.select_popup_item`'s discipline). If it already equals
  `desiredState`, no press is performed at all — `changeKind: .alreadyDesired` is itself the
  deterministic, structural proof that no mutation occurred (the only code path that returns
  without an intervening press).
- **Verification**: a new `QVerificationStrategy.axDisclosureStateMatchesDesired` independently
  re-resolves the target and re-reads `kAXValueAttribute` fresh, comparing it directly against
  `desiredState`. A successful press is never itself treated as proof of success — independent
  re-observation is the sole source of truth. An unreadable/indeterminate state after the press is
  `.failed`, never defaulted to either expanded or collapsed; an unresolvable target is likewise
  `.failed`, never assumed successful.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.toggle_disclosure":` branch that
reuses `observeDisclosureStateEvidence` — the exact same independent, read-only primitive
verification uses, not a parallel resolver. If the target already reports the requested desired
state, the step is recognized complete via genuine observation. Otherwise (unresolvable,
unreadable, or simply at the wrong state), the step resets to `pending` — never a blind replay of
the press. A resumed execution requires both a brand-new `QExecutionIdentity` and a genuinely
fresh user approval grant, since `QApprovalCoordinator`'s one-time grants are in-memory only and
never survive a crash/restart. A toggle without this explicit desired-state re-verification would
be unsafe to resume — this branch is exactly what makes it safe.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior.
Expand/collapse is a UI-chrome STATE fact, not content — the same low-risk class as a checkbox's
on/off state, categorically different from the content a disclosure triangle might reveal.
`QAXDisclosureToggleOutcome`/audit/durable-state records carry only `targetIdentity`,
`changeKind`, `previousState`, `currentState`, and `desiredState` — no outline-tree dump, no
screenshot, no unrelated UI content, no attribute beyond what identity/status/evidence requires.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXDisclosureRolePolicy`, `QAXDisclosureState`,
  `QAXDisclosureChangeKind`, `QAXDisclosureToggleOutcome`, `QAXDisclosureVerificationEvidence`,
  `toggleDisclosure`, `observeDisclosureStateEvidence`, `axDisclosureState`, and two new
  `QAXInteractionError` cases (`disallowedDisclosureRole`, `disclosureStateReadFailed`) — every
  other error case is reused from the existing enum.
- `QExecutionService.swift` — `executeToggleDisclosure` dispatch + implementation.
- `QActionVerification.swift` — `.axDisclosureStateMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticDisclosureToggleTests.swift` — new focused suite (35 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified.
`ui.click_element`, `ui.set_text_value`, `ui.read_element_value`, `ui.set_element_state`,
`ui.select_menu_item`, `ui.set_slider_value`, `ui.activate_application`, `ui.focus_element`, and
`ui.select_popup_item` are all unmodified — this phase reuses `ui.set_element_state`'s proven
mechanism shape without broadening its role policy or any other existing capability.

## Empirical fixture finding — a genuine, honest limitation

The Phase 2Q Discovery flagged an open question: which real AppKit structure reliably exposes
`AXDisclosureTriangle`? `NSOutlineView` was the presumed first choice. Investigating further
during implementation surfaced a real, structural obstacle: **`NSOutlineView`'s internal row
disclosure control has no accessible way to attach a settable `AXIdentifier`** — it is an
internal, framework-managed control, not something application code constructs or tags directly.
Every capability in this codebase requires exact identifier/title-based semantic targeting
(never coordinate/index-based targeting, per the project's fail-closed discipline), so an
untaggable internal control cannot serve as a usable fixture for *this specific capability's*
resolution contract, regardless of whether its authentic AX role is correct.

The test suite instead uses a small, real, custom `NSButton` subclass
(`QDisclosureTriangleFixtureButton`) that overrides `accessibilityRole()` to return
`NSAccessibility.Role.disclosureTriangle` — the same standard `NSAccessibility` protocol
override mechanism every custom-AX-role AppKit control uses, not a mock or simulation. Backed by
a real, live, on-screen button configured as a `.pushOnPushOff` toggle (so its `kAXValueAttribute`
is reported automatically by AppKit's built-in accessibility bridging — the same underlying
mechanism `AXCheckBox` already relies on, since a checkbox is fundamentally the same toggle-button
shape with a different bezel), this produces a genuinely real, live `AXUIElement` that the OS
accessibility subsystem will authentically query and report role `AXDisclosureTriangle` from, if
and when Accessibility trust is available. **The production role policy was never weakened to
accommodate this** — `QAXDisclosureRolePolicy.allowedRoles` is exactly `["AXDisclosureTriangle"]`,
unchanged and unrelated to this fixture-construction decision.

## Real macOS AX E2E — result

`QSemanticDisclosureToggleTests.realMacOSE2EToggleDisclosure` uses the fixture described above,
drives the full `ui.toggle_disclosure` plan through `QCoreRuntime.submitIntent` + approval in
*both* directions (collapsed→expanded, then expanded→collapsed), and independently re-reads
`kAXValueAttribute` after each to confirm the requested state was genuinely reached. This
capability requires Accessibility permission (`AXDisclosureTriangle` interaction is definitionally
an AX operation), so the test is gated on `AXIsProcessTrusted()`. In the isolated test-runner
environment used to validate this phase, `AXIsProcessTrusted()` was directly confirmed to return
`false` (verified via a temporary diagnostic print, removed before commit) — the same finding
independently documented for every prior AX capability in this codebase (Phase 2H through 2P) in
this identical environment. Real AX E2E is therefore **blocked by Accessibility trust
unavailability**, not by any defect in this implementation or by the fixture-construction decision
above. Every deterministic, non-AX-dependent test (35/35) ran for real and passed, including the
full approval lifecycle, recovery (both branches), verification independence, and
provenance/budget/privacy checks.

## Known limitations

1. `NSOutlineView`'s own row disclosure control could not serve as this capability's real-fixture
   test target — it has no accessible way to attach a settable `AXIdentifier` (see the Empirical
   fixture finding above). The custom `NSAccessibility`-role-overriding fixture used instead is a
   genuinely real, live AXUIElement, not a simulation, and the production role policy was not
   weakened to accommodate it.
2. Real, interactive-hardware validation against an actual `NSOutlineView`-hosted (or other
   real-world) disclosure triangle — as opposed to this suite's custom fixture — remains an
   explicit, outstanding requirement, distinct from and in addition to the general
   `AXIsProcessTrusted()` hardware-validation gap this phase shares with Phase 2K/2L/2M/2O/2P.
3. No recursive expand-all/collapse-all semantics — exactly one triangle, one toggle, matching
   this project's consistent "smallest necessary change" discipline.
4. No `AXOutline` row selection — a distinct, larger-scoped, higher-privacy-risk capability
   explicitly rejected as out of scope during Phase 2Q Discovery.
5. Exact role/identifier/title matching only — no fuzzy/substring fallback, consistent with every
   prior AX capability in this codebase.
6. The identity/state observation-binding re-verify (resolve → re-verify snapshot/state,
   back-to-back inside one synchronous closure with no `await` between them) covers the gap
   between resolution and dispatch within a single call; it does not, and structurally cannot
   without an artificial delay seam in production code, protect against a mutation landing in the
   sub-millisecond window between the two reads themselves — the same documented, honest,
   non-deterministically-testable limitation every prior AX capability in this codebase already
   accepts.
