# Phase 2AJ — Capability Roadmap Discovery

## Baseline
- **Branch**: `q-secure-foundation`
- **HEAD Commit**: `61ea89d`
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
| 35 | `ui.list_radio_group_items` | ui | Read-Only | Level 0 | Exact running app -> AXRadioGroup | Aggregate count verification | None | Ephemeral output | Real E2E |

Total Registered Capabilities: **35** (7 Level 0 Container Discovery Primitives).

---

## Current Architecture Findings

1. **Established Discovery Model**:
   - All 7 read-only discovery capabilities follow a strict, unified architectural pattern:
     - Exact application resolution via `resolveExactRunningApplication(named:)` (fail-closed on 0 or >1 matches).
     - Dedicated container role policy enum (e.g. `QAXRadioGroupRolePolicy`, `QAXTabGroupRolePolicy`).
     - Bounded direct-child enumeration only (defensive safe count bounds: 32–128).
     - Ephemeral exposure in `QActionResult.outputData`.
     - Aggregate-only strings in `result.summary` and `verifiedEvidence` (zero private label disk persistence).
     - `QDurablePlanStepSnapshot` excludes `outputData`.
     - Strict authorization isolation (Level 0 discovery never authorizes mutation).

2. **Window Surface Gap**:
   - `ui.list_windows` discovers top-level windows (`AXWindow`).
   - `ui.list_menu_items` discovers the application menu bar (`AXMenuBar`).
   - However, within an `AXWindow`, the primary action surface in macOS AppKit applications is the **Window Toolbar** (`AXToolbar` / `NSToolbar`).
   - Currently, no capability exists to discover toolbar items attached to a window.

---

## Existing Discovery/Mutation Gaps

- `ui.click_element` (Phase 2H) and `ui.select_popup_item` (Phase 2P) can click buttons and select popups in a toolbar, but the agent has to guess toolbar button titles or identifiers in advance.
- `ui.list_toolbar_items` directly resolves this gap by enumerating the direct controls of an `AXToolbar`.

---

## Candidate Capabilities

### Candidate 1: `ui.list_toolbar_items` (Semantic Window Toolbar Item Enumeration)
- **Role**: `AXToolbar` (`NSAccessibilityToolbarRole`).
- **Hierarchy**: `AXApplication` → `AXWindow` → `AXToolbar` (matched by `identifier` and/or `title`, or single toolbar in target window) → direct interactive children.
- **Child Roles Supported**: Standard toolbar control roles (`AXButton`, `AXPopUpButton`, `AXMenuButton`, `AXSearchField`, `AXSegmentedControl`, `AXRadioButton`, `AXCheckBox`, `AXGroup`, `AXTextField`).
- **Bounds**: `maxDirectToolbarItemsCount = 64`.
- **Risk Level**: Level 0 Read-Only. No mutation, no press, no focus change.

### Candidate 2: `ui.list_segmented_control_items` (Semantic Segmented Control Item Enumeration)
- **Role**: `AXSegmentedControl` / `AXGroup`.
- **Hierarchy**: `AXApplication` → `AXWindow` → `AXSegmentedControl` → direct segment elements.
- **Bounds**: `maxDirectSegmentsCount = 32`.
- **Risk Level**: Level 0 Read-Only.

### Candidate 3: `ui.list_checkbox_items` (Semantic Checkbox Item Enumeration)
- **Role**: `AXGroup` / container of checkboxes.
- **Limitation**: In AppKit, checkboxes do not have a dedicated standardized container role like `AXRadioGroup`.

### Candidate 4: `ui.list_focusable_elements` (Window-wide Focusable Element Crawl)
- **Limitation**: Requires recursive window tree walking, violating the direct-child safety boundary.

---

## AX Contract Analysis: `ui.list_toolbar_items`

1. **Target Container**:
   - `AXToolbar` (`NSAccessibilityToolbarRole`).
   - Role enforced via `QAXToolbarRolePolicy.allowedRoles = ["AXToolbar"]`.
   - Identified by `identifier` or `title` (or defaults to the single toolbar of the resolved `AXWindow`).

2. **Child Items**:
   - Direct children of `AXToolbar` via `kAXChildrenAttribute`.
   - Read safe metadata: `index: Int`, `title: String?`, `identifier: String?`, `role: String`, `subrole: String?`, `isEnabled: Bool?`, `help: String?`.

3. **Context Integrity**:
   - Every enumerated item is verified to be a direct child of the resolved `AXToolbar`.

---

## Security Analysis

