# Phase 2AW — Capability Roadmap

## Baseline
- **Commit**: `a4958ea`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AV (Semantic Multi-Column Browser Enumeration — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **44 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct schema inspection:

### 1. Read-Only Discovery Primitives (20 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`

### 4. Level 3 — High Risk (2 capabilities)
`app.quit`, `ui.close_window`

*(Total: 20 + 3 + 19 + 2 = 44)*

---

## Current Semantic Coverage

```
Application Layer
├── Lifecycle: ui.open_app, app.quit, ui.activate_application, ui.set_application_hidden
└── Global Discovery: system.running_apps

Window & Modal Overlay Layer
├── Management: ui.set_window_minimized, ui.set_window_main, ui.close_window, ui.set_window_full_screen
├── Window Discovery: ui.list_windows
├── Sheet Modal Containers: ui.list_sheet_dialogs, ui.list_sheet_actions
└── Popover Overlay Containers: [GAP: ui.list_popovers]

Menu Layer
├── Discovery: ui.list_menu_items, ui.list_popup_items
└── Selection: ui.select_menu_item, ui.select_popup_item

Form / Control Layer
├── Text: ui.set_text_value, ui.read_element_value
├── Binary / State: ui.set_element_state, ui.toggle_disclosure
├── Numeric / Continuous: ui.set_slider_value, ui.set_scroll_position
├── Focus: ui.focus_element
├── Action: ui.click_element
└── Combo Box: [GAP: ui.list_combo_box_items / ui.select_combo_box_item]

Structured Selection & Container Layer
├── Tabs: ui.list_tab_items → ui.select_tab
├── Radio Groups: ui.list_radio_group_items → (ui.set_element_state)
├── Table Rows: ui.list_table_rows → ui.select_table_row
├── Outline Rows: ui.list_outline_items → ui.select_outline_row
├── Toolbars: ui.list_toolbar_items → (ui.click_element, ui.select_popup_item)
├── Segmented Controls: ui.list_segmented_control_items → ui.select_segmented_control_item
├── Split Views: ui.list_split_panes → ui.set_splitter_position
└── Multi-Column Browsers: ui.list_browser_columns
```

---

## Candidate Analysis & Scoring

Candidates are evaluated across 9 weighted dimensions totaling 100 points:
- **Semantic AX authority** (20 pts)
- **Deterministic target identity** (15 pts)
- **Independent verification** (15 pts)
- **Agent usefulness** (15 pts)
- **Security safety** (10 pts)
- **Testability** (10 pts)
- **Recovery safety** (5 pts)
- **Privacy** (5 pts)
- **Architecture fit** (5 pts)

---

### Candidate 1: `ui.list_popovers` (Semantic Popover Container Discovery)
- **Identifier**: `ui.list_popovers`
- **Security Level**: Level 0 (Read-Only)
- **AX Role/Attribute/Action**: Role `AXPopover` (`NSAccessibilityPopoverRole`, `kAXPopoverRole`) attached to windows or application root.
- **Target Identity**: Exact `applicationName` (via `QBridgeAccessibility.resolveExactRunningApplication`) + optional exact `windowTitle`/`windowIdentifier` scoping + optional exact `popoverIdentifier`/`popoverTitle`. Fails closed on zero or ambiguous matches.
- **Read vs Mutation**: Read-Only (Level 0).
- **Verification**: Closed-loop aggregate count verification `QVerificationStrategy.popoverEnumerationSucceeded(applicationName:popoverCount:)`.
- **Recovery**: None required (Level 0 read-only, point-in-time snapshot).
- **Privacy**: Structural popover metadata only (index, role, subrole, title, identifier, isModal). No raw AX objects persisted. `QDurablePlanStepSnapshot` omits raw `outputData`.
- **Security Concerns**: Level 0 read-only discovery. Auto-allowed by `QPermissionGate`.
- **Implementation Complexity**: Low-Medium — matches established pattern from `ui.list_sheet_dialogs`, `ui.list_split_panes`, `ui.list_browser_columns`.
- **Score**: **100/100**
  - Semantic AX authority: 20/20
  - Deterministic target identity: 15/15
  - Independent verification: 15/15
  - Agent usefulness: 15/15
  - Security safety: 10/10
  - Testability: 10/10
  - Recovery safety: 5/5
  - Privacy: 5/5
  - Implementation fit: 5/5

---

### Candidate 2: `ui.read_element_help` (Semantic Tooltip / Help Text Perception)
- **Identifier**: `ui.read_element_help`
- **Security Level**: Level 0 (Read-Only, toolFamily "perception")
- **AX Role/Attribute/Action**: Any interactive element via `kAXHelpAttribute` ("AXHelp").
- **Target Identity**: Application + Window + Element identifier/title.
- **Read vs Mutation**: Read-Only.
- **Verification**: Content string read verification.
- **Recovery**: None.
- **Privacy**: Low risk.
- **Security Concerns**: Minimal.
- **Implementation Complexity**: Low.
- **Score**: **86/100**
  - Semantic AX authority: 19/20
  - Deterministic target identity: 14/15
  - Independent verification: 14/15
  - Agent usefulness: 11/15
  - Security safety: 10/10
  - Testability: 9/10
  - Recovery safety: 5/5
  - Privacy: 5/5
  - Implementation fit: 4/5

---

### Candidate 3: `ui.list_drawers` (Semantic Window Drawer Discovery)
- **Identifier**: `ui.list_drawers`
- **Security Level**: Level 0 (Read-Only)
- **AX Role/Attribute/Action**: `AXDrawer` (`kAXDrawerRole`, `NSAccessibilityDrawerRole`) attached to `AXWindow`.
- **Target Identity**: Application + Window + Drawer.
- **Read vs Mutation**: Read-Only.
- **Verification**: Aggregate count verification.
- **Recovery**: None.
- **Privacy**: Low risk.
- **Security Concerns**: Minimal.
- **Implementation Complexity**: Low, but `NSDrawer` is legacy/deprecated in modern AppKit.
- **Score**: **82/100**
  - Semantic AX authority: 18/20
  - Deterministic target identity: 15/15
  - Independent verification: 15/15
  - Agent usefulness: 6/15
  - Security safety: 10/10
  - Testability: 9/10
  - Recovery safety: 5/5
  - Privacy: 5/5
  - Implementation fit: 4/5

---

### Candidate 4: `ui.list_combo_box_items` (Semantic Combo Box Item Discovery)
- **Identifier**: `ui.list_combo_box_items`
- **Security Level**: Level 0 (Read-Only)
- **AX Role/Attribute/Action**: `AXComboBox` (`NSAccessibilityComboBoxRole`) → dropdown list items.
- **Target Identity**: Application + Window + Combo Box.
- **Read vs Mutation**: Read-Only.
- **Verification**: Aggregate count.
- **Recovery**: None.
- **Privacy**: Moderate (autofill, history).
- **Security Concerns**: Minimal.
- **Implementation Complexity**: Medium-High (AppKit `NSComboBox` does not consistently expose closed children).
- **Score**: **78/100**
  - Semantic AX authority: 14/20
  - Deterministic target identity: 13/15
  - Independent verification: 13/15
  - Agent usefulness: 14/15
  - Security safety: 10/10
  - Testability: 6/10
  - Recovery safety: 5/5
  - Privacy: 2/5
  - Implementation fit: 3/5

---

### Candidate 5: `ui.select_combo_box_item` (Semantic Combo Box Item Selection)
- **Identifier**: `ui.select_combo_box_item`
- **Security Level**: Level 2 (User Approval Required)
- **AX Role/Attribute/Action**: `AXComboBox` item selection.
- **Target Identity**: Application + Window + Combo Box + Item.
- **Read vs Mutation**: Mutation.
- **Verification**: Value comparison.
- **Recovery**: Observe-first value comparison.
- **Privacy**: Moderate.
- **Security Concerns**: Level 2 mutation.
- **Implementation Complexity**: High.
- **Score**: **72/100**
  - Semantic AX authority: 13/20
  - Deterministic target identity: 11/15
  - Independent verification: 11/15
  - Agent usefulness: 14/15
  - Security safety: 9/10
  - Testability: 6/10
  - Recovery safety: 4/5
  - Privacy: 2/5
  - Implementation fit: 2/5

---

### Candidate 6: `ui.scroll_page` (Semantic Page-Relative Scroll Action)
- **Identifier**: `ui.scroll_page`
- **Security Level**: Level 2 (User Approval Required)
- **AX Role/Attribute/Action**: `AXScrollBar` (`kAXIncrementPageAction` / `kAXDecrementPageAction`).
- **Target Identity**: Application + Window + ScrollArea + ScrollBar.
- **Read vs Mutation**: Action / Mutation.
- **Verification**: Weak / Non-Deterministic.
- **Recovery**: Difficult due to relative drift.
- **Privacy**: Low risk.
- **Security Concerns**: Level 2 action.
- **Implementation Complexity**: Fails independent deterministic verification requirement.
- **Score**: **68/100**
  - Semantic AX authority: 16/20
  - Deterministic target identity: 14/15
  - Independent verification: 5/15
  - Agent usefulness: 11/15
  - Security safety: 9/10
  - Testability: 6/10
  - Recovery safety: 2/5
  - Privacy: 5/5
  - Implementation fit: 3/5

---

## Scoring Summary Table

| Dimension | Weight | `ui.list_popovers` | `ui.read_element_help` | `ui.list_drawers` | `ui.list_combo_box_items` | `ui.select_combo_box_item` | `ui.scroll_page` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Semantic AX authority** | 20 | **20** | 19 | 18 | 14 | 13 | 16 |
| **Deterministic target identity** | 15 | **15** | 14 | 15 | 13 | 11 | 14 |
| **Independent verification** | 15 | **15** | 14 | 15 | 13 | 11 | 5 |
| **Agent usefulness** | 15 | **15** | 11 | 6 | 14 | 14 | 11 |
| **Security safety** | 10 | **10** | 10 | 10 | 10 | 9 | 9 |
| **Testability** | 10 | **10** | 9 | 9 | 6 | 6 | 6 |
| **Recovery safety** | 5 | **5** | 5 | 5 | 5 | 4 | 2 |
| **Privacy** | 5 | **5** | 5 | 5 | 2 | 2 | 5 |
| **Implementation fit** | 5 | **5** | 4 | 4 | 3 | 2 | 3 |
| **Total Score** | **100** | **100** | **86** | **82** | **78** | **72** | **68** |

---

## Recommended Capability
- **Identifier**: `ui.list_popovers`
- **Score**: **100 / 100**
- **Why it wins**:
  1. **Essential Overlay Container in Modern macOS**: `NSPopover` is pervasive across Apple and third-party macOS applications (Safari downloads, Mail filter menus, Xcode contextual HUDs, Notes popovers). It exposes `AXPopover` (`NSAccessibilityPopoverRole`, `kAXPopoverRole`).
  2. **Completes Modal and Overlay Discovery**: Complements sheet dialogs (`ui.list_sheet_dialogs`) with non-sheet floating transient overlays.
  3. **Strict Deterministic Identity & Verification**: Exact application, window, and popover resolution with snapshot drift verification and closed-loop aggregate count verification.
  4. **Strict Security & Privacy**: Level 0 Read-Only. Returns structural popover metadata without expanding internal subtrees or persisting raw AX references.
  5. **Direct Architectural Alignment**: Directly leverages existing container discovery patterns in `QBridgeAdapters.swift`.

---

## Deferred / Rejected Candidates
- `ui.read_element_help`: Deferred. Focused perception utility to be considered in future phases.
- `ui.list_drawers`: Deferred. `NSDrawer` is legacy/deprecated in modern AppKit.
- `ui.list_combo_box_items` / `ui.select_combo_box_item`: Deferred. AppKit `NSComboBox` does not expose closed children reliably.
- `ui.scroll_page`: Rejected. Fails deterministic independent verification.
