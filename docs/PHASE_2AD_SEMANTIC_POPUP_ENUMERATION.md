# Phase 2AD — Semantic Pop-Up Menu Item Enumeration (`ui.list_popup_items`)

Q's twenty-first controlled UI-interaction capability, and its **third read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows` and Phase 2AA's `ui.list_menu_items`). Enumerates direct menu items belonging to exactly ONE named `AXPopUpButton` in a named, currently running application. No mutation, no press, no open action, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AD, `ui.select_popup_item` (Phase 2P) required the caller to know the exact item title to select in advance. No capability in the codebase existed to discover the available options inside an `AXPopUpButton` in a running application without attempting a selection. `ui.list_popup_items` closes this discovery gap by providing a safe, read-only inspection primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture: an `NSPopUpButton` exposes an `AXPopUpButton` element. In the AX hierarchy, its direct children expose an `AXMenu` element containing the list of direct `AXMenuItem` children even when closed.

### Traversal Boundary

`kAXChildrenAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXPopUpButton` (semantic match by `role`, `identifier`/`title`)
- `AXPopUpButton` → direct `AXMenu` child (`kAXChildrenAttribute`)
- `AXMenu` → direct `AXMenuItem` children (`kAXChildrenAttribute`)

**Nested submenus, contextual menus, and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` is ever dispatched. The popup button remains closed and undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_popup_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXPopUpButton`) | The AX role of the target popup button. Validated strictly against `QAXPopupRolePolicy.allowedRoles` (`Set<String> = ["AXPopUpButton"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the pop-up button. |
| `title` | optional* | The accessibility title or description of the pop-up button. |

*\*At least one of `identifier` or `title` must be supplied to identify the target semantically.*

Returns:
- `selectedValue`: string title of the currently selected option (`kAXValueAttribute`)
- `items`: array of `QAXPopupItemMetadata` (`title?`, `identifier?`, `isEnabled?`, `isSelected: Bool`, `role: "AXMenuItem"`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectPopupItemsCount` = 128 (throws `menuItemCollectionExceedsSafeBound` if exceeded)

## Role validation and item metadata

- Pop-up button: validated as `AXPopUpButton` via `QAXPopupRolePolicy` (rejects `AXComboBox`, `AXButton`, etc.)
- Direct menu child: validated as `AXMenu`
- Menu items: validated as `AXMenuItem`

Optional metadata (`title`, `identifier`, `isEnabled`) defaults to `nil` if unreadable. `isSelected` is computed by matching `item.title == selectedValue`.

## Privacy boundary

Raw option titles and identifiers can contain user data or private context. Therefore:
- Full item metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts and selected value only** (e.g. `"Enumerated 3 popup item(s) (current value: 'Option A') for application 'TextEdit'."`), never leaking full option lists.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw option text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_popup_items` **never authorizes** `ui.select_popup_item`. Any subsequent selection must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.popupEnumerationSucceeded(applicationName:itemCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... popupRole=AXPopUpButton itemCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_popup_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
