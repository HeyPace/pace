# Phase 2AI — Capability Roadmap Discovery

## Baseline
- **Branch**: `q-secure-foundation`
- **HEAD Commit**: `2f00883`
- **Working Tree**: `CLEAN` (verified via `git status --short`)

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

---

## Architecture Findings

1. **Discovery / Mutation Symmetry**:
   - `ui.select_menu_item` (Phase 2L) ↔ `ui.list_menu_items` (Phase 2AA)
   - `ui.select_popup_item` (Phase 2P) ↔ `ui.list_popup_items` (Phase 2AD)
   - `ui.select_table_row` (Phase 2S) ↔ `ui.list_table_rows` (Phase 2AE)
   - `ui.select_outline_row` (Phase 2T) ↔ `ui.list_outline_items` (Phase 2AF)
   - `ui.select_tab` (Phase 2R) ↔ `ui.list_tab_items` (Phase 2AH)
   - `ui.set_element_state` (Phase 2K, for `AXRadioButton`) ↔ **Missing Discovery Counterpart: `ui.list_radio_group_items`**

2. **Container Boundaries**:
   - Every read-only discovery capability in Q operates strictly on a well-defined container (`AXWindow`, `AXMenuBar`, `AXPopUpButton`, `AXTable`, `AXOutline`, `AXTabGroup`).
   - Radio groups (`AXRadioGroup`) represent the final major standard AppKit mutual-exclusion container lacking bounded direct semantic item discovery.

---

## Candidate Capabilities

### Candidate 1: `ui.list_radio_group_items` (Semantic Radio Group Item Enumeration)
- **Role**: `AXRadioGroup` (`NSAccessibilityRadioGroupRole`).
- **Hierarchy**: `AXApplication` → `AXWindow` → `AXRadioGroup` (matched by `identifier` and/or `title`) → direct `AXRadioButton` children (where `subrole == nil` or `subrole != "AXTabButton"`).
- **Attributes Read**: `kAXTitleAttribute` / `kAXDescriptionAttribute`, `AXIdentifier`, `kAXValueAttribute` (clean 0/1 on/off state), `kAXEnabledAttribute`.
- **Bounds**: `maxDirectRadioItemsCount = 64`.
- **Risk**: Level 0 Read-Only. No mutation, no press, no focus change.

### Candidate 2: `ui.list_toolbar_items` (Semantic Window Toolbar Item Enumeration)
- **Role**: `AXToolbar` (`NSAccessibilityToolbarRole`).
- **Hierarchy**: `AXApplication` → `AXWindow` → `AXToolbar` → direct interactive controls (`AXButton`, `AXPopUpButton`, `AXSearchField`, etc.).
- **Bounds**: `maxDirectToolbarItemsCount = 64`.
- **Risk**: Level 0 Read-Only.

### Candidate 3: `ui.list_segmented_controls` (Semantic Segmented Control Item Enumeration)
- **Role**: `AXSegmentedControl` / `AXGroup`.
- **Hierarchy**: `AXApplication` → `AXWindow` → `AXSegmentedControl` → direct segment elements.
- **Bounds**: `maxDirectSegmentsCount = 32`.
- **Risk**: Level 0 Read-Only.

### Candidate 4: `ui.set_window_fullscreen` (Semantic Window Fullscreen State Mutation)
- **Role**: `AXWindow`.
- **Hierarchy**: `AXApplication` → `AXWindow`.
- **Attributes Mutated**: `kAXFullScreenAttribute` (`AXUIElementSetAttributeValue`).
- **Risk**: Level 2 User Approval.

---

## Security Analysis

1. **Physical Input & Scripting**: ZERO candidates introduce `CGEvent`, `NSEvent`, mouse/keyboard simulation, `AppleScript`, or shell execution.
2. **Application Resolution**: All candidates strictly use `QBridgeAccessibility.resolveExactRunningApplication(named:)` (0 matches → `applicationNotAvailable`, >1 matches → `ambiguousTarget`).
3. **Authorization Isolation**: For `ui.list_radio_group_items`, enumeration is purely informational and confers **zero authorization** to execute subsequent `ui.set_element_state` or `ui.click_element` mutations.

