# Phase 2BM — Capability Roadmap

## DISCOVERY ONLY — NO IMPLEMENTATION

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) contract for the next capability. No production source file,
registry entry, executor, bridge, verification strategy, or test file has been created or
modified as part of this phase.

## Baseline
- **Commit**: `f50c302` (full: `f50c302b245085127278dd847c0dc9985b0eb007`)
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BL (Semantic Element Attribute Enumeration — `ui.list_element_attributes`)
- **Authoritative capability count**: **60**, confirmed by direct source extraction (`grep -c '": ("'` against `QModelPlanParser.registeredCapabilities`), not any historical report.

---

## Fresh SDK Discovery Evidence

Phases 2BG–2BL exhaustively swept `AXRoleConstants.h` (all 94 roles), `AXAttributeConstants.h` (all 152 attributes, multiple passes: raw name sweep, `Writable? Yes` sweep, section-grouping/obsolete-marking sweep), `AXActionConstants.h` (all 11 actions), and — as of Phase 2BL — **every one of the 35 extern functions in `AXUIElement.h`**. Re-sweeping any of these would not constitute genuine fresh discovery. This phase instead performed a **line-by-line inspection of `NSAccessibilityProtocols.h`** — the Swift/ObjC protocol-conformance surface AppKit controls implement — which prior phases (2BK, 2BL) had only superficially catalogued by filename, never actually enumerated protocol-by-protocol.

### Complete `NSAccessibilityProtocols.h` protocol inventory (21 protocols, all confirmed present in the installed SDK)

| Protocol | Assessment |
|---|---|
| `NSAccessibilityElement`, `NSAccessibilityGroup`, `NSAccessibilityButton`, `NSAccessibilitySwitch`, `NSAccessibilityRadioButton`, `NSAccessibilityCheckBox`, `NSAccessibilityStaticText`, `NSAccessibilityNavigableStaticText`, `NSAccessibilityProgressIndicator`, `NSAccessibilityStepper`, `NSAccessibilitySlider`, `NSAccessibilityImage` | All back roles/attributes already fully catalogued in Phases 2BG–2BL (`AXGroup`, `AXButton`, `AXSwitch`, `AXRadioButton`, `AXCheckBox`, `AXStaticText`, `AXProgressIndicator`, `AXIncrementor`/stepper, `AXSlider`, `AXImage`). No new attribute-level surface. |
| `NSAccessibilityTable`, `NSAccessibilityOutline`, `NSAccessibilityList`, `NSAccessibilityRow` | Back `ui.list_table_rows`/`ui.list_table_columns`/`ui.list_outline_items` (Phases 2AE, 2AF, 2BI). Two methods stand out as genuinely unused: `accessibilityVisibleRows`/`accessibilityVisibleColumns`/`accessibilitySelectedColumns` (→ `kAXVisibleRowsAttribute`/`kAXVisibleColumnsAttribute`/`kAXSelectedColumnsAttribute`) — the protocol's own comment labels these **"Advanced table accessibility"**. Assessed below. |
| **`NSAccessibilityContainsTransientUI`** | Backs `kAXShowAlternateUIAction`/`kAXShowDefaultUIAction` (both already rejected in Phase 2BJ as hover-simulation-adjacent) **and** `kAXAlternateUIVisibleAttribute` — a pure boolean *read* distinct from the rejected actions. Assessed fresh below (not previously separated from the action pair it accompanies). |
| `NSAccessibilityLayoutArea`, `NSAccessibilityLayoutItem` | Back `AXLayoutArea`/`AXLayoutItem` — a Canvas/drawing-surface abstraction (confirmed in the header's own `#pragma mark Layout Area (Canvas)`) with no concrete, common AppKit control (no public `NSLayoutArea` class exists; this is typically implemented ad hoc by custom drawing views like Pages/Keynote's canvas). No realistic native AppKit E2E fixture exists. **Rejected — no viable AppKit fixture.** |
| **`NSAccessibilityElementLoading`** (10.13+) | A lazy-loading/virtualization protocol for apps with huge or infinite content (e.g. a text view or table that does not materialize every element upfront) — `accessibilityElementWithToken:` returns REAL elements on demand. This is a **provider-side implementation detail** (how an app internally constructs its own AX tree) with no corresponding client-observable attribute, function, or action — it changes nothing about what an AX *client* like this program can query; the resulting elements are indistinguishable from any other `AXUIElementRef` once resolved. **Not a capability surface — out of scope.** |
| `NSAccessibility` (the umbrella protocol, `@pragma mark General` onward) | Re-declares the same attribute/action surface already fully catalogued via the C headers — the Swift/ObjC-side implementation of facts already known, not a new source of them. |

