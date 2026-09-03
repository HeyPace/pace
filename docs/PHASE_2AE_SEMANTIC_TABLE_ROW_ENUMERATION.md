# Phase 2AE — Semantic Table Row Enumeration (`ui.list_table_rows`)

Q's twenty-second controlled UI-interaction capability, and its **fourth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, and Phase 2AD's `ui.list_popup_items`). Enumerates direct table rows belonging to exactly ONE named `AXTable` in a named, currently running application. No mutation, no press, no open action, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AE, `ui.select_table_row` (Phase 2S) required the caller to know the exact row title or identifier in advance. No capability in the codebase existed to discover the available rows inside an `AXTable` in a running application without attempting a selection. `ui.list_table_rows` closes this discovery gap by providing a safe, read-only inspection primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture: an `NSTableView` (or SwiftUI `Table`) exposes an `AXTable` element. In the AX hierarchy, its rows are exposed via `kAXRowsAttribute` (or direct `kAXChildrenAttribute` with role `AXRow` and subrole `AXTableRow`).

### Traversal Boundary

`kAXChildrenAttribute`/`kAXRowsAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXTable` (semantic match by `role`, `identifier`/`title`)
- `AXTable` → direct `AXRow` children (`kAXRowsAttribute` or direct child `AXRow` elements)

**Cells (`AXCell`), cell content, sub-tables, outline rows (`AXOutlineRow`), and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` is ever dispatched. The table remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_table_rows": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXTable`) | The AX role of the target table. Validated strictly against `QAXTableRolePolicy.allowedRoles` (`Set<String> = ["AXTable"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the table. |
| `title` | optional* | The accessibility title or description of the table. |

*\*At least one of `identifier` or `title` must be supplied to identify the target semantically.*

Returns:
- `applicationName`: string name of the target application
- `tableTitle`: optional title of the table
- `tableIdentifier`: optional identifier of the table
- `rowCount`: integer total count of enumerated direct rows
- `selectedRowCount`: integer count of positively selected rows
- `rows`: array of `QAXTableRowItemMetadata` (`index: Int`, `title?`, `identifier?`, `isSelected: Bool?`, `isEnabled: Bool?`, `role: "AXRow"`, `subrole: "AXTableRow"`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectTableRowsCount` = 128 (throws `tableRowCollectionExceedsSafeBound` if exceeded)

## Role validation and row metadata

- Table: validated as `AXTable` via `QAXTableRolePolicy` (rejects other roles)
- Table rows: validated as `AXRow` with subrole `AXTableRow` (rejects `AXOutlineRow` and other subroles)
- Parent context: rows are directly anchored to the resolved `AXTable`

Optional metadata (`title`, `identifier`, `isEnabled`, `isSelected`) defaults to `nil` or `false` safely if unreadable. Unknown selection states are not counted as selected.

## Privacy boundary

Raw row titles and identifiers can contain user data or private context. Therefore:
- Full row metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 12 table row(s) for table in application 'Mail' (selected rows: 1)..."`), never leaking full row lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw row text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_table_rows` **never authorizes** `ui.select_table_row`. Any subsequent selection must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.tableRowEnumerationSucceeded(applicationName:rowCount:selectedCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... tableRole=AXTable rowCount=... selectedCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_table_rows` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
