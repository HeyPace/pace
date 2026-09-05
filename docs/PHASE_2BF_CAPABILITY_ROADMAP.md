# Phase 2BF — Capability Roadmap

## Baseline
- **Commit**: `c58127e`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BE (Semantic Combo Box Item Selection — `ui.select_combo_box_item`)

---

## Authoritative Capability Inventory
The repository contains exactly **53 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection (`grep -c '": ("'` against the live file, not any historical count):

### 1. Read-Only Discovery Primitives (28 capabilities — Level 0 Read-Only)
`system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes`, `ui.list_rulers`, `ui.list_combo_box_items`

### 2. Level 1 — Safe Local Action (3 capabilities)
`ui.open_app`, `fs.write_sandbox`, `ui.activate_application`

### 3. Level 2 — User Approval Required, Reversible Local Action (20 capabilities)
`system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`, `ui.select_combo_box_item`

### 4. Level 3 — High Risk Local Action (2 capabilities)
`app.quit`, `ui.close_window`

**Total Registered Capabilities**: **53**

---

## SDK & AppKit Discovery
Inspected the live macOS SDK at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`, specifically `ApplicationServices.framework` -> `HIServices.framework` headers:
- `AXRoleConstants.h` — full enumerated role list (`kAXWindowRole` through `kAXPopoverRole`, 51 roles). Cross-referenced against every role already consumed by the 53 registered capabilities to find roles with **zero** capability coverage or **enumeration-only** coverage (a `list_*` capability exists but no paired mutation).
- `AXAttributeConstants.h` — confirmed `kAXValueIncrementAttribute` (`"AXValueIncrement"`, line 416): "Recommended for `kAXIncrementorRole` and other similar elements" — the authoritative step-size attribute for incrementor/stepper controls, and `kAXIncrementorAttribute` (`"AXIncrementor"`, line 1077), the convenience attribute linking a time/date field to its child incrementor.
- `AXActionConstants.h` — confirmed `kAXIncrementAction` (`"AXIncrement"`, line 49) and `kAXDecrementAction` (`"AXDecrement"`, line 57) as first-class, purpose-built AX actions distinct from `kAXPressAction`. **Neither action has been used anywhere in this codebase before this phase** — every existing Level 2 mutation uses either `AXUIElementPerformAction(kAXPressAction)` or `AXUIElementSetAttributeValue(kAXValueAttribute)`.
- `AXUIElement.h`, `AXValue.h` — reconfirmed no additional primitives relevant to a new capability beyond what's already in use (`AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `AXIsProcessTrusted`).
- Existing source inspected: `QModelPlanSchema.swift` (full 53-entry registry + comment history back to Phase 2E), `QBridgeAdapters.swift` (10,037 lines — `QAXIncrementorRolePolicy`, `listIncrementors`, `selectComboBoxItem`, `setSplitterPosition` read in full as implementation templates), `QExecutionService.swift` (`executeListIncrementors`, `executeSelectComboBoxItem` read in full), `QActionVerification.swift` (`splitterPositionMatchesDesired`, `axComboBoxValueMatchesDesired` strategies read in full — the numeric-tolerance and string-match closed-loop verification patterns), `QPlanExecutor.swift` (strategy-construction mapping for both), and the Phase 2BA/2BE test suites (`QSemanticIncrementorEnumerationTests.swift`, `QSemanticComboBoxSelectionTests.swift`, 544 and 586 lines) as the structural test template.

Key finding: `ui.list_incrementors` (Phase 2BA) already enumerates `AXIncrementor` elements read-only, but **no mutation capability targets `AXIncrementor` at all** — `ui.set_slider_value`'s role policy (`QAXSliderRolePolicy.allowedRoles = ["AXSlider", "AXStepper"]`) explicitly does **not** include `AXIncrementor`, and no other capability's role policy does either. This is a genuine, unclosed gap between an existing Level 0 enumeration and its natural Level 2 mutation counterpart — the same "enumerate, then later act" rhythm already completed for `AXTabGroup` (2AH -> 2AQ-adjacent), `AXSegmentedControl` (2AM -> 2AQ), `AXSplitGroup`/`AXSplitter` (2AT -> 2AU), and `AXComboBox` (2BB/2BD -> 2BE).