### Decisive finding #1 — `kAXAlternateUIVisibleAttribute` (read-only boolean) has near-zero utility for this program's execution model
Separated for the first time from the action pair it accompanies (`kAXShowAlternateUIAction`/`kAXShowDefaultUIAction`, both already rejected in Phase 2BJ), this attribute is a pure, real, non-obsolete boolean *read*: "is alternate/hover-revealed UI currently showing?" On reflection this has near-zero practical value for an agent-driven execution model *specifically because* this program categorically forbids simulating the mouse-hover interaction that is the only realistic way this state ever becomes `true` — an agent asking this question would receive `false` in virtually every real invocation. **Considered fresh this phase; not elevated to a scored candidate for weak utility, not for any security/architecture problem.**

### Decisive finding #2 — "visible rows/columns" is an enrichment to already-shipped capabilities, not a new one
`kAXVisibleRowsAttribute`/`kAXVisibleColumnsAttribute`/`kAXSelectedColumnsAttribute` are real, unused, and the protocol's own header explicitly labels them "Advanced table accessibility" — a genuinely useful bounded-by-viewport subset for very large tables. But this is architecturally an enrichment to `ui.list_table_rows`/`ui.list_table_columns`'s existing output (an additional filter mode or field), not a distinct semantic capability — the identical judgment this program has consistently applied to `kAXModalAttribute` (Phases 2BH–2BL: "enrichment to `ui.list_windows`, not standalone") is applied here for consistency rather than arbitrarily reversed. **Noted as a future maintenance-task opportunity, not scored as a new candidate.**

No obsolete, undocumented, or SDK-unavailable symbol was proposed as a target this phase — every protocol/attribute/method referenced above was confirmed present in the installed SDK by direct inspection.

---

## Full Current Capability Coverage (verified against source)

All 60 capabilities re-confirmed via direct extraction (`grep -oE '"[a-z_]+\.[a-z_]+": \("[a-z]+", \.[a-zA-Z0-9]+\)'`). Coverage map for the families most relevant to this phase's gap analysis:

