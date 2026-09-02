# Phase 2S — Semantic Table Row Selection (`ui.select_table_row`)

Q's twelfth controlled UI-interaction capability. Requests selection (never deselection) of
exactly one semantically-identified table row.

## Scope: selection only, table rows only

Unlike every prior explicit-desired-state capability in this codebase (`ui.toggle_disclosure`,
`ui.select_tab`), this phase does not support a two-way desired state. `desiredSelected` MUST be
exactly `"true"`; `"false"` (deselection) is refused deterministically — before any Accessibility
Trust check or application resolution is even attempted — never treated as a blind toggle and
never silently coerced. Multi-row selection, range selection, and cell-level (`AXCell`) addressing
are all out of scope; the schema (`QModelActionSchema.parameters: [String: String]?`) cannot even
express an array or range, so these are structurally impossible, not merely policy-refused.

## Exact macOS AX semantics — confirmed against the authoritative SDK headers

Confirmed directly against `AXRoleConstants.h`/`AXAttributeConstants.h` (the C-string-macro
headers underlying the ObjC-style names in `NSAccessibilityConstants.h` — the same header family
that caught Phase 2R's "AXTab" mistake):

| Symbol | Value | Role in this capability |
| --- | --- | --- |
| `kAXRowRole` | `"AXRow"` | The row's own base role — `QAXTableRowRolePolicy`'s only allowed role. |
| `kAXTableRole` | `"AXTable"` | The required parent-context role. |
| `kAXTableRowSubrole` | `"AXTableRow"` | The mandatory subrole for a genuine table row. |
| `kAXOutlineRowSubrole` | `"AXOutlineRow"` | A real, distinct subrole — recognized but explicitly **unsupported** in this phase. |
| `kAXSelectedAttribute` | — | The authoritative selection-state attribute (identical to `ui.select_tab`'s). |
| `kAXParentAttribute` | — | Read to establish table context; never written. |

`AXRow` is a genuine, standalone base role — not a subrole borrowed from something else the way a
tab item's `AXRadioButton`+`AXTabButton` shape was. `QAXTableRowRolePolicy` therefore allows
exactly `AXRow` as a search criterion, but `selectTableRow` additionally, unconditionally requires
BOTH:

1. `kAXSubroleAttribute == "AXTableRow"` — a resolved `AXRow` without this exact subrole is
   refused (`targetNotATableRow`), never treated as a table row.
2. A resolved `kAXParentAttribute` whose own `kAXRoleAttribute` is exactly `"AXTable"` — an
   arbitrary standalone `AXRow`+`AXTableRow` element with no such parent is refused
   (`tableContextUnavailable`), never accepted merely because it looks like a table row.

## `AXOutlineRow` — recognized, explicitly unsupported

`kAXOutlineRowSubrole` (`"AXOutlineRow"`) is a real, SDK-confirmed subrole — `NSOutlineView` rows
carry it instead of `AXTableRow`. This phase deliberately does not support it: a resolved `AXRow`
carrying `AXOutlineRow` is refused with its own distinct diagnostic
(`QAXInteractionError.outlineRowUnsupported`), checked and reported separately from the generic
`targetNotATableRow` case for a clearer error, and never silently folded into table-row handling.
Extending to outline rows — including determining whether `AXOutline` is the correct required
parent role, and whether `kAXSelectedAttribute`/press semantics behave identically for outline
rows — is explicitly deferred to a future phase, not assumed compatible.

## Capability contract

Registered as `"ui.select_table_row": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXRow` — the real base role table rows use. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present (identifier-preferred). |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`, only when `identifier` is absent. |
| `desiredSelected` | yes | Must be exactly `"true"` — `"false"` is refused. |

No coordinate, index, or fuzzy-matching parameter exists, and none is structurally reachable
(`QModelActionSchema.parameters` is a flat `[String: String]?`). The `AXTableRow` subrole and
`AXTable` parent-context requirements are **not** parameters — they are hard-coded into
`selectTableRow`'s own contract, never model-configurable.

### Identity strategy: identifier-preferred, via the existing generic matcher

This capability reuses the exact same generic `collectMatches`/`snapshotIfMatches` helpers every
prior AX capability uses, unmodified — no new matching logic was introduced. Those helpers already
check `identifier` before falling back to `title` when both are absent-vs-present (`if let
identifier { match on identifier } else if let title { match on title }`), which is exactly what
"identifier-preferred" requires: when the caller supplies an identifier, it is authoritative and
title is never consulted. No fuzzy/substring/case-insensitive fallback exists for either. If a
row's own `AXTitle`/`AXDescription` turns out to be unreliable in practice (a real, open risk for
table rows — see Known limitations), title-based matching simply fails to find a match and the
capability fails closed (`noMatchingElement`) — it can never silently resolve the wrong row,
because the exact-match discipline the shared helper already enforces prevents that.

## Why Level 2

Consistent with every other per-element AX mutation capability (click/text-entry/state-change/
slider/menu-select/focus/popup-select/disclosure-toggle/tab-select) — `ui.activate_application`'s
Level 1 remains the one deliberate exception, reserved for application-level activation with no
element target. Selecting a row is an app-defined action of unbounded consequence (e.g. selecting
a Mail message can trigger content load; selecting a Finder item changes preview state), so
per-action human approval remains the safety mechanism.

## Mutation: the proven `ui.select_tab` mechanism

`AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`, never
`kAXSelectedRowsAttribute` (the table-level multi-selection array, never read or written by this
single-row capability), never CGEvent, keyboard, mouse, or coordinate interaction.

## Idempotency and verification

- **Idempotency**: before any press, `kAXSelectedAttribute` is read (once at resolution, once
  again immediately before any dispatch decision — a selection-state-drift staleness check,
  refusing on mismatch via the existing generic `QAXInteractionError.valueDriftDetected`,
  mirroring `ui.select_tab`'s discipline). If it already reports `true`, no press is performed at
  all — `changeKind: .alreadyDesired` is itself the deterministic, structural proof that no
  mutation occurred.
- **Verification**: a new `QVerificationStrategy.axTableRowSelectionMatchesDesired` independently
  re-resolves the target — re-verifying the role, the `AXTableRow` subrole, AND the `AXTable`
  parent context — and re-reads `kAXSelectedAttribute` fresh, comparing it directly against
  `desiredSelected`. A successful press is never itself treated as proof of success. An unreadable
  selection state after the press is `.failed`, never defaulted; an unresolvable, ambiguous, or
  no-longer-subrole/context-qualified target is likewise `.failed`, never assumed successful.

## Recovery: observation-first, no blind replay, no persisted authorization

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.select_table_row":` branch that
reuses `observeTableRowSelectionEvidence` — the exact same independent, read-only primitive
verification uses, not a parallel resolver. If the target already reports `selected == true`, the
step is recognized complete via genuine observation. Otherwise, the step resets to `pending` —
never a blind replay of the press. A resumed execution requires both a brand-new
`QExecutionIdentity` and a genuinely fresh user approval grant, since `QApprovalCoordinator`'s
one-time grants are in-memory only and never survive a crash/restart. Because this capability only
ever supports `desiredSelected=true`, a persisted step is only ever resumed toward `true` — there
is no `desiredSelected=false` case for recovery to reconstruct.

## Provenance & privacy

Registered under `toolFamily: "ui"` — no taint-propagation or trust-upgrade behavior. A row's
selection state is a UI-chrome STATE fact, not content. `QAXTableRowSelectionOutcome`/audit/
durable-state records carry only `targetIdentity`, `changeKind`, `previousSelected`,
`currentSelected`, and `desiredSelected` — never the row's own cell contents, never a table dump,
never a screenshot, never any attribute beyond what identity/status/evidence requires.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXTableRowRolePolicy`, `QAXTableRowSelectionChangeKind`,
  `QAXTableRowSelectionOutcome`, `QAXTableRowSelectionEvidence`, `selectTableRow`,
  `observeTableRowSelectionEvidence`, and six new `QAXInteractionError` cases
  (`disallowedTableRowRole`, `targetNotATableRow`, `outlineRowUnsupported`,
  `tableContextUnavailable`, `rowSelectionStateReadFailed`, `rowDeselectionUnsupported`) — every
  other error case (`missingMatchCriteria`, `noMatchingElement`, `ambiguousTarget`,
  `targetDisabled`, `staleTarget`, `actionUnsupported`, `pressFailed`,
  `accessibilityPermissionDenied`, `applicationNotAvailable`, `valueDriftDetected`) is reused from
  the existing enum, unmodified. Reuses the existing `axElementAttribute(_:of:)` helper (previously
  used only for `kAXMenuBarAttribute`) to read `kAXParentAttribute` — no new low-level AX plumbing.
- `QExecutionService.swift` — `executeSelectTableRow` dispatch + implementation, including the
  early, pre-AX-call `desiredSelected == false` rejection.
- `QActionVerification.swift` — `.axTableRowSelectionMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticTableRowSelectionTests.swift` — new focused suite (39 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QExecutionIdentity`, `QResourceGuard`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QAuditLogger` are all unmodified. Every prior semantic
UI capability (click/text-entry/read/state-change/menu-select/slider/activate/focus/popup-select/
disclosure-toggle/tab-select) is unmodified, including `ui.select_tab`'s own `kAXSelectedAttribute`
usage, which this phase mirrors but does not touch.

## Real macOS AX E2E — result

`QSemanticTableRowSelectionTests.realMacOSE2ESelectTableRow` (and every other AX-trust-gated test
in the suite) uses a real, live pair of custom AppKit fixtures — `QTableContainerFixtureView` (an
`NSView` overriding `accessibilityRole()` → `NSAccessibility.Role(rawValue: "AXTable")`) containing
`QTableRowFixtureButton` (an `NSButton` overriding `accessibilityRole()` →
`NSAccessibility.Role(rawValue: "AXRow")` and `accessibilitySubrole()` →
`NSAccessibility.Subrole(rawValue: "AXTableRow")`) — drives the full `ui.select_table_row` plan
through `QCoreRuntime.submitIntent` + approval, and independently re-reads
`kAXSelectedAttribute` afterward. This capability requires Accessibility permission, so every such
test is gated on `AXIsProcessTrusted()`.

In the isolated test-runner environment used to validate this phase, `AXIsProcessTrusted()` was
directly confirmed to return `false` (verified via a temporary diagnostic print, executed once and
removed before the final commit) — the same finding independently documented for every prior AX
capability in this codebase (Phase 2H through 2R). **Real AX E2E was therefore NOT exercised in
this session** — every AX-trust-gated test no-op'd via its `guard AXIsProcessTrusted() else {
return }` rather than fabricating a pass. Every deterministic, non-AX-dependent test (39/39 in this
phase's suite; 2291/2291 across three consecutive full-regression runs) ran for real and passed,
including the full schema/registration, approval lifecycle (grant/deny/single-use/cross-
authorization/persisted-non-authorization/budget-exhaustion), recovery (both branches),
verification-strategy independence, structural forbidden-API/multi-row-impossibility checks, and
provenance/privacy checks — none of which depend on live AX role/subrole/parent reporting.

## Known limitations

1. **The two-level `AXTable`→`AXRow` parent/child AX bridging via plain `NSView`/`NSButton`
   `accessibilityRole()` overrides is unverified against a live AX query.** This is the direct
   analogue of Phase 2R's flagged `AXTabButton`-subrole-assignment uncertainty, and is a
   materially more significant open item than the routine `AXIsProcessTrusted()` gap every AX
   phase carries: standard AppKit AX bridging is documented to mirror the view hierarchy for
   `kAXParentAttribute`/`kAXChildrenAttribute` by default, and this fixture relies on that default
   (neither `accessibilityParent()` nor `accessibilityChildren()` is overridden), but this was not,
   and could not be, empirically confirmed in this session. Real-hardware validation must
   specifically confirm that `QTableRowFixtureButton`'s `kAXParentAttribute` resolves to
   `QTableContainerFixtureView`, and that its reported role is read back as exactly `"AXTable"`,
   before this capability should be considered fully validated.
2. **Whether real, production `NSTableView`/`NSOutlineView` rows reliably populate `AXIdentifier`
   or a usable `AXTitle`/`AXDescription` on the row element itself (as opposed to only on child
   cells) is unconfirmed.** This was the single largest open risk flagged in this phase's own
   Discovery. The capability's identity mechanism fails closed either way (an unpopulated
   identifier/title on a real row simply yields `noMatchingElement`, never a wrong-row match), but
   this means the capability's real-world applicability against genuine `NSTableView`/`List`/
   `Table` rows — as opposed to this session's custom fixture, which sets `AXIdentifier`
   explicitly — is itself an open item for hardware validation, not merely a matching-precision
   nuance.
3. `AXOutlineRow` is a real, SDK-confirmed subrole this phase deliberately does not support (see
   above) — a future phase would need its own discovery to confirm whether `AXOutline` is the
   correct required parent role and whether the identical press/`kAXSelectedAttribute` mechanism
   applies unchanged.
4. Multi-row selection (`kAXSelectedRowsAttribute`), range selection, and cell-level (`AXCell`)
   addressing are all out of scope — single-row, role/subrole-level targeting only.
5. Exact role/identifier/title matching only — no fuzzy/substring fallback, no index/positional
   targeting of any kind (structurally impossible, not merely policy-refused).
6. The identity/selection-state observation-binding re-verify (resolve → re-verify snapshot/
   state, back-to-back inside one synchronous closure with no `await` between them) covers the gap
   between resolution and dispatch within a single call; it does not, and structurally cannot
   without an artificial delay seam in production code, protect against a mutation landing in the
   sub-millisecond window between the two reads themselves — the same documented, honest
   limitation every prior AX capability in this codebase already accepts.
7. Deselection is categorically unsupported in this phase (not merely "unguaranteed" the way
   `ui.select_tab`'s single-item deselection is) — a future phase would need to define what
   deselecting a single row means when other rows in the same table are unaffected, and how that
   interacts with `kAXSelectedRowsAttribute`, before lifting this restriction.
