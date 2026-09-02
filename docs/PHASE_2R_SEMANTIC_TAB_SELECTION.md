# Phase 2R — Semantic Tab Selection (`ui.select_tab`)

Q's eleventh controlled UI-interaction capability. Requests an explicit desired selection state
for exactly one semantically-identified tab.

## A critical empirical correction — there is no "AXTab" role

Both this phase's Discovery and its original implementation instructions assumed "AXTab" was a
real, distinct Accessibility role, separate from `AXRadioButton`. **This assumption was wrong**,
and the error was caught mid-implementation, not glossed over:

While implementing the test fixture, `NSAccessibility.Role.tab` failed to compile
("reference to member 'tab' cannot be resolved without a contextual type"). Rather than guessing
at a workaround, the actual AppKit SDK header — `NSAccessibilityConstants.h`, which lists **every**
`NSAccessibilityRole` constant Apple has ever defined — was read directly. It contains
`NSAccessibilityTabGroupRole` (the tab *container*) and, separately,
`NSAccessibilityTabButtonSubrole` (`"AXTabButton"`) — a **subrole**, layered on top of some base
role. There is no standalone role for an individual tab item. This inaccuracy had already been
sitting, unverified, in `QAXElementReadRolePolicy.allowedRoles` since Phase 2J (harmless there — an
extra, never-matching entry in a wide read-only allowlist) and fed directly into this phase's
Discovery.

Implementation was **halted immediately** on this finding: a capability scoped to `role ==
"AXTab"` as originally specified would compile, pass every synthetic test, and then never match
any real macOS element — a silent, permanent production defect, not an honest environment
limitation like `AXIsProcessTrusted()` being unavailable. All in-progress changes were reverted
and the finding was reported to the user rather than proceeding on a false premise. The user
explicitly approved retargeting the capability to its real, header-confirmed shape: base role
`AXRadioButton` carrying subrole `AXTabButton`. Everything below reflects that corrected design.

## Capability contract

Registered as `"ui.select_tab": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXRadioButton` — the real base role tabs use. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier`. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`. |
| `desiredSelected` | yes | Exactly `"true"` or `"false"` — never a blind toggle. |

No coordinate, index, or fuzzy-matching parameter exists. The `AXTabButton` subrole requirement is
**not** a parameter — it is hard-coded into `selectTab`'s own contract, never model-configurable.

## The mandatory `AXTabButton` subrole gate — why this never becomes `ui.set_element_state`

```swift
public enum QAXTabRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRadioButton"]
}
```

`AXRadioButton` alone is **not** sufficient to be treated as a tab. Immediately after the existing
identity observation-binding check (role + identifier/title + enabled, reused unchanged from every
prior capability), `selectTab` performs one additional, unconditional check:
`kAXSubroleAttribute == "AXTabButton"`. A resolved `AXRadioButton` lacking that exact subrole is
refused (`QAXInteractionError.targetNotATabButton`) — never silently accepted, never treated as a
tab.

This is what keeps `ui.select_tab` from being cross-wired with `ui.set_element_state`'s existing,
unconditional `AXRadioButton` coverage (`QAXElementStateRolePolicy` already allows
`AXRadioButton`, with no subrole check, for ordinary radio-button groups). The two capabilities
target the same base role but are semantically disjoint in practice:

