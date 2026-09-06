# Phase 2BI — Capability Roadmap

## DISCOVERY ONLY — NO IMPLEMENTATION

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) test plan for the next capability. No production source
file, registry entry, executor, bridge, verification strategy, or test file has been created or
modified as part of this phase. See the explicit statement at the end of this file.

## Baseline
- **Commit**: `83d6d37`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BH (Semantic Application State Read — `ui.read_application_state`)

---

## Authoritative Capability Inventory
The repository contains exactly **56 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source extraction (`grep -oE '"[a-z_]+\.[a-z_]+": \("[a-z]+", \.[a-zA-Z0-9]+\)' | sort`), not any historical report.

Full enumeration (alphabetical, as extracted): `accessibility.read`, `app.quit`, `fs.read`, `fs.write_sandbox`, `screen.ocr`, `system.running_apps`, `test.noop`, `ui.activate_application`, `ui.click_element`, `ui.close_window`, `ui.focus_element`, `ui.list_browser_columns`, `ui.list_color_wells`, `ui.list_combo_box_items`, `ui.list_combo_boxes`, `ui.list_incrementors`, `ui.list_level_indicators`, `ui.list_menu_items`, `ui.list_outline_items`, `ui.list_popovers`, `ui.list_popup_items`, `ui.list_progress_indicators`, `ui.list_radio_group_items`, `ui.list_rulers`, `ui.list_segmented_control_items`, `ui.list_sheet_actions`, `ui.list_sheet_dialogs`, `ui.list_split_panes`, `ui.list_tab_items`, `ui.list_table_rows`, `ui.list_toolbar_items`, `ui.list_windows`, `ui.open_app`, `ui.read_application_state`, `ui.read_element_value`, `ui.read_focused_element`, `ui.select_combo_box_item`, `ui.select_menu_item`, `ui.select_outline_row`, `ui.select_popup_item`, `ui.select_segmented_control_item`, `ui.select_tab`, `ui.select_table_row`, `ui.set_application_hidden`, `ui.set_element_state`, `ui.set_scroll_position`, `ui.set_slider_value`, `ui.set_splitter_position`, `ui.set_text_value`, `ui.set_window_full_screen`, `ui.set_window_main`, `ui.set_window_minimized`, `ui.step_incrementor`, `ui.toggle_disclosure`.

**Total**: 56 ✓ (matches source-derived count and expected baseline)

---

## SDK / AppKit Discovery Methodology
Fresh, direct grep-based inspection of the live SDK at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`, cross-referenced against actual usage in `leanring-buddy/q-runtime/` (not assumed from Phase 2BG/2BH's own written summaries — those summaries were consulted only to avoid re-proposing something already explicitly rejected for a reason that still holds, per this phase's own instruction not to simply reuse the prior candidate list).

- **AX roles inspected**: all 94 constants in `AXRoleConstants.h`, cross-checked for zero-usage against the full `q-runtime/` tree.
- **AX attributes inspected**: all 152 constants in `AXAttributeConstants.h`, same zero-usage cross-check. Critically, this phase went one step further than 2BG/2BH by reading the **section grouping and inline comments** around each unused attribute, not just its bare name — this surfaced two decisive findings (below) that a name-only sweep would have missed entirely.
- **AX actions inspected**: all 11 constants in `AXActionConstants.h`, with full `@discussion` text read for every action not yet dispatched anywhere in the codebase.

### Decisive finding #1 — `kAXColumnTitlesAttribute` is explicitly obsolete
The SDK header itself groups attributes into named sections. `kAXColumnTitlesAttribute` sits under a section literally titled `// obsolete/unknown attributes`, alongside `kAXTextAttribute`, `kAXVisibleTextAttribute`, and `kAXIsEditableAttribute`. This directly confirms two things: (a) this codebase's existing choice to read `kAXValueAttribute` (never `kAXTextAttribute`) for `ui.read_element_value`/`ui.read_focused_element` was and remains correct — the same section marks `kAXTextAttribute` obsolete; (b) any future table-column capability must use `kAXColumnHeaderUIElementsAttribute` (grouped under the legitimate `// cell-based table attributes` section, immediately followed by `kAXRowIndexRangeAttribute`/`kAXColumnIndexRangeAttribute` under `// cell attributes`) — never `kAXColumnTitlesAttribute`, which looks tempting by name but is explicitly disclaimed by Apple's own header.

