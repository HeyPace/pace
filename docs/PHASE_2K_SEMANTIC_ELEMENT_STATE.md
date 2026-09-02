# Phase 2K — Semantic AX Element State Change (`ui.set_element_state`)

Q's fourth controlled UI-interaction capability, and its second mutation: a Level 2, semantically-
targeted, value-verified state change of a single checkbox or radio-button-shaped Accessibility
element. It closes a real, demonstrated gap in the existing interaction loop: `ui.click_element`
can press *any* role, including `AXCheckBox`/`AXRadioButton`, but its verification strategy
(`QAXElementSnapshot`) has no field for `kAXValueAttribute` — it diffs only role, identifier,
title, and enabled state. A checkbox toggle changes none of those. Pressing a checkbox via
`ui.click_element` today will very likely dispatch correctly but then have its own closed-loop
verification report a false failure, because the one thing that actually changed — the value —
is invisible to that verification strategy.

## Capability contract

Registered in `QModelPlanParser.registeredCapabilities` as `"ui.set_element_state": ("ui",
.level2UserApproval)`. Parameters (via `QModelActionSchema.parameters`):

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be on `QAXElementStateRolePolicy.allowedRoles` — `AXCheckBox` or `AXRadioButton` only, a fail-closed allowlist. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`. |
| `desiredState` | yes | Exactly `"on"` or `"off"`. No tri-state/mixed target is ever accepted. |

No coordinate parameter exists at all — this tool never accepts click counts, coordinates, key
presses, or shell commands.

## Why Level 2, not Level 0/1

Determined from the operation's actual properties, not defaulted: checkbox/radio/toggle state is
real, often-persisted application or system state (consent checkboxes, preference toggles, form
selections) — it changes external state and can carry meaningful consequences (enabling a
setting, agreeing to terms) even though it's reversible at the UI level. This is exactly the risk
band Level 2's doctrine exists for ("state-changing operations requiring user approval"), and
matches how `ui.click_element`/`ui.set_text_value` were both classified for analogous reasons.
Level 1 (`ui.open_app`'s tier) was considered and rejected: unlike launching an app (near-
universally low-consequence), a checkbox/toggle can gate consent or security-relevant settings —
per-action human approval is the safer default.

## Why AXUIElementPerformAction, never AXUIElementSetAttributeValue

Many native AppKit checkboxes/radio buttons implement their real state-change behavior (target-
action side effects, preference persistence, sibling deselection in a radio group) inside their
press *action handler* — not by observing `kAXValueAttribute` changes. Calling
`AXUIElementSetAttributeValue` directly could update the AX-exposed value without ever invoking
that handler, silently failing to produce the real effect a user's own click would. This
capability presses via `AXUIElementPerformAction(kAXPressAction)` — the exact same dispatch
primitive `ui.click_element` already uses and already proved correct — and adds *verification*
by value, which click's own strategy cannot provide.

## Why radio-button deselection is refused, not attempted

macOS provides no reliable, semantically-correct way to deselect a single `AXRadioButton` via its
own press action — the standard interaction model is to select a *different* button in the same
group instead; native radio buttons do not toggle off on a second press the way checkboxes do. If
`desiredState` is `"off"` and the target is currently `"on"`, `setElementState` refuses
(`AX_STATE_CHANGE_NOT_GUARANTEED`) rather than pressing and hoping — a direct application of "if
the AX API cannot safely guarantee the desired state, fail closed."

## Target resolution, value-drift staleness, and idempotency

`QBridgeAccessibility.setElementState` (`QBridgeAdapters.swift`) reuses the identical bounded AX
walk and identity observation-binding re-verify `ui.click_element`/`ui.set_text_value` already
use (`AX_STALE_TARGET` on identity drift, `AX_AMBIGUOUS_TARGET`, `AX_NO_MATCHING_ELEMENT`), and
adds a check neither of those needed: the element's *value* is read once at resolution and once
again immediately before dispatch; if they differ, the operation refuses
(`AX_VALUE_DRIFT_DETECTED`) rather than mutating a target whose observed state is no longer the
one that was captured. As with the identity re-verify, both value reads happen back-to-back
inside one synchronous closure with no `await` between them — a genuine race in the sub-
millisecond window between the two reads cannot be triggered deterministically without an
artificial delay seam in production code, the same documented, honest limitation
`ui.click_element` already accepts (see `docs/PHASE_2H_SEMANTIC_CLICK.md`).

If the (drift-checked) current state already equals `desiredState`, no `AXUIElementPerformAction`
call is made at all — an idempotent no-op, not a failure, and not an "unnecessary mutation."

## Post-action verification: a successful press is not goal success

A new `QVerificationStrategy.axElementStateMatchesDesired` case re-resolves the same target after
the press and compares only a SHA-256 hash of its current state against a hash of the desired
state (`QBridgeAccessibility.observeElementStateHash`) — never the raw value itself crosses this
boundary. Like `ui.set_text_value` (and deliberately *unlike* `ui.click_element`'s
`axElementStateChanged`), an unresolvable target after the change is treated as `.failed`, not
assumed success — a checkbox/radio's identity is not expected to change as a direct, benign
result of being toggled the way some buttons' identity does after a press.

## Privacy: no masking apparatus needed — a deliberate simplification

Unlike `ui.set_text_value`'s free-form `value` parameter, `desiredState` is a small, non-sensitive
two-value enum (`"on"`/`"off"`). This capability does **not** add an entry to
`QSensitiveArgumentPolicy`, does **not** route its approval text through
`approvalSafeLiteralAction`, and is registered under `toolFamily: "ui"` (not `"perception"`) —
it never observes or exposes arbitrary UI content, so none of Phase 2I's or Phase 2J's redaction/
taint machinery applies or is needed. This is a considered, evidence-based decision, not an
oversight — checkbox state simply isn't the same category of content as free text or an
observed value read.

## Approval, execution identity, and why arguments can never drift under one approval

Rides the unmodified `QResourceGuard → QPermissionGate → QApprovalCoordinator → QPlanExecutor →
QExecutionService` pipeline every other capability uses. A granted approval is single-use and
bound to `QExecutionIdentity.stepFingerprint` (`taskId:planId:stepId:actionName`). Because a plan
step's arguments are fixed once the plan is built, a genuinely different `desiredState` or target
can only ever arise from a genuinely different step (different `stepId`) or a replan (different
`planId`) — both of which are, by construction, a different execution identity requiring their
own fresh approval. No new argument-binding mechanism was needed or added; this property falls
directly out of the existing, unmodified architecture.

## Idempotency & recovery

`ui.set_element_state` gets no dedicated observation-first recovery branch in
`QTaskRecoveryManager` — like `ui.click_element`/`ui.set_text_value`, it relies on the default
fail-closed-to-pending behavior every unrecognized tool already gets. What makes a resumed retry
safe is that `setElementState` itself always re-observes current state (with the value-drift
check) and treats an already-correct state as a no-op before ever pressing — a step resumed after
a crash where the press already landed is a no-op on retry, not a duplicate mutation.

## Real macOS test coverage

`leanring-buddyTests/QSemanticElementStateTests.swift` (27 tests, gated on `AXIsProcessTrusted()`
for every test that needs a real, live AXUIElement, honest no-op fallback — mirroring
`QSemanticClickTests`/`QSemanticTextEntryTests`/`QSemanticElementReadTests` exactly): registration
and anti-downgrade, invalid schema, real checkbox/radio-button state changes in both directions,
radio-button deselection refusal, disallowed/unknown role rejection, ambiguous target, wrong
application, the value-drift check's non-spurious behavior under normal (non-racing) conditions,
idempotent no-op, the full approve/deny/persisted-non-reauthorization/reuse/cross-argument
approval lifecycle, closed-loop verification (including a deliberate mismatch case and an
unresolvable-target-after-dispatch case), no-dispatch-before-approval, uncertain-state recovery,
provenance (no taint upgrade), budget exhaustion, and safe-evidence-only audit/durable-state/
memory content for a real successful run.

**Honest environment note**: at the time this phase was implemented and validated, `AXIsProcessTrusted()`
was found to return `false` for the isolated test binary in the development environment — verified
directly by timing analysis showing even the pre-existing, unmodified Phase 2H Calculator E2E test
(which normally takes several seconds) completing in under a millisecond, the signature of the
honest no-op fallback engaging rather than real AX execution. This is a pre-existing environment-
state fact, not a Phase 2K regression — it affected every AX-gated test across every phase equally
in that session. Every deterministic, non-AX-dependent test (registration, role-policy rejection,
approval lifecycle, budget, recovery, verification-mismatch logic, provenance) still ran for real
and passed. Real hardware validation with Accessibility access actually granted to the test binary
(e.g. via the release smoke checklist) is required to confirm genuine on-device AX behavior before
shipping.

## Excluded capabilities (explicitly out of scope for this phase)

Keyboard simulation, CGEvent, coordinate-based interaction, arbitrary key injection, mouse
simulation, `AXUIElementSetAttributeValue`-based mutation, roles beyond `AXCheckBox`/
`AXRadioButton`, tri-state/mixed as a settable target, app activation, menu selection, scrolling,
and any new network/cloud dependency. None of these were added.

## Known limitations

- Role allowlist is fixed and narrow at launch (`AXCheckBox`/`AXRadioButton` only); a toggle-
  shaped custom control claiming a different role is not reachable — a deliberate fail-closed
  trade-off, same in kind as `ui.set_text_value`'s narrow write allowlist.
- `AXRadioButton` deselection is categorically refused, not just "usually" refused — an agent
  that needs to deselect a radio option must select a different button in its group instead; this
  is a real interaction-model constraint, not a bug.
- The value-drift staleness check's race window is the same sub-millisecond, non-deterministically-
  testable limitation every other AX observation-binding check in this codebase already accepts.
- A checkbox/radio button whose `kAXValueAttribute` reports the AX "mixed" tri-state (`2`) as its
  *current* value fails closed (`AX_STATE_READ_FAILED`) rather than being coerced into an on/off
  reading — correct, but means this capability cannot act on genuinely indeterminate controls at
  all until a future phase deliberately adds mixed-state handling.
