# Phase 2AO — Capability Roadmap Discovery

## Baseline
- **Branch**: `q-secure-foundation`
- **HEAD Commit**: `6a6f29e`
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
| 38 | `ui.list_sheet_dialogs` | ui | Read-Only | Level 0 | Exact running app -> AXWindow -> AXSheet | Aggregate count verification | None | Ephemeral output | Real E2E |

Total Registered Capabilities: **38** (10 Level 0 Container Discovery Primitives).

---

## Discovery Methodology & Problem Statement

Phase 2AN introduced `ui.list_sheet_dialogs` to discover blocking modal `AXSheet` containers attached to a window. To maintain strict isolation, Phase 2AN explicitly excluded button enumeration.
Consequently:
- An agent can discover that an active modal sheet exists (e.g. `Save Changes?`).
- However, the agent cannot discover the available semantic action buttons (e.g. `Save`, `Don't Save`, `Cancel`, `OK`, `Retry`) on that sheet without blind guessing.
- `ui.list_sheet_actions` directly completes this modal workflow by providing safe, bounded, read-only discovery of direct action controls belonging to an `AXSheet`.

---

## Candidate Capabilities

### Candidate 1: `ui.list_sheet_actions` (Semantic Sheet Action Control Enumeration) — RECOMMENDED
- **Target Hierarchy**:
  ```
  AXApplication
      ↓
  AXWindow (resolved by windowTitle or windowIdentifier)
      ↓
  AXSheet (resolved by identifier or title, or single active sheet)
      ↓
  direct action controls (AXButton, AXPopUpButton, AXCheckBox, AXRadioButton)
  ```
- **Allowed Roles**:
  - Target container: `AXSheet` only (`QAXSheetRolePolicy.allowedRoles = ["AXSheet"]`).
  - Child actions: `AXButton`, `AXPopUpButton`, `AXCheckBox`, `AXRadioButton`.
- **Direct-Child Only**: Inspects immediate children of the resolved `AXSheet` via `kAXChildrenAttribute`. No recursive crawling into sub-groups or text fields.
- **Bounds**: `maxDirectSheetActionsCount = 16` (fails closed if exceeded).
- **Risk Level**: Level 0 Read-Only (no approval, zero mutation, zero physical input).
- **Privacy Boundary**: Ephemeral `outputData`, aggregate counts in `summary` and `verifiedEvidence`.
- **Authorization Isolation**: Purely informational; confers **zero authorization** to click sheet buttons.

### Candidate 2: `ui.select_segmented_control_item` (Semantic Segment Selection Mutation)
- **Domain**: Segment Selection Mutation.
- **Risk Level**: Level 2 User Approval.

### Candidate 3: `ui.list_combo_box_items` (Combo Box Item Enumeration)
- **Domain**: Combo Box Dropdown Lists (`NSComboBox` / `AXComboBox`).
- **Risk Level**: Level 0 Read-Only.

### Candidate 4: `ui.read_window_state` (Window Semantic State Discovery)
- **Domain**: Window attributes inspection (`kAXFullScreenAttribute`, `kAXModalAttribute`, `kAXMainAttribute`).
- **Risk Level**: Level 0 Read-Only.

### Candidate 5: `ui.list_split_panes` (Split View Pane Enumeration)
- **Domain**: Split View Panes (`NSSplitView` / `AXSplitGroup`).
- **Risk Level**: Level 0 Read-Only.

---

## Candidate Scoring Table (out of 100)

| Criterion | `ui.list_sheet_actions` | `ui.select_segmented_control_item` | `ui.list_combo_box_items` | `ui.read_window_state` | `ui.list_split_panes` |
| :--- | :---: | :---: | :---: | :---: | :---: |
| Semantic Value (/10) | 10 | 9 | 8 | 8 | 7 |
| Distinctness (/10) | 10 | 10 | 9 | 9 | 9 |
| Target Integrity (/10) | 10 | 9 | 9 | 10 | 9 |
| Bounding Feasibility (/10) | 10 | 10 | 10 | 10 | 10 |
| Privacy Safety (/10) | 10 | 10 | 10 | 10 | 10 |
| Security Safety (/10) | 10 | 8 | 10 | 10 | 10 |
| Testability (/10) | 10 | 9 | 9 | 9 | 8 |
| Implementation Complexity (/10) | 10 | 9 | 9 | 10 | 9 |
| Low Hardware Risk (/10) | 9 | 9 | 8 | 9 | 8 |
| Architectural Fit (/10) | 10 | 9 | 9 | 9 | 8 |
| **TOTAL (/100)** | **99** | **93** | **91** | **92** | **86** |

