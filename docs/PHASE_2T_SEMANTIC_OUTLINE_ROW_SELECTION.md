# Phase 2T — Semantic Outline Row Selection (`ui.select_outline_row`)

Q's thirteenth controlled UI-interaction capability. Requests selection (never deselection) of
exactly one semantically-identified outline row — the reciprocal of Phase 2S's
`ui.select_table_row`, targeting `NSOutlineView`-shaped trees (Finder sidebar, Xcode navigator,
Mail account tree, System Settings sidebar) instead of flat tables.

## Scope: selection only, outline rows only, no auto-expand

Exactly the same discipline Phase 2S established: `desiredSelected` MUST be exactly `"true"`;
`"false"` (deselection) is refused deterministically — before any Accessibility Trust check or
application resolution is even attempted — never treated as a blind toggle and never silently
coerced. Multi-row selection, range selection, and cell-level (`AXCell`) addressing are all out of
scope and structurally impossible (`QModelActionSchema.parameters` is a flat `[String: String]?`).
New to this phase: **no auto-expand-then-select**. Resolution reuses the existing bounded
`collectMatches` tree walk unmodified — it never reads/writes `kAXDisclosingAttribute`, never
performs a disclosure/expand action, and never special-cases a collapsed row's hidden children. A
descendant of a collapsed outline row is simply outside the currently-exposed AX tree and is
treated identically to any other unresolvable target (`noMatchingElement`) — never automatically
expanded to make it reachable.

## Exact macOS AX semantics — confirmed against the authoritative SDK headers

