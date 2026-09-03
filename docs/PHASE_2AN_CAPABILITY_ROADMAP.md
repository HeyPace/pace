# Phase 2AN — Capability Roadmap Discovery

## Baseline
- **Branch**: `q-secure-foundation`
- **HEAD Commit**: `1f33435`
- **Working Tree**: `CLEAN` (verified via `git status --short`)
- **Discovery Status**: `DISCOVERY ONLY` (no source, test, or schema modifications)

---

## Current Capability Inventory

| # | Capability | Domain | Type | Risk Level | Target Resolution Model | Verification Model | Recovery Model | Privacy Class | Real E2E Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `system.running_apps` | system | Read-Only | Level 0 | System-wide process list | None (read is own result) | None | Safe aggregate metadata | Unit / Mock |
| 2 | `system.clipboard.read` | system | Read-Only | Level 0 | System pasteboard | None | None | Transient perception | Unit |
| 3 | `screen.ocr` | perception | Read-Only | Level 0 | Screen capture + Vision | None | None | Transient perception | Unit |
| 4 | `ui.open_app` | app | Mutation | Level 1 | Bundle URL / NSWorkspace | Process existence check | Re-verify running state | Safe process name | Unit |
| 5 | `fs.read` | fs | Read-Only | Level 0 | Sandboxed path | None | None | Local filesystem | Unit |
| 6 | `fs.write_sandbox` | fs | Mutation | Level 1 | Sandboxed path | File existence + hash | Re-verify file | Local filesystem | Unit |
| 7 | `test.noop` | test | Read-Only | Level 0 | Synthetic | Immediate true | None | None | Unit |
| 8 | `accessibility.read` | accessibility | Read-Only | Level 0 | AX UI hierarchy | None | None | Ephemeral AX tree | Unit |
| 9 | `system.clipboard.write` | system | Mutation | Level 2 | System pasteboard | Pasteboard match | Re-verify pasteboard | Masked sensitive data | Unit |
| 10 | `app.quit` | app | Mutation | Level 3 | Exact NSRunningApplication | Process absence | Verify termination | Safe process name | Real E2E |
| 11 | `ui.click_element` | ui | Mutation | Level 2 | Bounded AX tree search (role+id/title) | Snapshot match (role/id/title) | Re-verify element | Ephemeral output | Real E2E |
| 12 | `ui.set_text_value` | ui | Mutation | Level 2 | Focused element (AXTextField/Area) | kAXValueAttribute read | Re-verify value | Masked in durable state | Real E2E |
| 13 | `ui.read_element_value` | perception | Read-Only | Level 0 | Bounded AX tree search (role+id/title) | Read execution outcome | None | Transient perception | Real E2E |
| 14 | `ui.set_element_state` | ui | Mutation | Level 2 | Bounded AX search (AXCheckBox/Radio) | kAXValueAttribute read | Re-verify value | Safe state string | Real E2E |
| 15 | `ui.select_menu_item` | ui | Mutation | Level 2 | AXMenuBar -> MenuBarItem -> MenuItem | Evidence-based (item dismissed) | Re-verify closed | Ephemeral output | Real E2E |
| 16 | `ui.set_slider_value` | ui | Mutation | Level 2 | Bounded AX search (AXSlider/Stepper) | kAXValueAttribute numeric match | Re-verify numeric value | Non-sensitive numeric | Real E2E |
| 17 | `ui.activate_application` | app | Mutation | Level 1 | Exact running app (name/bundleId) | Frontmost process PID match | Re-verify frontmost | Safe process name | Real E2E |
| 18 | `ui.focus_element` | ui | Mutation | Level 2 | Bounded AX search (focusable role) | kAXFocusedAttribute read | Re-verify focus | Ephemeral output | Real E2E |
| 19 | `ui.select_popup_item` | ui | Mutation | Level 2 | AXPopUpButton -> direct AXMenuItem | kAXValueAttribute string match | Re-verify popup value | Ephemeral output | Real E2E |
| 20 | `ui.toggle_disclosure` | ui | Mutation | Level 2 | AXDisclosureTriangle | kAXDisclosingAttribute read | Re-verify disclosure | Safe boolean state | Real E2E |
| 21 | `ui.select_tab` | ui | Mutation | Level 2 | AXRadioButton (subrole AXTabButton) | kAXSelectedAttribute read | Re-verify tab selection | Ephemeral output | Real E2E |
| 22 | `ui.select_table_row` | ui | Mutation | Level 2 | AXRow (subrole AXTableRow in AXTable) | kAXSelectedAttribute read | Re-verify row selection | Ephemeral output | Real E2E |
| 23 | `ui.select_outline_row` | ui | Mutation | Level 2 | AXRow (subrole AXOutlineRow in AXOutline) | kAXSelectedAttribute read | Re-verify outline row | Ephemeral output | Real E2E |
| 24 | `ui.set_window_minimized` | ui | Mutation | Level 2 | AXWindow (exact title/id) | kAXMinimizedAttribute read | Re-verify minimized | Safe boolean state | Real E2E |
| 25 | `ui.set_application_hidden` | app | Mutation | Level 2 | Exact NSRunningApplication | NSRunningApplication.isHidden | Re-verify hidden state | Safe process name | Real E2E |
| 26 | `ui.set_scroll_position` | ui | Mutation | Level 2 | AXScrollArea -> AXScrollBar | kAXValueAttribute numeric match | Re-verify scroll value | Non-sensitive numeric | Real E2E |
| 27 | `ui.set_window_main` | ui | Mutation | Level 2 | AXWindow (exact title/id) | kAXMainAttribute read | Re-verify main state | Safe boolean state | Real E2E |
| 28 | `ui.close_window` | ui | Mutation | Level 3 | AXWindow -> Close AXButton | Window absence + App running | Re-verify absence | Safe title/id | Real E2E |
| 29 | `ui.list_windows` | ui | Read-Only | Level 0 | Exact running app -> kAXWindows | Aggregate count verification | None | Ephemeral output | Real E2E |
| 30 | `ui.list_menu_items` | ui | Read-Only | Level 0 | Exact running app -> kAXMenuBar | Aggregate count verification | None | Ephemeral output | Real E2E |
| 31 | `ui.list_popup_items` | ui | Read-Only | Level 0 | Exact running app -> AXPopUpButton | Aggregate count verification | None | Ephemeral output | Real E2E |
| 32 | `ui.list_table_rows` | ui | Read-Only | Level 0 | Exact running app -> AXTable | Aggregate count verification | None | Ephemeral output | Real E2E |
| 33 | `ui.list_outline_items` | ui | Read-Only | Level 0 | Exact running app -> AXOutline | Aggregate count verification | None | Ephemeral output | Real E2E |
| 34 | `ui.list_tab_items` | ui | Read-Only | Level 0 | Exact running app -> AXTabGroup | Aggregate count verification | None | Ephemeral output | Real E2E |
| 35 | `ui.list_radio_group_items` | ui | Read-Only | Level 0 | Exact running app -> AXRadioGroup | Aggregate count verification | None | Ephemeral output | Real E2E |
| 36 | `ui.list_toolbar_items` | ui | Read-Only | Level 0 | Exact running app -> AXToolbar | Aggregate count verification | None | Ephemeral output | Real E2E |
| 37 | `ui.list_segmented_control_items` | ui | Read-Only | Level 0 | Exact running app -> AXSegmentedControl | Aggregate count verification | None | Ephemeral output | Real E2E |

