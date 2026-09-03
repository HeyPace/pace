# Phase 2AI — Semantic Radio Group Item Enumeration (`ui.list_radio_group_items`)

Q's twenty-fifth controlled UI-interaction capability, and its **seventh read-only, Level 0 discovery capability at the application surface** (following Phase 2Z's `ui.list_windows`, Phase 2AA's `ui.list_menu_items`, Phase 2AD's `ui.list_popup_items`, Phase 2AE's `ui.list_table_rows`, Phase 2AF's `ui.list_outline_items`, and Phase 2AH's `ui.list_tab_items`). Enumerates direct radio button options belonging to exactly ONE named `AXRadioGroup` in a named, currently running application. No mutation, no press, no focus change, no approval, no recovery.

## Why this capability, and why now

Prior to Phase 2AI, `ui.set_element_state` (Phase 2K) allowed selecting an `AXRadioButton` by title or identifier, but no capability existed to discover what radio choices exist inside an `AXRadioGroup` container in a running application without attempting a mutation. `ui.list_radio_group_items` closes this discovery gap by providing a safe, read-only inspection primitive.

## Exact macOS AX semantics

Confirmed directly against AppKit Accessibility architecture (`NSStackView` of radio buttons / `NSMatrix`):
- A radio group container exposes an `AXRadioGroup` element (`NSAccessibilityRadioGroupRole`).
- In the AX hierarchy, its individual options are exposed as direct `AXRadioButton` children (`NSAccessibilityRadioButtonRole`).
- Subrole exclusion: `AXTabButton` (`NSAccessibilityTabButtonSubrole`) is strictly excluded, ensuring tabs (owned by Phase 2AH `ui.list_tab_items` / Phase 2R `ui.select_tab`) are never misidentified as radio group options.

### Traversal Boundary

`kAXChildrenAttribute` is permitted **only at explicitly bounded levels**:
- Application → `AXRadioGroup` (semantic match by `role`, `identifier`/`title`)
- `AXRadioGroup` → direct `AXRadioButton` children (`subrole != "AXTabButton"`)

**Nested subtrees inside other containers, tab buttons, ordinary buttons (`AXButton`), static text (`AXStaticText`), and arbitrary descendant traversals are strictly out of scope**. No `AXUIElementPerformAction(kAXPressAction)` or state mutation is ever dispatched. The radio group remains undisturbed throughout enumeration.

## Capability contract

Registered as `"ui.list_radio_group_items": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to target. Exact `localizedName`/`bundleIdentifier` match only via `resolveExactRunningApplication(named:)`. |
| `role` | no (defaults to `AXRadioGroup`) | The AX role of the target radio group. Validated strictly against `QAXRadioGroupRolePolicy.allowedRoles` (`Set<String> = ["AXRadioGroup"]`). |
| `identifier` | optional* | The accessibility identifier (`AXIdentifier`) of the radio group. |
| `title` | optional* | The accessibility title or description of the radio group. |

*\*At least one of `identifier` or `title` must be supplied to identify the target semantically.*

Returns:
- `applicationName`: string name of the target application
- `radioGroupTitle`: optional title of the radio group
- `radioGroupIdentifier`: optional identifier of the radio group
- `itemCount`: integer total count of enumerated direct radio options
- `selectedItemCount`: integer count of positively selected radio options
- `items`: array of `QAXRadioGroupItemMetadata` (`index: Int`, `title?`, `identifier?`, `isSelected: Bool?`, `isEnabled: Bool?`, `role: "AXRadioButton"`, `subrole: String?`)

## Application resolution — exact, ambiguity fails closed

Uses the shared exact application resolver `QBridgeAccessibility.resolveExactRunningApplication(named:)`:
- Zero matches: throws `applicationNotAvailable`
- More than one match: throws `ambiguousTarget(count:)`

## Bounded enumeration

Traversal is strictly bounded by defensive ceilings:
- `maxDirectRadioItemsCount` = 64 (throws `radioItemCollectionExceedsSafeBound` if exceeded)

## Role validation and radio metadata

- Radio group: validated as `AXRadioGroup` via `QAXRadioGroupRolePolicy` (rejects other roles)
- Radio items: validated as `AXRadioButton` with subrole `nil` or `subrole != "AXTabButton"` (rejects tab buttons and other roles)
- Parent context: items are directly anchored to the resolved `AXRadioGroup`

Optional metadata (`title`, `identifier`, `isEnabled`, `isSelected`) defaults to `nil` safely if unreadable. Unknown selection states are not counted as selected.

## Privacy boundary

Raw radio item titles and identifiers can contain sensitive form options. Therefore:
- Full radio option metadata remains ephemeral in `outputData` during the execution turn.
- `result.summary` contains **aggregate counts only** (e.g. `"Enumerated 3 radio item(s) for radio group in application 'ExampleApp' (selected: 1)..."`), never leaking full option lists or private contents.
- `QDurablePlanStepSnapshot` does not serialize `outputData`, preventing raw option text from entering SQLite WAL task stores, recovery snapshots, audit logs, or long-term memory.

## Authorization semantics

Discovery is strictly informational. `ui.list_radio_group_items` **never authorizes** `ui.set_element_state`. Any subsequent radio selection must independently resolve its target, re-verify state, and obtain required Level 2 user approvals via `QApprovalCoordinator`.

## Verification

`QVerificationStrategy.radioGroupEnumerationSucceeded(applicationName:itemCount:selectedCount:)` verifies the execution result's `success` flag and outputs aggregate counts in its evidence string (`"application=... radioGroupRole=AXRadioGroup itemCount=... selectedCount=... status=verified"`).

## No recovery branch

Being a Level 0 read-only capability, `ui.list_radio_group_items` does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.
