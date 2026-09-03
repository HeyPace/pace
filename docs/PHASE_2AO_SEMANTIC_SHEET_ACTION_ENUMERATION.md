# Phase 2AO — Semantic Sheet Action Enumeration (`ui.list_sheet_actions`)

Q's twenty-ninth controlled UI-interaction capability, and its **eleventh read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, Phase 2AF's `ui.list_outline_items`, Phase 2AH's `ui.list_tab_items`, Phase 2AI's `ui.list_radio_group_items`, Phase 2AK's `ui.list_toolbar_items`, Phase 2AM's `ui.list_segmented_control_items`, and Phase 2AN's `ui.list_sheet_dialogs`). Enumerates direct action controls (`AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`) belonging to exactly ONE named `AXSheet` in an application window. No mutation, no press, no focus change, no popup opening, no approval, no recovery.

## Why this capability, and why now

In Phase 2AN, `ui.list_sheet_dialogs` was introduced to discover blocking modal `AXSheet` containers attached to a window. To maintain strict isolation, Phase 2AN explicitly excluded button enumeration.
When presented with a modal sheet (such as `Save changes before closing?` with `Save`, `Don't Save`, and `Cancel` buttons):
1. An agent can discover that an active modal sheet exists via `ui.list_sheet_dialogs`.
2. However, the agent cannot discover the available action buttons on that sheet without blind guessing.
3. `ui.list_sheet_actions` provides the safe, bounded, read-only discovery primitive to inspect the direct action controls exposed on that specific sheet.

## Canonical AX Role Policy & Direct-Control Boundary

- **Target Container Role**: `AXSheet` (`NSAccessibilitySheetRole`).
- **Allowed Direct Control Roles**: `QAXSheetActionRolePolicy.allowedRoles = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"]`.
- **Tab Exclusion**: Direct children with `subrole == "AXTabButton"` are strictly excluded (owned by `ui.list_tab_items`).
- **PopUpButton Boundary**: Enumerate the popup control itself; do NOT open it or enumerate its options (owned by `ui.list_popup_items`).
- **Descendant Boundary**: Strictly direct children of the target `AXSheet`. Buttons nested within sub-groups (`AXGroup`), text fields, or scroll areas are NOT traversed.

## Exact macOS AX Hierarchy

```
AXApplication
    ↓
AXWindow (resolved by windowTitle or windowIdentifier)
    ↓
AXSheet (resolved by sheetIdentifier or sheetTitle, or single active sheet)
    ↓
direct action controls (AXButton, AXCheckBox, AXRadioButton, AXPopUpButton)
```

## Traversal Boundary

Direct children of `AXSheet` via `kAXChildrenAttribute` are inspected **only at the immediate control level**:
- Application → `AXWindow` (exact match by `windowTitle` or `windowIdentifier`)
- `AXWindow` → `AXSheet` (exact match by `sheetTitle` or `sheetIdentifier`, or single active sheet)
- `AXSheet` → direct action controls (`AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`)

**Nested controls inside groups or menus, text entry fields, and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or mutation is ever dispatched.

## Capability contract

Registered as `"ui.list_sheet_actions": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `windowTitle` | optional* | The title of the window containing the sheet. |
| `windowIdentifier` | optional* | The identifier of the window containing the sheet. |
| `sheetTitle` | optional** | The title of the target sheet. |
| `sheetIdentifier` | optional** | The identifier of the target sheet. |

*\*If window parameters are omitted, targets the single window belonging to the resolved application.*
*\*\*If sheet parameters are omitted, targets the single active sheet belonging to the resolved window.*

Returns:
- `applicationName`: string name of the target application
- `windowTitle`: optional title of the containing window
- `windowIdentifier`: optional identifier of the containing window
- `sheetTitle`: optional title of the target sheet
- `sheetIdentifier`: optional identifier of the target sheet
- `actionCount`: integer total count of enumerated direct action controls
- `actions`: array of `QAXSheetActionMetadata` (`index: Int`, `title?`, `identifier?`, `role: String`, `subrole: String?`, `isEnabled: Bool?`, `isSelected: Bool?`, `isFocused: Bool?`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectSheetActionsCount` = 16 (throws `sheetActionCollectionExceedsSafeBound` if exceeded)

## Context integrity & state observation

- Every action control is verified to belong directly to the resolved `AXSheet`.
- Unknown states safely remain `nil`.

## Privacy boundary

Raw button labels (such as "Save", "Don't Save", "Cancel") can contain sensitive context. Therefore:
- Full action metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 3 direct action control(s) for sheet in application 'ExampleApp' (sheet: 'Save Changes')"`), never leaking full button labels into durable storage.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw button labels from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_sheet_actions` **never authorizes** `ui.click_element`, `ui.set_element_state`, or any subsequent action. Any subsequent action must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.sheetActionEnumerationSucceeded(applicationName:actionCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... sheetActionRole=AXSheetAction actionCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_sheet_actions` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