Total Registered Capabilities: **37** (9 Level 0 Container Discovery Primitives).

---

## Existing Discovery Coverage

The current 9 Level 0 discovery primitives cover:
1. Applications & Windows (`ui.list_windows`)
2. Menu Bars & Top-level Menus (`ui.list_menu_items`)
3. Pop-up Buttons & Menus (`ui.list_popup_items`)
4. Tables & Table Rows (`ui.list_table_rows`)
5. Outlines & Hierarchical Rows (`ui.list_outline_items`)
6. Tab Groups & Tab Buttons (`ui.list_tab_items`)
7. Radio Groups & Radio Buttons (`ui.list_radio_group_items`)
8. Window Toolbars & Action Controls (`ui.list_toolbar_items`)
9. Segmented Controls & Segment Options (`ui.list_segmented_control_items`)

### Missing Discovery Surface: Window Modal Sheets & Dialogs
In macOS AppKit and SwiftUI applications, **Modal Sheets and Dialogs** (`AXSheet` / `AXDialog` via `NSAlert`, `NSSavePanel`, `NSOpenPanel`, or custom sheets) are attached directly to a parent `AXWindow` (exposed via `kAXSheetsAttribute` / `kAXChildrenAttribute`).
When an application presents a modal sheet (e.g., Save Changes, Export, Permissions Confirmation, Confirmation Alerts):
1. The parent window's standard controls become blocked.
2. `ui.list_windows` only enumerates top-level application windows (`kAXWindowsAttribute`), leaving attached modal sheets undiscovered.
3. An agent currently has no dedicated read-only discovery primitive to inspect whether a window has an active sheet, what its modal title/message is, and what direct action controls (`AXButton`) are present.
Adding `ui.list_sheet_dialogs` provides safe, bounded, read-only discovery for this critical modal surface.

