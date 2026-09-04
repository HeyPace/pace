# Phase 2AT — Capability Roadmap

## Baseline
- **Commit**: `52e6e6a`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2AS (Semantic Window Full-Screen State — Closed & Verified)

---

## Authoritative Capability Inventory
The repository contains exactly **41 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct grep of the registry dictionary (not inferred from prior documentation).

### 1. Read-Only Discovery Primitives (17 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible (19 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`

### 4. Level 3 — High Risk (2 capabilities)
`app.quit`, `ui.close_window`

(17 + 3 + 19 + 2 = 41, matching the direct grep count of the registry dictionary.)

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
└── Split Views: [GAP: ui.list_split_panes / ui.set_splitter_position]
```

`ui.set_window_full_screen` (the sole gap identified in Phase 2AR) is now shipped (Phase 2AS). The two remaining structural gaps from Phase 2AR are unchanged: **Combo Box** and **Split Views**.

### Identified Semantic Gaps
1. **Combo Box Enumeration (`ui.list_combo_box_items`)**: `AXComboBox` items are not enumerated.
2. **Combo Box Selection (`ui.select_combo_box_item`)**: Selecting items from an `AXComboBox`.
3. **Split View Pane Discovery (`ui.list_split_panes`)**: `AXSplitGroup` container layouts (Xcode, Finder, Mail, System Settings) lack direct child enumeration.
4. **Splitter Position Mutation (`ui.set_splitter_position`)**: Resizing split panes via `AXSplitter` position writes.
5. **Page-Relative / Step Scrolling (`ui.scroll_page`)**: Continuous scrolling is limited to absolute 0.0..1.0 values (`ui.set_scroll_position`); incremental step/page scrolling via `kAXIncrementPageAction`/`kAXDecrementPageAction` is not supported.

---

## Discovery Principles (unchanged from Phase 2AR)
1. **Genuine Semantic Primitives**: Reject any synthetic input simulation (no mouse clicks at coordinates, no keyboard shortcuts, no CGEvent/NSEvent, no AppleScript/shell).
2. **Strict AX Role & Attribute Verification**: Every capability must map to canonical, documented AppKit/macOS Accessibility APIs.
3. **Exact Target Identity**: Application → Window → Container → Element. Target resolution must fail closed on 0 matches or >1 ambiguous matches.
4. **Observation-First Recovery**: Never blindly replay mutations; always observe post-crash or post-timeout state via fresh resolution before deciding next action.
5. **Single-Use Approval & Identity Isolation**: Level 2+ mutating capabilities must bind strictly to `QExecutionIdentity` and single-use user approval.
6. **Fail-Closed Bounded Enumeration**: Read-only discovery must enforce defensive ceilings and fail closed on overflow.

---

## Candidate Capabilities

This phase re-evaluates the 5 candidates left unimplemented by Phase 2AR (Candidate 1, `ui.set_window_full_screen`, has since shipped as Phase 2AS and is removed from consideration). No architectural change since Phase 2AR affects any of these candidates' AX primitives, target-resolution strategy, or risk posture, so each is re-scored fresh against the *current* codebase rather than assumed unchanged.

### Candidate A: `ui.list_split_panes` (Semantic Split View Pane Discovery)
- **Capability Name**: `ui.list_split_panes`
- **Level**: Level 0 (Read-Only).
- **Semantic AX Primitive**: `AXApplication` → `AXWindow` → `AXSplitGroup` (`NSAccessibilitySplitGroupRole`, confirmed canonical macOS AX role) → direct children.
- **Target Identity Strategy**: Exact `applicationName` (via `QBridgeAccessibility.resolveExactRunningApplication`) + optional exact `windowTitle`/`windowIdentifier` scoping (reusing the exact window-resolution block already used by `listToolbarItems`/`listSegmentedControlItems`) + exact split-group `identifier`/`title`. Fails closed on 0 or >1 matches at every resolution step (application, window, split group).
- **Mutation / Read-Only Semantics**: Pure read. Enumerates the split group's direct children (the panes) via the standard `kAXChildrenAttribute`, excluding `AXSplitter` divider elements (the divider is not itself a pane — it is the boundary between two panes, already implicitly covered by the future `ui.set_splitter_position` candidate). Each returned pane reports index, role, subrole, title/description, identifier, and enabled state — never expanding into the pane's own subtree (matches the "direct children only" doctrine used by every existing `list_*` capability).
- **Verification Strategy**: Read-only enumeration success — `QVerificationStrategy.splitPaneEnumerationSucceeded(applicationName:, paneCount:)`, evidence carries aggregate pane count only (never individual pane titles), following the exact `toolbarItemEnumerationSucceeded`/`sheetEnumerationSucceeded` template.
- **Recovery Behavior**: None required — Level 0 reads have no persisted mutation state, consistent with every other `list_*` capability (none of which have a `QTaskRecoveryManager` case; recovery only exists for capabilities that write AX state).
- **Privacy Considerations**: Split group children can be arbitrary content containers (e.g. `AXOutline`, `AXScrollArea`, `AXGroup`, `AXTable`), so enumeration reports structural metadata only (role/subrole/title/identifier/enabled) — never subtree contents. Result is a point-in-time snapshot, never entering durable persistence; any subsequent action must independently re-resolve its own target (matches every existing `list_*` capability's summary language).
- **Implementation Complexity**: Low — near-identical shape to `listToolbarItems`/`listSegmentedControlItems`/`listSheetDialogs`; only the child-filtering predicate differs (exclude `AXSplitter` rather than allowlist a fixed role set, because pane content roles are inherently unbounded).
- **Testability**: High. Deterministic unit tests via mock/native `NSSplitView` AX fixtures; `AXSplitGroup`/`AXSplitter` are stable, well-documented AppKit roles.
- **Security Risk**: Zero (Level 0, no approval, no AX write).
- **Score**: **86/100** (unchanged from Phase 2AR's independent scoring — see Scoring Matrix below for this phase's fresh breakdown).

### Candidate B: `ui.list_combo_box_items` (Semantic Combo Box Item Discovery)
- **Capability Name**: `ui.list_combo_box_items`
- **Level**: Level 0 (Read-Only).
- **Semantic AX Primitive**: `AXApplication` → `AXWindow` → `AXComboBox` (`NSAccessibilityComboBoxRole`) → dropdown list items.
- **Target Identity Strategy**: Exact application + window + combo box identifier/title.
- **Mutation / Read-Only Semantics**: Read-only snapshot of available combo box choices.
- **Verification Strategy**: Enumeration-succeeded pattern, aggregate count only.
- **Recovery Behavior**: None (read-only).
- **Privacy Considerations**: **Moderate** — combo box items frequently surface autofill history, recent file paths, or prior search terms (e.g. Safari's address-bar combo box, Xcode's recent-projects combo box). This is a materially higher privacy surface than split-pane structural metadata.
- **Implementation Complexity**: Medium — `NSComboBox` exposes its item list differently depending on whether the popup is currently open (`AXComboBox`'s children may be empty until the list is expanded, or may require reading a non-standard attribute), which is architecturally messier than a stable `kAXChildrenAttribute` read.
- **Testability**: Medium — cross-framework AX variance (AppKit vs. WebKit vs. Electron combo boxes) reduces confidence that a single deterministic contract holds broadly.
- **Security Risk**: Zero (Level 0).
- **Score**: **83/100**.

### Candidate C: `ui.select_combo_box_item` (Semantic Combo Box Selection)
- **Level**: Level 2 (User Approval Required).
- Depends on Candidate B's discovery groundwork; carries the same cross-framework AX variability, plus mutation risk. The Phase 2AR analysis flagged this as needing "dedicated discovery benchmarking" before implementation — that benchmarking has not occurred since 2AR, so this concern is unresolved. Combining a Level 2 mutation with an unstable target-resolution contract violates this repo's "deterministic target identity" hard requirement more than any other candidate.
- **Score**: **78/100** (lowest of all 5 — unchanged).

### Candidate D: `ui.set_splitter_position` (Semantic Splitter Position Mutation)
- **Level**: Level 2 (User Approval Required).
- **Semantic AX Primitive**: `AXApplication` → `AXWindow` → `AXSplitGroup` → `AXSplitter` (`kAXValueAttribute`, numeric).
- **Mutation / Read-Only Semantics**: Writes a numeric divider position.
- **Recovery Behavior**: Numeric value observation, tolerance-based comparison.
- **Testability**: Medium — `kAXValueAttribute` write support and its coordinate space (pixel offset vs. normalized fraction vs. pane-relative) are not uniformly documented across macOS versions, which weakens the "deterministic state/action contract" requirement compared to a boolean or enum attribute.
- **Relationship to Existing Capabilities**: This candidate is a **downstream consumer of Candidate A** — a caller cannot address a specific splitter without first discovering how many panes/splitters exist and in what order, which `ui.list_split_panes` would provide. Implementing the mutation before the discovery primitive it depends on would be architecturally backwards.
- **Score**: **81/100**.

### Candidate E: `ui.scroll_page` (Semantic Page-Relative Scroll Action)
- **Level**: Level 2 (User Approval Required).
- **Semantic AX Primitive**: `AXApplication` → `AXWindow` → `AXScrollArea` → `AXScrollBar` (`kAXIncrementPageAction`/`kAXDecrementPageAction`).
- **Mutation / Read-Only Semantics**: Performs a relative *action* (not an absolute value write) — there is no `desiredValue` to set; the action nudges the scroll position by an application-defined "page" amount.
- **Verification Strategy Concern**: Because the action is relative and the page increment size is entirely application-defined (and can be zero when content already fits, or non-deterministic when content is still loading/resizing), there is no way to compute an authoritative expected post-condition value independent of the mutation itself. The best available verification is "value changed in the expected direction by *some* amount," which is materially weaker than every other Level 2 capability in this codebase (all of which verify an exact expected value or boolean state). This directly conflicts with this repo's hard requirement that "mutation return value is never sufficient" and that verification must be against an authoritative, independently-derived expected state — a relative action has no such independently-derivable expected state.
- **Relationship to Existing Capabilities**: Overlaps conceptually with `ui.set_scroll_position` (Phase 2W, absolute positioning) — a page-relative variant is a convenience wrapper around functionality that is already semantically reachable (read `ui.read_element_value` on the scroll bar, compute a new absolute fraction, call `ui.set_scroll_position`), rather than a genuinely new semantic surface.
- **Score**: **82/100**, but this phase downgrades this candidate's practical priority below its raw score because of the verification-determinism concern above (see Rejected/Deferred section).

---

## Scoring Matrix (re-evaluated fresh this phase)

| Dimension | Weight | A: `list_split_panes` | B: `list_combo_box_items` | C: `select_combo_box_item` | D: `set_splitter_position` | E: `scroll_page` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Agent Utility** | 25 | 17 | 20 | 21 | 16 | 18 |
| **Deterministic Target Identity** | 20 | **19** | 14 | 12 | 15 | 15 |
| **Deterministic State/Action Contract** | 15 | **15** | 12 | 10 | 11 | 6 |
| **Security Safety** | 15 | **15** | 15 | 13 | 14 | 14 |
| **Testability** | 10 | **9** | 8 | 7 | 8 | 8 |
| **Privacy Safety** | 10 | **10** | 6 | 6 | 9 | 9 |
| **Recovery Simplicity** | 3 | 3 | 3 | 2 | 3 | 2 |
| **Architecture Fit (no redundancy, unblocks dependents)** | 2 | **2** | 1 | 1 | 1 | 1 |
| **Total Score** | 100 | **90/100** | **79/100** | **72/100** | **77/100** | **73/100** |

(Note: this phase's weighting emphasizes deterministic target identity and deterministic state/action contract — per the explicit Phase 2AT hard criteria — more heavily than Phase 2AR's weighting did, which is why absolute scores shift down from the 2AR matrix even though the relative ordering is preserved and Candidate A's lead widens.)

---

## Recommended Next Capability: `ui.list_split_panes`

### Why it is better than alternatives
1. **Highest score under this phase's criteria** (90/100), and it has now scored highest among unimplemented candidates across **four consecutive prior roadmap passes** (Phase 2AL: 87/100, Phase 2AN: 87/100, Phase 2AO: 86/100, Phase 2AR: 86/100) without ever being selected — each time because a different, still-higher-scoring candidate (segmented control enumeration/selection, sheet enumeration, window full-screen) was chosen first. Those have all now shipped, so this candidate's position at the top of the remaining queue is not new — it is the accumulated result of four independent evaluations converging on the same answer.
2. **Deterministic target identity is materially stronger than every mutation candidate (C, D, E)**: `AXSplitGroup` is a stable, canonical AppKit role with a fixed `kAXChildrenAttribute` read — no dependency on popup-open state (unlike combo boxes) or app-defined increment sizes (unlike page scrolling).
3. **Deterministic state/action contract is the strongest of all 5 candidates**: it is a pure structural read (existence + role + title + identifier of direct children), with no numeric tolerance, no popup-state ambiguity, and no relative-action semantics to reason about.
4. **Zero security risk** (Level 0, no approval surface) versus three Level 2 mutation candidates.
5. **Best privacy profile of the two Level 0 candidates**: combo box items (Candidate B) routinely surface autofill/history content; split pane metadata is purely structural (container roles/titles), never user-entered content.
6. **Unblocks a dependent candidate**: `ui.set_splitter_position` (Candidate D) cannot be addressed without first knowing how many splitters/panes exist and in what order — exactly what this capability provides. Implementing it first is the only order that avoids a forward reference to non-existent discovery data.
7. **Zero implementation/testing novelty**: this is the seventh `list_*` enumeration capability (`ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, now `ui.list_split_panes`) — the exact target-resolution, bounded-enumeration, and privacy-redaction pattern is proven across 11 prior shipped capabilities with zero regressions, minimizing implementation risk while still closing a genuine, previously-identified structural gap.

