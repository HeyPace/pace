# Phase 2BJ — Capability Roadmap

## DISCOVERY ONLY — NO IMPLEMENTATION

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) test plan for the next capability. No production source
file, registry entry, executor, bridge, verification strategy, or test file has been created or
modified as part of this phase. See the explicit statement at the end of this file.

## Baseline
- **Commit**: `c609f17`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BI (Semantic Table Column Enumeration — `ui.list_table_columns`)

---

## Authoritative Capability Inventory
The repository contains exactly **57 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source extraction (`grep -oE '"[a-z_]+\.[a-z_]+": \("[a-z]+", \.[a-zA-Z0-9]+\)' | sort`), not any historical report.

**Total**: 57 ✓ (matches source-derived count and expected baseline). Full enumeration verified directly against source; see Existing Capability Inventory below for the semantic-family breakdown relevant to this phase's discovery.

---

## SDK Discovery Methodology
Fresh, direct grep-based inspection of the live SDK at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`, cross-referenced against actual usage in `leanring-buddy/q-runtime/`. This phase's discovery took a **different angle** than Phases 2BG/2BH/2BI (which each swept for unused role/attribute/action *names*): rather than re-sweeping names already exhausted three times, this phase specifically searched the header for every `Writable? Yes` annotation — a much smaller, higher-signal set — and cross-checked each writable attribute against what this codebase *already reads internally for mutation validation but never exposes as its own read-only capability output*. This mirrors the exact reasoning that produced Phase 2BH's winner (`ui.read_application_state`: state read internally by `ui.set_application_hidden`/`ui.activate_application` but never exposed) and applies it systematically rather than incidentally.

- **AX roles inspected**: re-confirmed all 94 constants in `AXRoleConstants.h` remain as previously catalogued; no new roles have appeared. Additionally cross-checked `QAXSliderRolePolicy.allowedRoles` (`["AXSlider", "AXStepper"]`) against the master role list and found `"AXStepper"` is **not actually a defined role constant anywhere in `AXRoleConstants.h`** — a pre-existing, harmless inert entry in that policy (an `NSStepper`'s real AX role is `AXIncrementor`, already covered by the separate `QAXIncrementorRolePolicy`/`ui.list_incrementors`). Not a defect requiring a fix in this phase (out of scope — a discovery-time observation, not an implementation task), but noted for completeness since accurate SDK grounding is this program's whole discipline.
- **AX attributes inspected**: systematically swept `AXAttributeConstants.h` for the literal string `Writable? Yes` — found in exactly **6** locations total across the entire 1327-line header: `kAXElementBusyAttribute`, `kAXFocusedAttribute` (already used — `ui.focus_element`), `kAXSelectedTextRangeAttribute`, `kAXSelectedTextRangesAttribute`, `kAXMainAttribute` (already used — `ui.set_window_main`), `kAXMinimizedAttribute` (already used — `ui.set_window_minimized`). This is a materially smaller, more tractable search space than a full 152-attribute name sweep, and it directly targets the question this phase's brief asks ("whether values have authoritative postconditions... whether attributes are readable/settable").
- **`kAXMinValueAttribute`/`kAXMaxValueAttribute`/`kAXValueIncrementAttribute`** were separately re-examined (they are not independently marked `Writable? Yes` — they participate in a *different* attribute's writability, namely `kAXValueAttribute`'s own range constraint) but carry an even stronger authority signal: `kAXMinValueAttribute`'s and `kAXMaxValueAttribute`'s own doc comments state *"Required for many user manipulatable elements"*, and `kAXValueIncrementAttribute`'s states *"Recommended for kAXIncrementorRole and other similar elements."* All three sit under the legitimate `// value attributes` section header — not the obsolete one. Direct source inspection confirms all three are read *internally* by `ui.set_slider_value`, `ui.step_incrementor`, and `ui.set_splitter_position` for their own idempotency/range-validation — but **never exposed as their own read-only output** to the model. This is the decisive finding of this phase.
- **AX actions inspected**: no new actions exist beyond the 11 already fully catalogued and evaluated across Phases 2BG/2BH/2BI (`kAXPressAction`/`kAXIncrementAction`/`kAXDecrementAction` in use; `kAXConfirmAction`/`kAXCancelAction`/`kAXPickAction`/`kAXRaiseAction`/`kAXShowMenuAction`/`kAXShowAlternateUIAction`/`kAXShowDefaultUIAction` all previously rejected on simulation-adjacency, obsolescence, or undocumented-behavior grounds that remain unchanged). No further action-based candidates were found this phase — confirmed by re-reading the full `AXActionConstants.h` end to end rather than assuming the prior phases' conclusions still hold without re-verification.