Confirmed directly against `AXRoleConstants.h` (the same header that confirmed
`ui.select_table_row`'s role/subrole/parent constants in Phase 2S):

| Symbol | Value | Role in this capability |
| --- | --- | --- |
| `kAXRowRole` | `"AXRow"` | The row's own base role — the identical base role `ui.select_table_row` uses; outline and table rows share one base role, differing only by subrole. |
| `kAXOutlineRole` | `"AXOutline"` | The required parent-context role. |
| `kAXOutlineRowSubrole` | `"AXOutlineRow"` | The mandatory subrole for a genuine outline row. |
| `kAXTableRowSubrole` | `"AXTableRow"` | A real, distinct subrole — recognized but explicitly refused (owned by `ui.select_table_row`). |
| `kAXSelectedAttribute` | — | The authoritative selection-state attribute (identical to `ui.select_tab`'s/`ui.select_table_row`'s). |
| `kAXParentAttribute` | — | Read to establish outline context; never written. |

`QAXOutlineRowRolePolicy` allows exactly `AXRow` as a search criterion (the same base role
`QAXTableRowRolePolicy` allows), but `selectOutlineRow` additionally, unconditionally requires
BOTH:

1. `kAXSubroleAttribute == "AXOutlineRow"` — a resolved `AXRow` without this exact subrole is
   refused (`targetNotAnOutlineRow`), never treated as an outline row.
2. A resolved `kAXParentAttribute` whose own `kAXRoleAttribute` is exactly `"AXOutline"` — an
   arbitrary standalone `AXRow`+`AXOutlineRow` element with no such parent is refused
   (`outlineContextUnavailable`), never accepted merely because it looks like an outline row. This
   is re-verified independently on every observation (idempotency check, closed-loop
   verification, and recovery all call the same primitive fresh) — a row discovered under an
   outline does not remain trustworthy as an outline row merely because it once was.

## `AXTableRow` — recognized, explicitly refused (the reciprocal of Phase 2S)

`kAXTableRowSubrole` (`"AXTableRow"`) is the real, SDK-confirmed subrole `ui.select_table_row`
already owns. This capability explicitly recognizes and refuses it
(`QAXInteractionError.tableRowUnsupportedForOutline`), checked and reported distinctly from the
generic `targetNotAnOutlineRow` case, and never silently folds table-row selection into
outline-row handling — the exact mirror image of `ui.select_table_row`'s own `AXOutlineRow`
refusal (Phase 2S).

## Capability contract

Registered as `"ui.select_outline_row": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXRow` — the real base role outline rows use. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present (identifier-preferred). |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`, only when `identifier` is absent. |
| `desiredSelected` | yes | Must be exactly `"true"` — `"false"` is refused. |

No coordinate, index, expand, or fuzzy-matching parameter exists, and none is structurally
reachable. The `AXOutlineRow` subrole and `AXOutline` parent-context requirements are **not**
parameters — they are hard-coded into `selectOutlineRow`'s own contract, never model-configurable.

### Identity strategy: identifier-preferred, via the existing generic matcher

Reuses the exact same generic `collectMatches`/`snapshotIfMatches` helpers `ui.select_table_row`
uses, unmodified — no new matching logic was introduced for this phase. Identifier is checked
before title when both are present; no fuzzy/substring/case-insensitive/positional fallback exists
for either. If a real outline row's own `AXTitle`/`AXDescription` turns out to be unreliable in
practice (the same open risk already flagged for table rows in Phase 2S), title-based matching
simply fails to find a match and the capability fails closed (`noMatchingElement`) — never a
wrong-row match.

## Why Level 2

Identical reasoning to every prior per-element AX mutation capability. Selecting an outline row is
an app-defined action of unbounded consequence (e.g. selecting a Finder sidebar item changes the
displayed folder; selecting an Xcode navigator item changes the editor's open file), so per-action
human approval remains the safety mechanism.

## Mutation: the proven `ui.select_table_row`/`ui.select_tab` mechanism

`AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`, never any
table/outline-level multi-selection attribute, never CGEvent, keyboard, mouse, or coordinate
interaction. `kAXSelectedAttribute` is read-only in this implementation.

## Idempotency and verification

- **Idempotency**: before any press, `kAXSelectedAttribute` is read (once at resolution, once
  again immediately before any dispatch decision — a selection-state-drift staleness check,
  refusing on mismatch via the existing generic `QAXInteractionError.valueDriftDetected`,
  mirroring `ui.select_table_row`'s discipline). If it already reports `true`, no press is
  performed at all — `changeKind: .alreadyDesired` is itself the deterministic, structural proof
  that no mutation occurred, and no approval is consumed for a mutation that was never needed.
- **Verification**: a new `QVerificationStrategy.axOutlineRowSelectionMatchesDesired` independently
  re-resolves the target — re-verifying the role, the `AXOutlineRow` subrole, AND the `AXOutline`
  parent context — and re-reads `kAXSelectedAttribute` fresh, comparing it directly against
  `desiredSelected`. A successful press is never itself treated as proof of success. An unreadable
  selection state after the press is `.failed`, never defaulted; an unresolvable, ambiguous, or
  no-longer-subrole/context-qualified target (including one whose role/subrole/parent context
  changed) is likewise `.failed`, never assumed successful.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.select_outline_row":` branch that
reuses `observeOutlineRowSelectionEvidence` — the exact same independent, read-only primitive
verification uses, not a parallel resolver. If the target already reports `selected == true`, the
step is recognized complete via genuine observation. Otherwise, the step resets to `pending` —
never a blind replay of the press, and a resumed execution requires both a brand-new
`QExecutionIdentity` and a genuinely fresh user approval grant, since `QApprovalCoordinator`'s
one-time grants are in-memory only and never survive a crash/restart. No persisted authorization
is ever consulted.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior. An outline
row's selection state is a UI-chrome STATE fact, not content. `QAXOutlineRowSelectionOutcome`/
audit/durable-state records carry only `targetIdentity`, `changeKind`, `previousSelected`,
`currentSelected`, and `desiredSelected` — never the row's own cell contents, never descendant
content, never a tree dump, never a screenshot.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXOutlineRowRolePolicy`, `QAXOutlineRowSelectionChangeKind`,
  `QAXOutlineRowSelectionOutcome`, `QAXOutlineRowSelectionEvidence`, `selectOutlineRow`,
  `observeOutlineRowSelectionEvidence`, and six new `QAXInteractionError` cases
  (`disallowedOutlineRowRole`, `targetNotAnOutlineRow`, `tableRowUnsupportedForOutline`,
  `outlineContextUnavailable`, `outlineRowSelectionStateReadFailed`,
  `outlineRowDeselectionUnsupported`) — every other error case is reused from the existing enum,
  unmodified, including `ui.select_table_row`'s own `outlineRowSubrole`/`tableRowSubrole` string
  constants (`"AXOutlineRow"`/`"AXTableRow"`), reused directly rather than redeclared, since this
  phase's implementation lives in the same file extension. Reuses the existing
  `axElementAttribute(_:of:)` helper (already used for `kAXParentAttribute` since Phase 2S) — no
  new low-level AX plumbing.
- `QExecutionService.swift` — `executeSelectOutlineRow` dispatch + implementation, including the
  early, pre-AX-call `desiredSelected == false` rejection.
- `QActionVerification.swift` — `.axOutlineRowSelectionMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticOutlineRowSelectionTests.swift` — new focused suite (40 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified. Every prior semantic
UI capability — including `ui.select_table_row`'s own `AXTableRow`/`AXTable` coverage — is
unmodified and un-cross-wired.

## Real macOS AX E2E — result

`QSemanticOutlineRowSelectionTests.realMacOSE2ESelectOutlineRow` (and every other AX-trust-gated
test in the suite) uses a real, live pair of custom AppKit fixtures — `QOutlineContainerFixtureView`
(an `NSView` overriding `accessibilityRole()` → `NSAccessibility.Role(rawValue: "AXOutline")`)
containing `QOutlineTreeRowFixtureButton` (an `NSButton` overriding `accessibilityRole()` →
`NSAccessibility.Role(rawValue: "AXRow")` and `accessibilitySubrole()` →
`NSAccessibility.Subrole(rawValue: "AXOutlineRow")`) — drives the full `ui.select_outline_row`
plan through `QCoreRuntime.submitIntent` + approval, and independently re-reads
`kAXSelectedAttribute` afterward. This capability requires Accessibility permission, so every such
test is gated on `AXIsProcessTrusted()`.

In the isolated test-runner environment used to validate this phase, `AXIsProcessTrusted()` was
directly confirmed to return `false` (verified via a temporary diagnostic print, executed once and
removed before the final commit) — the same finding independently documented for every prior AX
capability in this codebase (Phase 2H through 2S). **Real AX E2E was therefore NOT exercised in
this session** — every AX-trust-gated test no-op'd via its `guard AXIsProcessTrusted() else {
return }` rather than fabricating a pass. Every deterministic, non-AX-dependent test (40/40 in this
phase's suite) ran for real and passed, including the full schema/registration, role/subrole/
parent-context policy gate, approval lifecycle (grant/deny/single-use/cross-authorization/
persisted-non-authorization/budget-exhaustion), recovery (both branches), verification-strategy
independence, and structural forbidden-API/multi-row-impossibility/no-auto-expand checks — none of
which depend on live AX role/subrole/parent reporting.

Specifically regarding this phase's hardware-validation questions:

- **Whether real outline rows expose `AXOutlineRow`**: unconfirmed empirically this session (no
  live AX query was possible) — confirmed only from the SDK header (`kAXOutlineRowSubrole` is a
  real, defined constant).
- **Whether parent context resolves as `AXOutline`**: unconfirmed empirically — same limitation as
  Phase 2S's own unverified `AXTable` parent-bridging question; this fixture relies on the
  documented default AppKit behavior (subview hierarchy mirrors the AX parent/child tree) without
  overriding `accessibilityParent()`, which was not, and could not be, empirically exercised.
- **Whether `kAXPressAction` selects the row**: unconfirmed empirically — the fixture's own
  `isAccessibilitySelected()`/`setAccessibilitySelected(_:)` overrides make this trivially true
  *for the fixture*, but a real `NSOutlineView` row's actual press-to-select behavior was not
  exercised.
- **Whether `AXIdentifier`/`AXTitle` are reliably exposed on real rows**: unconfirmed — the same
  open question already flagged for table rows in Phase 2S, inherited unchanged here.

## Known limitations

1. **The two-level `AXOutline`→`AXRow` parent/child AX bridging via plain `NSView`/`NSButton`
   `accessibilityRole()` overrides is unverified against a live AX query.** The direct analogue of
   Phase 2S's own flagged parent-bridging gap (itself the analogue of Phase 2R's `AXTabButton`
   uncertainty) — real-hardware validation must specifically confirm that
   `QOutlineTreeRowFixtureButton`'s `kAXParentAttribute` resolves to `QOutlineContainerFixtureView`,
   and that its reported role is read back as exactly `"AXOutline"`.
2. **Whether real, production `NSOutlineView` rows reliably populate `AXIdentifier` or a usable
   `AXTitle`/`AXDescription` on the row element itself is unconfirmed** — the same open risk
   already flagged for table rows in Phase 2S, inherited unchanged. The capability's identity
   mechanism fails closed either way.
3. **Whether `kAXPressAction` on a real `AXOutlineRow` mutates `kAXSelectedAttribute` the same way
   it does for `AXTableRow` is unconfirmed** — this was the specific blocking unknown named in
   Phase 2T's own Discovery, and remains open pending real-hardware validation.
4. No auto-expand-then-select: a collapsed row's descendant is simply not resolvable, never
   specially detected or expanded — this is a deliberate scope boundary, not a defect, but means
   the model must ensure a target row is already visible (its ancestors already expanded) before
   requesting selection.
5. Multi-row selection, range selection, and cell-level (`AXCell`) addressing are all out of
   scope — single-row, role/subrole-level targeting only.
6. Exact role/identifier/title matching only — no fuzzy/substring fallback, no index/positional
   targeting of any kind (structurally impossible, not merely policy-refused).
7. The identity/selection-state observation-binding re-verify cannot protect against a mutation
   landing in the sub-millisecond window between its own two internal reads — the same documented,
   honest limitation every prior AX capability in this codebase already accepts.
8. Deselection is categorically unsupported in this phase, identical to `ui.select_table_row`'s
   own restriction and for the same reasons.