- `ui.set_element_state` reads/writes `kAXValueAttribute` (the control's own on/off value) — the
  correct model for an ordinary radio button.
- `ui.select_tab` reads `kAXSelectedAttribute` (a distinct, generically-documented Apple AX
  attribute for "is this one of several sibling elements currently selected" — also used for
  table/outline row selection, though that broader territory is explicitly out of scope here) and
  additionally requires the `AXTabButton` subrole before it will act at all.

An agent/model choosing `ui.select_tab` is choosing "target something that is specifically a tab";
choosing `ui.set_element_state` with `role=AXRadioButton` remains the correct path for an ordinary
radio button group. Both capabilities are frozen, unmodified, non-overlapping in enforced scope.

## Why explicit desired state, never a blind toggle

Mirrors `ui.toggle_disclosure`'s explicit-desired-state discipline exactly: the caller always
states the desired FINAL selection state (`desiredSelected`), and the operation is a true
idempotent no-op if the target already reports it. A capability whose result depends on an unknown
prior state is unsafe to resume after a crash — recovery could not distinguish "already correct"
from "needs replay" without first observing the current state anyway.

## Why Level 2

Consistent with every other per-element AX mutation capability (click/text-entry/state-change/
slider/menu-select/focus/popup-select/disclosure-toggle) — `ui.activate_application`'s Level 1
remains the one deliberate exception, reserved for application-level activation with no element
target. Tab selection is element-level AX interaction with a real, visible UI effect, so per-action
human approval remains the safety mechanism.

## Mutation: the proven `ui.set_element_state`/`ui.toggle_disclosure` mechanism

`AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`, never
CGEvent, keyboard, mouse, or coordinate interaction. AX provides no reliable way to deselect a
single tab via its own press action — the standard interaction model selects a *different* tab
instead, the same limitation Phase 2K already established for `AXRadioButton` deselection. A
`desiredSelected=false` request against an already-selected tab is refused
(`stateChangeNotGuaranteed`), never attempted.

## Idempotency and verification

- **Idempotency**: before any press, `kAXSelectedAttribute` is read (once at resolution, once
  again immediately before any dispatch decision — a selection-state-drift staleness check,
  refusing on mismatch, mirroring `ui.set_element_state`'s/`ui.toggle_disclosure`'s discipline).
  If it already equals `desiredSelected`, no press is performed at all — `changeKind:
  .alreadyDesired` is itself the deterministic, structural proof that no mutation occurred.
- **Verification**: a new `QVerificationStrategy.axTabSelectionMatchesDesired` independently
  re-resolves the target — re-verifying both the role match AND the `AXTabButton` subrole — and
  re-reads `kAXSelectedAttribute` fresh, comparing it directly against `desiredSelected`. A
  successful press is never itself treated as proof of success. An unreadable selection state
  after the press is `.failed`, never defaulted; an unresolvable, ambiguous, or no-longer-
  subrole-qualified target is likewise `.failed`, never assumed successful.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.select_tab":` branch that reuses
`observeTabSelectionEvidence` — the exact same independent, read-only primitive verification uses,
not a parallel resolver. If the target already reports the requested desired selection state, the
step is recognized complete via genuine observation. Otherwise, the step resets to `pending` —
never a blind replay of the press. A resumed execution requires both a brand-new
`QExecutionIdentity` and a genuinely fresh user approval grant, since `QApprovalCoordinator`'s
one-time grants are in-memory only and never survive a crash/restart.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior. A tab's
selection state is a UI-chrome STATE fact, not content. `QAXTabSelectionOutcome`/audit/durable-
state records carry only `targetIdentity`, `changeKind`, `previousSelected`, `currentSelected`,
and `desiredSelected` — no full radio-group/tab-strip dump, no screenshot, no unrelated UI
content, no attribute beyond what identity/status/evidence requires.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXTabRolePolicy`, `QAXTabSelectionChangeKind`,
  `QAXTabSelectionOutcome`, `QAXTabSelectionEvidence`, `selectTab`, `observeTabSelectionEvidence`,
  and three new `QAXInteractionError` cases (`disallowedTabRole`, `targetNotATabButton`,
  `tabSelectionStateReadFailed`) — every other error case is reused from the existing enum.
- `QExecutionService.swift` — `executeSelectTab` dispatch + implementation.
- `QActionVerification.swift` — `.axTabSelectionMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticTabSelectionTests.swift` — new focused suite (35 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified. Every prior semantic
UI capability (click/text-entry/read/state-change/menu-select/slider/activate/focus/popup-select/
disclosure-toggle) is unmodified, including `ui.set_element_state`'s existing `AXRadioButton`
coverage, which remains untouched and un-cross-wired.

## Real macOS AX E2E — result

`QSemanticTabSelectionTests.realMacOSE2ESelectTab` uses a real, live custom `NSButton` fixture
overriding `accessibilityRole()` → `.radioButton` and `accessibilitySubrole()` →
`NSAccessibility.Subrole(rawValue: "AXTabButton")`, drives the full `ui.select_tab` plan through
`QCoreRuntime.submitIntent` + approval, and independently re-reads `kAXSelectedAttribute`
afterward. This capability requires Accessibility permission, so the test is gated on
`AXIsProcessTrusted()`. In the isolated test-runner environment used to validate this phase,
`AXIsProcessTrusted()` was directly confirmed to return `false` (verified via a temporary
diagnostic print, removed before commit) — the same finding independently documented for every
prior AX capability in this codebase (Phase 2H through 2Q).

**An additional, honest layer of uncertainty beyond the usual AX-trust gap**: unlike prior phases,
this session could not empirically confirm that `NSAccessibility.Subrole(rawValue: "AXTabButton")`
— constructed from its raw string because `.tabButton` is, empirically, **not** exposed as a
pre-defined static member on this SDK's `NSAccessibility.Subrole` overlay (confirmed by the exact
same category of compile failure that first caught the "AXTab" role error, "reference to member
'tabButton' cannot be resolved") — actually produces a subrole the live AX subsystem reports back
correctly via `kAXSubroleAttribute`. The construction is standard, valid Swift for any
`NS_TYPED_ENUM`-backed type, and it compiles cleanly, but **no live AX query of any kind executed
in this session** (the same `AXIsProcessTrusted() == false` condition blocks this too), so this
specific mechanism is confirmed correct only by header/documentation analysis, not empirical
observation. Every deterministic, non-AX-dependent test (35/35) ran for real and passed, including
the full approval lifecycle, recovery (both branches), verification independence, and provenance/
budget/privacy checks — none of which depend on live AX subrole reporting.

## Known limitations

1. **The `AXTabButton` subrole assignment via `NSAccessibility.Subrole(rawValue:)` is unverified
   against a live AX query** (see the E2E section above) — this is a materially different, and
   more significant, category of open item than the routine `AXIsProcessTrusted()` gap every AX
   phase carries, and real-hardware validation must specifically confirm it before this capability
   should be considered fully validated.
2. `NSOutlineView`/table-row selection uses the same `kAXSelectedAttribute` mechanism but is
   explicitly out of scope for this capability — `ui.select_tab` targets `AXRadioButton` +
   `AXTabButton` only, never `AXRow`/`AXOutline`/`AXTable`.
3. SwiftUI's `TabView` hosted via `NSHostingView` was the presumed first-choice fixture per this
   phase's Discovery; its exact AX role/attribute behavior could not be empirically evaluated in
   this session (no live AX query was possible at all) — a custom `NSAccessibility`-role-
   overriding fixture was used instead, the same honest choice already established in Phase 2Q.
4. Exact role/identifier/title matching only — no fuzzy/substring fallback.
5. The identity/selection-state observation-binding re-verify (resolve → re-verify snapshot/
   state, back-to-back inside one synchronous closure with no `await` between them) covers the gap
   between resolution and dispatch within a single call; it does not, and structurally cannot
   without an artificial delay seam in production code, protect against a mutation landing in the
   sub-millisecond window between the two reads themselves — the same documented, honest
   limitation every prior AX capability in this codebase already accepts.
6. `ui.set_element_state`'s existing `AXRadioButton` coverage is unchanged and un-cross-wired —
   an ordinary (non-`AXTabButton`-subrole) radio button remains that capability's responsibility.
