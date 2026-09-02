# Phase 2O — Semantic AX Element Focus (`ui.focus_element`)

Q's eighth controlled UI-interaction capability, and its fourth to write AX state directly via
`AXUIElementSetAttributeValue` (after Phase 2I's text entry, Phase 2K's state change, and Phase
2M's slider value). Requests keyboard Accessibility focus for a single semantically-identified
element — nothing more. Closes a gap explicitly named in `ui.set_text_value`'s own contract since
Phase 2I: that tool "never clicks/focuses a field itself" and requires the target to already be
the system's genuinely focused element, with no first-class way to make that true.

## Capability contract

Registered as `"ui.focus_element": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be on `QAXFocusableRolePolicy`'s allowlist — a fail-closed allowlist, not a denylist. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`. |

No coordinate, value, or click-count parameter exists.

## Why Level 2, unlike `ui.activate_application`

`ui.activate_application` (Phase 2N) is the one Level 1 exception in this codebase's UI
capabilities, specifically because it is **application-level** activation with no element target.
Focus-setting is squarely **element-level** AX interaction — the same risk class as
`ui.click_element`/`ui.set_text_value`/`ui.set_element_state`/`ui.set_slider_value`, all Level 2 —
so it follows their precedent rather than 2N's exception. No special-cased approval bypass exists
or was considered; `QPermissionGate.evaluate` routes Level 2 straight to `.requireApproval` by its
existing, unmodified policy.

## Role allowlist — deliberately the narrowest write-capable policy in this codebase

```swift
public enum QAXFocusableRolePolicy {
    public static let allowedRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSlider", "AXStepper"
    ]
}
```

This is the union of every role already proven genuinely interactive by an **existing write-side
policy** in this codebase (`QAXTextEntryRolePolicy`'s `AXTextField`/`AXTextArea`,
`QAXElementStateRolePolicy`'s `AXCheckBox`/`AXRadioButton`, `QAXSliderRolePolicy`'s
`AXSlider`/`AXStepper`) plus `AXButton` itself (keyboard-activatable via Space/Return once
focused, and already `ui.click_element`'s press target).

**Deliberately excluded, by design:**
- `AXStaticText`, `AXImage`, `AXGroup` — never listed; non-interactive elements have no
  legitimate reason to receive keyboard focus.
- `AXSecureTextField` — never listed, consistent with `QAXTextEntryRolePolicy`'s and
  `QAXElementReadRolePolicy`'s blanket exclusion of that role from every existing AX interaction
  capability in this codebase, not just value read/write.
- `AXPopUpButton`/`AXComboBox` — already read-allowlisted by `QAXElementReadRolePolicy`, but
  deliberately **not** included here: selecting a value from either is a distinct, not-yet-built
  capability of its own (see Known limitations). Including them here would informally provide a
  sliver of that capability ahead of its own proper scoping — out of scope for this phase.

## Mutation: `kAXFocusedAttribute` only

`AXUIElementSetAttributeValue(element, kAXFocusedAttribute, kCFBooleanTrue)` — never a press,
never a value write, never `CGEvent`/keyboard/mouse simulation, never coordinates. Resolution
reuses the identical bounded AX walk and identity observation-binding re-verify every prior
mutation capability already establishes (`QBridgeAccessibility.collectMatches`/`snapshotIfMatches`
— no parallel resolver was created).

## Idempotency — a true no-op, proven structurally

Before any mutation decision, `focusElement` reads the systemwide currently-focused element
(`AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute`, the exact same primitive
`ui.set_text_value`'s focus precondition check already uses in production) and compares it against
the resolved target via `CFEqual`. If they already match, `changeKind: .alreadyFocused` is
returned and **no `AXUIElementSetAttributeValue` call is made at all**.

No artificial spy/seam was added to prove this — `.alreadyFocused` is itself the deterministic,
structural proof: it is the *only* code path in `focusElement`'s implementation that returns
without an intervening `AXUIElementSetAttributeValue` call, the same convention every prior
idempotent AX capability in this codebase already establishes (`setElementState`'s
`.alreadyDesired`, `setSliderValue`'s `.alreadyDesired`).

## Verification: `.axElementIsFocused` — independent, never trusts the mutation call

A new `QVerificationStrategy.axElementIsFocused` re-resolves the target fresh and independently
re-reads `kAXFocusedUIElementAttribute` via `QBridgeAccessibility.observeFocusedElementIdentity` —
a **separate** call from whatever `focusElement` itself observed. Three outcomes, mirroring
`axTextValueChanged`'s/`axElementStateMatchesDesired`'s conservative model (not
`axElementStateChanged`'s more permissive one):

- **`.focused`** → `.verified`.
- **`.notFocused`** (target resolvable but not the systemwide focused element, including the case
  where no focused element can be determined at all) → `.failed`.
- **`.targetUnavailable`** (target itself no longer resolvable) → `.failed` — nothing about being
  focused should make an element disappear, so an unresolvable target is never assumed to mean
  success.

A successful `AXUIElementSetAttributeValue` call is **never** itself treated as proof of
completion — confirmed directly by test 26 (`mutationSuccessAloneIsInsufficient`), which feeds a
fabricated `success: true` `QActionResult` through verification and confirms it alone changes
nothing about the independently-observed outcome.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.focus_element":` branch that reuses
`observeFocusedElementIdentity` — the **exact same** independent, read-only observation primitive
verification uses, not a parallel resolver. If the target is already the systemwide focused
element, the step is recognized complete via genuine observation. Otherwise (unresolvable,
ambiguous, or simply not focused), the step falls through to `verified = false` and resets to
`pending` — never a blind replay of the AX write. A resumed execution requires **both** a
brand-new `QExecutionIdentity` (minted fresh by `QPlanExecutor` for every step, per its existing,
unmodified per-step flow) **and** a genuinely fresh user approval grant, since
`QApprovalCoordinator`'s one-time grants are in-memory only and never survive a crash/restart (see
`QApprovalCoordinator.swift`'s own header comment). No persisted state is ever consulted as
authorization.

## Provenance & privacy

Registered under `toolFamily: "ui"` — the same family as click/text/state/slider/menu-select, no
taint-propagation or trust-upgrade behavior attached. **Focus-setting never reads element
content**: neither `focusElement` nor `observeFocusedElementIdentity` ever calls
`kAXValueAttribute` — the only AX reads performed are role/identifier/title/enabled (the existing
`QAXElementSnapshot` fields) and focus identity (a raw `AXUIElement` reference comparison via
`CFEqual`, never serialized as content). `QAXFocusOutcome`/`QAXFocusVerificationEvidence` carry
only a `targetIdentity` string (role + identifier/label) and a `changeKind`/focus-status enum —
structurally, there is no code path by which this capability could expose a secure field's value,
unlike `ui.read_element_value`/`ui.set_text_value`, which explicitly guard against that at the
value-read/write boundary this capability never reaches at all.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXFocusableRolePolicy`, `QAXFocusChangeKind`, `QAXFocusOutcome`,
  `QAXFocusVerificationEvidence`, `focusElement`, `observeFocusedElementIdentity`,
  `systemWideFocusedElement` (shared helper), and two new `QAXInteractionError` cases
  (`disallowedFocusRole`, `setFocusFailed`).
- `QExecutionService.swift` — `executeFocusElement` dispatch + implementation.
- `QActionVerification.swift` — `.axElementIsFocused` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticElementFocusTests.swift` — new focused suite (28 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified.
`ui.open_app` and `ui.activate_application` are unmodified — no compatibility issue was found
that would have justified touching either.

## Real macOS E2E — result

`QSemanticElementFocusTests` contains 9 AX-gated tests (real `NSTextField`/`NSButton` AppKit
fixtures, matching the established fixture pattern from `QSemanticSliderValueTests`), each
branching on `AXIsProcessTrusted()` and no-opping rather than fabricating a pass. In the isolated
test-runner environment used to validate this phase, `AXIsProcessTrusted()` was directly confirmed
to return `false` (verified via a temporary diagnostic print, removed before commit) — the exact
same finding independently documented for Phase 2H/2I/2J/2K/2L/2M in this identical environment,
confirmed unchanged across this session too. Real AX E2E is therefore **blocked by Accessibility
trust unavailability**, not by any defect in this implementation. Every deterministic,
non-AX-dependent test (28/28) ran for real and passed, including the full approval lifecycle,
recovery, verification-independence (via directly-constructed `QVerificationStrategy` cases and
fabricated `QActionResult`s, which do not require a live AX element), provenance, and budget
tests. Real, interactive-hardware validation of the actual focus-mutation and focus-verification
AX calls remains an outstanding requirement, joining Phase 2K/2L/2M's own still-outstanding
AX-trust hardware-validation notes.

## Known limitations

1. Exact role/identifier/title matching only — no fuzzy/substring fallback, consistent with every
   prior AX capability in this codebase.
2. `AXPopUpButton`/`AXComboBox` selection is explicitly out of scope for this phase (see Role
   allowlist above) — a distinct future capability, not informally provided here via focus-only
   access.
3. `AXSecureTextField` is never focusable via this capability.
4. Real, interactive-hardware validation of the AX focus mutation/verification calls is
   outstanding pending `AXIsProcessTrusted()` availability (see E2E section above).
5. The identity observation-binding re-verify (resolve → re-verify snapshot, back-to-back inside
   one synchronous closure with no `await` between them) covers the gap between resolution and
   dispatch within a single call; it does not, and structurally cannot without an artificial delay
   seam in production code, protect against a mutation landing in the sub-millisecond window
   between the two reads themselves — the same documented, honest, non-deterministically-testable
   limitation every prior AX capability in this codebase already accepts.
6. `ui.open_app` and `ui.activate_application` are unchanged; this phase does not address the
   window-level targeting gap `ui.activate_application` (Phase 2N) explicitly deferred.
