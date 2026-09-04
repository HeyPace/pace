# Phase 2AP — Capability Roadmap

## Baseline
- **Commit**: `4de47f7`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AO (Semantic Sheet Action Enumeration — Closed & Verified)

---

## Current Capability Inventory
The repository contains **39 authoritative registered capabilities** across three major families:

### 1. Read-Only Discovery Primitives (11 capabilities — Level 0)
1. `ui.list_windows`: Enumerates windows of an application via `kAXWindowsAttribute` (Phase 2Z).
2. `ui.list_menu_items`: Enumerates top-level menu bar and direct menu items via `kAXMenuBarAttribute` (Phase 2AA).
3. `ui.list_popup_items`: Enumerates direct popup menu items for an `AXPopUpButton` (Phase 2AD).
4. `ui.list_table_rows`: Enumerates direct table rows for an `AXTable` (Phase 2AE).
5. `ui.list_outline_items`: Enumerates direct outline items for an `AXOutline` (Phase 2AF).
6. `ui.list_tab_items`: Enumerates direct tab items for an `AXTabGroup` (Phase 2AH).
7. `ui.list_radio_group_items`: Enumerates direct radio buttons for an `AXRadioGroup` (Phase 2AI).
8. `ui.list_toolbar_items`: Enumerates direct toolbar controls for an `AXToolbar` (Phase 2AK).
9. `ui.list_segmented_control_items`: Enumerates direct segment options for an `AXSegmentedControl` (Phase 2AM).
10. `ui.list_sheet_dialogs`: Enumerates modal `AXSheet` containers attached to an `AXWindow` (Phase 2AN).
11. `ui.list_sheet_actions`: Enumerates direct action controls on an `AXSheet` (Phase 2AO).

### 2. Core Primitives (10 capabilities)
12. `system.running_apps`: (system, .level0ReadOnly)
13. `system.clipboard.read`: (system, .level0ReadOnly)
14. `system.clipboard.write`: (system, .level2UserApproval)
15. `screen.ocr`: (perception, .level0ReadOnly)
16. `fs.read`: (fs, .level0ReadOnly)
17. `fs.write_sandbox`: (fs, .level1SafeLocalAction)
18. `test.noop`: (test, .level0ReadOnly)
19. `accessibility.read`: (accessibility, .level0ReadOnly)
20. `app.quit`: (app, .level3HighRisk)
21. `ui.open_app`: (app, .level1SafeLocalAction)

### 3. Semantic UI / App Interaction Primitives (18 capabilities)
22. `ui.click_element`: Press an element via `kAXPressAction` (Phase 2H, Level 2).
23. `ui.set_text_value`: Write text via `kAXValueAttribute` on focused field (Phase 2I, Level 2).
24. `ui.read_element_value`: Read semantic element value (Phase 2J, Level 0).
25. `ui.set_element_state`: Set checkbox/radio state via `kAXPressAction` (Phase 2K, Level 2).
26. `ui.select_menu_item`: Two-press atomic menu item selection (Phase 2L, Level 2).
27. `ui.set_slider_value`: Set slider/stepper value via `kAXValueAttribute` (Phase 2M, Level 2).
28. `ui.activate_application`: Bring application to front via `NSRunningApplication.activate()` (Phase 2N, Level 1).
29. `ui.focus_element`: Set element focus via `kAXFocusedAttribute` (Phase 2O, Level 2).
30. `ui.select_popup_item`: Two-press atomic popup selection (Phase 2P, Level 2).
31. `ui.toggle_disclosure`: Set disclosure triangle state via `kAXPressAction` (Phase 2Q, Level 2).
32. `ui.select_tab`: Select tab item via `kAXPressAction` on `AXTabButton` (Phase 2R, Level 2).
33. `ui.select_table_row`: Select table row via `kAXPressAction` on `AXTableRow` (Phase 2S, Level 2).
34. `ui.select_outline_row`: Select outline row via `kAXPressAction` on `AXOutlineRow` (Phase 2T, Level 2).
35. `ui.set_window_minimized`: Set window minimized state via `kAXMinimizedAttribute` (Phase 2U, Level 2).
36. `ui.set_application_hidden`: Set application hidden state via `NSRunningApplication.hide()`/`.unhide()` (Phase 2V, Level 2).
37. `ui.set_scroll_position`: Set scroll bar position via `kAXValueAttribute` (Phase 2W, Level 2).
38. `ui.set_window_main`: Designate window as main document window via `kAXMainAttribute` (Phase 2X, Level 2).
39. `ui.close_window`: Close window via `kAXCloseButtonAttribute` press (Phase 2Y, Level 3).

---

## Existing Capability Families

```
Application Layer
├── Lifecycle: ui.open_app, app.quit, ui.activate_application, ui.set_application_hidden
└── Global Discovery: system.running_apps

Window Layer
├── Management: ui.set_window_minimized, ui.set_window_main, ui.close_window
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
└── Action: ui.click_element

Structured Selection Layer
├── Tabs: ui.list_tab_items → ui.select_tab
├── Radio Groups: ui.list_radio_group_items → (ui.set_element_state)
├── Table Rows: ui.list_table_rows → ui.select_table_row
├── Outline Rows: ui.list_outline_items → ui.select_outline_row
├── Toolbars: ui.list_toolbar_items → (ui.click_element, ui.select_popup_item)
└── Segmented Controls: ui.list_segmented_control_items → [MISSING MUTATION: ui.select_segmented_control_item]
```

