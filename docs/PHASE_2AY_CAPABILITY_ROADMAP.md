# Phase 2AY — Capability Roadmap

## Baseline
- **Commit**: `64013c0`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AX (Semantic Color Well Enumeration — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **46 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection:

### 1. Read-Only Discovery & Observation Primitives (22 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`

### 4. Level 3 — High-Risk Mutating Action (2 capabilities)
`app.quit`, `ui.close_window`

Total Count: **46 capabilities**.

---

## Remaining Semantic AX Candidates Evaluation & Scoring

| Dimension | Weight |
|---|---|
| Semantic AX authority | 20 |
| Deterministic target identity | 15 |
| Independent verification | 15 |
| Agent usefulness | 15 |
| Security safety | 10 |
| Testability | 10 |
| Recovery safety | 5 |
| Privacy | 5 |
| Architecture fit | 5 |
| **Total** | **100** |

### Candidate 1: `ui.list_progress_indicators` (Level 0 Read-Only Observation)
- **Identifier**: `ui.list_progress_indicators`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXProgressIndicator`, `AXBusyIndicator` (`kAXProgressIndicatorRole`, `kAXBusyIndicatorRole` / `NSAccessibilityProgressIndicatorRole`, `NSAccessibilityBusyIndicatorRole`)
- **AX Attributes**: `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`, `kAXDescriptionAttribute`, `axIdentifierAttributeName` (`"AXIdentifier"`), `kAXValueAttribute`, `kAXMinValueAttribute`, `kAXMaxValueAttribute`, `kAXEnabledAttribute`
- **Deterministic Identity**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`, optional exact window resolution, exact role validation `["AXProgressIndicator", "AXBusyIndicator"]`.
- **Authoritative Verification**: Closed-loop aggregate count verification `QVerificationStrategy.progressIndicatorEnumerationSucceeded(applicationName:indicatorCount:)`.
- **Agent Usefulness**: 15/15 (Critical capability allowing agents to observe operation progress, task completion percentages, downloading/exporting status, and busy spinners without polling OCR).
- **Security Safety**: 10/10 (read-only observation, no approval needed, strictly bounded result ceiling `maxDirectProgressIndicatorsCount = 32`).
- **Testability**: 10/10 (real AppKit `NSProgressIndicator` fixtures for both determinate progress and spinning busy indicators).
- **Recovery Safety**: 5/5 (Level 0 snapshot; no replay needed).
- **Privacy**: 5/5 (aggregate evidence reporting, zero persistence of sensitive user data).
- **Architecture Fit**: 5/5 (integrates cleanly into existing bridge/executor/verifier architecture).
- **Total Score**: **100/100**

### Candidate 2: `ui.list_layout_areas` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_layout_areas`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXLayoutArea`, `AXLayoutItem`
- **Total Score**: **82/100** (Deferred: canvas layout areas in document apps, lower priority than progress monitoring).

### Candidate 3: `ui.list_rulers` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_rulers`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXRuler`, `AXRulerMarker`
- **Total Score**: **80/100** (Deferred: niche text editing component, lower general agent utility).

### Candidate 4: `ui.scroll_page` (Level 2 Mutation)
- **Identifier**: `ui.scroll_page`
- **Security Level**: Level 2
- **Total Score**: **75/100** (Deferred: relative delta scrolling is non-idempotent without content bounds tracking; `ui.set_scroll_position` already provides absolute semantic positioning).

### Candidate 5: `ui.list_combo_box_items` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_combo_box_items`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXComboBox`
- **Total Score**: **68/100** (Deferred: In macOS AppKit, `NSComboBox` does not expose static list items as direct AX children until expanded/dropped down; unexpanded combo boxes only expose text value and expanded state).

---

## Recommended Capability: `ui.list_progress_indicators`
- **Score**: **100/100**
- **Why it wins**:
  1. Complete native semantic AX backing via `AXProgressIndicator` and `AXBusyIndicator` (`kAXProgressIndicatorRole`, `kAXBusyIndicatorRole`).
  2. Very high agent usefulness for observing operation completion, percentages, and busy states across macOS applications.
  3. Strict Level 0 read-only safety with deterministic containment resolution and bounded discovery ceilings (`maxDirectProgressIndicatorsCount = 32`).
  4. Robust closed-loop verification and full AppKit `NSProgressIndicator` testability.