### Decisive finding #2 — `kAXShowAlternateUIAction`/`kAXShowDefaultUIAction` are hover-simulation actions
Neither action was evaluated in Phase 2BG or 2BH (both phases stopped at `kAXConfirmAction`/`kAXCancelAction`/`kAXPickAction`/`kAXRaiseAction`/`kAXShowMenuAction`). Their full `@discussion` text: `kAXShowAlternateUIAction` — *"Show alternate or hidden UI. This is often used to trigger the same change that would occur on a mouse hover."*; `kAXShowDefaultUIAction` — *"Show default UI. This is often used to trigger the same change that would occur when a mouse hover ends."* Both are explicitly documented as substitutes for **mouse hover simulation** — a more direct textual match to this program's hard "no mouse simulation" boundary than even `kAXConfirmAction`'s "simulate pressing Return" framing. Neither has an authoritative, generically-verifiable postcondition (showing "alternate UI" is entirely app-defined). Rejected outright — see Rejection Analysis.

### Decisive finding #3 — `AXDialog`/`AXSystemDialog` are subroles, not top-level roles
Both are declared as `kAXDialogSubrole`/`kAXSystemDialogSubrole` under a `// new subroles` section — not standalone AX roles. A "dialog," in AX terms, is an `AXWindow` (or occasionally `AXGroup`) whose `kAXSubroleAttribute` happens to equal `"AXDialog"`. This rules out a naive "enumerate `AXDialog`-role elements" capability (there is no such role to search for) and reframes the real opportunity as an enrichment to `ui.list_windows`'s existing per-window metadata (adding a `subrole`/`isDialog` field) or a read of `kAXModalAttribute` (documented *"Required for all window elements"* — the strongest authority claim found this phase) — both discussed under Considered-But-Not-Elevated below, since both are enrichments to an *existing* capability's output, not a new standalone one, and this phase's own brief explicitly warns against duplicating `ui.list_windows`.

---

## Existing Capability Coverage (verified against source, not the prompt's list)
Application-level: `ui.open_app`, `ui.activate_application`, `ui.set_application_hidden`, `app.quit`, `ui.read_application_state` (Phase 2BH) — read/write of hidden/frontmost/main-window/focused-window state is now fully covered.

Window-level: `ui.list_windows`, `ui.set_window_minimized`, `ui.set_window_main`, `ui.set_window_full_screen`, `ui.close_window`. Still no read of a window's default/cancel button (carried-forward gap, unimplemented since Phase 2BG) and no `subrole`/modal classification in `ui.list_windows`'s output (a fresh finding this phase, framed as an enrichment, not a new capability).