---

## Candidate Analysis

### Candidate 1: `ui.list_sheet_dialogs` (Semantic Window Modal Sheet & Dialog Enumeration) — RECOMMENDED
- **Domain**: Modal Sheets & Dialogs (`AXSheet` / `AXDialog`).
- **Target Hierarchy**:
  - `AXApplication` → `AXWindow` (resolved by `windowTitle` or `windowIdentifier`) → `kAXSheetsAttribute` / direct `AXSheet` / `AXDialog` children → direct action buttons / controls.
- **Allowed Container Roles**: `AXSheet`, `AXDialog`.
- **Bounds**: `maxDirectSheetsCount = 16`.
- **Risk Level**: Level 0 Read-Only. No mutation, no press, no focus change, no approval.
- **Privacy Boundary**: Ephemeral in `outputData`, aggregate counts in `summary` and `verifiedEvidence`.
- **Authorization Isolation**: Purely informational; confers **zero authorization** to press buttons on the sheet.

### Candidate 2: `ui.list_combo_box_items` (Semantic Combo Box Item Enumeration)
- **Domain**: Combo Box Dropdown Lists (`NSComboBox` / `AXComboBox`).
- **Target Hierarchy**: `AXApplication` → `AXWindow` → `AXComboBox` → direct drop-down list items.
- **Bounds**: `maxDirectComboBoxItemsCount = 64`.
- **Risk Level**: Level 0 Read-Only.

### Candidate 3: `ui.select_segmented_control_item` (Semantic Segment Selection Mutation)
- **Domain**: Segment Selection Mutation.
- **Target Hierarchy**: `AXApplication` → `AXWindow` → `AXSegmentedControl` → specific segment target.
- **Risk Level**: Level 2 User Approval.

### Candidate 4: `ui.list_split_panes` (Semantic Split View Pane Enumeration)
- **Domain**: Split View Panes (`NSSplitView` / `AXSplitGroup`).
- **Target Hierarchy**: `AXApplication` → `AXWindow` → `AXSplitGroup` → direct panes.
- **Bounds**: `maxDirectPanesCount = 16`.
- **Risk Level**: Level 0 Read-Only.

---

## Scoring Table (out of 100)

| Criterion | `ui.list_sheet_dialogs` | `ui.list_combo_box_items` | `ui.select_segmented_control_item` | `ui.list_split_panes` |
| :--- | :---: | :---: | :---: | :---: |
| Semantic Value (/10) | 10 | 8 | 9 | 7 |
| User Utility (/10) | 10 | 8 | 9 | 7 |
| Exact Targetability (/10) | 10 | 9 | 9 | 8 |
| Security Safety (/10) | 10 | 10 | 8 | 10 |
| Testability (/10) | 10 | 9 | 9 | 8 |
| Determinism (/10) | 10 | 9 | 9 | 8 |
| Existing Infrastructure Reuse (/10) | 10 | 10 | 10 | 10 |
| Privacy Safety (/10) | 9 | 10 | 10 | 10 |
| Bounded Implementation (/10) | 10 | 10 | 10 | 10 |
| Architectural Fit (/10) | 10 | 10 | 9 | 9 |
| **TOTAL (/100)** | **99** | **93** | **92** | **87** |

