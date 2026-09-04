# Phase 2AR — Capability Roadmap

## Baseline
- **Commit**: `0dc29ce`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AQ (Semantic Segmented Control Item Selection — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **40 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`QModelPlanSchema.swift`):

### 1. Read-Only Discovery Primitives (11 capabilities — Level 0 Read-Only)
1. `ui.list_windows`: Enumerates windows belonging to an application via `kAXWindowsAttribute` (Phase 2Z).
2. `ui.list_menu_items`: Enumerates top-level menu bar and direct menu items via `kAXMenuBarAttribute` (Phase 2AA).
3. `ui.list_popup_items`: Enumerates direct popup menu items for an `AXPopUpButton` via direct `AXMenu` children (Phase 2AD).
4. `ui.list_table_rows`: Enumerates direct table rows for an `AXTable` via direct `AXRow`/`AXTableRow` children (Phase 2AE).
5. `ui.list_outline_items`: Enumerates direct outline rows for an `AXOutline` via direct `AXRow`/`AXOutlineRow` children (Phase 2AF).
6. `ui.list_tab_items`: Enumerates direct tab items for an `AXTabGroup` via direct `AXRadioButton` children with `AXTabButton` subrole (Phase 2AH).
7. `ui.list_radio_group_items`: Enumerates direct radio buttons for an `AXRadioGroup` via direct `AXRadioButton` children (Phase 2AI).
8. `ui.list_toolbar_items`: Enumerates direct interactive controls for an `AXToolbar` (Phase 2AK).
9. `ui.list_segmented_control_items`: Enumerates direct segment options for an `AXSegmentedControl` (Phase 2AM).
10. `ui.list_sheet_dialogs`: Enumerates modal `AXSheet` containers attached to an `AXWindow` via `kAXSheetsAttribute` (Phase 2AN).
11. `ui.list_sheet_actions`: Enumerates direct action controls on an `AXSheet` (Phase 2AO).

### 2. Core / System Primitives (10 capabilities)
12. `system.running_apps`: Lists running applications (`system`, Level 0).
13. `system.clipboard.read`: Reads system pasteboard content (`system`, Level 0).
14. `system.clipboard.write`: Writes system pasteboard content (`system`, Level 2).
15. `screen.ocr`: Extracts visual text via Vision framework (`perception`, Level 0).
16. `fs.read`: Reads sandboxed file content (`fs`, Level 0).
17. `fs.write_sandbox`: Writes to sandboxed filesystem path (`fs`, Level 1).
18. `test.noop`: No-operation test primitive (`test`, Level 0).
19. `accessibility.read`: Diagnostic accessibility tree reader (`accessibility`, Level 0).
20. `app.quit`: Terminates a running application (`app`, Level 3).
21. `ui.open_app`: Launches an application via Workspace (`app`, Level 1).

### 3. Semantic UI / App Interaction & Mutation Primitives (19 capabilities)
22. `ui.click_element`: Presses an element via `kAXPressAction` (Phase 2H, Level 2).
23. `ui.set_text_value`: Writes text via `kAXValueAttribute` on focused field (Phase 2I, Level 2).
24. `ui.read_element_value`: Reads semantic element value with perception redaction boundaries (Phase 2J, Level 0).
25. `ui.set_element_state`: Sets checkbox/radio state via `kAXPressAction` (Phase 2K, Level 2).
26. `ui.select_menu_item`: Two-press atomic menu bar item selection (Phase 2L, Level 2).
27. `ui.set_slider_value`: Sets slider/stepper numeric value via `kAXValueAttribute` (Phase 2M, Level 2).
28. `ui.activate_application`: Brings application to front via `NSRunningApplication.activate()` (Phase 2N, Level 1).
29. `ui.focus_element`: Sets element focus via `kAXFocusedAttribute` (Phase 2O, Level 2).
30. `ui.select_popup_item`: Two-press atomic popup item selection (Phase 2P, Level 2).
31. `ui.toggle_disclosure`: Sets disclosure triangle expanded/collapsed state via `kAXPressAction` (Phase 2Q, Level 2).
32. `ui.select_tab`: Selects tab item via `kAXPressAction` on `AXTabButton` (Phase 2R, Level 2).
33. `ui.select_table_row`: Selects table row via `kAXPressAction` on `AXTableRow` (Phase 2S, Level 2).
34. `ui.select_outline_row`: Selects outline row via `kAXPressAction` on `AXOutlineRow` (Phase 2T, Level 2).
35. `ui.set_window_minimized`: Sets window minimized state via `kAXMinimizedAttribute` (Phase 2U, Level 2).
36. `ui.set_application_hidden`: Sets application hidden/unhidden state via `NSRunningApplication.hide()`/`.unhide()` (Phase 2V, Level 2).
37. `ui.set_scroll_position`: Sets absolute scroll bar position via `kAXValueAttribute` (Phase 2W, Level 2).
38. `ui.set_window_main`: Designates window as main document window via `kAXMainAttribute` (Phase 2X, Level 2).
39. `ui.close_window`: Closes window via `kAXCloseButtonAttribute` press (Phase 2Y, Level 3).
40. `ui.select_segmented_control_item`: Selects segment item in `AXSegmentedControl` via `kAXPressAction` (Phase 2AQ, Level 2).