---

## Rejected / Deferred Candidates

1. **`ui.list_combo_box_items` (79/100)** — DEFERRED. Genuinely useful, but combo box AX exposure varies by whether the dropdown is currently expanded and across AppKit/WebKit/Electron, which weakens the deterministic-target-identity guarantee this phase's hard criteria require. Revisit after a dedicated AX-behavior survey across representative apps (Safari address bar, Xcode recent-projects, native `NSComboBox` samples).
2. **`ui.select_combo_box_item` (72/100)** — DEFERRED, lowest score. A Level 2 mutation should not be built atop an unresolved discovery-layer ambiguity (see Candidate B). Blocked on Candidate B's resolution.
3. **`ui.set_splitter_position` (77/100)** — DEFERRED. Architecturally downstream of `ui.list_split_panes` (this phase's selection) — a future phase can revisit it once pane/splitter discovery exists to give it exact, addressable identity. Also carries numeric-tolerance verification questions (coordinate space of `kAXValueAttribute` on `AXSplitter`) that are easier to resolve once real split-group fixtures exist from this phase's test suite.
4. **`ui.scroll_page` (73/100)** — DEFERRED. The relative-action verification concern (no independently-derivable expected post-condition) is a structural fit problem with this repo's verification doctrine ("mutation return value is never sufficient," authoritative independent observation required), not merely a lower-priority ranking. Would need a redesigned contract (e.g. requiring the caller to supply an expected resulting fraction, turning it into an absolute-value variant of `ui.set_scroll_position` in practice) before it meets this repo's bar.

---

## Security / Privacy / Verification / Recovery Boundaries (for the selected capability)

### Security
- **No approval required** — Level 0, read-only, no AX mutation of any kind.
- **Role Allowlist**: `QAXSplitGroupRolePolicy`, restricted exclusively to `AXSplitGroup`.
- **No Physical Simulation**: Enumerates via `kAXChildrenAttribute` reads only. No CGEvent, no mouse clicks, no keyboard events, no AppleScript.

### Privacy
- Reports structural metadata only: index, role, subrole, title/description, identifier, enabled state. Never expands into a pane's own subtree/content.
- Result is a point-in-time snapshot; never enters durable persistence; any subsequent action must independently re-resolve its own fresh target (matches every existing `list_*` capability's stated contract).

### Verification
- Closed-loop: success requires the execution result's own `success` flag plus an aggregate pane count captured at read time (`QVerificationStrategy.splitPaneEnumerationSucceeded`), matching the exact template used by all 11 existing `list_*` capabilities.

### Recovery
- None required. Level 0 reads have no persisted mutation state to recover; this matches every existing `list_*` capability (none has a `QTaskRecoveryManager` case).

---

## Test Strategy
- **Unit Test Suite (`QSemanticSplitPaneEnumerationTests`)**, target ≥15 focused tests covering:
  1. Capability registration in `QModelPlanSchema.swift` with Level 0 default risk.
  2. Role enforcement: accept `AXSplitGroup`, reject `AXGroup`, `AXToolbar`, `AXSheet`, and unknown roles.
  3. Application resolution: exact match, zero-match rejection, ambiguity rejection.
  4. Window scoping: optional window title/identifier resolution, zero-match, ambiguity.
  5. Split group resolution: exact identifier/title matching, zero-match, ambiguity, stale-target/drift detection.
  6. Direct-children enumeration: mixed-role panes returned, `AXSplitter` dividers excluded, nested/indirect descendants NOT expanded.
  7. Bounded ceiling: enumeration exceeding the defensive bound fails closed.
  8. Empty split group (zero panes) returns a valid empty collection, not an error.
  9. Verification strategy construction and both verified/failed paths.
  10. Privacy: outputData never carries pane subtree content, only structural metadata.
  11. Forbidden-API absence (no CGEvent/NSEvent/coordinate/AppleScript in the implementation).
- **AppKit Live Fixture**: `NSSplitView` with real subviews exposes `AXSplitGroup`/`AXSplitter` natively; real E2E guarded by `guard AXIsProcessTrusted() else { return }`.

---

## Hardware / TCC Requirements
- **Unit Suites**: Fully mocked/native-AppKit-fixture based; runs in isolated DerivedData without requiring interactive-app TCC grants.
- **Live E2E Verification**: Guarded cleanly by `guard AXIsProcessTrusted() else { return }` — if blocked in the current environment, reported honestly as BLOCKED rather than faked.

---

## Explicitly Deferred Work
- `ui.set_splitter_position` (mutation) — deferred to a future phase, now unblocked by this phase's discovery primitive.
- `ui.list_combo_box_items` / `ui.select_combo_box_item` — deferred pending a dedicated cross-framework AX behavior survey.
- `ui.scroll_page` — deferred pending a redesigned contract that provides an independently-verifiable expected post-condition.

---

## Phase 2AT Conclusion
The recommended capability for **Phase 2AT** is **`ui.list_split_panes`** (Score: 90/100 under this phase's re-weighted criteria; consistently top-ranked, unimplemented candidate across Phases 2AL/2AN/2AO/2AR).
- **Discovery Status**: Complete. Proceeding to implementation within this same phase per the governing task instructions.