| Family | Representative capability | Coverage status |
|---|---|---|
| Application state | `ui.read_application_state` (L0), `ui.set_application_hidden` (L2), `ui.activate_application` (L1) | Hidden/frontmost/main-window/focused-window fully covered. |
| Window operations | `ui.set_window_minimized`/`ui.set_window_main`/`ui.set_window_full_screen`/`ui.close_window` (L2/L3), `ui.list_windows` (L0, title/identifier/minimized/main per window) | **No read of a window's default/cancel button** — the gap this phase's winner closes. |
| Element inspection | `ui.read_element_value`/`ui.read_element_range`/`ui.read_focused_element`/`ui.list_element_actions`/`ui.list_element_attributes` (all L0) | Value, numeric range, systemwide focus, action vocabulary, and attribute vocabulary all covered — a genuinely complete self-orientation family as of Phase 2BL. |
| Container enumeration (24 capabilities) | `ui.list_table_rows`/`ui.list_table_columns`/`ui.list_outline_items`/`ui.list_tab_items`/`ui.list_radio_group_items`/`ui.list_segmented_control_items`/`ui.list_sheet_dialogs`/`ui.list_sheet_actions`/`ui.list_split_panes`/`ui.list_browser_columns`/`ui.list_toolbar_items`/`ui.list_color_wells`/`ui.list_progress_indicators`/`ui.list_level_indicators`/`ui.list_incrementors`/`ui.list_combo_boxes`/`ui.list_combo_box_items`/`ui.list_rulers`/`ui.list_menu_items`/`ui.list_popup_items`/`ui.list_popovers` | All L0, all exhaustively covered per family; `ui.list_ruler_markers` (the ruler *marker* sub-family) remains the one unimplemented carried-forward gap. |
| Selection mutations (7 capabilities) | `ui.select_menu_item`/`ui.select_popup_item`/`ui.select_tab`/`ui.select_table_row`/`ui.select_outline_row`/`ui.select_segmented_control_item`/`ui.select_combo_box_item` | All L2, all fully covered. |
| Numeric mutations | `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position`/`ui.set_scroll_position` | All L2, all fully covered; range-reading complement (`ui.read_element_range`) shipped Phase 2BJ. |

No duplicate or cosmetic alias was found or proposed against this inventory.

---

## Fresh Gap Analysis

