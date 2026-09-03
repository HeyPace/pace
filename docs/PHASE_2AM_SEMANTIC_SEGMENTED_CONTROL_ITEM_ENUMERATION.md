# Phase 2AM — Semantic Segmented Control Item Enumeration (`ui.list_segmented_control_items`)

Q's twenty-seventh controlled UI-interaction capability, and its **ninth read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, Phase 2AF's `ui.list_outline_items`, Phase 2AH's `ui.list_tab_items`, Phase 2AI's `ui.list_radio_group_items`, and Phase 2AK's `ui.list_toolbar_items`). Enumerates direct segment options belonging to exactly ONE named `AXSegmentedControl` in a named application window. No mutation, no press, no focus change, no approval, no recovery.

## Why this capability, and why now

In modern macOS AppKit and SwiftUI applications, **Segmented Controls** (`NSSegmentedControl` / `AXSegmentedControl`) are the primary compound control for multi-state mode selection (e.g. view mode switchers: Icons / List / Columns, Display style toggles, Text alignment).
Phase 2AK's `ui.list_toolbar_items` exposes `AXSegmentedControl` as a discrete item in a toolbar. `ui.list_segmented_control_items` provides the exact logical drill-down capability to inspect the individual segments inside any segmented control without blind guessing.

## Canonical AX Role Policy & `AXRadioGroup` Decision

- **Canonical Target Role**: `AXSegmentedControl` (`NSAccessibilitySegmentedControlRole`).
- **`AXRadioGroup` Decision**: `AXRadioGroup` is **strictly excluded** from `QAXSegmentedControlRolePolicy.allowedRoles`. This maintains a clean, non-overlapping semantic boundary:
  - Standard radio groups are handled exclusively by `ui.list_radio_group_items` (Phase 2AI).
  - Segmented controls are handled exclusively by `ui.list_segmented_control_items` (Phase 2AM).
- **Allowed Segment Roles**: `AXRadioButton`, `AXButton`.
- **Tab Exclusion**: Any segment child bearing `subrole == "AXTabButton"` is strictly excluded and rejected, as tab controls are owned exclusively by Phase 2AH (`ui.list_tab_items`).

## Exact macOS AX Hierarchy

```
AXApplication
    ↓
AXWindow (optional filter by windowTitle or windowIdentifier)
    ↓
AXSegmentedControl (matched by identifier and/or title)
    ↓
direct segment children (kAXChildrenAttribute)
```

## Traversal Boundary

`kAXChildrenAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXWindow` (by `windowTitle` or `windowIdentifier`, or default window search)
- `AXWindow` → `AXSegmentedControl` (semantic match by `role: "AXSegmentedControl"`, `identifier`/`title`)
- `AXSegmentedControl` → direct segment children

**Nested controls inside direct `AXGroup` items, menu items inside popups, and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or mutation is ever dispatched. The control remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_segmented_control_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXSegmentedControl`) | The AX role of the target container. Validated strictly against `QAXSegmentedControlRolePolicy.allowedRoles` (`Set<String> = ["AXSegmentedControl"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the segmented control. |
| `title` | optional* | The accessibility title or description of the segmented control. |
| `windowTitle` | optional | The title of the window containing the segmented control. |
| `windowIdentifier` | optional | The identifier of the window containing the segmented control. |

*\*If omitted, targets the single segmented control belonging to the resolved window/application.*

Returns:
- `applicationName`: string name of the target application
- `windowTitle`: optional title of the containing window
- `controlTitle`: optional title of the segmented control
- `controlIdentifier`: optional identifier of the segmented control
- `itemCount`: integer total count of enumerated direct segments
- `selectedItemCount`: integer total count of currently selected segments
- `items`: array of `QAXSegmentedControlItemMetadata` (`index: Int`, `title?`, `identifier?`, `role: String`, `subrole: String?`, `isEnabled: Bool?`, `isSelected: Bool?`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectSegmentsCount` = 32 (throws `segmentedControlItemCollectionExceedsSafeBound` if exceeded)

## Context integrity & state observation

- Every segment is verified to belong to `directChildren(resolvedSegmentedControl)`.
- Selection observation uses standard `kAXValueAttribute` / `kAXSelectedAttribute` reading.
- Unknown states safely remain `nil`.

## Privacy boundary

Raw segment titles and identifiers can contain sensitive context (such as document names or private options). Therefore:
- Full segment item metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 3 segment(s) for segmented control in application 'ExampleApp' (window: 'Main') (selected: 1)"`), never leaking full segment lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw segment text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_segmented_control_items` **never authorizes** `ui.select_tab`, `ui.set_element_state`, or any future segment mutation capability. Any subsequent mutation must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.segmentedControlEnumerationSucceeded(applicationName:itemCount:selectedCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... segmentedControlRole=AXSegmentedControl itemCount=... selectedCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_segmented_control_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