---

## Discovery Principles
1. **Semantic Target Integrity**: Strict 1:1 container and element resolution (fail closed on 0 or >1 matches).
2. **Exact Action Pairing**: Every high-value discovery primitive should have a strictly scoped semantic mutation primitive where direct interaction is required.
3. **No Recursive Crawling / No Coordinates**: Direct children only; no arbitrary descent; zero physical coordinates.
4. **Observation-First Recovery**: Never blindly replay mutations after failure or crash; re-observe authoritative state.
5. **Fail-Closed Defensive Bounds**: Strict collection limits (16, 32, 64, 128); fail closed on overflow.

---

## Candidate Capabilities

### Candidate 1: `ui.select_segmented_control_item`
- **Level**: Level 2 (Reversible local action, approval required).
- **Semantic Target**: Exactly ONE segment option belonging to exactly ONE resolved `AXSegmentedControl` in an `AXWindow`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXSegmentedControl` (`NSAccessibilityRadioGroupRole` / `NSAccessibilitySegmentedControlRole`) → direct segment child (`AXButton` / `AXRadioButton`).
- **Mutation Semantics**: `AXUIElementPerformAction(kAXPressAction)` on the target segment element. Authoritative state read from `kAXValueAttribute` or `kAXSelectedAttribute`.
- **Expected Value**: Bridges the exact gap left after Phase 2AM (`ui.list_segmented_control_items`). An agent discovering segmented control options (e.g. View Mode: Grid / List / Column, Text Alignment: Left / Center / Right) can now select specific segments deterministically with explicit state verification.
- **Security Risk**: Low/Bounded (Level 2). Single-use execution identity, scoped strictly to the target segment.
- **Privacy Implications**: Ephemeral segment labels in execution context; summary and verified evidence carry aggregate verification metadata only.
- **Recovery Implications**: Observation-first. If crashed, re-inspect `kAXValueAttribute` / `kAXSelectedAttribute` before attempting fresh retry.
- **Testability**: Extremely high. Standard `NSSegmentedControl` can be instantiated and tested deterministically in unit suites.
- **Hardware/TCC Dependency**: Unit tests mocked; real E2E guarded by `AXIsProcessTrusted()`.
- **Relationship to Existing Capabilities**: Directly completes the `ui.list_segmented_control_items` primitive (Phase 2AM).

### Candidate 2: `ui.set_window_full_screen`
- **Level**: Level 2 (Reversible local action, approval required).
- **Semantic Target**: Exactly ONE resolved `AXWindow`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` (`kAXFullScreenAttribute`).
- **Mutation Semantics**: `AXUIElementSetAttributeValue(kAXFullScreenAttribute, desiredFullScreen as CFBoolean)`.
- **Expected Value**: Completes window display management alongside `ui.set_window_minimized` (Phase 2U) and `ui.set_window_main` (Phase 2X).
- **Security Risk**: Medium (Level 2). Full screen affects display spaces and animations.
- **Privacy Implications**: No sensitive data in window full screen boolean.
- **Recovery Implications**: Reversible boolean attribute write.
- **Testability**: Medium. Full screen animations take 500-1000ms and headless WindowServer sessions in CI frequently reject full screen transitions.
- **Relationship to Existing Capabilities**: Complements `ui.set_window_minimized`.

### Candidate 3: `ui.zoom_window`
- **Level**: Level 2 (Reversible local action, approval required).
- **Semantic Target**: Exactly ONE resolved `AXWindow` via `kAXZoomButtonAttribute`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `kAXZoomButtonAttribute` (`AXButton`).
- **Mutation Semantics**: `AXUIElementPerformAction(kAXPressAction)` on zoom button.
- **Expected Value**: Allows toggling window zoom/maximization.
- **Security Risk**: Low/Medium.
- **Privacy Implications**: None.
- **Recovery Implications**: Zoom button toggle state in AppKit is non-deterministic (depends on user frame vs screen frame).
- **Testability**: Medium. Window sizing depends on screen geometry.
- **Relationship to Existing Capabilities**: Window management extension.

### Candidate 4: `ui.select_combo_box_item`
- **Level**: Level 2 (Reversible local action, approval required).
- **Semantic Target**: `AXComboBox`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXComboBox`.
- **Mutation Semantics**: Open combo box and select option or set value.
- **Expected Value**: Allows selecting items in text+popup hybrid combo boxes.
- **Security Risk**: Medium.
- **Privacy Implications**: Combo box text may contain user inputs.
- **Recovery Implications**: Multi-step open-poll-select.
- **Testability**: Low/Medium due to significant AppKit vs WebKit vs Electron role discrepancies on `AXComboBox`.
- **Relationship to Existing Capabilities**: Complements `ui.select_popup_item`.

### Candidate 5: `ui.set_splitter_position`
- **Level**: Level 2 (Reversible local action, approval required).
- **Semantic Target**: `AXSplitter` in `AXSplitGroup`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXSplitGroup` → `AXSplitter`.
- **Mutation Semantics**: `AXUIElementSetAttributeValue(kAXValueAttribute, desiredPosition)`.
- **Expected Value**: Resize master-detail or split pane views.
- **Security Risk**: Low.
- **Privacy Implications**: None.
- **Recovery Implications**: Numeric position observation.
- **Testability**: Medium. `NSSplitView` accessibility support varies across macOS versions.
- **Relationship to Existing Capabilities**: Complements `ui.set_scroll_position`.

