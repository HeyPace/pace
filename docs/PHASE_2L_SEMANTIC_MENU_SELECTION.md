# Phase 2L — Semantic Menu-Bar Item Selection (`ui.select_menu_item`)

Q's fifth controlled UI-interaction capability: a Level 2, single-level menu-bar selection that
opens one top-level application menu and selects one direct item within it. It closes a gap the
existing capability set could not reliably close through composition: `ui.click_element` can
already press any AX role including `AXMenuBarItem`/`AXMenuItem`, but two separately-approved
presses cannot safely open-then-select a menu, because the approval HUD appearing between them is
itself a focus-stealing event, and native macOS menus dismiss on focus loss. This capability opens
the menu and selects the item atomically within one approved execution.

## Scope

Supports **exactly one level**: a single top-level `AXMenuBarItem` (e.g. "File") and one direct
`AXMenuItem` within its opened `AXMenu` (e.g. "Save"). Explicitly does **not** support: nested
submenus (`File → Export → PDF`), context/right-click menus, the system-wide Apple menu (a
distinct AX element under `AXUIElementCreateSystemWide`, never queried by this capability), or the
application's own root menu (the menu bearing the app's display name, containing About/
Preferences/Quit — always index 0 of the menu bar by macOS AX convention, and explicitly refused).
Path-shaped input (`menuBarTitle`/`itemTitle` containing `/`, `>`, `\`, or `→`) is rejected before
any AX call.

## Capability contract

Registered in `QModelPlanParser.registeredCapabilities` as `"ui.select_menu_item": ("ui",
.level2UserApproval)`. Parameters (via `QModelActionSchema.parameters`):

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `menuBarTitle` | yes | The top-level menu's exact title (e.g. `"File"`). No path separators. |
| `itemTitle` | yes | The target item's exact title within that menu. No path separators. |

No `role` parameter exists — the `AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem` hierarchy is
fixed by macOS AX convention, not model-supplied; every resolution step still verifies the actual
role of what it finds and fails closed on a mismatch. No coordinate, click-count, key-equivalent,
or AX-path parameter exists at all.

## Why Level 2

Determined from the operation's actual properties, matching `ui.click_element`'s own reasoning
exactly: a menu item's real-world effect is arbitrary and app-defined — it could be "Reload" or
"Empty Trash" — so the risk is unbounded in general, the same category `ui.click_element` already
accepts at Level 2. Level 3 was considered and rejected: this capability's risk is per-target and
per-approval, not a property of the capability class itself (the same reasoning that kept
`ui.click_element` — which can also press a "Delete" button — at Level 2 rather than Level 3). No
content-based filtering of menu/item titles was added or considered as a safety mechanism —
approval is the sanctioned mechanism, consistent with the "no bypass/gate based on title content
alone" principle already established for `ui.read_element_value`.

## Why two presses in one approved execution, not two separately-approved `ui.click_element` calls

Every Level 2 press requires its own human approval. Two separately-approved clicks (open the
menu, then select the item) would very likely have the menu auto-dismissed by the time the second
approval resolves — the approval HUD's own appearance is a focus-stealing event, and native menus
close on essentially any loss of key focus. `ui.select_menu_item` closes this gap by pressing the
menu-bar item and, after a bounded wait, the target item, both inside one already-approved
execution — mirroring exactly how every other mutation capability in this codebase (click, text
entry, state change) performs its entire physical action within one call, all pre-approved.

## Target resolution and the application's own root menu

`QBridgeAccessibility.selectMenuItem` (`QBridgeAdapters.swift`) reads `kAXMenuBarAttribute` off
the application element (new AX territory for this codebase — every prior capability walks from
the app element's general `kAXChildrenAttribute`, not the distinct menu-bar subtree), finds the
named top-level `AXMenuBarItem`, and explicitly refuses it if it is the menu bar's index-0 item —
the application's own root menu, by macOS convention. Ambiguous or missing top-level items fail
closed exactly like every other capability's target resolution.

## Bounded polling — new behavior for this codebase, with a hard ceiling

Opening a native menu is asynchronous relative to the press call returning — the target
`AXMenuItem` is not guaranteed queryable in the same synchronous instant. Every prior Q capability
is single-shot, no-wait; this is the first to need a wait. The poll is a **fixed, hard-bounded**
loop: `maxMenuOpenPollAttempts = 10`, `menuOpenPollIntervalNanoseconds = 50_000_000` (50ms),
giving a deterministic ceiling of **500ms total**, never unbounded, never exponential — mirroring
the bounded-traversal philosophy (`collectMatches`'s fixed depth/node/time limits) already used
elsewhere in this file rather than introducing an open-ended wait. `Task.checkCancellation()` is
called on every poll iteration as correct-practice defensive cancellation support; because
`Task.detached` creates an independent task not automatically linked to any caller's cancellation
state, the load-bearing, testable guarantee that polling stops is the fixed ceiling itself, not
cancellation propagation — stated honestly rather than overclaimed. The poll runs entirely inside
one execution call, so no change to `QAgentBudget` was needed: the existing per-step accounting
(one step consumed regardless of internal duration, bounded to ≤500ms here) already covers it.

## Execution: fresh re-verification immediately before dispatch

After the poll finds the item, its enabled state is re-checked immediately before the second
press — if it became disabled in that window, the operation refuses
(`AX_STALE_TARGET`) rather than pressing regardless.

## Verification: an honest evidence contract, not an invented stronger claim

A new `QVerificationStrategy.axMenuItemSelectionEvidence` re-resolves the same menu/item after the
second press via `QBridgeAccessibility.observeMenuItemSelectionEvidence`, which distinguishes
three outcomes (`QMenuItemSelectionEvidence`):

- **`.itemNoLongerResolvable`** — the item (or its menu) is no longer resolvable by the same
  criteria used to find it. This is the expected, benign lifecycle for a genuinely-selected item
  (selecting it closes the menu) — the strongest generic signal AX alone can provide for this
  capability. Treated as `.verified`. No stronger claim (e.g. "the app definitely performed the
  Save") is invented, because AX cannot generically confirm that.
- **`.itemStillResolvable`** — the item is still there, unchanged. No evidence the selection took
  effect. Treated as `.failed`.
- **`.applicationOrTargetUnavailable`** — the application itself, or the top-level menu bar item,
  became unavailable — an *unexpected* disappearance, distinct from the item-level one above.
  Physical state is uncertain; treated as `.failed`, never assumed successful.

## Idempotency & retry semantics — deliberately NOT the `ui.set_element_state` model

Unlike `ui.set_element_state`, there is no coherent "already in the desired state" concept for a
momentary menu command — pressing "Save" twice is not obviously a safe no-op the way checking an
already-checked box is. `ui.select_menu_item` does **not** perform a pre-dispatch idempotency
check or skip the press under any circumstance short of the target being genuinely unresolvable/
disabled. A resumed execution after a crash is treated as a **fresh, independently-authorized**
attempt — `QTaskRecoveryManager`'s default fail-closed-to-pending behavior (no dedicated branch,
same as `ui.click_element`) resets an uncertain step to `pending`, and because
`QApprovalCoordinator` grants are single-use by construction, that resumed step re-enters the
normal `QPermissionGate` evaluation and requires its own fresh approval — the prior grant (if any)
was already consumed or never existed for this new attempt. A replan proposing the identical
selection is likewise always a new, independently-approved execution, never a silent reuse.

## Privacy, audit, memory, HUD, provenance

No free-form content, no masking apparatus — menu/item titles are non-secret targeting metadata,
the same posture already established for `ui.click_element`/`ui.set_element_state`. Registered
under `toolFamily: "ui"` (not `"perception"`) — no taint propagation, since this capability never
observes or exposes arbitrary UI content. `QActionResult.outputData` carries only
`applicationName`/`menuBarTitle`/`itemTitle`/`targetIdentity` — never an AX tree dump, screenshot,
or unrelated window content.

## Real macOS test coverage

`leanring-buddyTests/QSemanticMenuSelectionTests.swift` (27 tests, gated on
`AXIsProcessTrusted()` for every test needing a real, live AXUIElement, honest no-op fallback —
mirroring `QSemanticClickTests`/`QSemanticTextEntryTests`/`QSemanticElementReadTests`/
`QSemanticElementStateTests` exactly): registration/anti-downgrade, invalid schema, a real
top-level-menu-item selection (installed onto the test host's own `NSApp.mainMenu`), menu/item not
found, the bounded-poll timeout's determinism (elapsed-time assertion), ambiguous item, disabled
item (never pressed), wrong application, nested/multi-level path rejection, the application's own
root-menu rejection (index-0 check), best-effort cancellation, the full approve/deny/persisted-
non-reauthorization/reuse/cross-argument approval lifecycle, closed-loop verification (the
evidence-contract's three outcomes), no-dispatch-before-approval, uncertain-state recovery and the
retry-is-a-fresh-execution semantics specifically (distinct from `ui.set_element_state`'s
idempotent model), provenance, budget, and safe-evidence-only audit/durable-state/memory/HUD
content for a real successful run.

**Honest environment note**: at the time this phase was implemented and validated,
`AXIsProcessTrusted()` was again found to return `false` for the isolated test binary — confirmed
by timing analysis showing the real-fixture tests completing in milliseconds despite containing a
100ms sleep placed after the trust guard, identical to the finding already documented for Phase
2K. This is a persistent, pre-existing environment-state fact (unchanged from the prior session),
not a Phase 2L regression. Every deterministic, non-AX-dependent test (registration, schema
validation, path rejection, approval lifecycle, budget, recovery, verification-evidence-contract
logic) still ran for real and passed. **Real hardware validation with Accessibility access
genuinely granted to the test binary remains required before this capability — and Phase 2K's —
should be considered shipped**, particularly for this phase's genuinely new AX territory
(`kAXMenuBarAttribute` traversal and the menu-open poll timing), which a synthetic in-process
`NSMenu` fixture cannot fully substitute for real, system-menu-bar AX behavior.

## Excluded capabilities (explicitly out of scope for this phase)

Nested submenu traversal, context/right-click menus, the Apple menu, the application's own root
menu, keyboard shortcuts/key-equivalent invocation, CGEvent, coordinate-based interaction, mouse
simulation, AppleScript, shell commands, app activation, and any new network/cloud dependency.
None of these were added.

## Known limitations

- Single-level only, by design — a future phase would need its own deliberate scoping to support
  nested submenus, not a blind extension of this poll loop.
- The bounded-poll ceiling (500ms) is a conservative, fixed constant; an unusually slow-to-populate
  menu (uncommon for native AppKit menus) could time out even though the item would have appeared
  slightly later — a deliberate fail-closed trade-off, not a bug.
- Cancellation support is best-effort (`Task.checkCancellation()` inside the poll loop); the
  actual, testable guarantee against unbounded execution is the fixed ceiling, not cancellation
  propagation, since `Task.detached` does not automatically inherit a caller's cancellation state.
- Retry-as-fresh-execution (rather than idempotent no-op) means a resumed plan may, in principle,
  select the same item twice across two genuinely-separate approved executions if a user approves
  both — this is a deliberate, conservative design choice (see "Idempotency & retry semantics"
  above), not an oversight.
- Real on-device system-menu-bar AX behavior is unverified pending real-hardware validation (§
  above) — the in-process test-host fixture, while real AX, is not proven equivalent to every
  third-party application's menu-bar AX implementation.
