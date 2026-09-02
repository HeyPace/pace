# Phase 2M — Semantic AX Slider/Stepper Value Change (`ui.set_slider_value`)

Q's sixth controlled UI-interaction capability: a Level 2, semantically-targeted numeric value
change for a single `AXSlider`/`AXStepper` element. It closes the last significant gap in the
existing interaction loop: the agent could click, type, toggle checkbox/radio state, and select
menu items, but had no way to touch continuous/numeric range controls (volume, brightness, zoom,
playback position, or any bounded slider/stepper) at all.

## Scope

Supports exactly two roles — `AXSlider`, `AXStepper` — via `QAXSliderRolePolicy`, a fail-closed
allowlist mirroring `QAXTextEntryRolePolicy`'s/`QAXElementStateRolePolicy`'s narrow write-side
discipline. **Absolute value-setting only** — no relative increment/decrement actions
(`kAXIncrementAction`/`kAXDecrementAction`), by deliberate design: absolute setting is fully
deterministic and exactly verifiable ahead of time; platform-defined increment step sizes are not.
No popup/combo-box, tab, or disclosure-triangle support (explicitly out of scope, see the Phase 2M
discovery report for why each belongs elsewhere).

## Capability contract

Registered as `"ui.set_slider_value": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXSlider` or `AXStepper` — a fail-closed allowlist, not a denylist. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`. |
| `desiredValue` | yes | A finite numeric string. `NaN`/`Infinity`/malformed input is rejected. |

No coordinate, click-count, drag-distance, or increment/decrement parameter exists.

## Why direct `AXUIElementSetAttributeValue`, not press

Unlike `ui.set_element_state`'s checkbox/radio buttons (which need a real press to run their own
handler-driven side effects), a slider/stepper's `kAXValueAttribute` **is** its authoritative
state — the same reasoning `ui.set_text_value` already relies on for text fields. Direct value
setting is the AX-conventional approach here, not a workaround.

## Why Level 2

Determined from first principles, not inherited by default: a slider/stepper's value is real,
often-meaningful UI state (volume, brightness, playback position) — it changes external state and
carries real (if usually modest) consequences. Reversible (a value can always be set back), the
same risk band already accepted for `ui.set_element_state`. Level 1 (`ui.open_app`'s tier) was
rejected: unlike launching an app, a direct value mutation is a visible state change deserving
per-action approval, consistent with every other mutation capability in this codebase. Level 3 was
not seriously considered — nothing about this capability is inherently destructive.

## Range validation — a hard security boundary, never widened by tolerance

`kAXMinValueAttribute`/`kAXMaxValueAttribute` are new AX territory for this codebase (no prior
capability reads them). Before any mutation decision: both are read, `minValue <= maxValue` is
verified (an inverted range is refused, not trusted), the current value is sanity-checked to fall
within that range, and — critically — `desiredValue` is checked against `[minValue, maxValue]`
using **strict, non-tolerant** comparison (`desiredValue >= minValue && desiredValue <= maxValue`,
plain `Double` comparison operators, never `sliderValuesAreEqual`). This check happens **before**
any `AXUIElementSetAttributeValue` call — an out-of-range request never reaches the AX mutation
API at all, and is never silently clamped or normalized to a different value.

## The numeric tolerance rule — used everywhere EXCEPT range validation

`QBridgeAccessibility.sliderValuesAreEqual(_:_:)` is the single, canonical equality rule this
capability uses for idempotency, value/range-drift re-checks, and closed-loop verification — the
exact same function called at every one of those sites, per the explicit requirement that
comparison semantics stay consistent. The rule is a hybrid absolute+relative tolerance:

```
areEqual(a, b) = |a - b| <= 1e-6  OR  |a - b| <= max(|a|, |b|) * 1e-9
```

`valueComparisonAbsoluteTolerance = 1e-6` absorbs ordinary floating-point representation noise
from an AX round trip for small-magnitude values (e.g. a normalized `0.0`–`1.0` slider).
`valueComparisonRelativeTolerance = 1e-9` makes the rule scale-aware for larger-magnitude
values (e.g. a `0`–`1,000,000` stepper), where a fixed absolute tolerance alone would eventually
become either too loose or too tight. **This function is never used for range-boundary
validation** — that check is always the strict, unmodified comparison operators, so tolerance can
never turn an out-of-range request into an accepted one.

## Target resolution and value/range-drift protection

Reuses the identical bounded AX walk and identity observation-binding re-verify every prior
mutation capability already established. **New**: the pre-dispatch re-check re-reads not just the
current value but `minValue`/`maxValue` too, and refuses (`AX_VALUE_DRIFT_DETECTED`, reusing
Phase 2K's existing error case rather than duplicating it) if *any* of the three differ
(tolerantly) from what was captured at resolution — range changes are treated exactly like value
changes, both are staleness.

## Idempotency

If the (drift-checked) current value already equals `desiredValue` (tolerantly), no
`AXUIElementSetAttributeValue` call is made at all — `changeKind: .alreadyDesired`.

## Verification: exact numeric comparison, the strongest of any capability shipped so far

A new `QVerificationStrategy.axSliderValueMatchesDesired` re-resolves the target after the set and
compares its current value against `desiredValue` using `sliderValuesAreEqual` — unlike hash-based
text-entry/state-change verification (necessary because those values *can* be sensitive), this
capability's evidence carries the actual numbers directly (see Privacy below). An
internally-inconsistent post-change range, or an unresolvable target, is `.failed` — conservative,
mirroring text-entry/state-change's interpretation, not click's more permissive one.

## Idempotency & recovery

No dedicated `QTaskRecoveryManager` branch (default fail-closed-to-pending, matching every prior
mutation capability). A resumed retry re-observes current value and range before ever writing
again — safe by construction because idempotency is checked fresh on every attempt, never a blind
replay. A replan proposing the same value is a safe no-op via the identical idempotency check.

## Privacy, audit, memory, HUD, provenance

No masking apparatus — a slider/stepper's numeric value is not free-form sensitive content, the
same conclusion already reached for `ui.set_element_state`'s boolean state. `QActionResult
.outputData` and durable/audit/memory evidence carry the actual numbers (`previousValue`,
`currentValue`, `desiredValue`, `minValue`, `maxValue`) directly — never hashed, since there is
nothing to protect them from. Registered under `toolFamily: "ui"` — no taint propagation.

## Real macOS test coverage

`leanring-buddyTests/QSemanticSliderValueTests.swift` (32 tests, gated on `AXIsProcessTrusted()`
for every test needing a real, live AXUIElement, honest no-op fallback): registration/anti-
downgrade, non-finite/malformed `desiredValue` rejection, real `NSSlider`/`NSStepper` value
changes in both directions, disallowed/unknown role rejection, ambiguous/missing target, exact
boundary acceptance (min and max), out-of-range rejection **proven to occur before any mutation**
(fixture value asserted unchanged), an inverted-range defensive-check note, idempotent no-op,
drift-check non-false-positive behavior, the full approve/deny/persisted-non-reauthorization/
reuse/cross-argument approval lifecycle, closed-loop verification (mismatch and unresolvable-
target cases), the numeric tolerance rule's exact behavior (near-equal accepted, real difference
rejected, scale-aware), no-dispatch-before-approval, uncertain-state recovery, provenance, budget,
and safe-evidence-only audit/durable-state/memory content for a real successful run.

**Honest environment note**: at the time this phase was implemented and validated,
`AXIsProcessTrusted()` was again found to return `false` for the isolated test binary — confirmed
by timing analysis (a real-fixture test containing a 150ms sleep after the trust guard completed
in ~4ms). This is the same persistent, pre-existing environment-state fact already documented for
Phase 2K and Phase 2L, unchanged across three consecutive sessions, not a Phase 2M regression.
Every deterministic, non-AX-dependent test still ran for real and passed.

## Third-party AX hardware validation requirement

`kAXMinValueAttribute`/`kAXMaxValueAttribute` are new AX territory this codebase has never read
before. **Real hardware validation must specifically confirm these two attributes against at
least one real third-party application's slider/stepper** (e.g. System Settings' volume/
brightness sliders), not only the in-process AppKit `NSSlider`/`NSStepper` fixtures this suite
uses — an in-process fixture, while genuinely real AX, is not proof that every third-party AX
implementation reports range attributes the same way. This validation could not be performed in
this implementation session (AX trust unavailable, see above) and remains an explicit, outstanding
requirement before this capability — and Phase 2K's and Phase 2L's own still-outstanding
hardware-validation items — should be considered shipped.

## Excluded capabilities (explicitly out of scope for this phase)

Increment/decrement actions, non-numeric value controls, popup/combo-box selection, tab selection,
disclosure-triangle toggling, CGEvent, keyboard simulation, coordinate interaction, drag/mouse
simulation, AppleScript, shell/filesystem/browser automation, and any new network/cloud
dependency. None of these were added.

## Known limitations

- Absolute value-setting only, by design — no increment/decrement, no relative adjustment.
- The numeric tolerance constants (`1e-6` absolute, `1e-9` relative) are a considered, documented
  choice, not empirically tuned against every possible third-party AX slider implementation.
- Range validation trusts the target's own reported `kAXMinValueAttribute`/`kAXMaxValueAttribute`
  — a control that misreports its own range (a defect in the target application, not this
  capability) could still accept a request that later proves problematic; the pre-mutation sanity
  check (current value must itself fall within the reported range) is the primary defense against
  an obviously-inconsistent range, not a guarantee against every possible misreport.
- Real on-device, third-party-application AX behavior for `kAXMinValueAttribute`/
  `kAXMaxValueAttribute` is unverified pending hardware validation (see above).