---

## Candidate Scoring Matrix (9-Dimension Model)

| Dimension | Weight | `ui.step_incrementor` | `ui.select_radio_group_item` | `ui.select_browser_item` | `ui.set_level_indicator_value` | `ui.list_menu_bar_items` | `ui.set_date_field_value` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Native Semantic API Quality | 12% | 10/10 (12.0) | 7/10 (8.4) | 7/10 (8.4) | 6/10 (7.2) | 9/10 (10.8) | 5/10 (6.0) |
| 2. Deterministic Target Identity | 12% | 9/10 (10.8) | 8/10 (9.6) | 6/10 (7.2) | 8/10 (9.6) | 9/10 (10.8) | 6/10 (7.2) |
| 3. Authoritative State/Action Model | 11% | 10/10 (11.0) | 5/10 (5.5) | 6/10 (6.6) | 5/10 (5.5) | 7/10 (7.7) | 5/10 (5.5) |
| 4. Independent Verification Availability | 12% | 9/10 (10.8) | 7/10 (8.4) | 6/10 (7.2) | 6/10 (7.2) | 7/10 (8.4) | 5/10 (6.0) |
| 5. Autonomy Usefulness | 12% | 8/10 (9.6) | 7/10 (8.4) | 5/10 (6.0) | 4/10 (4.8) | 6/10 (7.2) | 5/10 (6.0) |
| 6. Implementation Complexity (simpler = higher) | 10% | 9/10 (9.0) | 6/10 (6.0) | 5/10 (5.0) | 7/10 (7.0) | 9/10 (9.0) | 4/10 (4.0) |
| 7. Security Implications | 11% | 10/10 (11.0) | 8/10 (8.8) | 8/10 (8.8) | 9/10 (9.9) | 10/10 (11.0) | 8/10 (8.8) |
| 8. Privacy Implications | 10% | 10/10 (10.0) | 9/10 (9.0) | 8/10 (8.0) | 9/10 (9.0) | 9/10 (9.0) | 7/10 (7.0) |
| 9. Resource Bounds Feasibility | 10% | 10/10 (10.0) | 8/10 (8.0) | 7/10 (7.0) | 8/10 (8.0) | 9/10 (9.0) | 8/10 (8.0) |
| **Total Score** | **100%** | **94.2 / 100** | **72.1 / 100** | **64.2 / 100** | **68.2 / 100** | **82.9 / 100** | **58.5 / 100** |

---

## Candidate Evaluation & Selection

- **Selected**: `ui.step_incrementor` (Score: **94.2/100**)

### Rejected Candidates

- **`ui.select_radio_group_item`** (72.1/100) — **Disqualified by duplication**, independent of score. The Phase 2AI comment for `ui.list_radio_group_items` explicitly documents the design intent: "every subsequent mutation capability (`ui.set_element_state`) must independently perform its own fresh, exact target resolution." Individual `AXRadioButton` elements are already reachable and mutable through the existing generic `ui.set_element_state` (Phase 2K, `kAXPressAction`) once discovered via `ui.list_radio_group_items`. A dedicated selection capability would duplicate shipped functionality.
- **`ui.select_browser_item`** (64.2/100) — Two-dimensional column+row addressing raises target-identity and post-mutation re-resolution complexity (selecting an item in one `AXColumn` of an `AXBrowser` can spawn a new column, changing the tree shape underneath the very verification step meant to observe it). `NSBrowser`/multi-column browser controls are also comparatively rare in modern macOS apps versus tables/outlines, which already have full list+select coverage.
- **`ui.set_level_indicator_value`** (68.2/100) — Most `AXLevelIndicator`/`AXRelevanceIndicator` instances are read-only display widgets; `kAXValueAttribute` writability is not reliably honored across apps for this role, so the "authoritative state/action" guarantee other Level 2 capabilities provide would be weak or app-dependent. Conceptually redundant with the already-shipped slider value-set model.
- **`ui.list_menu_bar_items`** (82.9/100) — A clean, valid Level 0 candidate, but it only adds descriptive enumeration; it does not close a mutation gap (`ui.select_menu_item`, Phase 2L, already supports acting on a named `menuBarTitle` directly). Read-only enumeration is already the best-represented category (28 of 53 capabilities); ranked below `ui.step_incrementor` because it does not resolve an existing enumerate/act asymmetry the way the selected candidate does.
- **`ui.set_date_field_value`** (58.5/100) — Highest implementation complexity and weakest authoritative-action guarantee of all candidates (locale-dependent multi-subfield parsing, no single AX primitive owns the whole value). Would also become partially redundant once `ui.step_incrementor` ships, since an `AXDateField`'s embedded `AXIncrementor` child becomes independently steppable through the very capability this phase adds.