---

## Existing Capability Inventory (verified against source)
Explicitly re-verified against every capability named in this phase's own overlap-check list:

- `ui.read_application_state`, `ui.read_focused_element` — application/focus-element state reads; neither touches range attributes.
- `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_table_columns`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells` — container/collection enumerations; none targets `AXSlider`.
- `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors` — **these three already expose `minValue`/`maxValue` in their per-item `outputData`** (confirmed by direct source read at `QExecutionService.swift` lines 3493-3494, 3581-3582, 3670-3671). This is an important, precise finding: the range-exposure gap this phase identifies is **not present** for progress indicators, level indicators, or incrementors (enumerated *collections* already surface it) — it is specifically absent for (a) sliders, which have **no enumeration capability at all**, and (b) the single-element read path (`ui.read_element_value`) used for any of these four role families when the model already knows a specific element's identifier but only wants its range, not a full enumeration.
- `ui.list_combo_boxes`, `ui.list_combo_box_items`, `ui.select_combo_box_item`, `ui.step_incrementor`, `ui.set_splitter_position`, `ui.set_window_full_screen` — explicitly re-checked per this phase's own list; no overlap with a range-read capability.
- `ui.set_slider_value` (Level 2) and `ui.set_splitter_position` (Level 2) both read `kAXMinValueAttribute`/`kAXMaxValueAttribute` **internally**, before ever proposing a mutation, but this validated range is **never surfaced to the model** ahead of the approval prompt — the model currently has no way to know a slider's valid range before requesting a value be set, risking a wasted approval round-trip on an out-of-range guess.
- **`ui.list_sliders` does not exist** — confirmed by direct registry grep: no capability enumerates `AXSlider` elements at all. Every other major native control family shipped in this program (buttons via click_element, checkboxes/radio buttons via list_radio_group_items/set_element_state, tabs, tables, outlines, combo boxes, incrementors, progress/level indicators, color wells, popovers, toolbars, segmented controls) has an enumeration path; sliders alone do not.

---

## Candidates

### 1. `ui.read_element_range` — SELECTED
1. **Capability ID**: `ui.read_element_range`
2. **Risk level**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: `kAXMinValueAttribute`, `kAXMaxValueAttribute` (both documented *"Required for many user manipulatable elements"*), `kAXValueIncrementAttribute` (documented *"Recommended for kAXIncrementorRole and other similar elements"*), plus the element's own current `kAXValueAttribute` for context. Target roles: the union of every existing Level 2 range-based mutation's own role scope — `AXSlider`, `AXStepper` (from `QAXSliderRolePolicy`), `AXIncrementor` (from `QAXIncrementorRolePolicy`), `AXSplitter` (from `QAXSplitterRolePolicy`) — via one new, narrowly-scoped union policy (`QAXRangeReadRolePolicy`), the identical "fresh union policy for a cross-cutting concern" pattern `QAXFocusableRolePolicy` (Phase 2O) already established; no existing policy is modified.
4. **Exact target semantics**: identical resolution chain to `ui.read_element_value` (exact app/window resolution, then exactly one element by role + identifier-or-title via `collectMatches`/`snapshotIfMatches`).
5. **Read vs mutation**: read-only, zero mutation.
6. **Authoritative state/action available**: yes — the OS's own authoritative range constraints, the same values `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position` already validate against internally.
7. **Independent verification feasibility**: yes — read-succeeded evidence; the range is internally consistent (`min <= max`) or the read is refused.
8. **Resource bounds**: single element, at most 4 fixed attribute reads (min, max, increment, current value) — zero traversal, tied with `ui.read_focused_element`/`ui.read_application_state` for the tightest bound of any capability in this program.
9. **Privacy implications**: numeric bounds only — no text, no titles required beyond identity confirmation. Arguably the cleanest privacy profile of any capability proposed across four consecutive discovery phases.
10. **Existing-capability overlap**: zero — `ui.read_element_value` never reads range attributes; `ui.list_progress_indicators`/`ui.list_level_indicators`/`ui.list_incrementors` already expose range for their own enumerated collections (confirmed, not a duplicate — this capability serves the single-element-lookup case those enumerations don't cover, and is the *only* path to a slider's range at all, since sliders have no enumeration capability).
11. **Real macOS E2E feasibility**: HIGH — `NSSlider`/`NSStepper` with `minValue`/`maxValue` set is trivial, standard AppKit, and the identical role family `ui.set_slider_value`'s own shipped fixture already exercises reliably.
12. **Why valuable to Q × PACE**: directly improves the practical quality and safety of three *already-shipped* Level 2 mutations by letting the model learn valid bounds *before* proposing a value for human approval — reducing wasted approval round-trips on out-of-range guesses — while also being the **only** way to learn a slider's range at all, since sliders have zero enumeration coverage.

### 2. `ui.list_sliders` — NEW this phase
1. **Capability ID**: `ui.list_sliders`
2. **Risk level**: 0 (Read-Only)
3. **Native AX/AppKit primitive**: direct children of a window/application filtered by `kAXRoleAttribute == "AXSlider"`, per-slider `kAXTitleAttribute`/`AXIdentifier`/`kAXValueAttribute`/`kAXMinValueAttribute`/`kAXMaxValueAttribute`/`kAXEnabledAttribute`. Role scope: `AXSlider` only (via `QAXSliderRolePolicy`, reused — though `"AXStepper"` on that same policy is inert per this phase's own finding above, since no real control emits that exact role string).
4. **Exact target semantics**: identical pattern to `ui.list_incrementors`/`ui.list_color_wells` (direct-children enumeration bounded by a defensive ceiling, e.g. 32).
5. **Read vs mutation**: read-only.
6. **Authoritative state/action available**: yes.
7. **Independent verification feasibility**: yes — aggregate count evidence.
8. **Resource bounds**: bounded enumeration ceiling (proposed 32, matching sibling `list_*` ceilings), direct children only.
9. **Privacy implications**: title + numeric value/range — clean, though marginally less so than the winner since it also surfaces each slider's *current* value and title, not range alone.
10. **Existing-capability overlap**: zero overlap with any shipped capability — sliders currently have no enumeration path at all.
11. **Real macOS E2E feasibility**: HIGH — `NSSlider` construction is trivial.
12. **Why valuable to Q × PACE**: closes a genuine "family completeness" gap (every other major control family has enumeration; sliders alone do not) — narrower real-world agent value than the winner since sliders are less universally present across native macOS apps than tables/toolbars/menus, and its value is largely subsumed by the winner for the specific, highest-value use case (knowing a slider's range before setting it) once the model already knows the slider exists by some other means.

### 3. `ui.read_window_default_button` — carried forward from Phases 2BG/2BH/2BI, still unimplemented
Unchanged from prior discovery phases' own assessment — re-verified this phase with no new evidence changing it. `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` on `AXWindow`, Level 0, narrow "what activates on Enter/Escape" utility, zero overlap, high E2E feasibility (`NSWindow.defaultButtonCell`).

### 4. `ui.list_ruler_markers` — carried forward from Phase 2BI, still unimplemented
Unchanged from Phase 2BI's own assessment. `kAXMarkerUIElementsAttribute`/`kAXMarkerTypeAttribute` on `AXRuler`, Level 0, complements the already-shipped `ui.list_rulers`, moderate E2E feasibility (a real but more involved `NSRulerView`/`NSRulerMarker` fixture than a plain control).

### 5. `ui.read_element_label` — carried forward from Phase 2BH/2BI, still unimplemented
Unchanged from prior assessment. `kAXTitleUIElementAttribute`, Level 0, narrower value than the winner since the same fact is often reachable today if the label's own identifier is known.

### Still-rejected candidates, re-confirmed (not re-scored in full — no new evidence)
- **`ui.read_element_url`** (`kAXURLAttribute`) — the identical fixture-availability concern flagged in Phases 2BG, 2BH, and 2BI remains true; re-verified a fourth time with no change.
- **`ui.list_grid_items`** (`AXGrid`/`AXCell`) — `NSCollectionView`'s unreliable `AXGrid` emission, re-confirmed unchanged from Phase 2BH/2BI's rejection.
- **`ui.list_rating_indicators`** (`AXRatingIndicator`) — no public `NSRatingIndicator` AppKit class exists; re-confirmed unchanged.
- **`AXSwitch`/`AXToggle` role-policy extension** — still correctly out of scope as a *new capability* (would duplicate `ui.set_element_state`); remains a maintenance-task recommendation, not a phase candidate.
- **`kAXElementBusyAttribute`** (Writable? Yes) — considered fresh this phase as part of the `Writable? Yes` sweep, and rejected: this attribute exists so an *application* can inform assistive technology that its own content is loading — there is no coherent reason for an external desktop agent to set an application's busy flag on its behalf, and doing so has no defined, useful effect from the agent's perspective. Weak autonomous-agent value; not elevated to a scored candidate.
- **`kAXSelectedTextRangeAttribute`/`kAXSelectedTextRangesAttribute`** (Writable? Yes) — considered fresh this phase, and rejected: writing a text selection range doesn't itself expose content, but it sits directly adjacent to the already-privacy-rejected `kAXSelectedTextAttribute` (rejected in Phase 2BG's own discovery for exposing arbitrary user-selected content), creates an asymmetric mutation-without-matching-read surface, and has weak, unclear autonomous-agent value (an agent wanting to act on a text field already has `ui.set_text_value` for full-value replacement — a narrower "move the cursor/selection" capability solves no problem this program's existing tools don't already solve better). Not elevated to a scored candidate.

---

## Scoring (0–100 per dimension, weighted)

Weights (identical methodology to Phase 2BI, carried forward unchanged): Semantic usefulness 10%, AX authority/determinism 14%, Independent verification 14%, Security 12%, Privacy 12%, Resource boundedness 10%, Architecture fit 10%, Real macOS E2E feasibility 8%, Non-duplication/ecosystem value 10% (sum = 100%).

| Dimension | Weight | `ui.read_element_range` | `ui.list_sliders` | `ui.read_window_default_button` | `ui.list_ruler_markers` | `ui.read_element_label` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic usefulness | 10% | 85 | 65 | 55 | 45 | 60 |
| 2. AX authority / determinism | 14% | 92 | 88 | 85 | 80 | 82 |
| 3. Independent verification | 14% | 88 | 85 | 88 | 78 | 82 |
| 4. Security | 12% | 95 | 95 | 92 | 92 | 88 |
| 5. Privacy | 12% | 96 | 90 | 88 | 90 | 78 |
| 6. Resource boundedness | 10% | 95 | 88 | 92 | 92 | 88 |
| 7. Architecture fit | 10% | 90 | 90 | 85 | 85 | 85 |
| 8. Real macOS E2E feasibility | 8% | 92 | 90 | 80 | 65 | 70 |
| 9. Non-duplication / ecosystem value | 10% | 90 | 85 | 90 | 95 | 80 |
| **Weighted Total** | **100%** | **91.5** | **86.4** | **84.4** | **80.9** | **79.8** |
| **Risk level** | | Level 0 | Level 0 | Level 0 | Level 0 | Level 0 |

**Ranking**: `ui.read_element_range` (91.5) > `ui.list_sliders` (86.4) > `ui.read_window_default_button` (84.4) > `ui.list_ruler_markers` (80.9) > `ui.read_element_label` (79.8).

---

## Rejection Analysis
- **`ui.list_sliders`** (86.4) — not rejected outright (a solid, real, viable candidate), but scores lower than the winner on semantic usefulness (65 vs 85) and privacy (90 vs 96): its highest-value use case (knowing a slider's range before setting it) is fully subsumed by the winner, while the winner *additionally* serves `AXStepper`/`AXIncrementor`/`AXSplitter` — three more role families the enumeration-only approach would not reach without three separate new `list_*` capabilities.
- **`kAXElementBusyAttribute`** — rejected for weak autonomous-agent value (an application-owned status flag with no coherent agent-facing use case), not a security or duplication problem.
- **`kAXSelectedTextRangeAttribute`/`kAXSelectedTextRangesAttribute`** — rejected for proximity to a previously-established privacy rejection (`kAXSelectedTextAttribute`) and weak marginal value over the already-shipped `ui.set_text_value`.
- **`ui.read_element_url`, `ui.list_grid_items`, `ui.list_rating_indicators`** — all re-confirmed rejected for the identical reasons established in Phases 2BG/2BH/2BI, with no new SDK or empirical evidence this phase changing any of them.
- **`AXSwitch`/`AXToggle`** — still correctly framed as a role-policy-extension task for `ui.set_element_state`/`ui.read_element_value`, not a new-capability candidate; including it as a standalone capability would duplicate existing mutation/read semantics.

No technically interesting candidate was suppressed merely because implementation would be harder — `ui.list_ruler_markers`'s more involved fixture requirement was scored honestly on its own merits (moderate E2E feasibility, 65/100) rather than excluded.

---

## Selected Capability

**Selected capability**: `ui.read_element_range`
**Capability ID**: `ui.read_element_range`
**Risk level**: Level 0 (Read-Only)
**Score**: 91.5 / 100
**Native primitive**: `kAXMinValueAttribute` / `kAXMaxValueAttribute` / `kAXValueIncrementAttribute` (plus contextual `kAXValueAttribute`), read on a semantically-identified `AXSlider`/`AXStepper`/`AXIncrementor`/`AXSplitter` element.
**Why selected**: highest score on 6 of 9 dimensions (privacy, resource boundedness, verification, security, architecture fit, real E2E feasibility) and the only candidate discovered via a genuinely systematic method (a full `Writable? Yes` sweep of the SDK header, rather than an ad hoc name search) that directly mirrors the exact reasoning that produced Phase 2BH's own winner — state already read internally for mutation validation but never exposed as its own queryable fact. It is also the *only* candidate that directly improves the practical safety and quality of three already-shipped Level 2 mutations (`ui.set_slider_value`, `ui.step_incrementor`, `ui.set_splitter_position`) by letting the model learn valid bounds before proposing a value for human approval.
**Why runner-up was not selected**: `ui.list_sliders` (86.4) is a solid, genuinely fresh, real candidate — but its single highest-value use case is fully subsumed by the winner, while the winner additionally reaches three more role families (`AXStepper`, `AXIncrementor`, `AXSplitter`) a slider-only enumeration would never touch. `ui.list_sliders` remains a reasonable candidate for a future phase if slider *discovery* (as opposed to *range-reading* for an already-known element) becomes independently valuable.

---

## Security Design Preview (design only — not implemented)
- **Exact application resolution**: `resolveExactRunningApplication(named:)`, reused unmodified — zero/ambiguous matches fail closed.
- **Exact target resolution**: exactly one element resolved by role + (`identifier` or `title`) via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives — identical pattern to `ui.read_element_value`. Role must be on the new `QAXRangeReadRolePolicy` allowlist (`AXSlider`, `AXStepper`, `AXIncrementor`, `AXSplitter`) — checked before any AX call.
- **Ambiguity behavior**: 0 matches → `AX_NO_MATCHING_ELEMENT`; 2+ matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
- **Fail-closed conditions**: AX trust absent, application absent/ambiguous, element absent/ambiguous, disallowed role, `kAXMinValueAttribute`/`kAXMaxValueAttribute` unreadable (both required — the read fails closed rather than reporting a partial or fabricated range), an internally-inconsistent range (`min > max`).
- **Authorization requirements**: none — Level 0, no mutation.
- **Execution identity**: not applicable — no mutation, no approval, no execution-identity binding needed.
- **Single-use approval**: not applicable.
- **Recovery semantics**: none needed — a read that does not throw IS its own result; an uncertain in-flight step fails closed to `pending`, a retry is always safe.
- **Durable-state implications**: only the target's identity and a boolean "range read succeeded" ever cross into persisted evidence — the numeric bounds themselves are informational to the model but, mirroring every prior Level 0 capability's own privacy contract, need not be withheld from durable evidence given their complete lack of sensitivity (numeric bounds carry zero privacy risk) — a decision to be confirmed at implementation time against the closest precedent (`ui.list_incrementors`' own min/max exposure in `outputData` is not redacted, suggesting the same applies here).
- **Raw AX pointer handling**: never persisted, never returned — snapshot-then-discard discipline identical to all 57 shipped capabilities.
- **Forbidden fallback mechanisms**: none — pure `AXUIElementCopyAttributeValue` reads, no `CGEvent`/keyboard/mouse simulation, ever.
- **Resource limits**: see below.

---

## Privacy Design Preview
- **Classification of exposed data**: exclusively **structural/numeric metadata** — `minValue`, `maxValue`, `valueIncrement` (all `Double`), and the element's own current `value` (also `Double`) plus its identity (`role`, `identifier`, `title`). No application state booleans beyond `enabled`, no user-visible free-form text, no user-entered values in the sensitive sense (a slider's numeric position is not comparable to typed text content), no credentials, no OTPs, no payment data, no URLs, no personal information of any kind.
- **Sensitive-data risk assessment**: negligible — arguably lower than any capability proposed across four consecutive discovery phases, since even the "value" field here is a bounded number (e.g., a volume level or zoom percentage), not free text. No rejection or additional constraint is warranted; the existing structural-metadata precedent is more than sufficient.

---

## Resource Bounds (concrete, pre-committed)
- **Max traversal depth**: 0 — resolution is the bounded `collectMatches` search identical to `ui.read_element_value`'s own existing depth ceiling (not a new traversal), and the range read itself is a fixed set of direct attribute reads on the one resolved element.
- **Max nodes**: 1 (the resolved element itself; `collectMatches`'s own existing search-time node ceiling applies unchanged during resolution, exactly as it does for `ui.read_element_value` today).
- **Max children enumerated (by the range read itself, post-resolution)**: 0.
- **Max returned elements**: 1 (a single structured result — min, max, increment, current value — never a collection).
- **Max actions**: 0 — read-only.
- **Max polling**: 0 — a single synchronous set of attribute reads, no polling loop.
- **Max text/value size**: not applicable — every returned field is a `Double` or a short structural identity string; no free-form text of any kind is ever returned.

---

## Verification Design (design only — not implemented)
Verification must be based on the read's own success/failure, established entirely inside the eventual `QBridgeAccessibility.readElementRange` implementation (exact application/element resolution, `kAXMinValueAttribute`/`kAXMaxValueAttribute` both successfully read as `Double`, and `minValue <= maxValue` internally consistent) — the identical "a stateless read's own success/failure IS the ground truth" discipline every Level 0 capability's `QVerificationStrategy` already uses. The proposed strategy name is `elementRangeReadSucceeded(applicationName: String, role: String)`. This deliberately checks the execution result's own `success` flag as a genuine, meaningful assertion — never a bare `{ true }` bypass. Rejected verification approaches: screenshots (never used anywhere in this program), OCR (never used), visual appearance (never used), timing (no polling exists to time), model interpretation (the model never adjudicates its own success), process existence (irrelevant to a single-element range read), assumed side effects (there are none — this is a pure read). Since this is Level 0/read-only, verification is independent of any mutation request by construction — there is no mutation request to be independent of.

---

## Real macOS E2E Design (design only — not claimed as executed)
- **Fixture**: a plain `NSWindow` containing an `NSSlider` with `minValue = 0`, `maxValue = 100`, and a set `doubleValue`, given an `NSAccessibilityIdentifier`.
- **AX role**: `AXSlider`.
- **Authoritative attribute**: `kAXMinValueAttribute`, `kAXMaxValueAttribute` on the resolved slider element; `kAXValueAttribute` for the current value.
- **Expected state**: the returned `minValue`/`maxValue` match the fixture's configured `minValue`/`maxValue` exactly.
- **Independent verification**: the eventual test re-resolves the same slider fresh (never trusting the read call's own return value uncritically) and re-reads `kAXMinValueAttribute`/`kAXMaxValueAttribute` to confirm the same bounds.
- **TCC dependency**: yes — `AXIsProcessTrusted()` gates all real dispatch, identical to every prior phase.
- **PASS criteria**: the real fixture's configured min/max are read back exactly, under genuine Accessibility trust, with the test's own timing evidence (a fixture window creation + AX round-trip necessarily takes measurable real time, not sub-millisecond) supporting a genuine dispatch occurred.
- **TCC BLOCKED criteria**: `AXIsProcessTrusted() == false` in the isolated test host (anticipated, based on this exact environment's consistent behavior across every prior phase — most recently confirmed for Phase 2BI via direct `.xcresult` timing evidence, where every `AXIsProcessTrusted()`-guarded test completed in `0.001s`) — to be reported honestly as BLOCKED, never fabricated as a PASS.

---

## Proposed Focused Test Plan (NOT IMPLEMENTED — count only, 20+)
Estimated 20+ focused tests following the exact structure of every prior phase's own test suite: capability registration + anti-downgrade (both directions), missing `applicationName`/match-criteria fails closed, disallowed role rejected (role policy reused verbatim, not forked), zero/ambiguous application resolution fails closed, zero/ambiguous element target resolution fails closed, correct min/max/increment extraction for a real `AXSlider` fixture, missing `kAXValueIncrementAttribute` handled safely (optional field, not every role reports it), malformed/internally-inconsistent range (`min > max`) fails closed, unavailable `kAXMinValueAttribute`/`kAXMaxValueAttribute` fails closed (both required), no traversal beyond the single resolved element, no mutation occurs, no polling occurs, no actions performed, evidence-based verification (never bare `{ true }`, never restates the numeric bounds in evidence text if that decision is confirmed at implementation time), privacy boundary (numeric-only output), normal `QPlanExecutor`/`QExecutionService` pipeline integration, `QPermissionGate` never requires approval, uncertain in-flight step recovery fails closed to pending, forbidden-API audit (structural), real macOS E2E (TCC-guarded, `NSSlider` fixture).

Related existing suites expected to remain green: any suite covering `ui.set_slider_value`/`ui.step_incrementor`/`ui.set_splitter_position` (shares the same range-bearing role families and, for the new union role policy, must not regress any of their existing role-validation behavior), `QApplicationResolutionHardeningTests` (shares the exact application-resolution contract), full regression suite (`scripts/test-pace.sh`, currently 3165/3165 green as of Phase 2BI).

---

## Expected Implementation Scope
Based on the identical pattern every predecessor Level 0 single-element read capability (`ui.read_focused_element`, `ui.read_application_state`) has followed:
- `QModelPlanSchema.swift` — one new registry entry (`toolFamily: "ui"`, matching `ui.read_element_value`'s own family for the same reason — no free-form content requiring the `perception` boundary; numeric bounds carry no such risk).
- `QBridgeAdapters.swift` — one new output type (`QAXElementRangeMetadata` or similar), one new `QAXRangeReadRolePolicy` (a fresh union policy, not a fork of any existing one), one new `readElementRange` method reusing `resolveExactRunningApplication`/`collectMatches`/`snapshotIfMatches` verbatim, and one new `QAXInteractionError` case for the range-inconsistency/unreadable-range failure mode.
- `QExecutionService.swift` — one new dispatch case, one new `executeReadElementRange` method.
- `QActionVerification.swift` — one new `QVerificationStrategy.elementRangeReadSucceeded` case + evaluate branch.
- `QPlanExecutor.swift` — one new `determineVerificationStrategy` branch.
- A new dedicated test file (estimated 20+ tests).
- Documentation: an implementation addendum to this roadmap document, plus a new `docs/PHASE_2BJ_SEMANTIC_ELEMENT_RANGE_READ.md` (or equivalent name), mirroring the exact structure of `docs/PHASE_2BI_SEMANTIC_TABLE_COLUMN_ENUMERATION.md`.

No changes anticipated to `QPermissionGate`, `QApprovalCoordinator`, `QResourceGuard`, execution identity, or recovery logic — Level 0 capabilities have never required changes to any of these in any prior phase.

---

## Risks / Open Questions
- **`toolFamily` choice**: recommended `"ui"` (matching `ui.read_element_value`), but should be confirmed against the closest architectural precedent at implementation time — the same open-item discipline every prior phase's roadmap applied to its own `toolFamily` choice.
- **Durable-evidence redaction decision**: whether the numeric range should be included verbatim in verification evidence (as `ui.list_incrementors`' own precedent suggests is acceptable given zero sensitivity) or kept to an aggregate "range read succeeded" boolean only (matching the more conservative pattern `ui.read_focused_element`/`ui.read_application_state` established for their own, more sensitive fields) — a real design choice to make explicitly at implementation time, not a discovery-phase decision, since both are defensible given this capability's low sensitivity.
- **Scroll position exclusion**: `ui.set_scroll_position` *also* reads `kAXMinValueAttribute`/`kAXMaxValueAttribute` internally (on an `AXScrollBar` resolved via a convenience-reference attribute from an `AXScrollArea`, not by direct role search) — deliberately excluded from this capability's role scope because its target-resolution shape differs architecturally from the four directly-role-searchable roles (`AXSlider`/`AXStepper`/`AXIncrementor`/`AXSplitter`); including it would require a special-cased resolution branch rather than the uniform `collectMatches`-based pattern this capability otherwise shares with `ui.read_element_value`. Noted as a known limitation, not a gap to close in this same phase.
- **`AXStepper` inert-role observation**: as documented above, `QAXSliderRolePolicy`'s inclusion of `"AXStepper"` appears to be inert (no real AX role constant of that name exists in the current SDK) — this is a pre-existing characteristic of an already-shipped policy, not something this phase's implementation should attempt to fix; the new `QAXRangeReadRolePolicy` will include `"AXStepper"` for consistency with the existing `QAXSliderRolePolicy` it partially mirrors, accepting that it may never match a real element in practice, exactly as the existing policy already does.

---

## Explicit Statement

**Phase 2BJ is Discovery only.** Implementation has NOT started. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase.

*(This statement describes this document's own discovery phase and is preserved verbatim as the historical record of that phase. Implementation has since been completed under separate explicit approval — see [`PHASE_2BJ_SEMANTIC_ELEMENT_RANGE_READ.md`](./PHASE_2BJ_SEMANTIC_ELEMENT_RANGE_READ.md) for the full implementation contract, test results, and security/privacy audit. Note: the approved implementation contract restricted `QAXRangeReadRolePolicy` to exactly `{AXSlider, AXIncrementor, AXSplitter}` — stricter than this discovery document's own proposal, which had considered carrying forward `QAXSliderRolePolicy`'s historical `"AXStepper"` entry for consistency. The implementation phase's own fresh SDK re-verification confirmed `"AXStepper"` has no backing role constant at all, and it was correctly excluded rather than carried forward — see the implementation document's own findings.)*