---

## Current Semantic Coverage

```
Application Layer
├── Lifecycle: ui.open_app, app.quit, ui.activate_application, ui.set_application_hidden
└── Global Discovery: system.running_apps

Window Layer
├── Management: ui.set_window_minimized, ui.set_window_main, ui.close_window, [GAP: ui.set_window_full_screen]
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
└── Split Views: [GAP: ui.list_split_panes / ui.set_splitter_position]
```

### Identified Semantic Gaps:
1. **Window Full-Screen Mutation (`ui.set_window_full_screen`)**: Window management currently covers minimization (`kAXMinimizedAttribute`), main status (`kAXMainAttribute`), and closing (`kAXCloseButtonAttribute`). Full-screen state is a first-class macOS window attribute (`kAXFullScreenAttribute`) with no dedicated semantic primitive.
2. **Combo Box Enumeration (`ui.list_combo_box_items`)**: Form controls support popups, text fields, radio groups, and sliders, but `AXComboBox` items (which combine text input with dropdown lists) are not enumerated.
3. **Combo Box Selection (`ui.select_combo_box_item`)**: Selecting items from an `AXComboBox` dropdown.
4. **Split View Pane Discovery (`ui.list_split_panes`)**: Split container layouts (`AXSplitGroup`) are common in macOS productivity apps (Xcode, Finder, Mail) but lack direct child enumeration.
5. **Splitter Position Mutation (`ui.set_splitter_position`)**: Resizing split panes via `AXSplitter` position writes.
6. **Page-Relative / Step Scrolling (`ui.scroll_page`)**: Continuous scrolling is limited to absolute 0.0..1.0 values; incremental step/page scrolling is not supported.

---

## Discovery Principles
1. **Genuine Semantic Primitives**: Reject any synthetic input simulation (no mouse clicks at coordinates, no keyboard shortcuts, no CGEvent/NSEvent, no AppleScript/shell).
2. **Strict AX Role & Attribute Verification**: Every capability must map to canonical, documented AppKit/macOS Accessibility APIs (e.g. `AXAttributeConstants.h`, `AXRoleConstants.h`).
3. **Exact Target Identity**: Application → Window → Container → Element. Target resolution must fail closed on 0 matches or >1 ambiguous matches.
4. **Observation-First Recovery**: Never blindly replay mutations; always observe post-crash or post-timeout state via fresh resolution before deciding next action.
5. **Single-Use Approval & Identity Isolation**: Level 2+ mutating capabilities must bind strictly to `QExecutionIdentity` and single-use user approval.
6. **Fail-Closed Bounded Enumeration**: Read-only discovery must enforce defensive ceilings (16, 32, 64, 128) and fail closed on overflow.

---

## Candidate Capabilities

