# Phase 2BE — Capability Roadmap

## Baseline
- **Commit**: `401c66a`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BD (Semantic Combo Box Item Enumeration — `ui.list_combo_box_items`)

---

## Authoritative Capability Inventory
The repository contains exactly **52 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection:

### 1. Read-Only Discovery Primitives (28 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes`, `ui.list_rulers`, `ui.list_combo_box_items`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`

### 4. Level 3 — High Risk Local Action (2 capabilities)
`app.quit`, `ui.close_window`

**Total Registered Capabilities**: **52**

---

## SDK & AppKit Discovery
Inspected macOS SDK (`MacOSX.sdk`), `ApplicationServices` / `HIServices` (`AXRoleConstants.h`, `AXAttributeConstants.h`, `AXActionConstants.h`, `AXUIElement.h`, `AXValue.h`), and AppKit (`NSAccessibilityConstants.h`, `NSAccessibilityProtocols.h`, `NSComboBox`).

Key semantic roles and candidate gaps identified:
- `AXComboBox` selection (`ui.select_combo_box_item`, `kAXValueAttribute`, `kAXSelectedChildrenAttribute`)
- `AXBusyIndicator` (`kAXBusyIndicatorRole`)
- `AXRelevanceIndicator` (`kAXRelevanceIndicatorRole`, `NSAccessibilityRelevanceIndicatorRole`)
- `AXHelpTag` (`kAXHelpTagRole`, `NSAccessibilityHelpTagRole`)
- `AXHandle` (`kAXHandleRole`, `NSAccessibilityHandleRole`)

---

## Candidate Scoring Matrix (9-Dimension Model)

| Dimension | Weight | ui.select_combo_box_item | ui.list_busy_indicators | ui.list_relevance_indicators | ui.list_help_tags | ui.list_handles | ui.set_ruler_marker_position |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Targeting Determinism | 15% | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 8/10 (12.0) | 9/10 (13.5) | 9/10 (13.5) |
| 2. Verification Determinism | 15% | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 7/10 (10.5) | 9/10 (13.5) | 9/10 (13.5) |
| 3. Usefulness to Agent | 15% | 10/10 (15.0) | 8/10 (12.0) | 7/10 (10.5) | 8/10 (12.0) | 7/10 (10.5) | 7/10 (10.5) |
| 4. Security Impact | 15% | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 10/10 (15.0) | 9/10 (13.5) |
| 5. Privacy Impact | 10% | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 9/10 (9.0) | 10/10 (10.0) | 10/10 (10.0) |
| 6. Resource Bounds | 10% | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 10/10 (10.0) | 9/10 (9.0) |
| 7. Implementation Complexity | 10% | 10/10 (10.0) | 9/10 (9.0) | 9/10 (9.0) | 9/10 (9.0) | 8/10 (8.0) | 7/10 (7.0) |
| 8. Role/API Authoritativeness | 5% | 10/10 (5.0) | 9/10 (4.5) | 9/10 (4.5) | 8/10 (4.0) | 8/10 (4.0) | 9/10 (4.5) |
| 9. Error Containment | 5% | 10/10 (5.0) | 10/10 (5.0) | 10/10 (5.0) | 9/10 (4.5) | 9/10 (4.5) | 8/10 (4.0) |
| **Total Score** | **100%** | **100.0 / 100** | **90.5 / 100** | **89.0 / 100** | **86.0 / 100** | **84.5 / 100** | **85.0 / 100** |

---

## Candidate Evaluation & Selection
- **Selected**: `ui.select_combo_box_item` (Score: **100.0/100**)
  - Completes the semantic combo box capability triad (`ui.list_combo_boxes` -> `ui.list_combo_box_items` -> `ui.select_combo_box_item`).
  - Level 2 User Approval Required, Reversible Local Action.
  - Native AppKit `NSComboBox` / `AXComboBox` semantic value mutation (`kAXValueAttribute`).
  - Deterministic target matching, observation-binding staleness check, idempotent no-op when already selected, and independent post-mutation verification.

---

## Architectural & Security Blueprint for `ui.select_combo_box_item`
- **Capability Identifier**: `ui.select_combo_box_item`
- **Tool Family**: `ui`
- **Risk Level**: Level 2 (`.level2UserApproval`)
- **Target Resolution**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`, optional window resolution, deterministic target matching on `AXComboBox` by identifier/title, target item by `itemTitle` or `itemIndex`.
- **Verification Model**: Closed-loop `QVerificationStrategy.comboBoxSelectionSucceeded(applicationName:targetIdentity:desiredItemTitle:)`.
- **Idempotency**: Returns `changeKind: .alreadySelected` without mutating when the desired item is already active.
- **Recovery Model**: Observe-first recovery; requires fresh approval if postcondition is not already satisfied.
- **Privacy Model**: Ephemeral structural metadata; no raw AXUIElement pointers or sensitive data written to disk or audit logs.