Element-level: `ui.read_element_value`, `ui.read_focused_element`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.set_slider_value`, `ui.focus_element`, `ui.toggle_disclosure`, `ui.step_incrementor`. Still no read of an element's associated label (`kAXTitleUIElementAttribute`, carried-forward gap) or its URL (`kAXURLAttribute`, carried-forward gap).

Container/collection families fully covered (enumerate + where applicable, select — verified directly against source, explicitly checked for overlap per this phase's own list): `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows` (rows only — **not columns**, confirmed by direct inspection: `ui.list_table_rows` reads `kAXRowsAttribute`-adjacent row children only, never `kAXColumnHeaderUIElementsAttribute`), `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs` + `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns` (confirmed via direct source read at `QBridgeAdapters.swift:7805` — this targets `AXBrowser`'s `"AXColumns"` attribute, a completely different role and attribute than the `AXTable`/`kAXColumnHeaderUIElementsAttribute` pair a table-column capability would use; **not a duplicate**), `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes` + `ui.list_combo_box_items` + `ui.select_combo_box_item`, `ui.list_rulers` (ruler *containers* only — **not their markers**, confirmed by direct inspection: no reference to `kAXMarkerUIElementsAttribute` anywhere in the codebase).

---

## Candidates

### 1. `ui.list_table_columns` — SELECTED
1. **Capability ID**: `ui.list_table_columns`
2. **Level / risk**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXColumnHeaderUIElementsAttribute` (confirmed this phase to sit under the legitimate `// cell-based table attributes` section, not the obsolete one), `kAXColumnsAttribute`, per-column `kAXTitleAttribute`, optionally `kAXSortDirectionAttribute`. Target role `AXTable` (`QAXTableRolePolicy`, reused unmodified from Phase 2AE).
4. **Exact target semantics**: exact application resolution (`resolveExactRunningApplication`, unmodified) → optional exact window resolution → exactly one `AXTable` by identifier/title via the existing `collectMatches`/`snapshotIfMatches` primitives (0 matches → `AX_NO_MATCHING_ELEMENT`, 2+ → `AX_AMBIGUOUS_TARGET`) → direct, non-recursive enumeration of that table's column headers only.
5. **Read vs mutation**: read-only, zero mutation.
6. **Authoritative state available?**: yes — `kAXColumnHeaderUIElementsAttribute` is the OS's own authoritative list of a table's header elements, not inferred from row content.
7. **Independent verification possible?**: yes — read-succeeded evidence (aggregate column count only), the same discipline as every other Level 0 `list_*` capability's verification strategy.
8. **Resource-bound strategy**: bounded column-count ceiling (proposed 32, matching `ui.list_browser_columns`'s existing `maxDirectBrowserColumnsCount = 32`), direct children only — no recursive descent into a column's own contents.
9. **Privacy implications**: column header titles are structural metadata ("Name", "Date Modified", "Size") — the same low-risk class every other `list_*` capability's title fields already carry.
10. **Existing-capability overlap**: explicitly checked against `ui.list_table_rows` (rows only, confirmed no column-header read exists) and `ui.list_browser_columns` (confirmed via direct source read: targets `AXBrowser`'s `"AXColumns"`, a different role and attribute entirely) — **zero overlap with either**.
11. **Real macOS E2E feasibility**: HIGH — `NSTableView` + 2+ `NSTableColumn`s with distinct header titles inside a plain `NSWindow` is trivial, standard AppKit, and empirically reliable (unlike `NSCollectionView`'s inconsistent `AXGrid` emission).
12. **Why valuable to Q × PACE**: closes a real, specific asymmetry flagged independently in both Phase 2BG's and Phase 2BH's own discovery documents (this is the *third* time this exact gap has been identified as the strongest still-unimplemented candidate) — a model that can enumerate a table's rows but never learn what its columns *mean* cannot reliably reason about tabular data (e.g. distinguishing a "Date" column from an "Amount" column before reading cell values).

### 2. `ui.list_ruler_markers` — NEW this phase
1. **Capability ID**: `ui.list_ruler_markers`
2. **Level / risk**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXMarkerUIElementsAttribute` (array of `AXRulerMarker`-role children), `kAXMarkerTypeAttribute`/`kAXMarkerTypeDescriptionAttribute` per marker, `kAXUnitsAttribute`/`kAXUnitDescriptionAttribute` on the parent ruler for context. Target role `AXRuler` (`QAXRulerRolePolicy`, reused unmodified from Phase 2BC — the same role `ui.list_rulers` already resolves).
4. **Exact target semantics**: identical resolution chain to `ui.list_rulers`, then direct enumeration of exactly one resolved ruler's marker children (never recursive).
5. **Read vs mutation**: read-only, zero mutation.
6. **Authoritative state available?**: yes — the OS's own marker collection, not inferred from ruler appearance.
7. **Independent verification possible?**: yes — read-succeeded evidence, aggregate marker count only.
8. **Resource-bound strategy**: bounded marker-count ceiling (proposed 32, matching sibling `list_*` ceilings), direct children only.
9. **Privacy implications**: marker type/position metadata only — structural, not user content.
10. **Existing-capability overlap**: complements (never overlaps) `ui.list_rulers`, which enumerates rulers themselves but has zero reference to `kAXMarkerUIElementsAttribute` — confirmed by direct source grep.
11. **Real macOS E2E feasibility**: MODERATE — `NSRulerView` + `NSRulerMarker` are real, public AppKit API, but constructing a live fixture (a ruler-enabled `NSScrollView`/`NSTextView` with an actual marker added) is meaningfully more involved than a plain `NSWindow` + one control, and this exact role has never been exercised by a live fixture in this codebase before (unlike `AXRuler` itself, which `ui.list_rulers`'s own shipped E2E test already proved empirically reliable — a real point in this candidate's favor, but the *marker* sub-role specifically remains untested).
12. **Why valuable to Q × PACE**: a narrow but genuine, zero-overlap sibling to an already-shipped capability; lower real-world agent utility than table columns (ruler tab-stop inspection is a niche desktop-publishing/word-processing use case, not a broadly common agent task).

### 3. `ui.read_element_label` — carried forward from Phase 2BH, still unimplemented
1. **Capability ID**: `ui.read_element_label`
2. **Level / risk**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXTitleUIElementAttribute` (single-element reference), read policy re-validated against `QAXElementReadRolePolicy` (Phase 2J, unmodified) before exposure.
4. **Exact target semantics**: identical to `ui.read_element_value`'s own target resolution, plus one single-hop reference follow.
5. **Read vs mutation**: read-only.
6. **Authoritative state available?**: yes, where an app has wired the linkage (via Interface Builder or `accessibilityTitleUIElement`) — absence is a valid `nil`, not an error.
7. **Independent verification possible?**: yes — read-succeeded evidence.
8. **Resource-bound strategy**: one base target resolution + exactly one additional single-attribute reference read.
9. **Privacy implications**: label text — same risk class `ui.read_element_value` already accepts.
10. **Existing-capability overlap**: no overlap with `ui.read_element_value` (which reads a target's *own* value, never a *separate* labeling element) or `ui.read_focused_element`.
11. **Real macOS E2E feasibility**: MODERATE — requires deliberately wiring `accessibilityTitleUIElement` in the fixture; a plain, unwired `NSTextField` will not exhibit this linkage by default.
12. **Why valuable to Q × PACE**: closes a real convenience gap (reading a form field's own descriptive label when its own title is empty, the common case for well-built accessible forms) — narrower value than table columns since the same fact is often already reachable today if the label's own identifier happens to be known/guessable.

### 4. `ui.read_window_default_button` — carried forward from Phase 2BG/2BH, still unimplemented
1. **Capability ID**: `ui.read_window_default_button`
2. **Level / risk**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXDefaultButtonAttribute`, `kAXCancelButtonAttribute` on `AXWindow`.
4. **Exact target semantics**: exact app + exact window resolution (`QAXWindowRolePolicy`, unmodified), two fixed reference reads.
5. **Read vs mutation**: read-only.
6. **Authoritative state available?**: yes, where the window has one — a valid `nil` otherwise.
7. **Independent verification possible?**: yes — read-succeeded evidence.
8. **Resource-bound strategy**: single window, two fixed attribute reads.
9. **Privacy implications**: button title/identifier only — low risk.
10. **Existing-capability overlap**: none — no existing capability surfaces which button activates on Enter/Escape.
11. **Real macOS E2E feasibility**: HIGH — `NSWindow.defaultButtonCell` is trivial, standard AppKit.
12. **Why valuable to Q × PACE**: narrow but genuinely useful "what happens if I press Enter" fact, re-scored this phase with no new information changing its prior assessment.

### 5. `ui.read_element_url` — carried forward, re-verified, still fixture-risky
1. **Capability ID**: `ui.read_element_url`
2. **Level / risk**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXURLAttribute`, primarily on `AXLink`.
4. **Existing-capability overlap**: none.
5. **Real macOS E2E feasibility**: LOW — the identical concern flagged in both Phase 2BG and Phase 2BH remains true: no confirmed, reliable native-AppKit-only control (outside WebKit/`AXLink` contexts) emits this attribute at the element level. Re-verified this phase, not merely copy-pasted forward — the concern still holds and no new SDK evidence changes it.
6. **Why it loses**: weakest fixture-feasibility of the serious candidates.

### 6. `ui.list_grid_items` — re-considered, still rejected (fixture-reliability risk)
1. **Capability ID**: `ui.list_grid_items`
2. **Level / risk**: 0 (Read-Only) (would be)
3. **Native AX/AppKit primitive**: `AXGrid`/`AXCell` roles, `kAXRowCountAttribute`/`kAXColumnCountAttribute` (confirmed this phase to sit under a legitimate `// grid attributes` section — the attribute names themselves are not obsolete).
4. **Existing-capability overlap**: none.
5. **Real macOS E2E feasibility**: LOW — `NSCollectionView` does not reliably emit `AXGrid`; many configurations report a plain `AXScrollArea`/`AXGroup` hierarchy instead. The attribute names being legitimate (not obsolete, per this phase's more careful section-grouping review) does not resolve the underlying role-emission-reliability problem, which is about AppKit's actual runtime behavior, not the SDK header's documentation quality.
6. **Why it loses**: re-confirmed rejection from Phase 2BH — no new evidence this phase changes the empirical unreliability finding.

---

## Scoring (0–100 per dimension, weighted)

Weights (chosen to mirror the emphasis established in Phase 2BG/2BH's own scoring — authority, verification, security, and privacy weighted highest — while accommodating this phase's explicit addition of "Real macOS E2E feasibility" as its own axis): Semantic usefulness 10%, AX authority/determinism 14%, Independent verification 14%, Security 12%, Privacy 12%, Resource boundedness 10%, Architecture fit 10%, Real macOS E2E feasibility 8%, Non-duplication/ecosystem value 10% (sum = 100%).

| Dimension | Weight | `ui.list_table_columns` | `ui.read_window_default_button` | `ui.list_ruler_markers` | `ui.read_element_label` | `ui.read_element_url` | `ui.list_grid_items` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic usefulness | 10% | 80 | 55 | 45 | 60 | 55 | 55 |
| 2. AX authority / determinism | 14% | 90 | 85 | 80 | 82 | 70 | 60 |
| 3. Independent verification | 14% | 85 | 88 | 78 | 82 | 75 | 70 |
| 4. Security | 12% | 95 | 92 | 92 | 88 | 85 | 90 |
| 5. Privacy | 12% | 85 | 88 | 90 | 78 | 70 | 80 |
| 6. Resource boundedness | 10% | 90 | 92 | 92 | 88 | 90 | 82 |
| 7. Architecture fit | 10% | 92 | 85 | 85 | 85 | 82 | 78 |
| 8. Real macOS E2E feasibility | 8% | 90 | 80 | 65 | 70 | 40 | 35 |
| 9. Non-duplication / ecosystem value | 10% | 95 | 90 | 95 | 80 | 88 | 92 |
| **Weighted Total** | **100%** | **89.0** | **84.4** | **80.9** | **79.8** | **73.6** | **72.1** |

**Ranking**: `ui.list_table_columns` (89.0) > `ui.read_window_default_button` (84.4) > `ui.list_ruler_markers` (80.9) > `ui.read_element_label` (79.8) > `ui.read_element_url` (73.6) > `ui.list_grid_items` (72.1).

---

## Rejection Analysis

- **`ui.read_element_url`** (73.6) — **inability to verify/fixture, not a security or duplication problem**. `kAXURLAttribute` is a legitimate, non-obsolete attribute, but no confirmed native-AppKit-only control reliably emits it outside WebKit/`AXLink` contexts. Re-verified for a third consecutive discovery phase with no new evidence changing this. Not rejected outright — kept as a scored, lower-ranked candidate rather than discarded, since the underlying attribute itself remains sound; only its real-world fixture-ability is weak.
- **`ui.list_grid_items`** (72.1) — **unreliable AX role emission**. `AXGrid`/`AXCell` are legitimate roles with legitimate (non-obsolete) attributes, but `NSCollectionView` does not reliably emit `AXGrid` across macOS versions/configurations. A capability whose E2E test cannot be reliably constructed from a standard AppKit control carries real implementation risk independent of its other scoring dimensions.
- **`ui.set_switch_state`/`AXSwitch` enumeration or mutation** — **duplication**. `AXSwitch` (backing `NSSwitch`, macOS 10.15+) is a real, modern, entirely uncovered role — but the correct fix is extending `QAXElementStateRolePolicy`/`QAXElementReadRolePolicy`/`QAXFocusableRolePolicy`'s existing allowlists to include it, not minting a new `ui.set_switch_state` capability that would functionally duplicate `ui.set_element_state`. Not scored as a candidate — flagged here explicitly per this phase's instruction to identify near-duplicates, and left as a role-policy-extension recommendation for a future maintenance task, not a new-capability phase.
- **`kAXShowAlternateUIAction`/`kAXShowDefaultUIAction`** — **simulation-adjacent + no authoritative postcondition**. Both actions' own SDK `@discussion` text explicitly frames them as substitutes for mouse-hover behavior ("trigger the same change that would occur on a mouse hover" / "when a mouse hover ends") — a direct textual match to this program's hard "no mouse simulation" boundary. Neither has a generically verifiable postcondition (showing "alternate UI" is entirely app-defined). Not elevated to scored-candidate status.
- **`AXDialog`/`AXSystemDialog` enumeration** — **not a real top-level role**. Both are subroles (`kAXDialogSubrole`/`kAXSystemDialogSubrole`) on `AXWindow`, not standalone AX roles — there is nothing to "enumerate" as a distinct element family. The genuine opportunity here (reading `kAXModalAttribute`, or exposing `subrole` on `ui.list_windows`'s existing per-window output) is an enrichment to an *already-shipped* capability, which this phase's own brief explicitly warns against duplicating — not scored as a new candidate.
- **`kAXColumnTitlesAttribute`** — **documented obsolete**. Grouped under the SDK header's own `// obsolete/unknown attributes` section. Never a sound foundation for any capability; `kAXColumnHeaderUIElementsAttribute` (the legitimate alternative) is what `ui.list_table_columns` actually uses.

---

## Selected Capability

**Selected capability**: `ui.list_table_columns`
**Capability ID**: `ui.list_table_columns`
**Risk level**: Level 0 (Read-Only)
**Score**: 89.0 / 100
**Why selected**: highest score on 6 of 9 dimensions (security, resource boundedness, architecture fit, real macOS E2E feasibility, non-duplication, and tied for architecture fit) and the only candidate with the combination of (a) an authority claim freshly reconfirmed this phase against the SDK's own explicit obsolescence-marking convention, (b) zero overlap with either of the two capabilities most plausibly confused with it (`ui.list_table_rows`, `ui.list_browser_columns` — both explicitly checked against actual source, not assumed), and (c) the highest real-world semantic usefulness of any candidate (tabular data with meaningful, named columns is broadly common across native macOS apps an agent would plausibly operate). This is also the third independent discovery phase in a row to identify this exact gap as the strongest still-unimplemented candidate — a consistency signal, not a reason to select it by default (the scoring this phase was performed independently, using this phase's own explicit rubric, and arrived at the same conclusion on its own merits).
**Why runner-up was not selected**: `ui.read_window_default_button` (84.4) is a solid, low-risk Level 0 candidate with excellent verification/security/resource characteristics, but scores lower on semantic usefulness (55 vs 80) and real-world ecosystem value (90 vs 95) — it answers a narrower question ("what activates on Enter/Escape") than table-column semantics answers ("what does this data mean"), and does not close a gap independently flagged across multiple prior discovery phases the way the winner does.

---

## Security Design Preview (design only — not implemented)
- **Exact application resolution**: `resolveExactRunningApplication(named:)`, reused unmodified — zero/ambiguous matches fail closed.
- **Target identity**: exactly one `AXTable` element, resolved by the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (role `AXTable`, matched by `identifier` or `title`) — never by index alone, never by position/coordinates.
- **Ambiguity handling**: 0 matches → `AX_NO_MATCHING_ELEMENT`; 2+ matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
- **Fail-closed conditions**: AX trust absent, application absent/ambiguous, table absent/ambiguous, column collection malformed (copy succeeds but cast to `[AXUIElement]` fails) — mirroring `ui.list_windows`'s existing `windowsCollectionMalformed`-style discipline.
- **Authorization requirements**: none — Level 0, no mutation.
- **Execution identity**: not applicable — no mutation, no approval, no execution-identity binding needed.
- **Recovery behavior**: none needed — a read that does not throw IS its own result; an uncertain in-flight step fails closed to `pending`, a retry is always safe (identical to every other Level 0 capability).
- **Durable-state implications**: only an aggregate column count crosses into persisted evidence, mirroring every prior `list_*` capability's own privacy contract — individual column titles are informational to the model but never threaded into `QDurablePlanStepSnapshot.resultSummary`/`verifiedEvidence`.
- **Raw AX pointer handling**: never persisted, never returned — snapshot-then-discard discipline identical to all 56 shipped capabilities.
- **Forbidden physical-input fallback**: none — pure `AXUIElementCopyAttributeValue` reads, no `CGEvent`/keyboard/mouse simulation of any kind, ever.
- **Resource bounds**: see below.

---

## Privacy Design Preview
- **Classification of exposed data**: exclusively **structural metadata** — column header titles (e.g. "Name", "Date Modified") and, optionally, sort direction. No application state booleans, no user-visible cell *content*, no potentially sensitive values, no credentials, no payment information, no personal information of any kind are ever read by this capability (it never touches `AXRow`/`AXCell` content — only the header row).
- **Sensitive-data risk assessment**: negligible. A column header is, by definition, a data-model label the application itself chose to display as a heading — not user-entered content. No rejection or additional constraint is warranted; the existing structural-metadata precedent every other `list_*` capability already establishes is sufficient and requires no new privacy mechanism.

---

## Resource Bounds (concrete, pre-committed)
- **Max traversal depth**: 1 (the resolved `AXTable` element's direct column-header children only; never descends into a column's own contents).
- **Max nodes**: 1 (the table) + up to 32 (columns) = 33 maximum elements ever touched in a single call.
- **Max children enumerated**: 32 (proposed ceiling, matching `ui.list_browser_columns`'s existing `maxDirectBrowserColumnsCount = 32`).
- **Max returned elements**: 32 (one metadata record per column — title, optionally sort direction).
- **Max actions**: 0 — read-only.
- **Max polling**: 0 — a single synchronous enumeration, no polling loop.
- **Max text/value size**: not applicable — column titles are short, bounded UI labels, not free-form content; no truncation ceiling beyond what every other `list_*` capability's title fields implicitly accept.

---

## Verification Design (design only — not implemented)
Verification must be based on the read's own success/failure, established entirely inside the eventual `QBridgeAccessibility.listTableColumns` implementation (exact application/table resolution, a successfully-read and well-formed column collection) — the identical "a stateless enumeration's own success/failure IS the ground truth" discipline every other Level 0 `list_*` capability's `QVerificationStrategy` already uses (e.g. `windowEnumerationSucceeded`, `comboBoxItemEnumerationSucceeded`). The proposed strategy name is `tableColumnEnumerationSucceeded(applicationName: String, columnCount: Int)`. This deliberately checks the execution result's own `success` flag as a genuine, meaningful assertion — never a bare `{ true }` bypass — so a step that somehow reached verification without a successful read is still correctly reported `.failed`. Rejected verification approaches: timing (no polling exists to time), screenshots (never used anywhere in this program), visual appearance (never used), model interpretation (the model never adjudicates its own success), process existence (irrelevant to a column-header read), assumed side effects (there are none — this is a pure read).

---

## Real macOS E2E Design (design only — not claimed as executed)
- **Fixture**: a plain `NSWindow` containing an `NSTableView` with 2+ `NSTableColumn`s, each given a distinct `title` (e.g. "Name", "Date Modified").
- **AX role**: `AXTable` (window target), `AXColumn` (each returned header element).
- **Authoritative attribute**: `kAXColumnHeaderUIElementsAttribute` on the resolved `AXTable`.
- **Expected state**: the returned column collection's count matches the fixture's `NSTableColumn` count exactly, and each column's `kAXTitleAttribute` matches the fixture's configured title exactly.
- **Independent verification**: the eventual test re-resolves the same `AXTable` fresh (never trusting the enumeration call's own return value uncritically) and re-reads `kAXColumnHeaderUIElementsAttribute` to confirm the same count.
- **TCC dependency**: yes — `AXIsProcessTrusted()` gates all real dispatch, identical to every prior phase.
- **What constitutes PASS**: the real fixture's column titles are read back exactly, under genuine Accessibility trust, with the test's own timing evidence (a fixture window creation + AX round-trip necessarily takes measurable real time, not sub-millisecond) supporting a genuine dispatch occurred.
- **What constitutes TCC BLOCKED**: `AXIsProcessTrusted() == false` in the isolated test host (anticipated, based on this exact environment's consistent behavior across every prior phase — most recently confirmed for Phase 2BH via direct `.xcresult` timing evidence, where every `AXIsProcessTrusted()`-guarded test completed in `0.001s`) — to be reported honestly as BLOCKED, never fabricated as a PASS.

---

## Expected Testing Strategy
A dedicated `QSemanticTableColumnEnumerationTests.swift` (or the repository's established naming convention at implementation time) with an estimated 20+ focused tests, following the exact structure of Phase 2BG's/2BH's own test suites: registration/anti-downgrade, missing/wrong-application, missing/ambiguous table target, happy-path column enumeration with title/sort-direction fields, zero-columns-is-valid, resource-bound enforcement (ceiling exceeded fails closed), no mutation, no polling, forbidden-API audit, normal pipeline usage, `QPermissionGate` never requires approval, uncertain-step recovery fails closed to pending, real macOS E2E (TCC-guarded).

Related existing suites expected to remain green: `QApplicationResolutionHardeningTests` (shares the exact application-resolution contract), any existing table-row test suite (shares `QAXTableRolePolicy` and the `AXTable` target-resolution pattern — to be identified precisely by filename at implementation time), full regression suite (`scripts/test-pace.sh`, currently 3138/3138 green as of Phase 2BH).

---

## Expected Implementation Scope
Based on the identical pattern every predecessor Level 0 `list_*` capability has followed:
- `QModelPlanSchema.swift` — one new registry entry (`toolFamily: "ui"`, matching `ui.list_table_rows`'s own family, not `perception` — column titles are structural metadata like every other `list_*` capability's output, carrying no free-form content requiring the sanitize-before-persist boundary).
- `QBridgeAdapters.swift` — one new output type (`QAXTableColumnMetadata` or similar), one new `listTableColumns` method reusing `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches`/`QAXTableRolePolicy` verbatim, and (if a malformed-collection failure mode is needed) possibly one new `QAXInteractionError` case mirroring `windowsCollectionMalformed`'s existing precedent.
- `QExecutionService.swift` — one new dispatch case, one new `executeListTableColumns` method.
- `QActionVerification.swift` — one new `QVerificationStrategy.tableColumnEnumerationSucceeded` case + evaluate branch.
- `QPlanExecutor.swift` — one new `determineVerificationStrategy` branch.
- A new dedicated test file (estimated 20+ tests).
- Documentation: an implementation addendum to this roadmap document, plus a new `docs/PHASE_2BI_SEMANTIC_TABLE_COLUMN_ENUMERATION.md` (or equivalent name), mirroring the exact structure of `docs/PHASE_2BH_SEMANTIC_APPLICATION_STATE_READ.md`.

No changes anticipated to `QPermissionGate`, `QApprovalCoordinator`, `QResourceGuard`, execution identity, or recovery logic — Level 0 capabilities have never required changes to any of these in any prior phase.

---

## Risks / Open Questions
- **Sort-direction field**: `kAXSortDirectionAttribute` is a real, legitimate attribute that could enrich this capability's output, but its exact reliability across third-party (non-Apple) `NSTableView` usages has not been empirically re-verified this phase — a decision to include or omit it should be made at implementation time based on what the real E2E fixture actually reports, not assumed in advance.
- **`toolFamily` choice**: recommended `"ui"` (matching `ui.list_table_rows`), but this should be confirmed against the closest architectural precedent at implementation time, the same open-item discipline Phase 2BH's own roadmap document applied to its own `toolFamily` choice.
- **Column-count ceiling**: proposed 32 by direct analogy to `ui.list_browser_columns`'s existing `maxDirectBrowserColumnsCount = 32`; a real table could plausibly have more columns than a browser view in some data-heavy apps (e.g. spreadsheet-adjacent tools) — worth a final sanity check against `ui.list_table_rows`'s own row ceiling (`maxDirectTableRowsCount = 128`) at implementation time to confirm 32 isn't unreasonably tight for the column case specifically.

---

## Explicit Statement

**Phase 2BI is Discovery only.** Implementation has NOT started. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase.

*(This statement describes this document's own discovery phase and is preserved verbatim as the historical record of that phase. Implementation has since been completed under separate explicit approval — see [`PHASE_2BI_SEMANTIC_TABLE_COLUMN_ENUMERATION.md`](./PHASE_2BI_SEMANTIC_TABLE_COLUMN_ENUMERATION.md) for the full implementation contract, test results, and security/privacy audit.)*
