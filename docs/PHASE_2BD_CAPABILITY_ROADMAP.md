# Phase 2BD — Capability Roadmap

## Baseline
- **Commit**: `8b43477`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BC (Semantic Ruler Enumeration — `ui.list_rulers`)

---

## Authoritative Capability Inventory
The repository contains exactly **51 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection:

### 1. Read-Only Discovery Primitives (27 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes`, `ui.list_rulers`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`

### 4. Level 3 — High Risk Local Action (2 capabilities)
`app.quit`, `ui.close_window`

**Total Registered Capabilities**: **51**

---

## SDK & AppKit Discovery
Inspected macOS SDK (`MacOSX.sdk`), `ApplicationServices` / `HIServices` (`AXRoleConstants.h`, `AXAttributeConstants.h`, `AXActionConstants.h`), and AppKit (`NSAccessibilityConstants.h`, `NSAccessibilityProtocols.h`, `NSComboBox`).

Key semantic roles and candidate gaps identified:
- `AXComboBox` items (`kAXChildrenAttribute`, `AXList` child, `kAXValuesAttribute` / items)
- `AXHelpTag` (`kAXHelpTagRole`, `NSAccessibilityHelpTagRole`)
- `AXRelevanceIndicator` (`kAXRelevanceIndicatorRole`, `NSAccessibilityRelevanceIndicatorRole`)
- `AXBusyIndicator` (`kAXBusyIndicatorRole`)
- `AXHandle` (`kAXHandleRole`, `NSAccessibilityHandleRole`)

---

## Candidate Scoring Matrix (9-Dimension Model)

| Dimension | Weight | ui.list_combo_box_items | ui.list_help_tags | ui.list_relevance_indicators | ui.list_busy_indicators | ui.select_combo_box_item | ui.list_handles |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Targeting Determinism | 15% | 10/10 (15.0) | 8/10 (12.0) | 10/10 (15.0) | 10/10 (15.0) | 9/10 (13.5) | 9/10 (13.5) |
| 2. Verification Determinism | 15% | 10/10 (15.0) | 7/10 (10.5) | 10/10 (15.0) | 10/10 (15.0) | 9/10 (13.5) | 9/10 (13.5) |
| 3. Usefulness to Agent | 15% | 10/10 (15.0) | 8/10 (12.0) | 7/10 (10.5) | 8/10 (12.0) | 9/10 (13.5) | 7/10 (10.5) |
| 4. Security Impact | 15% | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 8/10 (12.0) | 10/10 (15.0) |
| 5. Privacy Impact | 10% | 10/10 (10.0) | 9/10 (9.0) | 10/10 (10.0) | 10/10 (10.0) | 9/10 (9.0) | 10/10 (10.0) |
| 6. Resource Bounds | 10% | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 9/10 (9.0) | 10/10 (10.0) |
| 7. Implementation Complexity | 10% | 10/10 (10.0) | 9/10 (9.0) | 9/10 (9.0) | 9/10 (9.0) | 7/10 (7.0) | 8/10 (8.0) |
| 8. Role/API Authoritativeness | 5% | 10/10 (5.0) | 8/10 (4.0) | 9/10 (4.5) | 9/10 (4.5) | 9/10 (4.5) | 8/10 (4.0) |
| 9. Error Containment | 5% | 10/10 (5.0) | 9/10 (4.5) | 10/10 (5.0) | 10/10 (5.0) | 8/10 (4.0) | 9/10 (4.5) |
| **Total Score** | **100%** | **100.0 / 100** | **86.0 / 100** | **89.0 / 100** | **90.5 / 100** | **78.5 / 100** | **84.5 / 100** |

---

## Candidate Evaluation & Selection
- **Selected**: `ui.list_combo_box_items` (Score: **100/100**)
  - Direct natural counterpart to `ui.list_combo_boxes` (Phase 2BB).
  - Level 0 Read-Only observation allowing an agent to deterministically inspect all dropdown options of a specific combo box.
  - Strict role validation (`AXComboBox`), deterministic target matching, bounded traversal (`maxDirectComboBoxItemsCount = 128`), and fail-closed verification.

---

## Architectural & Security Blueprint for `ui.list_combo_box_items`
- **Capability Identifier**: `ui.list_combo_box_items`
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Target Resolution**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`, optional window resolution, deterministic target matching on `AXComboBox` by identifier/title.
- **Verification Model**: Closed-loop `QVerificationStrategy.comboBoxItemEnumerationSucceeded(applicationName:comboBoxIdentifier:itemCount:)`.
- **Resource Limits**: Max items = 128, max traversal depth = 6.
- **Privacy Model**: Ephemeral structural metadata; no raw AXUIElement pointers or sensitive data written to disk or audit logs.