### Candidate 1: `ui.set_window_full_screen` (Semantic Window Full-Screen State Mutation)
- **Capability Name**: `ui.set_window_full_screen`
- **Level**: Level 2 (Reversible local action, user approval required).
- **Semantic Target**: Exactly ONE resolved `AXWindow` in a named running application.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` (`kAXFullScreenAttribute` / `"AXFullScreen"`).
- **Target Identity Strategy**: Exact `applicationName` + exact `windowTitle` or `windowIdentifier` (reusing `QBridgeAccessibility.resolveExactWindowElement`).
- **Mutation / Read-Only Semantics**: Bidirectional boolean attribute mutation via `AXUIElementSetAttributeValue(windowRef, kAXFullScreenAttribute, desiredFullScreen as CFBoolean)`. No coordinate clicks on green zoom buttons, no Cmd+Ctrl+F shortcuts, no CGEvent.
- **Expected Agent Utility**: Extremely high (24/25). Enabling full-screen workspace focus or restoring windowed state is a primary window management workflow for autonomous desktop agents.
- **Security Risk**: Low/Bounded (Level 2). Mutates display mode of exactly one approved window; requires single-use execution approval.
- **Privacy Risk**: Minimal (Level 0 privacy risk). Operates on boolean window state; no application content or window text is persisted.
- **Recovery Model**: Observation-first. Reads `kAXFullScreenAttribute` on the resolved window; if current state matches `desiredFullScreen`, marks complete without re-executing; if mismatched, requires fresh plan step and fresh approval.
- **Verification Model**: Closed-loop verification. Re-resolves target window independently post-mutation and checks `kAXFullScreenAttribute == desiredFullScreen`.
- **Bounds**: Cardinality = exactly 1 window.
- **Testability**: High (14/15). Deterministic unit tests with mock AX providers verifying true/false mutation, idempotency, role enforcement, window ambiguity rejection, and error handling. Real AppKit window fixture supports `NSWindow.toggleFullScreen`.
- **Third-Party / TCC Dependency**: Mock tests require zero permissions; real E2E guarded by `AXIsProcessTrusted()`.
- **Relationship to Existing Capabilities**: Completes the window lifecycle suite alongside `ui.set_window_minimized` (Phase 2U), `ui.set_window_main` (Phase 2X), `ui.close_window` (Phase 2Y), and `ui.list_windows` (Phase 2Z).

### Candidate 2: `ui.list_combo_box_items` (Semantic Combo Box Item Discovery)
- **Capability Name**: `ui.list_combo_box_items`
- **Level**: Level 0 (Read-Only).
- **Semantic Target**: Exactly ONE resolved `AXComboBox` in a named application window.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXComboBox` (`NSAccessibilityComboBoxRole`) → direct dropdown list items / children.
- **Target Identity Strategy**: Exact `applicationName` + exact `windowTitle`/`windowIdentifier` + exact combo box `identifier` or `title`.
- **Mutation / Read-Only Semantics**: Read-only snapshot of available combo box dropdown choices.
- **Expected Agent Utility**: Moderate/High (20/25). Discovers available options in combo box inputs.
- **Semantic Stability**: Moderate (14/20). AppKit `NSComboBox` exposes items differently depending on whether the list is popped up; WebKit and Electron combo boxes exhibit wide variance in AX tree representations.
- **Security Risk**: Zero (Level 0 Read-Only).
- **Privacy Risk**: Moderate (8/10). Combo box items may contain autofill history, recent paths, or user search terms; must enforce strict ephemeral output boundaries.
- **Recovery Model**: N/A (Read-only primitive; read failure fails closed).
- **Verification Model**: Successful non-empty or valid collection within defensive bound.
- **Bounds**: Defensive ceiling of 64 items; fail closed on overflow.
- **Testability**: Medium (12/15).
- **Third-Party / TCC Dependency**: Unit tests mocked; real E2E requires trusted accessibility.
- **Relationship to Existing Capabilities**: Complements `ui.list_popup_items` (Phase 2AD) for hybrid text+dropdown controls.

