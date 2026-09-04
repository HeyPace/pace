# Phase 2AX — Capability Roadmap

## Baseline
- **Commit**: `e831a6c`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AW (Semantic Popover Container Enumeration — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **45 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection:

### 1. Read-Only Discovery & Observation Primitives (21 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`

### 4. Level 3 — High-Risk Mutating Action (2 capabilities)
`app.quit`, `ui.close_window`

Total Count: **45 capabilities**.

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

### Candidate 1: `ui.list_color_wells` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_color_wells`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXColorWell` (`kAXColorWellRole` / `NSAccessibilityColorWellRole`)
- **AX Attributes**: `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`, `kAXIdentifierAttribute`, `kAXValueAttribute`, `kAXEnabledAttribute`
- **Deterministic Identity**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`, optional exact window resolution, exact role validation `["AXColorWell"]`.
- **Authoritative Verification**: Closed-loop aggregate count verification `QVerificationStrategy.colorWellEnumerationSucceeded(applicationName:colorWellCount:)`.
- **Agent Usefulness**: 15/15 (enables discovery and inspection of color pickers and palettes in creative, design, preferences, document, and drawing tools).
- **Security Safety**: 10/10 (read-only, no approval needed, strictly bounded result ceiling `maxDirectColorWellsCount = 32`).
- **Testability**: 10/10 (real AppKit `NSColorWell` fixtures, comprehensive mock AX elements, edge cases).
- **Recovery Safety**: 5/5 (Level 0 snapshot; no replay needed).
- **Privacy**: 5/5 (aggregate evidence reporting, zero persistence of sensitive user data).
- **Architecture Fit**: 5/5 (integrates seamlessly into existing bridge/executor/verifier architecture).
- **Total Score**: **100/100**

### Candidate 2: `ui.list_progress_indicators` (Level 0 Read-Only Observation)
- **Identifier**: `ui.list_progress_indicators`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXProgressIndicator`, `AXBusyIndicator`, `AXLevelIndicator`
- **AX Attributes**: `kAXValueAttribute`, `kAXMinValueAttribute`, `kAXMaxValueAttribute`
- **Total Score**: **95/100** (polymorphic role handling across distinct indicator roles).

### Candidate 3: `ui.list_combo_box_items` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_combo_box_items`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXComboBox`
- **Total Score**: **68/100** (Deferred: In macOS AppKit, `NSComboBox` does not expose static list items as direct AX children until expanded/dropped down; unexpanded combo boxes only expose text value and expanded state. Static item enumeration is not natively supported by AppKit AX without UI state mutation).

### Candidate 4: `ui.select_combo_box_item` (Level 2 Mutation)
- **Identifier**: `ui.select_combo_box_item`
- **Security Level**: Level 2
- **Total Score**: **72/100** (Deferred: requires text value setting or popup interaction; text setting already covered by `ui.set_text_value`).

### Candidate 5: `ui.scroll_page` (Level 2 Mutation)
- **Identifier**: `ui.scroll_page`
- **Security Level**: Level 2
- **Total Score**: **75/100** (Deferred: relative delta scrolling is non-idempotent without content bounds tracking; `ui.set_scroll_position` provides absolute semantic positioning).

### Candidate 6: `ui.list_rulers` (Level 0 Read-Only Discovery)
- **Identifier**: `ui.list_rulers`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `AXRuler`, `AXRulerMarker`
- **Total Score**: **80/100** (Deferred: niche text editing component, lower general agent utility).

---

## Recommended Capability: `ui.list_color_wells`
- **Score**: **100/100**
- **Why it wins**:
  1. Complete native semantic AX backing via `AXColorWell` (`kAXColorWellRole`).
  2. High agent value for inspecting color selections, palettes, and swatch controls in macOS applications.
  3. Strict Level 0 read-only safety with deterministic containment resolution and bounded discovery ceilings (`maxDirectColorWellsCount = 32`).
  4. Robust closed-loop verification and full AppKit `NSColorWell` testability without physical automation.
