# Phase 2BH — Capability Roadmap (DISCOVERY ONLY)

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) test plan for the next capability. See the explicit
statement at the end of this file.

## Baseline
- **Commit**: `c4e346d`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BG (Semantic Focused Element Read — `ui.read_focused_element`)

---

## Authoritative Capability Inventory
The repository contains exactly **55 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection (`grep -c '": ("'`), not any historical report or the prompt's own summary list.

Full enumeration, extracted directly from source (`grep -oE '"[a-z_]+\.[a-z_]+": \("[a-z]+", \.[a-zA-Z0-9]+\)'`):

- **Level 0 Read-Only** (29): `system.running_apps`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes`, `ui.list_rulers`, `ui.list_combo_box_items`, `system.clipboard.read`, `ui.read_focused_element`
- **Level 1 Safe Local Action** (3): `ui.open_app`, `fs.write_sandbox`, `ui.activate_application`
- **Level 2 User Approval Required** (21): `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`, `ui.select_combo_box_item`, `ui.step_incrementor`, `system.clipboard.write`
- **Level 3 High Risk** (2): `app.quit`, `ui.close_window`

**Total**: 29 + 3 + 21 + 2 = **55** ✓ (matches source-derived count and expected baseline)

Note: `system.clipboard.read`/`system.clipboard.write` and `ui.read_focused_element` are listed above under their correct levels — the phase-numbered comment blocks in the registry are not in strict level-grouped order, so this breakdown is derived directly from the extracted `(toolFamily, level)` pairs, not from re-reading old phase comments.

---

## SDK & Architecture Discovery

**SDK sources inspected** (live, at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`):
- `ApplicationServices.framework` → `HIServices.framework`: `AXRoleConstants.h` (94 roles enumerated fresh via direct grep, re-verified against the full 55-capability registry), `AXAttributeConstants.h` (152 attribute constants enumerated fresh; cross-referenced against the entire `q-runtime` tree with `grep -rc` per-constant to determine genuine usage — not assumed from prior reports), `AXActionConstants.h` (11 action constants — `kAXConfirmAction`, `kAXCancelAction`, `kAXDecrementAction`, `kAXIncrementAction`, `kAXPickAction`, `kAXPressAction`, `kAXRaiseAction`, `kAXShowAlternateUIAction`, `kAXShowDefaultUIAction`, `kAXShowMenuAction`; note `kAXAcceptAction` is NOT a real symbol in this SDK — the header's own comment reads *"Don't know if this is still correct. Is this what used to be kAXAcceptAction?"*, meaning only `kAXConfirmAction`/`kAXCancelAction` exist where an "accept/cancel" pair might be assumed), `AXUIElement.h`, `AXValue.h`.
- **Methodology correction applied mid-discovery**: an initial `grep -rc "$attr" file` loop silently mis-reported due to `-r` prefixing filenames onto single-file grep output, masking real zero-counts as non-zero. Caught and corrected by re-running the sweep across the whole `q-runtime/` directory with per-file count summation — the corrected sweep is what the findings below are based on. Recorded here so a future phase does not have to rediscover this quirk.

**Architecture inspected**: `QModelPlanSchema.swift` (full registry, freshly extracted), `QBridgeAdapters.swift` (10,000+ lines — read the `AXUIElementCreateApplication(pid)` usage pattern shared by every list/read capability, `ui.set_application_hidden`'s actual implementation, `ui.list_windows`'s `QAXWindowMetadata` output shape, `QAXElementReadRolePolicy`, `resolveExactRunningApplication`), `QExecutionService.swift`, `QActionVerification.swift`, `QPlanExecutor.swift`, `QPermissionGate`, and the existing test suites named in this phase's brief.

**Key finding #1 — application-level AX state has zero read coverage**: `kAXFrontmostAttribute`, `kAXHiddenAttribute`, `kAXMainWindowAttribute`, and `kAXFocusedWindowAttribute` are four real, documented, adjacent AX attributes (grouped together in `AXAttributeConstants.h` immediately after `kAXMenuBarAttribute`/`kAXWindowsAttribute`, which this codebase already reads on the exact same `AXUIElementCreateApplication(pid)` element for `ui.list_menu_items`/`ui.list_windows`) that are **never read anywhere in this codebase**. Cross-checked against the actual implementation of `ui.set_application_hidden` (`QExecutionService.executeSetApplicationHidden`): it uses `NSRunningApplication.isHidden`/`.hide()`/`.unhide()` — a wholly different, non-AX API — never `kAXHiddenAttribute`. `ui.activate_application` similarly uses `NSRunningApplication.activate()`, never AX. This means: (a) `kAXHiddenAttribute`/`kAXFrontmostAttribute` genuinely duplicate information already available via `NSRunningApplication.isHidden`/`NSWorkspace.shared.frontmostApplication` — included for completeness, not because they unlock new facts; (b) `kAXMainWindowAttribute` is *partially* redundant with `ui.list_windows`'s existing per-window `main: Bool?` field (`QAXWindowMetadata`) — you can already determine the main window by enumerating and filtering, just not in one direct read; (c) `kAXFocusedWindowAttribute` is **the one genuinely novel fact** — `ui.list_windows`'s `QAXWindowMetadata` has no `focused` field at all, and `ui.read_focused_element` (Phase 2BG) returns the focused *element*, not which *window* currently holds that focus as an app-level, directly-queryable fact independent of already knowing/guessing a window title to test against.

**Key finding #2 — `kAXTitleUIElementAttribute`/`kAXServesAsTitleForUIElementsAttribute` are unused**: a real, standard AppKit-wired linkage (a form field's associated descriptive label, e.g. an `NSTextField` wired via `accessibilityTitleUIElement`/Interface Builder's label-to-control connection) that lets an element report *which other element serves as its label* — distinct from the element's own `kAXTitleAttribute`, which is frequently empty for fields whose visible label is a separate, adjacent static-text view. No existing capability surfaces this linkage.

**Key finding #3 — several attractive-looking AX actions are unusable for a new capability, and the header itself signals why**: `kAXPickAction` is explicitly listed under an `@group Obsolete Actions` header — building a new capability on a documented-obsolete action would violate architectural soundness even though the symbol still compiles. `kAXConfirmAction`'s own doc comment reads *"Simulate pressing Return in the UIElement"* and `kAXCancelAction`'s reads *"Simulate a Cancel action"* — both are legitimate `AXUIElementPerformAction` dispatches (never `CGEvent`/keyboard simulation), but their documented semantics as *simulating* a keystroke/click sit close enough to this program's hard "no keyboard simulation" boundary, and — more concretely — neither has an authoritative, independently-re-readable boolean state to verify against (pressing "cancel" on an app-defined dialog has an arbitrary, app-specific effect with no generic postcondition to check), the same verification-authority problem that sank `ui.set_window_zoomed` in Phase 2BG. `kAXRaiseAction` and `kAXShowMenuAction` are both marked `/* Need discussion for following */` in the header with empty `@discussion` blocks — genuinely under-specified by Apple's own documentation. None of these were elevated to full candidate status this round (see Rejected Candidates).

**Other findings**: `kAXColumnHeaderUIElementsAttribute`/`kAXRowHeaderUIElementsAttribute` (table headers — still unused, still viable; carried forward from Phase 2BG's own runner-up, `ui.list_table_columns`, which was never implemented), `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (window default/cancel button identity — still unused; carried forward from Phase 2BG's candidate #3), `kAXURLAttribute` (still unused; carried forward from Phase 2BG's candidate #4, same fixture-availability caveat still applies), `AXGrid`/`AXCell` roles (never referenced by any role policy in this codebase — a genuinely uncovered control family, but see Rejected Candidates for the fixture-reliability concern), `AXRatingIndicator` role (never referenced — see Rejected Candidates), `kAXModalAttribute` (a window's modal state — a plausible enrichment field for `ui.list_windows`'s existing output, not a standalone capability, so not elevated to candidate status on its own).

---

## Existing Capability Coverage (verified against source, not the prompt's list)
Application-level: `ui.open_app` (launch), `ui.activate_application` (foreground, Level 1), `ui.set_application_hidden` (Level 2), `app.quit` (Level 3), `system.running_apps` (existence only — names, no state). **No read of an application's own hidden/frontmost/main-window/focused-window state exists.**

Window-level: `ui.list_windows` (enumerate, with per-window minimized/main), `ui.set_window_minimized`, `ui.set_window_main`, `ui.set_window_full_screen`, `ui.close_window`. **No read of a window's default/cancel button, no per-window `focused` field, no column-header-style structural enrichment for any container.**

Element-level: `ui.read_element_value` / `ui.read_focused_element` (read), `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.set_slider_value`, `ui.focus_element`, `ui.toggle_disclosure`. **No capability reads an element's associated label (`kAXTitleUIElementAttribute`) or its URL (`kAXURLAttribute`).**

Container/collection families fully covered (enumerate + where applicable, select): menus, popups, tables (rows only — not columns), outlines, tabs, radio groups, toolbars, segmented controls, sheets (dialogs + actions), split panes, browser columns, popovers, color wells, progress indicators, level indicators, incrementors, combo boxes (+ items + selection), rulers.

---

## Candidates

### 1. `ui.read_application_state` — SELECTED
- **Purpose**: Reports a named running application's own hidden/frontmost state and, where present, the title/identifier of its current main window and current focused window — the first capability giving the model any read visibility into an application's own AX-level state, complementing the write-only `ui.set_application_hidden`/`ui.activate_application` pair with the read counterpart neither currently has.
- **Level**: 0 (Read-Only).
- **AX role(s)**: `AXApplication` (target, via `AXUIElementCreateApplication(pid)` — the exact same element `ui.list_windows`/`ui.list_menu_items` already resolve); referenced windows read only for `title`/`AXIdentifier` (structural identity, never further descended into).
- **AX attribute(s)**: `kAXHiddenAttribute`, `kAXFrontmostAttribute` (booleans — included for completeness/consistency since they sit on the same already-resolved element at zero extra cost, though both are also obtainable via `NSRunningApplication.isHidden`/`NSWorkspace.shared.frontmostApplication`, honestly noted as not uniquely new information); `kAXMainWindowAttribute` (partially redundant with `ui.list_windows`'s existing per-window `main` field — a direct single-attribute route to the same fact); `kAXFocusedWindowAttribute` (**the genuinely novel fact** — no existing capability exposes which window, if any, currently holds focus within a named application).
- **AX action(s)**: none.
- **Semantic API**: `AXUIElementCreateApplication(pid)` (pid from `resolveExactRunningApplication`, unmodified) → four direct `AXUIElementCopyAttributeValue` reads → for the two window-reference attributes, one further `AXUIElementCopyAttributeValue(kAXTitleAttribute)`/`AXIdentifier` read on the referenced window element only (no recursion beyond that single hop).
- **Target resolution**: `applicationName` resolved exactly via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `applicationNotAvailable`; multiple matches → `ambiguousTarget`. No window/element-level targeting is needed for the boolean fields; the two window-reference fields resolve to *whichever* window the OS itself reports as main/focused (a value the OS provides, never model-guessed), read only for its own title/identifier — never treated as an actionable target for a later mutation.
- **Independent verification**: Level 0 — verification confirms the read itself succeeded and produced a structurally valid result, mirroring every other Level 0 capability's `<X>EnumerationSucceeded`-style discipline (a new `applicationStateReadSucceeded` strategy), never a bare `{ true }`.
- **Mutation**: none. **Approval**: none required (Level 0). **Recovery**: none (no side effects, always safe to retry).
- **Resource-bound strategy**: a fixed four attribute reads on one application-root element, plus at most two further single-attribute reads on directly-referenced window elements — zero recursive traversal, zero enumeration, tied with `ui.read_focused_element` for the tightest resource bound of any capability in this program.
- **Privacy implications**: booleans plus (optionally) window titles — titles are already exposed by the shipped `ui.list_windows`, so this introduces no new exposure class; no element values, no arbitrary text, no user content of any kind.
- **Why not already covered**: every existing application-level capability is write-only (`open_app`/`activate_application`/`set_application_hidden`/`quit`) or existence-only (`system.running_apps`); no capability lets the model confirm the *current* state before or after acting on it.
- **Known macOS limitations**: `kAXMainWindowAttribute`/`kAXFocusedWindowAttribute` may legitimately resolve to nothing for a background-only or newly-launched application with no window yet — a valid, honestly-reported empty result, never fabricated.
- **Real-E2E fixture strategy**: a plain `NSWindow`, `window.makeMain()`/`makeKeyAndOrderFront`, confirm `AXUIElementCreateApplication(getpid())`'s `kAXMainWindowAttribute` resolves to that exact window's title.
- **Implementation complexity**: LOW — no new role policy, no new resolver, structurally almost identical to `ui.read_focused_element`'s own shape (singleton root, zero traversal).
- **Security risk**: LOW — read-only, zero mutation surface, tightest resource bound tied with the previous phase's own capability.

### 2. `ui.list_table_columns` — Runner-up (carried forward from Phase 2BG, still unimplemented)
- **Purpose**: Enumerates a table's column headers (titles), complementing the already-shipped `ui.list_table_rows`. Re-verified this phase: still genuinely unimplemented — `ui.list_table_rows` still has no column-header counterpart.
- **Level**: 0 (Read-Only).
- **AX role(s)**: `AXTable` (target), `AXColumn` (children read).
- **AX attribute(s)**: `kAXColumnHeaderUIElementsAttribute`, `kAXColumnsAttribute`, `kAXTitleAttribute`, optionally `kAXSortDirectionAttribute` per column.
- **Target resolution**: identical pattern to `ui.list_table_rows` — exact app/window resolution, then exactly one `AXTable` by identifier/title.
- **Verification**: read-succeeded evidence (aggregate column count only).
- **Mutation/Approval/Recovery**: none/none/none.
- **Resource bound**: bounded column-count ceiling (e.g. 32), same style as existing `list_*` ceilings.
- **Privacy**: column header titles are structural metadata, low risk.
- **Why it loses to #1**: still a *dependent* capability requiring the model to already know a table exists and have its identifier — the same limitation every existing capability except `ui.read_focused_element`/`ui.read_application_state` shares.

### 3. `ui.read_element_label` — NEW
- **Purpose**: Reads the label text describing a semantically-identified target element via `kAXTitleUIElementAttribute` — e.g. resolving an `NSTextField`'s associated "Email:" static-text label without already knowing that label's own identifier.
- **Level**: 0 (Read-Only).
- **AX role(s)**: any target role already on `QAXElementReadRolePolicy`'s allowlist (reused unmodified); the *referenced* label element's own role independently re-validated against the same policy before its text is exposed — never trusted merely because the reference resolved.
- **AX attribute(s)**: `kAXTitleUIElementAttribute` (single-element reference, not an array) on the target, then `kAXValueAttribute`/`kAXTitleAttribute` on the referenced element via the same polymorphic reader `readElementValue` already uses.
- **Semantic API**: `AXUIElementCopyAttributeValue(target, kAXTitleUIElementAttribute)` → one single-hop follow, never recursive.
- **Target resolution**: identical to `ui.read_element_value` (app/window/role/identifier-or-title), plus the one-hop label reference.
- **Verification**: read-succeeded evidence. **Mutation/Approval/Recovery**: none/none/none.
- **Resource bound**: one base target resolution (existing bounded search) + exactly one additional single-attribute reference read — zero additional traversal.
- **Privacy**: exposes label text — structural form-field labeling, the same risk class `ui.read_element_value` already accepts; the referenced element's role is independently policy-checked, so a label reference can never be used to smuggle a secure field's content out under a different attribute name.
- **Why not already covered**: `ui.read_element_value` reads a target's *own* value/title; it has no path to the *separate* element that visually labels it when the target's own title is empty (the common case for a well-built accessible form).
- **Known limitations**: `kAXTitleUIElementAttribute` support is inconsistent outside Interface-Builder-wired or explicitly-`accessibilityTitleUIElement`-set controls; a plain, unwired `NSTextField` will report no label reference — a valid empty result, not an error.
- **Why it loses to #1 and #2**: narrower, convenience-level gap (a label is often independently readable today via `ui.read_element_value` if you already know or can guess its identifier) versus #1's foundational, zero-prior-knowledge application-state gap.

### 4. `ui.read_window_default_button` (carried forward from Phase 2BG, still unimplemented)
- **Purpose**: Reports the identity of a window's designated default/cancel button (what activates on Enter/Escape).
- **Level**: 0. **AX role(s)**: `AXWindow` (target), `AXButton` (returned identity only).
- **AX attribute(s)**: `kAXDefaultButtonAttribute`, `kAXCancelButtonAttribute`.
- **Verification/Mutation/Approval/Recovery**: read-succeeded evidence / none / none / none.
- **Resource bound**: single window, two fixed attribute reads.
- **Privacy**: button title/identifier only — low risk.
- **Why it loses**: narrow, edge-case utility ("what does pressing Enter do") — re-scored this phase with no new information changing its Phase 2BG assessment.

### 5. `ui.read_element_url` (carried forward from Phase 2BG, still unimplemented, re-scored)
- **Purpose**: Reads `kAXURLAttribute` of a semantically-identified element (links, some images/fields).
- **Level**: 0. **AX role(s)**: primarily `AXLink` (already read-allowlisted).
- **Why it loses**: the identical fixture-availability concern flagged in Phase 2BG remains true today — no confirmed, reliable native-AppKit-only control (outside WebKit/`AXLink` contexts) that emits `kAXURLAttribute` at the element level; re-verified, not merely copy-pasted forward, and the concern still holds.

### 6. `ui.list_grid_items` — REJECTED (fixture-reliability risk)
- **Purpose**: Enumerate `AXGrid`/`AXCell` elements (e.g. `NSCollectionView`-backed grids).
- **Level**: 0 (would be).
- **Rejection reason**: `AXGrid`/`AXCell` are real SDK roles never referenced anywhere in this codebase, but Apple does not guarantee `NSCollectionView` emits `AXGrid` — many collection views report as a plain `AXScrollArea` containing generic `AXGroup`/button hierarchies instead, role emission is empirically inconsistent across macOS versions and layout configurations. A capability whose real-fixture E2E test cannot be reliably constructed from a standard AppKit control carries meaningfully higher implementation risk than its scoring dimensions alone suggest — the same category of concern (though more severe) that downgraded `ui.read_element_url` in Phase 2BG. Aggregate score 79.0/100.

### 7. `ui.list_rating_indicators` — REJECTED (no native fixture path)
- **Purpose**: Enumerate `AXRatingIndicator` elements (star-rating widgets, e.g. Mail/Photos/Music).
- **Level**: 0 (would be).
- **Rejection reason**: `AXRatingIndicator` is a real, distinct SDK role — but unlike `AXLevelIndicator`/`AXProgressIndicator` (both backed by real, public `NSLevelIndicator`/`NSProgressIndicator` AppKit classes this program already ships enumeration for), **no public `NSRatingIndicator` class exists in AppKit**. Every real-world emitter of this role is a private/custom view inside Apple's own first-party apps, with undocumented, unreliable AX wiring — there is no standard control this program could use to build a genuine, non-fabricated real-macOS E2E fixture. Aggregate score 79.0/100, entirely on the strength of trivial architectural mirroring (identical shape to `ui.list_level_indicators`) — overridden by having essentially zero real-world fixture path, a harder version of candidate #6's concern.

### Considered but not elevated to full candidate status (AX actions)
- **`kAXConfirmAction`/`kAXCancelAction`** (dialog accept/cancel): both are legitimate `AXUIElementPerformAction` dispatches, but (a) their own SDK doc comments describe them as *simulating* Return/Cancel keystrokes — uncomfortably close to this program's hard "no keyboard simulation" boundary even though the dispatch mechanism itself is a real AX action, and (b) neither has an authoritative, independently-re-readable postcondition to verify against — an app-defined dialog's response to "cancel" is arbitrary and non-generic, the identical verification-authority problem that sank `ui.set_window_zoomed` in Phase 2BG. Not elevated to a scored candidate.
- **`kAXPickAction`**: explicitly listed under `AXActionConstants.h`'s own `@group Obsolete Actions` header. Never a sound foundation for a new capability.
- **`kAXRaiseAction`/`kAXShowMenuAction`**: both marked `/* Need discussion for following */` with empty `@discussion` blocks in the live SDK header — under-specified by Apple's own documentation; `kAXRaiseAction` in particular (raising a window without making it main) would face the same "no authoritative boolean state to verify" problem as the rejected zoom capability. Flagged as a candidate to revisit only if Apple's documentation for these ever becomes concrete.

---

## Scoring Matrix (9-Dimension Model, weights sum to 100%)

| Dimension | Weight | `ui.read_application_state` | `ui.list_table_columns` | `ui.read_element_label` | `ui.read_window_default_button` | `ui.read_element_url` | `ui.list_grid_items` | `ui.list_rating_indicators` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic API authority | 12% | 10 (12.0) | 9 (10.8) | 9 (10.8) | 8 (9.6) | 8 (9.6) | 7 (8.4) | 6 (7.2) |
| 2. Deterministic targeting | 12% | 10 (12.0) | 9 (10.8) | 9 (10.8) | 9 (10.8) | 9 (10.8) | 8 (9.6) | 8 (9.6) |
| 3. Deterministic verification | 12% | 9 (10.8) | 9 (10.8) | 9 (10.8) | 8 (9.6) | 8 (9.6) | 8 (9.6) | 7 (8.4) |
| 4. Security / risk suitability | 12% | 10 (12.0) | 10 (12.0) | 9 (10.8) | 10 (12.0) | 9 (10.8) | 9 (10.8) | 10 (12.0) |
| 5. Architectural fit | 10% | 10 (10.0) | 9 (9.0) | 9 (9.0) | 8 (8.0) | 9 (9.0) | 8 (8.0) | 9 (9.0) |
| 6. Recovery / crash-safety fit | 10% | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) |
| 7. Resource-bounding feasibility | 10% | 10 (10.0) | 9 (9.0) | 9 (9.0) | 10 (10.0) | 10 (10.0) | 8 (8.0) | 10 (10.0) |
| 8. Privacy characteristics | 12% | 10 (12.0) | 9 (10.8) | 8 (9.6) | 9 (10.8) | 8 (9.6) | 8 (9.6) | 9 (10.8) |
| 9. Product / capability value | 10% | 9 (9.0) | 8 (8.0) | 7 (7.0) | 6 (6.0) | 6 (6.0) | 5 (5.0) | 2 (2.0) |
| **Total** | **100%** | **97.8** | **91.2** | **87.8** | **86.8** | **85.4** | **79.0** | **79.0** |

**Winner**: `ui.read_application_state` (97.8) — highest score on 6 of 9 dimensions, including a perfect 10/10 on semantic API authority, deterministic targeting, security suitability, architectural fit, recovery fit, resource bounding, and privacy. Closes a genuine, foundational, previously-undiscussed gap (application-level state has zero read coverage across all 55 shipped capabilities).

**Runner-up**: `ui.list_table_columns` (91.2) — a solid, low-risk, carried-forward Level 0 candidate still genuinely unimplemented after two phases; loses because it remains a dependent capability (must already know a table exists) rather than a foundational, zero-prior-knowledge one.

**Rejected for fixture-reliability risk**: `ui.list_grid_items` (79.0), `ui.list_rating_indicators` (79.0) — both technically scoreable but face real-world AX-role-emission unreliability (grid) or the complete absence of a public AppKit class to build a genuine fixture from (rating indicator).
**Not elevated to scored-candidate status**: `kAXConfirmAction`/`kAXCancelAction` (simulation-adjacent semantics + no verifiable postcondition), `kAXPickAction` (documented obsolete), `kAXRaiseAction`/`kAXShowMenuAction` (undocumented by Apple's own header).

---

## Security Assessment (Section 7 Gate Walk-Through — `ui.read_application_state`)

| Gate | Status |
|---|---|
| Exact application resolution | ✅ `resolveExactRunningApplication(named:)` reused unmodified |
| Exact window resolution where applicable | N/A for the boolean fields; the two window-reference fields resolve to whichever window the OS itself designates, never a model-supplied window guess |
| Exact semantic element resolution | ✅ resolution *is* the read itself (the application root element is a singleton per process) |
| Fail-closed on zero matches | ✅ zero running-app matches → fail closed |
| Fail-closed on ambiguous matches | ✅ multiple matches → fail closed, never `.first` |
| No fuzzy targeting | ✅ exact application-name matching only, reused unmodified |
| No coordinate targeting / CGEvent / keyboard / mouse simulation | ✅ pure AX attribute reads |
| No raw AX pointer persistence | ✅ same snapshot-then-discard discipline as all 55 shipped capabilities |
| No standing authorization | N/A — Level 0, no approval involved |
| Level 2/3 explicit approval | N/A — Level 0 |
| Observation-first recovery | N/A — no mutation, no replay |
| Uncertain physical state fails closed | ✅ an unreadable attribute is reported as absent (`nil`), never fabricated as a default |
| Independent post-mutation verification | N/A for a read, but the equivalent "read genuinely succeeded" discipline is preserved |
| No security bypass through replanning | ✅ read-only; cannot itself substitute for an approved mutation |

All applicable gates pass. No gate is violated or requires a design compromise.

---

## Privacy Assessment
- Exposes only: two booleans (`hidden`, `frontmost`) and up to two window titles/identifiers (`mainWindow`, `focusedWindow`) — no element values, no arbitrary text, no user-entered content of any kind.
- Window titles are already exposed by the shipped `ui.list_windows` — this introduces no new exposure class, only a more direct route to two of the same facts (`main`) plus one genuinely new fact (`focused`), which carries the identical risk profile as `main` (a window's title, already accepted as safe structural metadata).
- No secure-field, password, credential, OTP, or payment-data exposure risk exists at all for this candidate — its entire output surface is two booleans and two window identity strings.
- No sensitive-role encounter is possible: the target is always the application root element itself, never a leaf control.

---

## Resource Bounds (concrete, pre-committed)
- **Max traversal depth**: 0 for the application element itself; 1 for the single-hop window-reference follow (never descends further into that window's own children).
- **Max node count**: 1 application element + at most 2 referenced window elements (main, focused) = 3 elements maximum ever touched in a single call.
- **Max direct children read**: 0 — no children of the application or the referenced windows are ever enumerated.
- **Max actions per call**: 0 — read-only.
- **Max polling duration**: 0 — a fixed set of synchronous attribute reads, no polling loop.
- **Max returned items**: 1 structured result (booleans + up to two window identity strings) — never a collection.
- **Max payload size**: window titles only, no truncation ceiling needed beyond what `ui.list_windows` already accepts implicitly (window titles are not free-form user content).

---

## Proposed Implementation Contract (for the eventual implementation phase, not now)
- **Capability ID**: `ui.read_application_state`
- **Risk level**: Level 0 (Read-Only)
- **Semantic AX API**: `AXUIElementCreateApplication(pid)` → `AXUIElementCopyAttributeValue` for `kAXHiddenAttribute` (Bool), `kAXFrontmostAttribute` (Bool), `kAXMainWindowAttribute` (AXUIElement?), `kAXFocusedWindowAttribute` (AXUIElement?) → for each present window reference, one further `AXUIElementCopyAttributeValue(kAXTitleAttribute)` / `AXIdentifier` read only.
- **Target chain**: `applicationName` → `resolveExactRunningApplication(named:)` (unmodified) → `processIdentifier` → `AXUIElementCreateApplication(pid)`. No window/element role policy needed for the boolean fields; the two window references are read for identity only, never treated as a target for any subsequent action.
- **Role policy**: none new — the target is always the application root; the referenced windows are read for `kAXTitleAttribute`/`AXIdentifier` only, the same safe, content-free fields every other window-identity read already exposes (no value/content exposure risk, so no `QAXElementReadRolePolicy` gating is needed for this specific pair of fields).
- **Input validation**: `applicationName` required, non-empty; no other parameters (unlike `ui.read_focused_element`, no `windowTitle` scoping parameter is needed — there is nothing to scope, since this reads exactly the one application-root element).
- **Output contract**: `isHidden: Bool`, `isFrontmost: Bool`, `mainWindowTitle: String?`, `mainWindowIdentifier: String?`, `focusedWindowTitle: String?`, `focusedWindowIdentifier: String?`.
- **Verification**: new `QVerificationStrategy.applicationStateReadSucceeded(applicationName: String)` — checks the execution result's own `success` flag, evidence carries only `application=<name> status=verified`, never restating the booleans or window titles in evidence text (mirroring every Level 0 enumeration's aggregate-only evidence discipline).
- **Approval**: none (Level 0), routed through the real `QPermissionGate`, not bypassed.
- **Recovery**: none — a read has no side effects; an uncertain in-flight step fails closed to `pending`, a retry is always safe.
- **Privacy**: booleans + window identity strings only, as detailed above.
- **Bounds**: as detailed in Resource Bounds above.

---

## Proposed Test Plan (NOT IMPLEMENTED)

### Focused tests (Level 0 minimum: 15+; proposing 20)
1. Registration under toolFamily `ui` (or `app` — to be confirmed against the closest architectural precedent at implementation time; unlike `ui.read_element_value`/`ui.read_focused_element`, this capability exposes no free-form content, so the `perception` sanitize-before-persist boundary is not obviously required — an implementation-time judgment call, not a discovery-phase decision), Level 0 Read-Only by default
2. Parser accepts a valid step with only `applicationName`
3. Risk level override rejected in both directions (fails closed)
4. Missing `applicationName` fails closed
5. Non-existent application fails closed (`AX_APPLICATION_NOT_AVAILABLE`)
6. Ambiguous application resolution fails closed (`AX_AMBIGUOUS_TARGET`)
7. `isHidden`/`isFrontmost` correctly reflect a real running application's state
8. `mainWindowTitle`/`mainWindowIdentifier` correctly resolve for an app with a real main window
9. `focusedWindowTitle`/`focusedWindowIdentifier` correctly resolve for an app with real window focus
10. An application with no windows at all yields `nil` for both window fields, never a fabricated value
11. Missing Accessibility trust fails closed with `AX_PERMISSION_DENIED` before any application resolution is attempted
12. No new role policy is introduced (structural/documentation check)
13. Verification strategy — read-succeeded evidence structure (never a bare `{ true }`)
14. `QPlanExecutor` strategy mapping for `ui.read_application_state`
15. Durable state boundary excludes raw pointers and memory addresses
16. No approval gate is invoked for this Level 0 capability
17. Real macOS accessibility trust guard probe runs safely without crashing
18. Forbidden physical automation API audit (no `CGEvent`/`NSEvent`/keyboard/mouse/`osascript`/`AppleScript`/`Process(`)
19. No tree traversal beyond the single-hop window-reference follow (resource bound)
20. Repeated reads are idempotent (zero side effects, same result for unchanged state)

### Related regression suites that must remain green
- `QSemanticElementFocusTests.swift`, `QSemanticFocusedElementReadTests.swift` (share `resolveExactRunningApplication`)
- `QApplicationResolutionHardeningTests.swift` (shares the exact application-resolution contract)
- Full regression suite (`scripts/test-pace.sh`, currently 3110/3110 green as of Phase 2BG)

### Real macOS E2E strategy
Build a plain `NSWindow`, call `window.makeKeyAndOrderFront(nil)` and `window.makeMain()` on `@MainActor`, then invoke the new bridge method scoped to the current test-host application and confirm `mainWindowTitle` resolves to that exact window's title. A second fixture with two windows (one made main, one not) proves the reference is unambiguous.

### TCC limitation (anticipated)
Based on this exact isolated/unsigned test host's behavior in every prior phase (most recently confirmed for Phase 2BG via direct `.xcresult` timing evidence — every `AXIsProcessTrusted()`-guarded test completed in 0.001s), `AXIsProcessTrusted()` is expected to evaluate `false` in this environment. The proposed E2E test would take the existing `guard AXIsProcessTrusted() else { return }` early-exit path and pass trivially without exercising the real dispatch — to be honestly reported as **BLOCKED**, not fabricated as a real-world pass, exactly as every prior phase's own live fixture tests were.

---

## Implementation Constraints (for the eventual implementation phase, not now)
- Reuse `resolveExactRunningApplication(named:)` verbatim — no new resolver.
- Reuse the exact `AXUIElementCreateApplication(pid)` pattern already present in `ui.list_windows`/`ui.list_menu_items` — do not reinvent.
- No new role policy for the window-reference fields — they are read for identity (title/identifier) only, the same content-free fields every window-identity read already exposes.
- No new forbidden-API surface: no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, `AppleScript`/`osascript`, or `Process(`-based fallback.
- Confirm at implementation time whether `toolFamily` should be `"ui"` or `"app"` — this capability is application-scoped like `ui.activate_application`/`ui.set_application_hidden` (registered `"app"`), not element-scoped like most `"ui"` capabilities; a discovery-phase recommendation, not a decision, since the exact convention should be confirmed against the closest precedent at implementation time.

---

## Explicit Statement

**Phase 2BH is Discovery only.** Implementation has NOT started. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase.

*(This statement describes this document's own discovery phase and is preserved verbatim as the historical record of that phase. Implementation has since been completed under separate explicit approval — see [`PHASE_2BH_SEMANTIC_APPLICATION_STATE_READ.md`](./PHASE_2BH_SEMANTIC_APPLICATION_STATE_READ.md) for the full implementation contract, test results, and security/privacy audit.)*