### A. Element metadata/state
Systematically re-checked against this phase's own list: `label` (→ `ui.read_element_label`, carried forward, unimplemented), `description`/`help` (no dedicated gap beyond what `ui.read_element_value`'s title-or-description fallback already covers), `url` (→ `ui.read_element_url`, rejected repeatedly for fixture unreliability, re-confirmed unchanged), `selected`/`enabled`/`focused` (covered by `ui.read_focused_element` + per-family `isSelected`/`isEnabled` fields in every relevant `list_*` capability), `expanded` (covered by `ui.list_outline_items`), `hidden` (covered by `ui.read_application_state` at the app level; window-level hidden state is not a real AX concept distinct from minimized), `orientation` (a real, unused attribute — `kAXOrientationAttribute` — but with no clear, bounded standalone use case beyond enriching existing scroll-area/split-group/window enumerations; not elevated), `role/subrole` (already exposed structurally by every `list_*`/read capability's own output), `position/size` (explicitly forbidden — this program's hard rule against coordinate-based data), **`default-button semantics`** (→ **this phase's winner**), `title` (covered), `value-related state` (covered by `ui.read_element_value`/`ui.read_element_range`).

### B. Structural enumeration
`ui.list_ruler_markers` (carried forward) remains the one live, unimplemented gap. "Visible rows/columns" (Decisive Finding #2 above) is an enrichment opportunity, not a new capability. No unrepresented control family was found — every major AppKit control with a first-class AX role now has enumeration coverage.

### C. Semantic mutation
No new authoritative, deterministically-verifiable mutation gap was found this phase. Every `Writable? Yes` attribute in the SDK was already exhaustively catalogued in Phase 2BJ (six total; three already shipped as mutations, `kAXElementBusyAttribute`/`kAXSelectedTextRangeAttribute`/`kAXSelectedTextRangesAttribute` all previously rejected for weak agent value or privacy proximity, re-confirmed unchanged this phase).

### D. Native semantic actions
No new action gap was found. All 11 `AXActionConstants.h` entries were exhaustively evaluated across Phases 2BG–2BJ (3 in use, 8 rejected on simulation-adjacency/obsolescence/undocumented-behavior grounds, re-confirmed unchanged). `NSAccessibilityContainsTransientUI`'s action pair (`ShowAlternateUI`/`ShowDefaultUI`) is the Swift-protocol-level restatement of the same two already-rejected `AXActionConstants.h` actions — not a new finding.

---

## Candidates

### 1. `ui.read_window_default_button` — SELECTED (carried forward from Phases 2BG–2BL, now selected after genuine fresh elimination of every alternative)
1. **Capability ID**: `ui.read_window_default_button`
2. **Risk level**: 0 (Read-Only)
3. **AX role**: `AXWindow` (`QAXWindowRolePolicy`, reused unmodified from Phase 2U).
4. **AX attribute/action**: `kAXDefaultButtonAttribute`, `kAXCancelButtonAttribute` — both re-verified fresh this phase: `kAXDefaultButtonAttribute` is documented *"Required for all window elements that have a default button"* (a strong authority claim, the identical class of wording already relied upon for `kAXModalAttribute`'s "Required for all window elements"), grouped in the SDK header's legitimate main attribute section, `Writable? No`.
5. **Native AppKit counterpart**: `NSWindow.defaultButtonCell` — a real, public, trivially-settable property.
6. **Current coverage status**: zero overlap — `ui.list_windows` exposes title/identifier/minimized/main per window; no capability surfaces which button activates on Enter/Escape.
7. **Exact resolution strategy**: identical to every other `AXWindow`-targeting capability — exact application resolution (`resolveExactRunningApplication`, unmodified), then exactly one `AXWindow` by identifier/title via `collectMatches`/`snapshotIfMatches`. Zero/ambiguous matches fail closed.
8. **Verification strategy**: the read's own success/failure — a well-formed reference (or absence) was obtained.
9. **Privacy implications**: exposes only the referenced button's own title/identifier (structural UI labels like `"OK"`/`"Cancel"`) — never content, never a value.
10. **Resource bounds**: single window, two fixed reference reads, each followed by exactly one further title/identifier read on the referenced button (never descending into the button's own children) — a maximum of 3 elements ever touched (the window + its default button + its cancel button), mirroring `ui.read_application_state`'s own "1 root + N referenced elements" bound shape.
11. **Approval requirement**: none — Level 0.
12. **Recovery behavior**: observation-first, trivially — a read has no side effects.
13. **Native E2E feasibility**: HIGH — `NSWindow.defaultButtonCell` is trivial, standard, and immediately testable.
14. **Why materially useful**: answers a genuinely orientational question ("what happens if I press Enter/Escape here") no existing capability can answer, closing a gap independently re-identified and re-scored across all seven discovery phases to date (2BG through this one) without ever being beaten by a fresher alternative in this specific round.

### 2. `ui.list_ruler_markers` — carried forward from Phases 2BI–2BL, still unimplemented
Unchanged from prior assessment. `kAXMarkerUIElementsAttribute`/`kAXMarkerTypeAttribute` on `AXRuler`, Level 0, complements the already-shipped `ui.list_rulers`.

### 3. `ui.read_element_label` — carried forward from Phases 2BH–2BL, still unimplemented
Unchanged from prior assessment. `kAXTitleUIElementAttribute`, Level 0.

### 4. `ui.read_element_action_description` — carried forward from Phase 2BL, still unimplemented
Unchanged from prior assessment. `AXUIElementCopyActionDescription`, Level 0, weak marginal utility over the already-shipped `ui.list_element_actions`.

### Considered fresh this phase, not elevated
- **Read `kAXAlternateUIVisibleAttribute`** — real, non-obsolete, but near-zero utility for this program's non-hover-driven execution model (Decisive Finding #1).
- **Read `kAXVisibleRowsAttribute`/`kAXVisibleColumnsAttribute`/`kAXSelectedColumnsAttribute`** — real, but an enrichment to already-shipped enumeration capabilities, not a standalone one (Decisive Finding #2, consistent with the established `kAXModalAttribute` precedent).
- **`NSAccessibilityLayoutArea`/`NSAccessibilityLayoutItem`-backed canvas enumeration** — rejected for no viable native AppKit fixture (no public `NSLayoutArea` class; only ad hoc custom drawing views implement this).
- **`NSAccessibilityElementLoading`-based capability** — rejected as a provider-side implementation detail with no client-observable capability surface.

---

## Scoring (0–100 per dimension, explicit weights per this phase's own model)

Weights: Semantic authority/AX support 20, Deterministic verification 15, Security/fail-closed compatibility 15, Architectural reuse 10, User utility 10, Privacy safety 10, Resource boundedness 5, Native AppKit E2E testability 10, Non-duplication/roadmap value 5 (sum = 100).

| Dimension | Weight | `ui.read_window_default_button` | `ui.list_ruler_markers` | `ui.read_element_label` | `ui.read_element_action_description` |
|---|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic authority / AX support | 20 | 85 → 17.00 | 78 → 15.60 | 78 → 15.60 | 80 → 16.00 |
| 2. Deterministic verification | 15 | 85 → 12.75 | 78 → 11.70 | 80 → 12.00 | 80 → 12.00 |
| 3. Security / fail-closed compatibility | 15 | 92 → 13.80 | 92 → 13.80 | 86 → 12.90 | 85 → 12.75 |
| 4. Architectural reuse | 10 | 88 → 8.80 | 85 → 8.50 | 85 → 8.50 | 85 → 8.50 |
| 5. User utility | 10 | 55 → 5.50 | 40 → 4.00 | 55 → 5.50 | 35 → 3.50 |
| 6. Privacy safety | 10 | 90 → 9.00 | 90 → 9.00 | 75 → 7.50 | 78 → 7.80 |
| 7. Resource boundedness | 5 | 92 → 4.60 | 92 → 4.60 | 88 → 4.40 | 90 → 4.50 |
| 8. Native AppKit E2E testability | 10 | 88 → 8.80 | 62 → 6.20 | 68 → 6.80 | 75 → 7.50 |
| 9. Non-duplication / roadmap value | 5 | 92 → 4.60 | 95 → 4.75 | 78 → 3.90 | 60 → 3.00 |
| **Weighted Total** | **100** | **84.85** | **78.15** | **76.60** | **75.55** |

**Ranking**: `ui.read_window_default_button` (84.85) > `ui.list_ruler_markers` (78.15) > `ui.read_element_label` (76.60) > `ui.read_element_action_description` (75.55). No score was inflated — this round's fresh `NSAccessibilityProtocols.h` sweep found nothing that outscored the strongest carried-forward candidate, and that finding is itself reported honestly rather than manufacturing a weaker "new" winner to appear novel.

---

## Selected Capability

**Capability ID**: `ui.read_window_default_button`
**Risk**: Level 0 (Read-Only)

### Target
Exactly one semantically-identified `AXWindow` (`QAXWindowRolePolicy`, reused verbatim).

### Inputs
`applicationName` (required), `windowTitle` **or** `windowIdentifier` (at least one required — matching `ui.set_window_main`'s existing window-targeting parameter convention).

### Resolution
Exact application resolution (`resolveExactRunningApplication`, unmodified) → exactly one `AXWindow` via `collectMatches`/`snapshotIfMatches` (role `AXWindow`, matched by identifier or title) → staleness re-check immediately before the read.

### AX operation
`AXUIElementCopyAttributeValue(windowElement, kAXDefaultButtonAttribute, ...)` and `AXUIElementCopyAttributeValue(windowElement, kAXCancelButtonAttribute, ...)` — each yielding an `AXUIElementRef` reference (or absence, a valid result for a window with no default/cancel button), followed by exactly one further `kAXTitleAttribute`/`AXIdentifier` read on each referenced button — never descending into the button's own children, never any other attribute.

### Verification
Proposed named strategy: `QVerificationStrategy.windowDefaultButtonReadSucceeded(applicationName: String, windowTitle: String?)` — checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`. Evidence: `application=<name> status=verified` — never the button titles/identifiers themselves.

### Approval
None required — Level 0, routed by `QPermissionGate.evaluate` straight to `.allow`.

### Recovery
Observation-first, trivially: a read has no side effects; an uncertain in-flight step fails closed to `pending`. No raw `AXUIElement` pointer is ever persisted.

### Privacy
**May leave the immediate reasoning boundary**: the default/cancel button's own title and identifier (structural UI labels, e.g. `"OK"`/`"Cancel"`) — never content, never a value. **Must remain ephemeral / never persisted beyond identity**: individual button title/identifier strings kept out of durable verification evidence, matching the conservative pattern `ui.list_element_actions`/`ui.list_element_attributes` already established for their own per-item strings.

### Bounds
- Elements: **3 maximum** (the window + its default button + its cancel button).
- Traversal depth: **0** beyond the two direct reference follows (no descent into either button's own children).
- Children: **0**.
- Actions performed: **0** — pure attribute reads, no `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` of any kind.
- Polling: **0** — a fixed set of synchronous calls.
- Returned records: **1** structured result (window-scoped; never a collection).
- String lengths: default/cancel button title and identifier each bounded to a defensive length ceiling (proposed 256 characters, matching `ui.list_element_actions`/`ui.list_element_attributes`'s own precedent), never an arbitrarily large model-visible string.

### E2E
A plain `NSWindow` with an `NSButton` assigned to `window.defaultButtonCell`, given a real `NSAccessibilityIdentifier` — trivial, standard, immediately verifiable.

---

## Security Challenge

1. **Can an untrusted model misuse it?** No — strictly read-only, returns only structural button identity (title/identifier), grants no new authority, and cannot itself cause any button to be pressed or any window to change state.
2. **Can it target the wrong application?** No — reuses `resolveExactRunningApplication` unmodified; fails closed on zero/ambiguous matches, identical to all 60 shipped capabilities.
3. **Can target ambiguity occur?** Handled identically to `ui.set_window_main`'s own window-targeting resolution — zero or 2+ matches fail closed, never `.first`.
4. **Can stale state produce an unsafe result?** No unsafe result is possible — this capability never performs a mutation; staleness at worst yields an inaccurate informational snapshot of which button is currently default/cancel, mitigated by the same observation-binding staleness check every prior capability already applies.
5. **Can authorization survive crash/recovery?** Not applicable — Level 0, no authorization exists to survive.
6. **Can raw AX objects escape?** No — the two `AXUIElementRef` references `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` yield are read for title/identifier only and immediately discarded; the output type carries only `String`/`String?` fields.
7. **Can sensitive content leak?** No — button titles/identifiers are structural UI labels (e.g. `"OK"`, `"Cancel"`, `"Don't Save"`), never user-entered content or typed values.
8. **Can it become a hidden physical-input fallback?** No — never calls `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, or any coordinate/keyboard/mouse API.
9. **Can custom accessibility implementations spoof identity?** Inherited from the existing architecture's already-accepted trust model, not newly introduced or amplified: every capability already trusts an application's own self-reported window/button metadata; the bounded blast radius here (title/identifier strings only, zero mutation surface) is no larger than for any existing read capability.
10. **Is the selected risk level (Level 0) actually justified?** Yes — zero mutation surface, zero content exposure beyond short structural labels.

No unresolved security risk was identified. The candidate is not rejected.

---

## Explicit Implementation Deferral

**Implementation: NOT STARTED.** This document is discovery-only. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase. The proposed contract above is a design proposal for a future, separately-approved implementation phase — not a description of code that exists today.

Phase 2BM — DISCOVERY COMPLETE

---

*(Post-discovery note: implementation has since been completed under separate explicit approval — see [`PHASE_2BM_SEMANTIC_WINDOW_DEFAULT_BUTTON.md`](./PHASE_2BM_SEMANTIC_WINDOW_DEFAULT_BUTTON.md) for the full implementation contract, test results, and security/privacy audit. The implementation additionally refined the missing-vs-failure distinction beyond what this discovery document specified in detail: a genuine read failure, a malformed reference, or a wrong-role reference for EITHER button fails the WHOLE read closed, rather than degrading only that one field — a deliberate, documented design choice made at implementation time for auditability.)*