---

## Ranked Candidates

### Rank 1: `ui.list_sheet_dialogs` (Score: 99/100) — RECOMMENDED
- **Why it Wins**:
  - Critical visibility into blocking modal dialogs and sheets (`AXSheet` / `AXDialog`) attached to application windows.
  - Allows an agent to detect why a window is unresponsive (e.g. Save Prompt, Unsaved Changes Alert, Permission Dialog) and enumerate the sheet's direct buttons.
  - Level 0 Read-Only, bounded (`maxDirectSheetsCount = 16`), zero mutation, zero approval.

### Rank 2: `ui.list_combo_box_items` (Score: 93/100)
- **Summary**: Read-only discovery of combo box dropdown options (`AXComboBox`).

### Rank 3: `ui.select_segmented_control_item` (Score: 92/100)
- **Summary**: Level 2 mutation capability to select a segment item.

### Rank 4: `ui.list_split_panes` (Score: 87/100)
- **Summary**: Read-only discovery of split view panes (`AXSplitGroup`).

---

## Security Review of Top Candidate (`ui.list_sheet_dialogs`)

1. **Targeting & Hierarchy**:
   - Application resolved strictly via `resolveExactRunningApplication(named:)`.
   - Window resolved by `windowTitle` or `windowIdentifier` (fails closed on absence or ambiguity).
   - Inspects `kAXSheetsAttribute` and direct children of the resolved `AXWindow` for roles in `QAXSheetRolePolicy.allowedRoles = ["AXSheet", "AXDialog"]`.
2. **Traversal & Bounds**:
   - Direct sheets of the resolved window only.
   - For each sheet, reads immediate direct child controls (e.g. `AXButton` for "Save", "Don't Save", "Cancel").
   - `maxDirectSheetsCount = 16`.
3. **Privacy Boundary**:
   - Sheet metadata remains ephemeral in `QActionResult.outputData`.
   - `result.summary` and `verifiedEvidence` carry aggregate counts only (`"Enumerated N sheet(s) for window 'Main' in application 'X'"`).
   - `QDurablePlanStepSnapshot` excludes `outputData`.
4. **Authorization Isolation**:
   - Level 0 Read-Only. Confers **zero authorization** to press sheet buttons.
5. **Forbidden APIs**:
   - ZERO `CGEvent`, `NSEvent`, mouse/keyboard simulation, `AppleScript`, shell execution, subprocess, clipboard, network calls, OCR, screen capture, or `kAXPressAction` mutation.

---

## Test Strategy for Proposed Next Capability

- **Unit Tests**:
  - Registration under `"ui"` tool family as `.level0ReadOnly`.
  - Application resolution (exact, missing, ambiguous).
  - Window resolution (exact, missing, ambiguous).
  - Sheet role policy enforcement (`AXSheet`, `AXDialog` allowed; non-sheets rejected).
  - Direct child enforcement (nested recursive trees rejected).
  - Bounds enforcement (16 accepted, 17 fails closed).
  - Privacy boundaries (ephemeral outputData, aggregate summary, durable snapshot exclusion).
  - Authorization isolation (no approval grant, no mutation authorization).
- **Real AppKit Fixture**:
  - Live `NSAlert().beginSheetModal(for: window)` attached to an `NSWindow`, guarded by `guard AXIsProcessTrusted() else { return }`.

---

## Conclusion & Implementation Boundary

Phase 2AN is discovery-only. No runtime/source/test implementation was performed.
The recommended capability for Phase 2AO is **`ui.list_sheet_dialogs`**.