---

## Architectural & Security Blueprint for `ui.step_incrementor`

- **Capability Identifier**: `ui.step_incrementor`
- **Tool Family**: `ui`
- **Risk Level**: Level 2 (`.level2UserApproval`) — reversible local action, explicit single-use approval required
- **Semantic API**: `AXUIElementPerformAction(target, kAXIncrementAction)` / `AXUIElementPerformAction(target, kAXDecrementAction)` — the native, purpose-built AX actions for `AXIncrementor` controls. Never `AXUIElementSetAttributeValue(kAXValueAttribute)` directly (that is the combo box/slider/splitter model; incrementors are driven by their own dedicated actions so a genuine value-change side effect fires, mirroring why `ui.set_element_state` uses `kAXPressAction` rather than a raw value write).
- **Target Resolution**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)` (no new resolver). Optional window scoping (`windowTitle`/`windowIdentifier`, same `AXWindow`-role match + stale-check pattern as every prior capability). Target `AXIncrementor` element resolved by `identifier`/`title` via the existing `collectMatches`/`snapshotIfMatches` primitives — 0 matches or 2+ matches fail closed (`AX_NO_MATCHING_ELEMENT` / `AX_AMBIGUOUS_TARGET`). Role restricted to `QAXIncrementorRolePolicy.allowedRoles = ["AXIncrementor"]` (reused unmodified from Phase 2BA — no new role policy needed).
- **Inputs**: `applicationName` (required), `role` (optional, must be `AXIncrementor`), `identifier`/`title` (at least one required), `windowTitle`/`windowIdentifier` (optional), `direction` (required: `"increment"` or `"decrement"`, no blind toggle), `steps` (optional, default `1`, bounded `1...20`).
- **Idempotency**: Before dispatch, reads `kAXValueAttribute` plus `kAXMinValueAttribute`/`kAXMaxValueAttribute`. If the current value is already at the bound implied by the requested direction, returns `changeKind: .alreadyAtBound` and performs **zero** AX actions — the same no-op discipline as `ui.select_combo_box_item`'s `.alreadySelected` and `ui.set_splitter_position`'s `.alreadyDesired`.
- **Verification**: New `QVerificationStrategy.axIncrementorValueMovedAsDesired` independently re-resolves the target and re-reads `kAXValueAttribute` fresh (never trusting the dispatch call's own `AXError` return). `.verified` requires the freshly observed value to have moved strictly in the requested direction relative to the value captured immediately before mutation (or, for the already-at-bound no-op path, to be unchanged). An unreadable/unresolvable target after mutation is always `.failed`, never assumed successful.
- **Approval**: Explicit single-use approval bound to `QExecutionIdentity`, no standing grant, no persisted authorization, no automatic reauthorization after restart — identical model to every other Level 2 capability.
- **Recovery**: Observe-first — a retry independently re-reads the current value before deciding whether any further action is needed, never blindly replaying steps.
- **Resource Bounds**: Single target element only (no traversal/enumeration in the mutation path itself); `steps` capped at 20 per call; each individual AX action re-checks the bound and stops early if the incrementor reaches its min/max before the requested step count is exhausted (never spins past the control's own reported range).
- **Privacy Model**: Outcome carries only numeric values (current/previous `Double`) and a structural `targetIdentity` string (application/role/identifier/label) — no raw `AXUIElement` pointers, no memory addresses, no screen coordinates, ever written to durable state, audit log, or model output.
