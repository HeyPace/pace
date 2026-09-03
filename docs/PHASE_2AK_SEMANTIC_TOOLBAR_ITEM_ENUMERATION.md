# Phase 2AK — Semantic Toolbar Item Enumeration (`ui.list_toolbar_items`)

Q's twenty-sixth controlled UI-interaction capability, and its **eighth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, Phase 2AF's `ui.list_outline_items`, Phase 2AH's `ui.list_tab_items`, and Phase 2AI's `ui.list_radio_group_items`). Enumerates direct interactive controls belonging to exactly ONE named `AXToolbar` in a named application window. No mutation, no press, no focus change, no popup/menu expansion, no approval, no recovery.

## Why this capability, and why now

In macOS applications, window toolbars (`NSToolbar` / `AXToolbar`) host the primary top-level action controls (buttons, popups, search fields, segmented controls, radio groups, checkboxes). Prior to Phase 2AK, an agent had to guess toolbar button titles or identifiers blindly in order to use `ui.click_element` or `ui.select_popup_item`. `ui.list_toolbar_items` closes this gap by providing a safe, read-only discovery primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture (`NSToolbar` / `NSWindow`):
- A window toolbar exposes an `AXToolbar` element (`NSAccessibilityToolbarRole`).
- In the AX hierarchy, its individual controls are exposed as direct children (`kAXChildrenAttribute`).
- Allowed direct child roles: `AXButton`, `AXPopUpButton`, `AXMenuButton`, `AXSearchField`, `AXSegmentedControl`, `AXRadioButton`, `AXCheckBox`, `AXGroup`, `AXTextField`, `AXComboBox`, `AXSlider`.
- Subtrees, popups, and menus are strictly **NOT expanded**. A pop-up button or menu button is reported as a single direct toolbar control item without opening it or enumerating its menu items.

### Traversal Boundary

`kAXChildrenAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXWindow` (by `windowTitle` or `windowIdentifier`, or default window search)
- `AXWindow` → `AXToolbar` (semantic match by `role: "AXToolbar"`, `identifier`/`title`)
- `AXToolbar` → direct interactive children

**Nested controls inside direct `AXGroup` items, menu items inside popups, segments inside segmented controls, and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or mutation is ever dispatched. The toolbar remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_toolbar_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXToolbar`) | The AX role of the target toolbar. Validated strictly against `QAXToolbarRolePolicy.allowedRoles` (`Set<String> = ["AXToolbar"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the toolbar. |
| `title` | optional* | The accessibility title or description of the toolbar. |
| `windowTitle` | optional | The title of the window containing the toolbar. |
| `windowIdentifier` | optional | The identifier of the window containing the toolbar. |

*\*If omitted, targets the single toolbar belonging to the resolved window/application.*

Returns:
- `applicationName`: string name of the target application
- `windowTitle`: optional title of the containing window
- `toolbarTitle`: optional title of the toolbar
- `toolbarIdentifier`: optional identifier of the toolbar
- `itemCount`: integer total count of enumerated direct controls
- `items`: array of `QAXToolbarItemMetadata` (`index: Int`, `title?`, `identifier?`, `role: String`, `subrole: String?`, `isEnabled: Bool?`, `isSelected: Bool?`, `help: String?`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectToolbarItemsCount` = 64 (throws `toolbarItemCollectionExceedsSafeBound` if exceeded)

## Role validation and toolbar metadata

- Toolbar container: validated as `AXToolbar` via `QAXToolbarRolePolicy` (rejects other roles)
- Toolbar items: validated against `allowedDirectToolbarItemRoles`
- Parent context: items are directly anchored to the resolved `AXToolbar`

Optional metadata (`title`, `identifier`, `isEnabled`, `isSelected`, `help`, `subrole`) defaults to `nil` safely if unreadable.

## Privacy boundary

Raw toolbar item titles and identifiers can contain sensitive context (such as document names or sensitive actions). Therefore:
- Full toolbar item metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 5 toolbar item(s) for toolbar in application 'ExampleApp' (window: 'Main')"`), never leaking full item lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw item text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_toolbar_items` **never authorizes** `ui.click_element` or `ui.select_popup_item`. Any subsequent mutation must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.toolbarItemEnumerationSucceeded(applicationName:itemCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... toolbarRole=AXToolbar itemCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_toolbar_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