### Candidate 3: `ui.select_combo_box_item` (Semantic Combo Box Selection)
- **Capability Name**: `ui.select_combo_box_item`
- **Level**: Level 2 (Reversible local action, user approval required).
- **Semantic Target**: Exactly ONE resolved `AXComboBox`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXComboBox` → target item.
- **Mutation / Read-Only Semantics**: Sets value or opens dropdown and selects item.
- **Expected Agent Utility**: Moderate/High (21/25).
- **Semantic Stability**: Low/Moderate (12/20). High discrepancy between editable vs non-editable combo boxes in AppKit, SwiftUI, and WebKit.
- **Security Risk**: Low/Medium (Level 2).
- **Privacy Risk**: Moderate (8/10).
- **Recovery Model**: Observation-first via `kAXValueAttribute`.
- **Verification Model**: Closed-loop value comparison.
- **Bounds**: Exactly 1 target item.
- **Testability**: Medium (11/15).
- **Third-Party / TCC Dependency**: Trusted accessibility.
- **Relationship to Existing Capabilities**: Complements `ui.select_popup_item`.

### Candidate 4: `ui.list_split_panes` (Semantic Split View Pane Discovery)
- **Capability Name**: `ui.list_split_panes`
- **Level**: Level 0 (Read-Only).
- **Semantic Target**: Exactly ONE resolved `AXSplitGroup` (`NSAccessibilitySplitGroupRole`).
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXSplitGroup` → direct split panes / sub-containers.
- **Target Identity Strategy**: Exact application + window + split group identifier.
- **Mutation / Read-Only Semantics**: Read-only enumeration of child panes.
- **Expected Agent Utility**: Moderate (17/25).
- **Semantic Stability**: Good (16/20). `NSSplitView` accessibility exposes `AXSplitGroup` reliably in native AppKit.
- **Security Risk**: Zero (Level 0 Read-Only).
- **Privacy Risk**: Low (10/10). Returns container identifiers/roles.
- **Recovery Model**: N/A (Read-only).
- **Verification Model**: Valid collection snapshot.
- **Bounds**: Defensive ceiling of 16 panes.
- **Testability**: High (14/15).
- **Third-Party / TCC Dependency**: Trusted accessibility.
- **Relationship to Existing Capabilities**: Expands container discovery alongside `ui.list_toolbar_items` and `ui.list_sheet_dialogs`.