1. **Permission Level**: Level 0 Read-Only (no approval, no mutation).
2. **Target Application**: Strictly resolved via `resolveExactRunningApplication(named:)`.
3. **Authorization Isolation**: Purely informational; confers **zero authorization** to execute `ui.click_element` or other mutations.
4. **Forbidden APIs**: Zero physical input, keyboard/mouse simulation, `CGEvent`, `NSEvent`, `AppleScript`, shell execution, subprocess, clipboard, network, OCR, or `kAXPressAction` mutation.

---

## Privacy Analysis

- **Ephemeral Storage**: Full item list with titles/identifiers is placed into `QActionResult.outputData` only for immediate agent reasoning.
- **Durable Scrubbing**: `result.summary` and `verifiedEvidence` carry aggregate counts only (`"Enumerated N toolbar item(s) for toolbar in application 'X'..."`).
- **Zero Disk Leakage**: `QDurablePlanStepSnapshot` excludes `outputData`, preventing toolbar labels or document paths from reaching SQLite WAL, task store, or audit logs.

---

## Recovery Analysis

- Level 0 discovery capability: does not mutate system state and requires no recovery branch in `QTaskRecoveryManager`.

---

## Testability Analysis

- Deterministic mocked tests with mock provider.
- Live AppKit E2E fixture using `NSToolbar` attached to `NSWindow`, guarded by `guard AXIsProcessTrusted() else { return }`.

---

## Architectural Reuse

- Reuses `QBridgeAccessibility.resolveExactRunningApplication(named:)`.
- Reuses `QAXInteractionError` conventions (`disallowedToolbarRole`, `toolbarItemCollectionExceedsSafeBound`).
- Reuses `QVerificationStrategy` pattern (`.toolbarItemEnumerationSucceeded(applicationName:itemCount:)`).

---

## Scoring

| Candidate | Semantic Determinism (/10) | Security Simplicity (/10) | Testability (/10) | Architectural Reuse (/5) | User Usefulness (/5) | Privacy Safety (/5) | TOTAL (/45) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **1. `ui.list_toolbar_items`** | **9** | **10** | **10** | **5** | **5** | **5** | **44** |
| **2. `ui.list_segmented_control_items`** | 6 | 9 | 7 | 4 | 4 | 5 | **35** |
| **3. `ui.list_checkbox_items`** | 6 | 8 | 7 | 4 | 4 | 5 | **34** |
| **4. `ui.list_focusable_elements`** | 4 | 6 | 6 | 3 | 4 | 3 | **26** |

---

## Ranking

### Rank 1: `ui.list_toolbar_items` (Score: 44/45)
- **Why Now**: Window toolbars are the primary action container across macOS applications. Calling `ui.list_toolbar_items` completes the window exploration surface alongside `ui.list_windows` and `ui.list_menu_items`.
- **Contract**: `AXApplication` → `AXWindow` → `AXToolbar` → direct semantic items (`AXButton`, `AXPopUpButton`, `AXSearchField`, etc.).
- **Security Model**: Level 0 Read-Only, bounded direct traversal (`maxDirectToolbarItemsCount = 64`), authorization isolation.
- **Test Strategy**: Unit tests + mock provider + TCC-guarded `NSToolbar` in `NSWindow` live fixture.

### Rank 2: `ui.list_segmented_control_items` (Score: 35/45)
- **Summary**: Read-only discovery of segments. Role variance across macOS AppKit versions.

### Rank 3: `ui.list_checkbox_items` (Score: 34/45)
- **Summary**: Checkboxes lack a standard AppKit container role.

---

## Recommended Next Capability

**`ui.list_toolbar_items`**

---

## Known Risks & Mitigations
- **Risk**: Toolbar item with custom subviews.
  - **Mitigation**: Direct child inspection only; captures the top-level element role and title/identifier without recursive descent.
- **Risk**: Overlong toolbars in complex apps.
  - **Mitigation**: Defensive safe bound `maxDirectToolbarItemsCount = 64` (fails closed).

---

## Deferred Candidates
- `ui.list_segmented_control_items`: Deferred pending segment subrole standardisation.
- `ui.list_checkbox_items`: Deferred due to lack of standard container role in AppKit.
- `ui.list_focusable_elements`: Rejected due to requirement for recursive whole-window crawling.

---

## Blockers
- **None**: Baseline is clean, architecture is sound, and all prerequisites are satisfied.

---

DISCOVERY COMPLETE
NO IMPLEMENTATION PERFORMED
NO EXISTING CAPABILITY MODIFIED
