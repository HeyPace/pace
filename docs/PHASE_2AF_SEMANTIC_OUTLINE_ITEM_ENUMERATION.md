# Phase 2AF — Semantic Outline Item Enumeration (`ui.list_outline_items`)

Q's twenty-third controlled UI-interaction capability, and its **fifth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, and Phase 2AE's `ui.list_table_rows`). Enumerates direct outline rows belonging to exactly ONE named `AXOutline` in a named, currently running application. No mutation, no press, no open action, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AF, `ui.select_outline_row` (Phase 2T) required the caller to know the exact outline row title or identifier in advance. No capability in the codebase existed to discover the available items inside an `AXOutline` in a running application without attempting a selection. `ui.list_outline_items` closes this discovery gap by providing a safe, read-only inspection primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture: an `NSOutlineView` (or SwiftUI `OutlineGroup` / hierarchical list) exposes an `AXOutline` element. In the AX hierarchy, its visible/disclosed rows are exposed linearly in display order via `kAXRowsAttribute` (or direct `kAXChildrenAttribute` with role `AXRow` and subrole `AXOutlineRow`).

### Traversal Boundary

`kAXChildrenAttribute`/`kAXRowsAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXOutline` (semantic match by `role`, `identifier`/`title`)
- `AXOutline` → direct `AXRow` children (`kAXRowsAttribute` or direct child `AXRow` elements with subrole `AXOutlineRow`)

**Cells (`AXCell`), cell content, sub-outlines, table rows (`AXTableRow`), and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or disclosure mutation is ever dispatched. The outline remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_outline_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXOutline`) | The AX role of the target outline. Validated strictly against `QAXOutlineRolePolicy.allowedRoles` (`Set<String> = ["AXOutline"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the outline. |
| `title` | optional* | The accessibility title or description of the outline. |

*\*At least one of `identifier` or `title` must be supplied to identify the target semantically.*

Returns:
- `applicationName`: string name of the target application
- `outlineTitle`: optional title of the outline
- `outlineIdentifier`: optional identifier of the outline
- `itemCount`: integer total count of enumerated direct rows
- `selectedItemCount`: integer count of positively selected rows
- `expandedItemCount`: integer count of positively expanded/disclosing rows
- `items`: array of `QAXOutlineRowItemMetadata` (`index: Int`, `title?`, `identifier?`, `depth: Int`, `isExpanded: Bool?`, `isSelected: Bool?`, `isEnabled: Bool?`, `role: "AXRow"`, `subrole: "AXOutlineRow"`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectOutlineItemsCount` = 128 (throws `outlineItemCollectionExceedsSafeBound` if exceeded)
- `maxOutlineDepth` = 12 (throws `outlineItemDepthExceedsSafeBound` if exceeded)

## Role validation and row metadata

- Outline: validated as `AXOutline` via `QAXOutlineRolePolicy` (rejects other roles)
- Outline rows: validated as `AXRow` with subrole `AXOutlineRow` (rejects `AXTableRow` and other subroles)
- Parent context: rows are directly anchored to the resolved `AXOutline`

Optional metadata (`title`, `identifier`, `isEnabled`, `isSelected`, `isExpanded`) defaults to `nil` or `false` safely if unreadable. Unknown selection/expansion states are not counted as selected/expanded.

## Privacy boundary

Raw outline item titles and identifiers can contain user data or private context. Therefore:
- Full row metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 15 outline item(s) for outline in application 'Xcode' (selected: 1, expanded: 3)..."`), never leaking full item lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw outline text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_outline_items` **never authorizes** `ui.select_outline_row` or `ui.toggle_disclosure`. Any subsequent selection or disclosure mutation must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.outlineItemEnumerationSucceeded(applicationName:itemCount:selectedCount:expandedCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... outlineRole=AXOutline itemCount=... selectedCount=... expandedCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_outline_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