---

## Privacy Analysis

- **Ephemeral Storage**: Detailed row/item data remains strictly in `QActionResult.outputData` for immediate reasoning.
- **Durable Scrubbing**: `result.summary` and `verifiedEvidence` carry aggregate counts only (`"Enumerated N radio item(s) for radio group in application 'X' (selected: 'Y')"`).
- **Zero Disk Leakage**: `QDurablePlanStepSnapshot` excludes `outputData`, preventing radio button labels or user configuration options from reaching SQLite WAL, audit logs, or recovery snapshots.

---

## Recovery Analysis

- **Level 0 Discovery Capabilities**: `ui.list_radio_group_items`, `ui.list_toolbar_items`, and `ui.list_segmented_controls` perform no mutation and require no recovery branch in `QTaskRecoveryManager` (a read that completes without throwing is its own verified result).
- **Level 2 Mutation Capabilities**: `ui.set_window_fullscreen` would require observation-first recovery matching `kAXFullScreenAttribute`.

---

## Testability Analysis

- `ui.list_radio_group_items` can be tested deterministically with a real AppKit fixture using `NSStackView` containing `NSButton(radioButtonWithTitle:...)` elements inside an `NSWindow`, fully guarded by `guard AXIsProcessTrusted() else { return }`.

---

## Scoring

| Candidate | Semantic Determinism (/10) | Security Simplicity (/10) | Testability (/10) | Architectural Reuse (/5) | User Usefulness (/5) | Privacy Safety (/5) | TOTAL (/45) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **1. `ui.list_radio_group_items`** | **10** | **10** | **10** | **5** | **5** | **5** | **45** |
| **2. `ui.list_toolbar_items`** | 7 | 9 | 8 | 4 | 4 | 5 | **37** |
| **3. `ui.list_segmented_controls`** | 6 | 9 | 7 | 4 | 4 | 5 | **35** |
| **4. `ui.set_window_fullscreen`** | 7 | 7 | 6 | 5 | 4 | 5 | **34** |

---

## Ranking

### Rank 1: `ui.list_radio_group_items` (Score: 45/45)
- **Why Now**: Provides the direct, natural read-only discovery counterpart for `AXRadioGroup` option controls (pairing with `ui.set_element_state`).
- **Contract**: `AXApplication` → `AXWindow` → `AXRadioGroup` (matching `identifier` or `title`) → direct `AXRadioButton` children (`subrole != "AXTabButton"`).
- **Security Model**: Level 0 Read-Only, exact application matching, bounded direct traversal (`maxDirectRadioItemsCount = 64`), authorization isolation.
- **Implementation Complexity**: Low, follows exact established discovery pattern from Phases 2Z, 2AA, 2AD, 2AE, 2AF, 2AH.
- **Test Strategy**: Unit tests + mock provider + TCC-guarded AppKit `NSStackView` of radio buttons fixture.

### Rank 2: `ui.list_toolbar_items` (Score: 37/45)
- **Summary**: Read-only discovery of window toolbar controls. Heterogeneous child roles require more complex multi-type normalization.

### Rank 3: `ui.list_segmented_controls` (Score: 35/45)
- **Summary**: Read-only discovery of segment items. Role definitions vary between AppKit versions.

---

## Recommended Next Capability

**`ui.list_radio_group_items`**

---

## Known Risks & Mitigations
- **Risk**: Confusion with `AXTabButton` subroles.
  - **Mitigation**: Strict filter requiring `role == "AXRadioButton"` and rejecting `subrole == "AXTabButton"`.
- **Risk**: Unbounded children in large forms.
  - **Mitigation**: Fail-closed defensive bound `maxDirectRadioItemsCount = 64`.

---

## Deferred Candidates
- `ui.list_toolbar_items`: Deferred pending standardized heterogeneous control schema.
- `ui.list_segmented_controls`: Deferred pending multi-version AppKit segment role normalization.
- `ui.set_window_fullscreen`: Deferred to avoid Spaces transition timing nondeterminism in test runners.

---

DISCOVERY COMPLETE
NO IMPLEMENTATION PERFORMED
NO EXISTING CAPABILITY MODIFIED