### Candidate 5: `ui.set_splitter_position` (Semantic Splitter Position Mutation)
- **Capability Name**: `ui.set_splitter_position`
- **Level**: Level 2 (Reversible local action, user approval required).
- **Semantic Target**: Exactly ONE resolved `AXSplitter` in an `AXSplitGroup`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXSplitGroup` → `AXSplitter` (`kAXValueAttribute`).
- **Target Identity Strategy**: Exact application + window + split group + splitter index/identifier.
- **Mutation / Read-Only Semantics**: Writes numeric position to `kAXValueAttribute`.
- **Expected Agent Utility**: Moderate (16/25). Resizing split panes is rarely critical to agent completion.
- **Semantic Stability**: Moderate (15/20). `kAXValueAttribute` write support on `AXSplitter` varies across macOS versions.
- **Security Risk**: Low (Level 2).
- **Privacy Risk**: Low (10/10).
- **Recovery Model**: Numeric value observation.
- **Verification Model**: Value comparison within tolerance.
- **Bounds**: Single splitter target.
- **Testability**: Medium (12/15).
- **Third-Party / TCC Dependency**: Trusted accessibility.
- **Relationship to Existing Capabilities**: Mirrors `ui.set_slider_value` and `ui.set_scroll_position`.

### Candidate 6: `ui.scroll_page` (Semantic Page-Relative Scroll Action)
- **Capability Name**: `ui.scroll_page`
- **Level**: Level 2 (Reversible local action, user approval required).
- **Semantic Target**: Exactly ONE resolved `AXScrollBar` in an `AXScrollArea`.
- **Exact AX Hierarchy**: `AXApplication` → `AXWindow` → `AXScrollArea` → `AXScrollBar` (`kAXIncrementPageAction` / `kAXDecrementPageAction`).
- **Target Identity Strategy**: Exact application + window + scroll area + orientation.
- **Mutation / Read-Only Semantics**: Performs `AXUIElementPerformAction(kAXIncrementPageAction)` or `decrement`.
- **Expected Agent Utility**: Moderate/High (18/25).
- **Semantic Stability**: Moderate (15/20). Actions exist in header, but postcondition delta verification is noisy when content size is dynamic.
- **Security Risk**: Low (Level 2).
- **Privacy Risk**: Low (10/10).
- **Recovery Model**: Observation of scroll value change.
- **Verification Model**: Relative scroll value delta check.
- **Bounds**: Exactly 1 scroll bar.
- **Testability**: Medium (13/15).
- **Third-Party / TCC Dependency**: Trusted accessibility.
- **Relationship to Existing Capabilities**: Complements absolute `ui.set_scroll_position` (Phase 2W).

---

## Scoring Matrix

| Dimension | Weight | Candidate 1: `ui.set_window_full_screen` | Candidate 2: `ui.list_combo_box_items` | Candidate 3: `ui.select_combo_box_item` | Candidate 4: `ui.list_split_panes` | Candidate 5: `ui.set_splitter_position` | Candidate 6: `ui.scroll_page` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Agent Utility** | 25 | **24** | 20 | 21 | 17 | 16 | 18 |
| **Semantic Stability** | 20 | **19** | 14 | 12 | 16 | 15 | 15 |
| **Security Safety** | 20 | **19** | 20 | 18 | 20 | 19 | 19 |
| **Testability** | 15 | **14** | 12 | 11 | 14 | 12 | 13 |
| **Privacy Safety** | 10 | **10** | 8 | 8 | 10 | 10 | 10 |
| **Recovery Simplicity**| 5 | **5** | 5 | 4 | 5 | 5 | 3 |
| **Architecture Fit** | 5 | **5** | 4 | 4 | 4 | 4 | 4 |
| **Total Score** | 100 | **96/100** | **83/100** | **78/100** | **86/100** | **81/100** | **82/100** |

---

## Recommended Next Capability: `ui.set_window_full_screen`

### 1. Highest-Value Semantic Gap
Window lifecycle control is a foundational pillar of desktop agent orchestration. While minimization (`ui.set_window_minimized`), main window promotion (`ui.set_window_main`), closing (`ui.close_window`), and window listing (`ui.list_windows`) exist, full-screen transition remains completely unsupported. Autonomous agents currently get stuck when user requests ask to enter/exit full-screen mode or when applications launch into full-screen Spaces.

### 2. Not Redundant
`ui.set_window_full_screen` addresses an entirely separate window state from minimization (Dock iconification) and main designation (key document status). It does not duplicate any existing primitive.

### 3. Canonical AX Stability
`kAXFullScreenAttribute` (`"AXFullScreen"`, CFBoolean, writable) is an authoritative, first-class attribute documented in Apple's `AXAttributeConstants.h` and supported natively on `AXWindow` since macOS 10.7 (Lion).

### 4. Exact Target Contract
- **Target Schema**: `applicationName: String`, `windowTitle: String?`, `windowIdentifier: String?`, `desiredFullScreen: Bool`.
- **Target Resolution**: Reuses `QBridgeAccessibility.resolveExactWindowElement` enforcing single-window cardinality. Fails closed on 0 or >1 matches.

### 5. Security Level
- **Level 2 (Reversible Local Action, User Approval Required)**.
- Bound to exact `QExecutionIdentity`, single-use approval, and explicit boolean target state.

### 6. Privacy Model
- Boolean state write only; summary contains aggregate metadata (`"Set window 'X' full-screen state to true"`).
- Zero exposure or durable persistence of document contents.

### 7. Verification Model
- **Precondition Observation**: Authoritative `kAXFullScreenAttribute` read. If already equal to `desiredFullScreen`, no-op with immediate success.
- **Mutation**: `AXUIElementSetAttributeValue(windowRef, kAXFullScreenAttribute, desiredFullScreen as CFBoolean)`.
- **Independent Postcondition**: Fresh window resolution and fresh read of `kAXFullScreenAttribute == desiredFullScreen`.

### 8. Recovery Model
- Purely observation-first. If execution interrupts or crashes, re-observe `kAXFullScreenAttribute`. If state matches, mark complete; if mismatched, require fresh execution identity and approval. Never blind replay.

### 9. Bounds
- Exactly 1 target window element.

### 10. Test Strategy
- Deterministic unit tests (25+ tests) verifying schema parsing, Level 2 approval gating, role policy enforcement (`AXWindow` only), target ambiguity, missing window, already-at-desired-state idempotency, mutation failure, and verification strategy.

### 11. Real E2E Feasibility
- Deterministic AppKit test fixture (`NSWindow` with `.toggleFullScreen(nil)` / `kAXFullScreenAttribute`). Real AX tests guarded cleanly by `guard AXIsProcessTrusted() else { return }`.

### 12. Why Strong Alternatives Should Wait
- `ui.list_split_panes` (Score 86) and `ui.list_combo_box_items` (Score 83) are read-only discovery primitives with lower agent impact compared to the core window management capability `ui.set_window_full_screen`.
- `ui.select_combo_box_item` (Score 78) has significant cross-framework AX variability that warrants dedicated discovery benchmarking before implementation.

---

## Strong Alternatives
1. **`ui.list_split_panes` (Score: 86/100)**: Clean Level 0 read-only discovery of split container panes (`AXSplitGroup`), but lower overall agent demand.
2. **`ui.list_combo_box_items` (Score: 83/100)**: Valuable form control discovery for `AXComboBox`, but requires deeper qualification of AppKit vs WebKit dropdown hierarchy differences.

---

## Rejected Candidates
1. **Window Zoom via Zoom Button Press (`ui.zoom_window`)**:
   - **Reason**: REJECTED — macOS AppKit zoom toggles between user frame and standard frame, but AX provides no authoritative `kAXZoomedAttribute` boolean for independent verification. State cannot be deterministically verified without fragile screen coordinate geometry calculations.
2. **Dedicated Radio Group Selection (`ui.select_radio_group_item`)**:
   - **Reason**: REJECTED (REDUNDANT) — `ui.set_element_state(role: "AXRadioButton", desiredState: "on")` already provides full semantic coverage for radio button selection within radio groups.
3. **Dedicated Checkbox State (`ui.set_checkbox_state`)**:
   - **Reason**: REJECTED (REDUNDANT) — Fully covered by `ui.set_element_state(role: "AXCheckBox", desiredState: "on"/"off")`.
4. **Coordinate-Based Window Maximization (`ui.maximize_window_at_point`)**:
   - **Reason**: REJECTED — SECURITY/ARCHITECTURE BOUNDARY. Violates coordinate prohibition and semantic accessibility boundaries.
5. **Keyboard Shortcut Full-Screen Toggle (`ui.send_fullscreen_hotkey`)**:
   - **Reason**: REJECTED — SECURITY/ARCHITECTURE BOUNDARY. Violates prohibition on keyboard simulation and physical input.

---

## Security Boundaries
- **Approval Gating**: Level 2 User Approval required; `QPermissionGate` will route to approval request before dispatch.
- **Execution Identity**: Mutating step bound to single-use `QExecutionIdentity`.
- **Role Allowlist**: Restricted exclusively to `QAXWindowRolePolicy` (`AXWindow` only).
- **No Physical Simulation**: Dispatches via `AXUIElementSetAttributeValue(kAXFullScreenAttribute)` only. No CGEvent, mouse clicks, or keyboard events.

---

## Privacy Boundaries
- **Ephemeral Context**: Window title and full-screen target state used only during execution.
- **Durable Persistence**: `QDurablePlanStepSnapshot` carries only sanitized aggregate summaries. Zero window contents or sensitive screen metadata stored.

---

## Verification Boundaries
- **Closed-Loop Verification**: Re-resolves target window via fresh Accessibility query post-mutation.
- **Authoritative Attribute**: Evaluates `kAXFullScreenAttribute` boolean directly.

---

## Recovery Boundaries
- **Observation-First**: Check `kAXFullScreenAttribute` on recovery before taking any action.
- **No Blind Replay**: Stale mutations are never blindly retried; requires fresh execution identity and approval.

---

## Test Strategy
- **Unit Test Suite (`QSemanticWindowFullScreenTests`)**:
  1. Capability registration in `QModelPlanSchema.swift` with Level 2 default risk.
  2. Role enforcement: accept `AXWindow`, reject `AXButton`, `AXGroup`, `AXSheet`, `AXDialog`, and unknown roles.
  3. Window resolution: exact title/identifier matching, zero-match rejection, ambiguity (>1 match) rejection.
  4. Idempotency: `desiredFullScreen == currentFullScreen` is a verified no-op.
  5. Bidirectional mutations: `true -> false` and `false -> true`.
  6. Closed-loop verification strategy: `QVerificationStrategy.axWindowFullScreenMatchesDesired`.
  7. Observation-first recovery in `QTaskRecoveryManager`.
  8. Privacy and sanitization checks.
- **AppKit Live Fixture**: `NSWindow` supporting native full screen in test harness.

---

## Hardware / TCC Requirements
- **Unit Suites**: Fully mocked via AX provider architecture; runs in headless CI without accessibility trust.
- **Live E2E Verification**: Guarded cleanly by `guard AXIsProcessTrusted() else { return }`.

---

## Explicitly Deferred Work
- Multi-display Space assignment and screen index targeting (macOS Spaces API boundary).
- Window frame/origin coordinate resizing (violates non-coordinate semantic principles).
- Stage Manager group window orchestration.

---

## Phase 2AR Conclusion
The recommended capability for **Phase 2AS** is **`ui.set_window_full_screen`** (Score: 96/100).
- **Implementation Status**: DISCOVERY ONLY (Zero source/test code modifications made).
- **Next Step**: Await user prompt for Phase 2AS implementation.
