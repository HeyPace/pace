# Phase 2AU — Capability Roadmap

## Baseline
- **Commit**: `3d3a711`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AT (Semantic Split View Pane Enumeration — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **42 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct grep and schema inspection:

### 1. Read-Only Discovery Primitives (18 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`

### 4. Level 3 — High Risk (2 capabilities)
`app.quit`, `ui.close_window`

*(Total: 18 + 3 + 19 + 2 = 42)*

---

## Current Semantic Coverage

```
Application Layer
├── Lifecycle: ui.open_app, app.quit, ui.activate_application, ui.set_application_hidden
└── Global Discovery: system.running_apps

Window Layer
├── Management: ui.set_window_minimized, ui.set_window_main, ui.close_window, ui.set_window_full_screen
├── Discovery: ui.list_windows
└── Modal / Sheet Containers: ui.list_sheet_dialogs, ui.list_sheet_actions

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

Structured Selection Layer
├── Tabs: ui.list_tab_items → ui.select_tab
├── Radio Groups: ui.list_radio_group_items → (ui.set_element_state)
├── Table Rows: ui.list_table_rows → ui.select_table_row
├── Outline Rows: ui.list_outline_items → ui.select_outline_row
├── Toolbars: ui.list_toolbar_items → (ui.click_element, ui.select_popup_item)
├── Segmented Controls: ui.list_segmented_control_items → ui.select_segmented_control_item
└── Split Views: ui.list_split_panes → [GAP: ui.set_splitter_position]
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
- **Implementation fit with existing architecture** (5 pts)

---

### Candidate 1: `ui.set_splitter_position` (Semantic Splitter Position Mutation)
- **Identifier**: `ui.set_splitter_position`
- **Security Level**: Level 2 (User Approval Required, Reversible Local Action)
- **AX Role/Attribute/Action**: Role `AXSplitter` (`NSAccessibilitySplitterRole`) within container `AXSplitGroup` (`NSAccessibilitySplitGroupRole`). Attribute `kAXValueAttribute` (`AXValue`) writable with `NSNumber`/`Double`. Bound by `kAXMinValueAttribute` and `kAXMaxValueAttribute`.
- **Target Identity**: Exact `applicationName` (via `QBridgeAccessibility.resolveExactRunningApplication`) + optional exact `windowTitle`/`windowIdentifier` scoping + optional exact `splitGroupIdentifier`/`splitGroupTitle` + exact 0-indexed `splitterIndex` (default 0). Fails closed on zero or ambiguous matches.
- **Read vs Mutation**: Mutation (Level 2).
- **Verification**: Post-mutation independent observation: fresh target resolution → read authoritative `kAXValueAttribute` → compare against `desiredPosition` within numeric tolerance (`abs(observed - desired) <= tolerance`).
- **Recovery**: Observe-first. Check fresh AX value. If already matches desired state, mark complete without replay. If not matching, require fresh execution identity & approval before bounded re-execution. If state uncertain, fail closed.
- **Privacy**: Pure numeric coordinate offset (e.g. 250.0). No UI text, no user content, no element internals persisted.
- **Security Concerns**: Standard Level 2 UI layout mutation. Blast radius is confined to resizing panes within a single application split group. Gated on single-use approval bound to `QExecutionIdentity`.
- **Implementation Complexity**: Low-Medium — directly leverages existing numeric tolerance (`sliderValuesAreEqual` pattern), exact window/container scoping, and `QAXSplitterRolePolicy`.
- **Score**: **98/100**
  - Semantic AX authority: 20/20
  - Deterministic target identity: 15/15
  - Independent verification: 15/15
  - Agent usefulness: 13/15
  - Security safety: 10/10
  - Testability: 10/10
  - Recovery safety: 5/5
  - Privacy: 5/5
  - Implementation fit: 5/5

---

### Candidate 2: `ui.list_combo_box_items` (Semantic Combo Box Item Discovery)
- **Identifier**: `ui.list_combo_box_items`
- **Security Level**: Level 0 (Read-Only)
- **AX Role/Attribute/Action**: `AXComboBox` (`NSAccessibilityComboBoxRole`) → dropdown list items.
- **Target Identity**: Exact application + window + combo box identifier/title.
- **Read vs Mutation**: Read-Only.
- **Verification**: Aggregate count verification.
- **Recovery**: None (read-only).
- **Privacy**: **Moderate Concern** — combo boxes frequently contain autofill history, search queries, recent file paths.
- **Security Concerns**: Minimal (Level 0).
- **Implementation Complexity**: Medium-High — Empirical testing shows AppKit `NSComboBox` does not expose items via `kAXChildrenAttribute` when closed (`accessibilityChildren()` contains only button cell proxy); requires transient popup expansion or non-standard cell inspection.
- **Score**: **78/100**
  - Semantic AX authority: 14/20 (Inconsistent AX child exposure across closed vs open state)
  - Deterministic target identity: 13/15
  - Independent verification: 13/15
  - Agent usefulness: 14/15
  - Security safety: 10/10
  - Testability: 6/10 (AppKit popup state coupling makes closed testing brittle)
  - Recovery safety: 5/5
  - Privacy: 2/5 (Autofill / sensitive history exposure)
  - Implementation fit: 3/5 (Needs special popup handling)

---

### Candidate 3: `ui.select_combo_box_item` (Semantic Combo Box Item Selection)
- **Identifier**: `ui.select_combo_box_item`
- **Security Level**: Level 2 (User Approval Required)
- **AX Role/Attribute/Action**: `AXComboBox` item selection.
- **Target Identity**: Exact application + window + combo box + item title.
- **Read vs Mutation**: Mutation.
- **Verification**: Value comparison.
- **Recovery**: Observe-first value comparison.
- **Privacy**: Moderate (form inputs/history).
- **Security Concerns**: Level 2 mutation.
- **Implementation Complexity**: High (depends on resolving Candidate 2's popup expansion mechanics first).
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

### Candidate 4: `ui.scroll_page` (Semantic Page-Relative Scroll Action)
- **Identifier**: `ui.scroll_page`
- **Security Level**: Level 2 (User Approval Required)
- **AX Role/Attribute/Action**: `AXScrollBar` (`kAXIncrementPageAction` / `kAXDecrementPageAction`).
- **Target Identity**: Application + Window + ScrollArea + ScrollBar.
- **Read vs Mutation**: Action / Mutation.
- **Verification**: **Weak / Non-Deterministic** — relative page scroll size is dynamic and application-defined; cannot independently compute or verify an exact expected post-condition value.
- **Recovery**: Difficult due to relative drift and lack of absolute expected state.
- **Privacy**: Low risk.
- **Security Concerns**: Level 2 action.
- **Implementation Complexity**: Low-Medium, but fundamentally fails the independent deterministic verification principle.
- **Score**: **68/100**
  - Semantic AX authority: 16/20
  - Deterministic target identity: 14/15
  - Independent verification: 5/15 (Fails independent deterministic verification requirement)
  - Agent usefulness: 11/15 (Overlaps with `ui.set_scroll_position`)
  - Security safety: 9/10
  - Testability: 6/10 (Page size varies by viewport/content)
  - Recovery safety: 2/5 (Uncertain state after partial scroll)
  - Privacy: 5/5
  - Implementation fit: 3/5

---

### Candidate 5: `ui.list_browser_columns` (Semantic Browser Column Enumeration)
- **Identifier**: `ui.list_browser_columns`
- **Security Level**: Level 0 (Read-Only)
- **AX Role/Attribute/Action**: `AXBrowser` / `AXColumn` (`NSAccessibilityBrowserRole`).
- **Target Identity**: Application + Window + Browser element.
- **Read vs Mutation**: Read-Only.
- **Verification**: Aggregate count verification.
- **Recovery**: None.
- **Privacy**: Low-Medium (directory contents).
- **Security Concerns**: Minimal.
- **Implementation Complexity**: Medium (niche AppKit control, rarely used outside Finder column view).
- **Score**: **65/100**

---

## Scoring Summary Table

| Dimension | Weight | `ui.set_splitter_position` | `ui.list_combo_box_items` | `ui.select_combo_box_item` | `ui.scroll_page` | `ui.list_browser_columns` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Semantic AX authority** | 20 | **20** | 14 | 13 | 16 | 14 |
| **Deterministic target identity** | 15 | **15** | 13 | 11 | 14 | 12 |
| **Independent verification** | 15 | **15** | 13 | 11 | 5 | 12 |
| **Agent usefulness** | 15 | **13** | 14 | 14 | 11 | 8 |
| **Security safety** | 10 | **10** | 10 | 9 | 9 | 10 |
| **Testability** | 10 | **10** | 6 | 6 | 6 | 6 |
| **Recovery safety** | 5 | **5** | 5 | 4 | 2 | 5 |
| **Privacy** | 5 | **5** | 2 | 2 | 5 | 4 |
| **Implementation fit** | 5 | **5** | 3 | 2 | 3 | 3 |
| **Total Score** | **100** | **98** | **78** | **72** | **68** | **65** |

---

## Recommended Capability
- **Identifier**: `ui.set_splitter_position`
- **Score**: **98 / 100**
- **Why it wins**:
  1. **Direct natural pair to Phase 2AT**: Phase 2AT implemented `ui.list_split_panes`. Resizing split panes via `ui.set_splitter_position` completes the semantic split-view interaction model.
  2. **Authoritative AppKit AX Support**: `NSSplitView` directly exposes `AXSplitter` with writable `kAXValueAttribute` bounded by `kAXMinValueAttribute` and `kAXMaxValueAttribute`.
  3. **Strict Deterministic Verification**: Verified via fresh post-mutation observation of `kAXValueAttribute` with standard floating-point tolerance (`abs(observed - desired) <= tolerance`).
  4. **Robust Idempotency & Observe-First Recovery**: If current position already matches `desiredPosition` within tolerance, it is a verified no-op.
  5. **Clean Privacy & Security**: Operates purely on numeric coordinates (e.g. 250.0). No user content or element internals persisted. Level 2 single-use approval bound to `QExecutionIdentity`.

---

## Deferred / Rejected Candidates
- `ui.list_combo_box_items` / `ui.select_combo_box_item`: Deferred. AppKit `NSComboBox` does not expose items via `kAXChildrenAttribute` in its closed state, creating testability and reliability challenges. Also poses autofill privacy considerations.
- `ui.scroll_page`: Rejected for mutation ranking. Cannot satisfy independent deterministic verification because page-increment size is dynamic and application-defined. Absolute positioning is already fully supported via `ui.set_scroll_position`.
- `ui.list_browser_columns`: Deferred. Niche AppKit control with low practical agent utility compared to primary container and layout controls.
