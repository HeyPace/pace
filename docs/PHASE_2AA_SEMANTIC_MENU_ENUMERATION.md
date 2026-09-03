# Phase 2AA — Semantic Menu Enumeration (`ui.list_menu_items`)

Q's twentieth controlled UI-interaction capability, and its **second read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`). Enumerates the top-level menus and direct menu items belonging to exactly ONE named, currently running application. No mutation, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AA, `ui.select_menu_item` (Phase 2L) required the caller to know the exact top-level menu bar title and direct item title in advance. No capability in the codebase existed to discover the available menu hierarchy of a running application. `ui.list_menu_items` closes this discovery gap by providing a safe, read-only inspection primitive.

## Exact macOS AX semantics

Confirmed directly against `AXAttributeConstants.h`: `kAXMenuBarAttribute` returns an application's menu bar element (`AXMenuBar`). From the menu bar, direct children represent top-level menu elements (`AXMenuBarItem`, `AXMenu`, or `AXMenuExtra`). For each top-level menu, its direct menu representation exposes direct menu items (`AXMenuItem`).

### Traversal Boundary

`kAXChildrenAttribute` is permitted **only at explicitly bounded menu levels**:
- Application → Menu Bar (`kAXMenuBarAttribute`)
- Menu Bar → Top-Level Menu (`kAXChildrenAttribute`)
- Top-Level Menu → Direct Menu Items (`kAXChildrenAttribute`)

**Nested submenus, contextual menus, and arbitrary descendant traversals are strictly out of scope**. If a menu item represents a submenu, only the direct item metadata is captured; the submenu is not followed.

## Capability contract

Registered as `"ui.list_menu_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to enumerate. Exact `localizedName`/`bundleIdentifier` match only — no fuzzy/substring matching. |

Returns, per top-level menu and direct menu item: `title?`, `identifier?`, `isEnabled?`, `role` — never raw `AXUIElement` references, never arbitrary descendants, never document content.

## Application resolution — exact, ambiguity fails closed

`NSWorkspace.shared.runningApplications` is filtered for exact matches against `applicationName`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxTopLevelMenuCount` = 32 (throws `menuCollectionExceedsSafeBound` if exceeded)
- `maxDirectMenuItemsPerMenuCount` = 128 (throws `menuItemCollectionExceedsSafeBound` if exceeded)
- `maxTotalMenuItemsCount` = 512 (throws `totalMenuItemCollectionExceedsSafeBound` if exceeded)

## Role validation and optional metadata

- Menu bar: validated as `AXMenuBar`
- Top-level menus: validated as `AXMenuBarItem`, `AXMenu`, or `AXMenuExtra`
- Menu items: validated as `AXMenuItem`

Wrong-role or malformed elements are silently skipped (`continue`, never `throw`). Optional metadata (`title`, `identifier`, `isEnabled`) defaults to `nil` if unreadable.

## Privacy boundary

Raw menu titles and identifiers can contain sensitive context (e.g. document titles, account names). Therefore:
- Full menu trees remain ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 4 menu(s) and 20 direct item(s) for application 'Finder'."`), never leaking menu or item titles.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing menu text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_menu_items` **never authorizes** `ui.select_menu_item`. Any subsequent selection must independently resolve its target, re-verify state, and obtain required approvals.

## Verification

`QVerificationStrategy.menuEnumerationSucceeded(applicationName:menuCount:itemCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... menuCount=... itemCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_menu_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