---

## Scoring Matrix

| Dimension | Weight | Candidate 1: `ui.select_segmented_control_item` | Candidate 2: `ui.set_window_full_screen` | Candidate 3: `ui.zoom_window` | Candidate 4: `ui.select_combo_box_item` | Candidate 5: `ui.set_splitter_position` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Agent Utility** | 25 | **25** | 22 | 19 | 21 | 18 |
| **Semantic Stability** | 20 | **20** | 18 | 17 | 14 | 15 |
| **Security Safety** | 20 | **19** | 19 | 19 | 18 | 19 |
| **Testability** | 15 | **15** | 13 | 14 | 12 | 13 |
| **Privacy Safety** | 10 | **10** | 10 | 10 | 10 | 10 |
| **Recovery Simplicity**| 5 | **5** | 5 | 4 | 4 | 5 |
| **Architecture Fit** | 5 | **5** | 5 | 5 | 4 | 4 |
| **Total Score** | 100 | **99/100** | **92/100** | **88/100** | **83/100** | **84/100** |

---

## Recommended Next Capability: `ui.select_segmented_control_item`

### Detailed Architectural Justification:
1. **Closes the Discovery-Action Gap**: In Phase 2AM, `ui.list_segmented_control_items` was introduced and verified. However, selecting a segment currently has no dedicated semantic mutation primitive. Providing `ui.select_segmented_control_item` completes the structured control suite.
2. **Canonical AX Stability**: `NSSegmentedControl` in AppKit exposes direct children with roles `AXButton` or `AXRadioButton` with clear `kAXValueAttribute` / `kAXSelectedAttribute` states.
3. **Strict Target Containment**: Requires resolving application → window → container `AXSegmentedControl` → specific segment target by title or index.
4. **Level 2 Approval & Reversible Local Action**: Requires explicit single-use approval bound to the exact segment execution identity.
5. **Observation-First Closed-Loop Verification**: Verifies `kAXValueAttribute == 1` or `kAXSelectedAttribute == true` on the targeted segment post-mutation.
6. **No Physical Simulation**: Dispatches purely via standard `AXUIElementPerformAction(kAXPressAction)`.

---

## Strong Alternatives
1. **`ui.set_window_full_screen` (Score: 92/100)**: Excellent semantic window control, but macOS space transitions and animation timing introduce WindowServer headless test sensitivity.
2. **`ui.zoom_window` (Score: 88/100)**: Useful for window management, but AppKit zoom toggles have non-deterministic return geometry across varied display setups.

---

## Rejected Candidates
- **Generic Descendant Action Crawler (`ui.click_any_child`)**: REJECTED — violates direct-child containment, risks unbounded recursive crawling and accidental dangerous button activation.
- **Coordinate-based Click (`ui.click_at_point`)**: REJECTED — coordinates violate semantic accessibility boundaries and break across display scaling.
- **Context Menu Opener (`ui.open_context_menu`)**: REJECTED — requires mouse hover/secondary click simulation; native context menus steal focus and dismiss unpredictably.

---

## Security, Privacy & Recovery Boundaries
- **Security**: Level 2 User Approval; strict `QAXSegmentedControlRolePolicy`; execution identity binding; single-use approval; no physical input.
- **Privacy**: Ephemeral segment labels in execution context; summary and verified evidence carry aggregate verification metadata only (`"Selected segment 'X' in segmented control 'Y'"`).
- **Recovery**: Purely observation-first. Re-inspect segment selection state before attempting any fresh execution.

---

## Test Strategy & Hardware/TCC Requirements
- **Unit / Mock Tests**: 20+ unit tests covering registration, Level 2 approval requirement, parameter validation, role enforcement, bounds, privacy, and plan execution.
- **Real AppKit Fixture**: `NSSegmentedControl` with multiple segments embedded in an `NSWindow`.
- **Hardware/TCC**: Live E2E tests guarded by `guard AXIsProcessTrusted() else { return }` without fabricating success in headless CI.

---

## Explicitly Deferred Work
- Deselection of single segments when segmented control is single-select (unsupported by AppKit).
- Multi-segment simultaneous batch selection (must be executed as sequential single-segment steps).
- Traversing buttons inside generic `AXGroup` layout wrappers.

---

## Phase 2AP Conclusion
The recommended capability for **Phase 2AQ** is **`ui.select_segmented_control_item`** (Score: 99/100).
- **Implementation Status**: NOT IMPLEMENTED (Discovery only).
- **Next Step**: Await user prompt for Phase 2AQ implementation.
