# Phase 2J — Semantic AX Element Value Read (`ui.read_element_value`)

Q's third controlled UI-interaction capability, and its first that isn't a mutation: a Level 0,
read-only value read of a single, semantically-identified Accessibility element. It closes the
one gap Phase 2H (click) and Phase 2I (text entry) left open — the agent could act on
semantically-identified UI but had no way to cheaply, precisely confirm arbitrary UI state (a
label's text, a checkbox's state, a button's title) without a full-screen OCR pass or guessing
from a mutation's own before/after diff.

## Capability contract

Registered in `QModelPlanParser.registeredCapabilities` as `"ui.read_element_value": ("perception",
.level0ReadOnly)`. Parameters (via `QModelActionSchema.parameters`):

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | The AX role to match. Any role **except** `AXSecureTextField` — a denylist, not an allowlist (see below). |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`. |

No `value` parameter exists — this tool never writes anything.

## Why a denylist, not an allowlist — the opposite of `ui.set_text_value`

`ui.set_text_value`'s role policy is an allowlist of exactly two roles because writing is
inherently risky and the safe set is small and well-understood. Reading is categorically
different: a read has zero mutation risk, and restricting it to two roles would make it far less
useful than it should be — an agent legitimately needs to read button titles, checkbox states,
static text, and menu items, not just text fields. `QBridgeAccessibility.readElementValue`
therefore denies exactly one role, `AXSecureTextField`, and allows everything else — the same
"exclude the one known-secret-shaped role" judgment `ui.set_text_value` already made, applied in
the opposite (permissive-by-default) direction appropriate to a read-only capability.

## Why `toolFamily: "perception"`, not `"ui"` — the key security decision

Unlike `ui.set_text_value` (where the model already knows the value it's writing, so hiding it
from every persisted/displayed surface is pure upside), `ui.read_element_value`'s entire purpose
is to surface *previously-unknown* content to the model. Applying Phase 2I's redact-everywhere
posture here would defeat the capability.

The Phase 2J discovery's security pre-check found the concrete gap this would otherwise create:
`QPlanExecutor.swift`'s `isScreenDerivedStep` predicate — the mechanism that already sanitizes
`screen.ocr`'s result before it reaches `QAuditRecord`/`QDurablePlanStepSnapshot`/`QMemoryStore`,
while still letting the raw content flow into `QTaskContext` (untrusted-tagged) for the local
planner to reason with — keys on `toolFamily == "perception"`. Registering this capability under
that same family, rather than `"ui"` (which `ui.click_element`/`ui.set_text_value` use), routes it
through that exact, already-tested boundary **with zero changes to `QPlanExecutor.swift`**. This
was the "GO AFTER SECURITY REMEDIATION" condition from the Phase 2J discovery report — the
remediation turned out to be a registration-time choice, not a code change, because the existing
predicate was already written generically enough to support it.

## AX resolution and value reading

`QBridgeAccessibility.readElementValue` (`QBridgeAdapters.swift`) reuses the identical bounded
tree walker (`collectMatches`, depth 12 / 3,000 nodes / 1.5s budget) `ui.click_element`/
`ui.set_text_value` already use. It performs the secure-field denylist check before any search
(`AX_SECURE_FIELD_READ_DENIED`), resolves zero/one/many matches
(`AX_NO_MATCHING_ELEMENT`/`AX_AMBIGUOUS_TARGET`), and reads the value via a polymorphic helper
(`axValueDescription`): `kAXValueAttribute` as a `String` if present and non-empty, else as a
boxed `NSNumber` (covers checkboxes/sliders/steppers) converted to its string representation,
falling back to the resolved element's title-or-description for roles (buttons, static text, menu
items) that don't carry a meaningful `AXValue` at all. No observation-binding re-verify or
mutation follows resolution — there is nothing to protect against drifting into, since nothing is
dispatched.

## No approval, no closed-loop verification — and why that's correct, not a shortcut

Level 0 never halts for approval (`QPermissionGate`'s existing default-allow branch, unmodified) —
the same precedent `screen.ocr`/`system.running_apps`/`accessibility.read` already set. No
dedicated `QVerificationStrategy` case was added: a read's own successful execution *is* its
evidence (there is no separate physical effect to independently re-observe), so
`QPlanExecutor.determineVerificationStrategy` falls through to the existing default
(`.customCheck(description: "Default step verification") { true }`) unmodified — exactly the same
path every other read-only tool already takes.

## Idempotency & recovery

Trivially idempotent: repeated reads have no side effects and always reflect current state.
`QTaskRecoveryManager` gets no dedicated branch (falls to `default: verified = false` → `pending`
→ safe re-execution) — a duplicate read costs nothing and risks nothing, more so than any mutation
capability in this codebase.

## Real macOS test coverage

`leanring-buddyTests/QSemanticElementReadTests.swift` (14 tests, gated on `AXIsProcessTrusted()`,
honest no-op fallback): registration/anti-downgrade (including the *upgrade* direction, since
Level 0 is the floor rather than the ceiling), text-field/button/checkbox reads (proving the
polymorphic value reader), missing parameters, secure-field denial, zero/ambiguous match,
idempotency, no-approval-ever, uncertain-state recovery, and — the two tests that directly prove
the toolFamily security decision — a redaction test (a real secret read stays out of durable
state/audit/memory) paired with a provenance test (the same read's untrusted taint still forces a
*later* Level 2 step to require fresh approval, which is only possible if the raw value really did
reach `QTaskContext`). A final E2E test composes `ui.set_text_value` and `ui.read_element_value` in
one plan, writing a value and reading it back.

## Excluded capabilities (explicitly out of scope for this phase)

Any mutation, keyboard simulation, CGEvent, coordinate-based interaction, reading
`AXSecureTextField`, full-screen/vision-based reading (that remains `screen.ocr`'s job), browser
automation, and any new network/cloud dependency. None of these were added.

## Known limitations

- Matching is exact-string, by design, matching every other AX capability in this codebase.
- The polymorphic value reader covers `String` and `NSNumber`-boxed values; an AX attribute of
  some other exotic type would return the title-or-description fallback rather than a
  representation of that value.
- The role denylist covers `AXSecureTextField` specifically; a custom-drawn secure-looking field
  claiming a different role is the same class of limitation already documented for
  `ui.set_text_value`'s role policy.
- The internal (non-user-facing) `QTaskContext` event-log `sourceId` this capability's taint
  propagation uses (`"step_\(i)_ocr"`, inherited unchanged from the shared `isScreenDerivedStep`
  code path) is a generic, pre-existing label shared with `screen.ocr` — cosmetic only, not a
  correctness or security issue.
