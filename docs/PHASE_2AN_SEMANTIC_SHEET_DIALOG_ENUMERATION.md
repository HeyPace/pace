# Phase 2AN — Semantic Sheet/Dialog Enumeration (`ui.list_sheet_dialogs`)

Q's twenty-eighth controlled UI-interaction capability, and its **tenth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, Phase 2AF's `ui.list_outline_items`, Phase 2AH's `ui.list_tab_items`, Phase 2AI's `ui.list_radio_group_items`, Phase 2AK's `ui.list_toolbar_items`, and Phase 2AM's `ui.list_segmented_control_items`). Enumerates direct `AXSheet` modal elements attached to exactly ONE named `AXWindow` in a named application. No mutation, no press, no focus change, no button enumeration, no approval, no recovery.

## Why this capability, and why now

In macOS AppKit and SwiftUI applications, **Modal Sheets** (`NSWindow.beginSheet`, `NSAlert.beginSheetModal(for:)`, `NSSavePanel`, `NSOpenPanel`) are attached directly to a parent window. When presented:
1. The parent window's standard controls become non-interactive.
2. `ui.list_windows` only enumerates top-level application windows (`kAXWindowsAttribute`), leaving attached modal sheets invisible.
3. An agent needs a safe, bounded, read-only discovery primitive to inspect whether a window currently has an active sheet, what its modal title/identifier is, and whether it is modal.

## Canonical AX Role Policy & `AXDialog` Restriction

- **Canonical Target Role**: `AXSheet` (`NSAccessibilitySheetRole`).
- **`AXDialog` Restriction**: `AXDialog` and generic modal containers are **strictly excluded** from `QAXSheetRolePolicy.allowedRoles`. The production semantic contract is strictly `AXSheet` enumeration. If an `AXDialog` appears, it is ignored and not included in the returned sheet collection.
- **Button/Descendant Restriction**: Strictly **no button or descendant enumeration**. Child action controls (such as "Save", "Don't Save", "Cancel") inside the sheet are NOT inspected or returned.

## Exact macOS AX Hierarchy

```
AXApplication
    ↓
AXWindow (resolved by windowTitle or windowIdentifier)
    ↓
AXSheet (kAXSheetsAttribute / direct children with role == "AXSheet")
```

## Traversal Boundary

`kAXSheetsAttribute` and direct children of `AXWindow` are inspected **only at the direct sheet level**:
- Application → `AXWindow` (exact match by `windowTitle` or `windowIdentifier`)
- `AXWindow` → direct `AXSheet` elements

**Nested controls inside the sheet (such as buttons, fields, labels) and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or mutation is ever dispatched.

## Capability contract

Registered as `"ui.list_sheet_dialogs": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `windowTitle` | optional* | The title of the window containing the sheet. |
| `windowIdentifier` | optional* | The identifier of the window containing the sheet. |

*\*If omitted, targets the single window belonging to the resolved application.*

Returns:
- `applicationName`: string name of the target application
- `windowTitle`: optional title of the containing window
- `windowIdentifier`: optional identifier of the containing window
- `sheetCount`: integer total count of enumerated direct sheets
- `sheets`: array of `QAXSheetMetadata` (`index: Int`, `title?`, `identifier?`, `role: String`, `subrole: String?`, `isModal: Bool?`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectSheetsCount` = 16 (throws `sheetCollectionExceedsSafeBound` if exceeded)

## Context integrity & state observation

- Every sheet is verified to belong directly to the resolved `AXWindow`.
- Duplicate elements from both `kAXSheetsAttribute` and direct children are deterministically deduplicated.
- Unknown states safely remain `nil`.

## Privacy boundary

Raw sheet titles and identifiers can contain sensitive context (such as document names or private prompts). Therefore:
- Full sheet metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 1 sheet(s) for window in application 'ExampleApp' (window: 'Main')"`), never leaking full sheet titles or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw sheet text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_sheet_dialogs` **never authorizes** `ui.close_window`, `ui.click_element`, or any button mutation. Any subsequent action must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.sheetEnumerationSucceeded(applicationName:sheetCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... sheetRole=AXSheet sheetCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_sheet_dialogs` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