---

## Ranked Candidates

### Rank 1: `ui.list_sheet_actions` (Score: 99/100) — RECOMMENDED
- **Why it Wins**:
  - Direct logical complement to Phase 2AN's `ui.list_sheet_dialogs`.
  - Enables an agent to inspect the action controls on a modal dialog (e.g. "Save", "Don't Save", "Cancel") safely without blind guessing.
  - Level 0 Read-Only, bounded (`maxDirectSheetActionsCount = 16`), direct-child only, zero mutation.

### Rank 2: `ui.select_segmented_control_item` (Score: 93/100)
- **Summary**: Level 2 mutation counterpart for segmented controls.

### Rank 3: `ui.read_window_state` (Score: 92/100)
- **Summary**: Read-only discovery of window fullscreen/modal/main state attributes.

### Rank 4: `ui.list_combo_box_items` (Score: 91/100)
- **Summary**: Read-only discovery of combo box dropdown options (`AXComboBox`).

### Rank 5: `ui.list_split_panes` (Score: 86/100)
- **Summary**: Read-only discovery of split view panes (`AXSplitGroup`).

---

## Security & Privacy Analysis for `ui.list_sheet_actions`

1. **Target Resolution**:
   - Application: exact resolution via `resolveExactRunningApplication(named:)`.
   - Window: exact match by `windowTitle` or `windowIdentifier` (fails closed on 0 or >1 matches).
   - Sheet: exact match by `sheetIdentifier` or `sheetTitle`, or single active sheet under window.
2. **Traversal & Bounds**:
   - Direct children of target `AXSheet` only (`kAXChildrenAttribute`).
   - Allowed child action roles: `AXButton`, `AXPopUpButton`, `AXCheckBox`, `AXRadioButton`.
   - Hard bound: `maxDirectSheetActionsCount = 16` (fails closed if exceeded).
3. **Authorization Isolation**:
   - Level 0 Read-Only. Confers **zero authorization** to perform `ui.click_element` or mutate sheet buttons.
4. **Privacy**:
   - Full button labels live ephemerally in `outputData` for the active turn.
   - `summary` and `verifiedEvidence` carry aggregate counts only (`"Enumerated N action(s) for sheet 'Save' in application 'X'"`).
   - `QDurablePlanStepSnapshot` excludes `outputData`.
5. **Forbidden APIs**:
   - ZERO `CGEvent`, `NSEvent`, mouse/keyboard simulation, `AppleScript`, shell execution, subprocess, clipboard, network calls, OCR, screen capture, or `kAXPressAction` mutation.

---

## Testability & AppKit Fixture

- **Unit Tests**: Mock execution provider covering registration, Level 0 classification, exact application resolution, missing/ambiguous application, missing/ambiguous window, missing/ambiguous sheet, role policy enforcement, direct child filtering, bounded collection, privacy boundaries, and authorization isolation.
- **Real AppKit Fixture**: Live `NSAlert` modal sheet presenting "Save", "Don't Save", "Cancel" buttons on an `NSWindow`, guarded by `guard AXIsProcessTrusted() else { return }`.

---

## Capability Overlap Proof

`ui.list_sheet_actions` is non-overlapping:
- `ui.list_windows`: enumerates top-level `AXWindow` elements.
- `ui.list_sheet_dialogs`: enumerates `AXSheet` containers attached to a window, without enumerating buttons.
- `ui.list_sheet_actions`: enumerates direct interactive action buttons belonging specifically to an `AXSheet`.
- `ui.list_toolbar_items`: enumerates controls in `AXToolbar`.
- `ui.list_segmented_control_items`: enumerates segments in `AXSegmentedControl`.

---

## Conclusion & Implementation Boundary

Phase 2AO is discovery-only. No runtime/source/test implementation was performed.
The recommended capability for Phase 2AP is **`ui.list_sheet_actions`**.
