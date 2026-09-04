# Phase 2BA — Capability Roadmap & Selection

## 1. Baseline & Current State
- **Authoritative Baseline Commit**: `0ad7f0f` (`feat: add semantic level indicator enumeration`)
- **Branch**: `q-secure-foundation`
- **Working Tree**: Clean
- **Current Authoritative Capability Count**: **48 capabilities**

---

## 2. Authoritative Capability Inventory (48 Registered Capabilities)

### Level 0: Read-Only Discovery & Observation (25 capabilities)
- `system.running_apps`
- `system.clipboard.read`
- `screen.ocr`
- `fs.read`
- `test.noop`
- `accessibility.read`
- `ui.read_element_value`
- `ui.list_windows`
- `ui.list_menu_items`
- `ui.list_popup_items`
- `ui.list_table_rows`
- `ui.list_outline_items`
- `ui.list_tab_items`
- `ui.list_radio_group_items`
- `ui.list_toolbar_items`
- `ui.list_segmented_control_items`
- `ui.list_sheet_dialogs`
- `ui.list_sheet_actions`
- `ui.list_split_panes`
- `ui.list_browser_columns`
- `ui.list_popovers`
- `ui.list_color_wells`
- `ui.list_progress_indicators`
- `ui.list_level_indicators`

### Level 1: Safe Local Action (3 capabilities)
- `ui.open_app`
- `fs.write_sandbox`
- `ui.activate_application`

### Level 2: User Approval Required, Reversible Local Action (18 capabilities)
- `system.clipboard.write`
- `ui.click_element`
- `ui.set_text_value`
- `ui.set_element_state`
- `ui.select_menu_item`
- `ui.set_slider_value`
- `ui.focus_element`
- `ui.select_popup_item`
- `ui.toggle_disclosure`
- `ui.select_tab`
- `ui.select_table_row`
- `ui.select_outline_row`
- `ui.set_window_minimized`
- `ui.set_application_hidden`
- `ui.set_scroll_position`
- `ui.set_window_main`
- `ui.select_segmented_control_item`
- `ui.set_window_full_screen`
- `ui.set_splitter_position`

### Level 3: High-Risk Action (2 capabilities)
- `app.quit`
- `ui.close_window`

---

## 3. macOS SDK Discovery & Candidate Evaluation

From direct inspection of the installed macOS SDK headers (`AXRoleConstants.h`, `AXAttributeConstants.h`, `AXActionConstants.h`) and AppKit runtime probes:

| Candidate Identifier | Level | AX Role(s) | AX Attributes / Actions | Contract Authority | Target Identity | Independent Verification | Usefulness | Security | Testability | Recovery | Privacy | Arch Fit | Total Score |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **`ui.list_incrementors`** | **Level 0** | `AXIncrementor` | `kAXValueAttribute`, `kAXMinValueAttribute`, `kAXMaxValueAttribute`, `kAXTitleAttribute`, `kAXDescriptionAttribute`, `kAXIdentifierAttribute`, `kAXEnabledAttribute` | **20/20** | **15/15** | **15/15** | **15/15** | **10/10** | **10/10** | **5/5** | **5/5** | **5/5** | **100/100** |
| `ui.list_combo_box_items` | Level 0 | `AXComboBox` | `kAXChildrenAttribute`, `kAXVisibleChildrenAttribute` | 14/20 | 14/15 | 12/15 | 13/15 | 10/10 | 6/10 | 5/5 | 5/5 | 4/5 | **83/100** |
| `ui.scroll_page` | Level 2 | `AXScrollArea`, `AXScrollBar` | `AXScrollUpByPage`, `AXScrollDownByPage` | 15/20 | 12/15 | 11/15 | 12/15 | 8/10 | 7/10 | 4/5 | 5/5 | 5/5 | **79/100** |
| `ui.select_combo_box_item` | Level 2 | `AXComboBox` | `AXShowMenu`, `AXPress`, `kAXValueAttribute` | 14/20 | 12/15 | 11/15 | 13/15 | 8/10 | 6/10 | 4/5 | 5/5 | 4/5 | **77/100** |
| `ui.list_rulers` | Level 0 | `AXRuler`, `AXRulerMarker` | `kAXChildrenAttribute`, `kAXValueAttribute` | 16/20 | 13/15 | 12/15 | 6/15 | 10/10 | 7/10 | 5/5 | 5/5 | 4/5 | **78/100** |

---

## 4. Winning Selection & Evidence

**Selected Capability**: `ui.list_incrementors`
- **Domain**: `ui`
- **Security Level**: `Level 0 (Read-Only)`
- **Why it wins**:
  1. **Strict Semantic AX Authority**: Supported directly by `AXIncrementor` (`kAXIncrementorRole` in `AXRoleConstants.h`) and AppKit's `NSStepper` with native attributes (`kAXValueAttribute`, `kAXMinValueAttribute`, `kAXMaxValueAttribute`, `kAXEnabledAttribute`).
  2. **Deterministic Identity**: Uses `QBridgeAccessibility.resolveExactRunningApplication(named:)` requiring exact match; supports optional window scoping and element identifier/title filtering.
  3. **High Agent Usefulness**: Steppers and incrementors represent numeric quantity pickers, zoom controls, pagination steppers, and discrete value incrementors across macOS applications.
  4. **Closed-Loop Verification**: Verified via `QVerificationStrategy.incrementorEnumerationSucceeded(applicationName:incrementorCount:)`.
  5. **Clean AppKit Testability**: Directly testable against real AppKit `NSStepper` controls.
