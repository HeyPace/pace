# Phase 2AH — Semantic Tab Item Enumeration (`ui.list_tab_items`)

Q's twenty-fourth controlled UI-interaction capability, and its **sixth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, and Phase 2AF's `ui.list_outline_items`). Enumerates direct tab items belonging to exactly ONE named `AXTabGroup` in a named, currently running application. No mutation, no press, no focus change, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AH, `ui.select_tab` (Phase 2R) required the caller to know the exact tab title or identifier in advance. No capability in the codebase existed to discover what tabs were available within an `AXTabGroup` in a running application without attempting a selection. `ui.list_tab_items` closes this discovery gap by providing a safe, read-only tab discovery primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture (`NSTabView` / SwiftUI `TabView`):
- A tab container exposes an `AXTabGroup` element (`NSAccessibilityTabGroupRole`).
- In the AX hierarchy, its individual tabs are exposed via `kAXTabsAttribute` (`"AXTabs"`) or direct children with base role `AXRadioButton` (`NSAccessibilityRadioButtonRole`) and subrole `AXTabButton` (`NSAccessibilityTabButtonSubrole`).

### Traversal Boundary

`kAXTabsAttribute`/`kAXChildrenAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXTabGroup` (semantic match by `role`, `identifier`/`title`)
- `AXTabGroup` → direct `AXRadioButton` children with subrole `AXTabButton`

**Pane contents, nested controls inside tab pages, ordinary radio buttons without the `AXTabButton` subrole, and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or selection mutation is ever dispatched. The tab group remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_tab_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXTabGroup`) | The AX role of the target tab group. Validated strictly against `QAXTabGroupRolePolicy.allowedRoles` (`Set<String> = ["AXTabGroup"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the tab group. |
| `title` | optional* | The accessibility title or description of the tab group. |

*\*At least one of `identifier` or `title` must be supplied to identify the target semantically.*

Returns:
- `applicationName`: string name of the target application
- `tabGroupTitle`: optional title of the tab group
- `tabGroupIdentifier`: optional identifier of the tab group
- `itemCount`: integer total count of enumerated direct tabs
- `selectedItemCount`: integer count of positively selected tabs
- `items`: array of `QAXTabItemMetadata` (`index: Int`, `title?`, `identifier?`, `isSelected: Bool?`, `isEnabled: Bool?`, `role: "AXRadioButton"`, `subrole: "AXTabButton"`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectTabItemsCount` = 64 (throws `tabItemCollectionExceedsSafeBound` if exceeded)

## Role validation and tab metadata

- Tab group: validated as `AXTabGroup` via `QAXTabGroupRolePolicy` (rejects other roles)
- Tab items: validated as `AXRadioButton` with subrole `AXTabButton` (rejects ordinary radio buttons and other subroles)
- Parent context: tabs are directly anchored to the resolved `AXTabGroup`

Optional metadata (`title`, `identifier`, `isEnabled`, `isSelected`) defaults to `nil` safely if unreadable. Unknown selection states are not counted as selected.

## Privacy boundary

Raw tab item titles and identifiers can contain sensitive context. Therefore:
- Full tab metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 4 tab item(s) for tab group in application 'ExampleApp' (selected: 1)..."`), never leaking full tab lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw tab text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_tab_items` **never authorizes** `ui.select_tab`. Any subsequent tab selection must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.tabItemEnumerationSucceeded(applicationName:tabCount:selectedCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... tabGroupRole=AXTabGroup tabCount=... selectedCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_tab_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
