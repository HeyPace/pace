# Phase 2BO — Capability Discovery Roadmap (Discovery Only)

**Status:** DISCOVERY COMPLETE — Implementation NOT STARTED.
**Baseline commit:** `5125a62` (`5125a62ca66f0e0db086390446bbef5c6359ea85`)
**Authoritative capability count at start of discovery:** 62 (verified via `grep -c '": ("' leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`)
**Last closed capability:** `ui.read_element_title_reference` (Phase 2BN)
**Working tree at start of discovery:** CLEAN

This document is the sole artifact of Phase 2BO. No production code, test code, or capability
registry entries were modified to produce it.

---

## 1. Baseline

```
$ git status --short
(empty — clean)
$ git rev-parse HEAD
5125a62ca66f0e0db086390446bbef5c6359ea85
$ grep -c '": ("' leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift
62
```

All three checks match the stated baseline exactly. Discovery proceeded.

---

## 2. Authoritative Capability Count

**62**, confirmed directly from `QModelPlanParser.registeredCapabilities` in
`QModelPlanSchema.swift` — never trusted from any prior roadmap document.

---

## 3. Existing Capability Inventory (source-derived)

| Capability ID | Risk | Read/Mutation | Primary AX role/API | Semantic purpose |
|---|---|---|---|---|
| `system.running_apps` | 0 | Read | NSWorkspace | Enumerate running applications |
| `system.clipboard.read` | 0 | Read | NSPasteboard | Read clipboard contents |
| `screen.ocr` | 0 | Read | Vision framework | On-device text recognition from screen capture |
| `ui.open_app` | 1 | Mutation (local action) | NSWorkspace | Launch an application |
| `fs.read` | 0 | Read | FileManager | Read a sandboxed file |
| `fs.write_sandbox` | 1 | Mutation | FileManager | Write a sandboxed file |
| `test.noop` | 0 | Read | — | Test harness no-op |
| `accessibility.read` | 0 | Read | AX (generic) | Legacy generic AX read |
| `system.clipboard.write` | 2 | Mutation | NSPasteboard | Write clipboard contents |
| `app.quit` | 3 | Mutation | NSRunningApplication | Terminate an application |
| `ui.click_element` | 2 | Mutation | `AXUIElementPerformAction` (`kAXPressAction`) | Press a button/control |
| `ui.set_text_value` | 2 | Mutation | `kAXValueAttribute` (write) | Set a text field's value |
| `ui.read_element_value` | 0 | Read | `kAXValueAttribute` | Read a semantic element's value |
| `ui.set_element_state` | 2 | Mutation | `kAXValueAttribute` (write) | Toggle checkbox/radio state |
| `ui.select_menu_item` | 2 | Mutation | `AXUIElementPerformAction` | Select a menu item |
| `ui.set_slider_value` | 2 | Mutation | `kAXValueAttribute` (write) | Set a slider's value |
| `ui.activate_application` | 1 | Mutation (local action) | NSRunningApplication | Bring an app to the foreground |
| `ui.focus_element` | 2 | Mutation | `kAXFocusedAttribute` (write) | Focus an element |
| `ui.select_popup_item` | 2 | Mutation | `AXUIElementPerformAction` | Select a pop-up button item |
| `ui.toggle_disclosure` | 2 | Mutation | `kAXValueAttribute` (write) | Expand/collapse a disclosure triangle |
| `ui.select_tab` | 2 | Mutation | `AXUIElementPerformAction` | Select a tab |
| `ui.select_table_row` | 2 | Mutation | `kAXSelectedAttribute` (write) | Select a table row |
| `ui.select_outline_row` | 2 | Mutation | `kAXSelectedAttribute` (write) | Select an outline row |
| `ui.set_window_minimized` | 2 | Mutation | `kAXMinimizedAttribute` (write) | Minimize/restore a window |
| `ui.set_application_hidden` | 2 | Mutation | `kAXHiddenAttribute` (write) | Hide/unhide an application |
| `ui.set_scroll_position` | 2 | Mutation | `kAXValueAttribute` on `AXScrollBar` | Set scroll position |
| `ui.set_window_main` | 2 | Mutation | `kAXMainAttribute` (write) | Make a window main |
| `ui.close_window` | 3 | Mutation | `AXUIElementPerformAction` (`kAXPressAction` on close button) | Close a window |
| `ui.list_windows` | 0 | Read | `AXWindow` enumeration | List windows with title/identifier/minimized/main |
| `ui.list_menu_items` | 0 | Read | `AXMenuBarItem`/`AXMenuItem` | List top-level menu items |
| `ui.list_popup_items` | 0 | Read | `AXPopUpButton` menu | List pop-up button items |
| `ui.list_table_rows` | 0 | Read | `AXTable`/`AXRow` | List table rows |
| `ui.list_outline_items` | 0 | Read | `AXOutline`/`AXRow` | List outline rows |
| `ui.list_tab_items` | 0 | Read | `AXTabGroup` | List tabs |
| `ui.list_radio_group_items` | 0 | Read | `AXRadioGroup` | List radio buttons |
| `ui.list_toolbar_items` | 0 | Read | `AXToolbar` | List toolbar items |
| `ui.list_segmented_control_items` | 0 | Read | `AXSegmentedControl`? (via children) | List segments |
| `ui.list_sheet_dialogs` | 0 | Read | `AXSheet` | List sheets attached to a window |
| `ui.list_sheet_actions` | 0 | Read | `AXSheet` buttons | List a sheet's action buttons |
| `ui.select_segmented_control_item` | 2 | Mutation | `kAXValueAttribute` (write) | Select a segment |
| `ui.set_window_full_screen` | 2 | Mutation | `kAXFullScreenAttribute` (write) | Toggle full-screen |
| `ui.list_split_panes` | 0 | Read | `AXSplitGroup` | List split-view panes |
| `ui.set_splitter_position` | 2 | Mutation | `kAXValueAttribute` on `AXSplitter` | Move a splitter |
| `ui.list_browser_columns` | 0 | Read | `AXBrowser` | List browser columns |
| `ui.list_popovers` | 0 | Read | `AXPopover` | List popovers |
| `ui.list_color_wells` | 0 | Read | `AXColorWell` | List color wells |
| `ui.list_progress_indicators` | 0 | Read | `AXProgressIndicator`/`AXBusyIndicator` | List progress/busy indicators |
| `ui.list_level_indicators` | 0 | Read | `AXLevelIndicator` | List level indicators |
| `ui.list_incrementors` | 0 | Read | `AXIncrementor` | List incrementors/steppers |
| `ui.list_combo_boxes` | 0 | Read | `AXComboBox` | List combo boxes |
| `ui.list_rulers` | 0 | Read | `AXRuler` | List rulers (title/orientation/unit description/marker **count** only) |
| `ui.list_combo_box_items` | 0 | Read | `AXComboBox` menu | List a combo box's dropdown items |
| `ui.select_combo_box_item` | 2 | Mutation | `AXUIElementPerformAction` | Select a combo box item |
| `ui.step_incrementor` | 2 | Mutation | `AXUIElementPerformAction` (`kAXIncrementAction`/`kAXDecrementAction`) | Step an incrementor |
| `ui.read_focused_element` | 0 | Read | `AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute` | Read the systemwide focused element |
| `ui.read_application_state` | 0 | Read | `kAXFocusedWindowAttribute`, `kAXHiddenAttribute`, etc. | Read app-level state snapshot |
| `ui.list_table_columns` | 0 | Read | `kAXColumnsAttribute`/`kAXColumnTitleAttribute` | List table column headers |
| `ui.read_element_range` | 0 | Read | `kAXMinValueAttribute`/`kAXMaxValueAttribute`/`kAXValueAttribute`/`kAXValueIncrementAttribute` | Read a slider/incrementor/splitter's numeric range |
| `ui.list_element_actions` | 0 | Read | `AXUIElementCopyActionNames` | Enumerate an element's supported action names |
| `ui.list_element_attributes` | 0 | Read | `AXUIElementCopyAttributeNames` | Enumerate an element's supported attribute names |
| `ui.read_window_default_button` | 0 | Read | `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` | Read a window's default/cancel button references |
| `ui.read_element_title_reference` | 0 | Read | `kAXTitleUIElementAttribute` | Read the element that serves as a target's title/label |

**Equivalence check**: no two capabilities above target the same AX API for the same semantic
purpose — confirmed by direct enumeration; every `list_*`/`read_*` pair reads a distinct attribute
or distinct C API.

### Notable structural observation feeding this round's gap analysis
`ui.list_rulers` reads `kAXOrientationAttribute`/`kAXUnitDescriptionAttribute` on the ruler itself
and reports a bare **marker count** via generic `AXChildren` — it never reads
`kAXMarkerUIElementsAttribute` (the ruler-marker-specific convenience attribute) nor any
per-marker attribute (`kAXMarkerTypeAttribute`/`kAXMarkerTypeDescriptionAttribute`). Confirmed via
direct grep: zero matches for `kAXMarkerUIElementsAttribute`, `kAXMarkerTypeAttribute`,
`kAXMarkerTypeDescriptionAttribute`, `kAXUnitsAttribute`, or `AXRulerMarker` anywhere in the
codebase.

---

## 4. Previous Roadmap / Rejection History (2AI → 2BN)

Reviewed every existing `docs/PHASE_2A*_CAPABILITY_ROADMAP.md` /
`docs/PHASE_2B*_CAPABILITY_ROADMAP.md` document (28 files; no `2AC`–`2AH`-numbered roadmap
documents exist in this repository — the earliest present is `2AI`) via direct `grep` across all
of them for every previously-mentioned `ui.*` candidate identifier, then cross-referenced each
against the current registry to separate "implemented," "rejected," and "carried forward but never
selected."

**Load-bearing finding this round**: `ui.read_element_label` (first proposed Phase 2BH, "carried
forward" and re-confirmed unimplemented in Phases 2BI/2BJ/2BK/2BL/2BM) was defined identically to
what Phase 2BN's `ui.read_element_title_reference` actually implemented: both resolve
`kAXTitleUIElementAttribute` and both surface the referenced element's own `kAXTitleAttribute`
text (`QAXElementTitleReference.title`, confirmed by direct source inspection of
`resolveElementTitleReference` in `QBridgeAdapters.swift`). **`ui.read_element_label` is therefore
now RESOLVED as a side effect of Phase 2BN's implementation, not merely rejected** — it is removed
from further consideration and is not re-scored this round.

**Carried-forward, never-selected candidates re-examined this round** (no new SDK evidence
required to re-list these — they were runners-up, not rejections):
- `ui.read_scroll_position` (Phase 2BN alternative, 89/100) — still unimplemented, still a
  legitimate read-only counterpart to `ui.set_scroll_position`.
- `ui.read_text_selection_state` (Phase 2BN alternative, 91/100) — still unimplemented.
- `ui.read_window_full_screen_state` (Phase 2BN alternative, 84/100) — still unimplemented.
- `ui.list_element_labeled_by_targets` (Phase 2BN runner-up, `kAXServesAsTitleForUIElementsAttribute`) — still
  unimplemented; re-examined below with an updated composability argument now that its mirror
  (`ui.read_element_title_reference`) exists.

**Previously rejected candidates re-confirmed still-rejected** (checked for materially new SDK
evidence; found none):
- `ui.read_element_url` (`kAXURLAttribute`) — first proposed Phase 2BG, "rejected repeatedly for
  fixture unreliability," re-confirmed through 2BH/2BI/2BJ/2BK/2BM. The SDK evidence is unchanged
  (still `CFURLRef`, still `Writable? No`, still scoped to "elements that represent a disk or
  network item") and no standard, unmodified AppKit control populates it without a custom
  `NSAccessibility` override — the same fixture-reliability problem persists. Re-scored honestly
  below (72/100) rather than silently omitted.
- `ui.list_element_linked_references` (`kAXLinkedUIElementsAttribute`) — rejected Phase 2BN for
  unpredictable population (no role-specific "required for" documentation exists for this
  attribute anywhere in the SDK). Unchanged this round.
- `ui.read_element_parent_reference` (`kAXParentAttribute`/`kAXTopLevelUIElementAttribute`) —
  rejected Phase 2BN for bounds risk (one hop from an unbounded upward walk) and low
  non-duplication (re-derives context already obtainable by resolving the container directly).
  Unchanged this round.
- `ui.list_focusable_elements` — rejected Phase 2AJ: "Requires recursive window-tree walking,
  violating the direct-child safety boundary." This is a structural/architectural rejection, not
  an SDK-evidence one — nothing about the underlying constraint (this codebase's bounded,
  non-recursive-beyond-declared-limits traversal discipline) has changed. Unchanged this round.
- `AXTextMarker*` family, `AXObserver*` push/notification architecture,
  `AXUIElementPostKeyboardEvent`: rejected in multiple earlier phases (privacy-adjacent/complex,
  requires new architecture, forbidden keyboard simulation respectively) — reaffirmed, not
  revisited.
- Coordinate/geometry attributes (`kAXPositionAttribute`/`kAXSizeAttribute`): rejected Phase 2BN on
  security grounds (coordinate-adjacency) independent of score. Reaffirmed.

---

## 5. Fresh Apple SDK Research (this round)

SDK root: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`.

- **`AXAttributeConstants.h`** — re-read targeting two clusters not the focus of any prior phase's
  search axis:
  - **Window-state cluster** (lines ~805–951): `kAXMainAttribute` ("Whether a window is the main
    document window... Writable? Yes. Required for all window elements.") and
    **`kAXModalAttribute`** ("Whether a window is modal. Value: A CFBooleanRef... Writable? No.
    Required for all window elements."). `kAXMain` is already partially surfaced (as the `main`
    field in `ui.list_windows`'s `QAXWindowMetadata`); **`kAXModalAttribute` is completely
    unused anywhere in this codebase** — confirmed by direct grep, zero matches.
  - **Ruler-marker cluster** (lines ~1246–1252, grouped under a `// ruler attributes` comment,
    the same un-individually-documented style already accepted as valid SDK evidence for
    `ui.list_rulers`'s own `kAXUnitsAttribute`/`kAXOrientationAttribute` reads in Phase 2BC):
    `kAXMarkerUIElementsAttribute` (`CFArrayRef` of `AXUIElementRef`, each expected role
    `AXRulerMarker` per `AXRoleConstants.h` line 384), `kAXUnitsAttribute`,
    `kAXUnitDescriptionAttribute`, `kAXMarkerTypeAttribute`, `kAXMarkerTypeDescriptionAttribute`.
    All five confirmed completely unused anywhere in this codebase by direct grep.
- **`AXUIElement.h`** — re-swept specifically for C functions never yet called anywhere in this
  codebase (a narrower axis than 2BL's full-function enumeration, which found
  `AXUIElementCopyActionNames`/`AXUIElementCopyAttributeNames` already implemented by 2BK/2BL).
  Found **`AXUIElementCopyActionDescription`** (line 312): "Returns a localized description of the
  specified accessibility object's action." Signature: `AXUIElementCopyActionDescription(element:
  AXUIElementRef, action: CFStringRef, description: CFStringRef?*) -> AXError`. Distinct error
  semantics documented (`kAXErrorActionUnsupported`, `kAXErrorIllegalArgument`,
  `kAXErrorInvalidUIElement`, `kAXErrorCannotComplete`, `kAXErrorNotImplemented`) — a genuine,
  real, non-deprecated C API confirmed by direct grep to have zero call sites anywhere in this
  codebase, despite its sibling `AXUIElementCopyActionNames` having been in production use since
  Phase 2BK.
- **`kAXServesAsTitleForUIElementsAttribute`** (re-confirmed present, same header cluster as
  `kAXTitleUIElementAttribute`, line ~1204) — still unused; re-examined below as
  `ui.list_element_labeled_by_targets`.
- **`NSApplication.h`** (AppKit) — checked for a genuine, non-blocking way to construct a real
  modal-window fixture for `kAXModalAttribute` testing: confirmed
  `-beginModalSessionForWindow:` (Swift: `NSApplication.beginModalSession(for:)`, returning
  `NSApplication.ModalSession`) and `-endModalSession:` are current, public, non-deprecated APIs
  (the deprecated overload is only the two-window `relativeToWindow:` variant) — these begin a
  real modal session without blocking the calling thread the way `-runModalForWindow:` would,
  making a genuine (not merely theoretical) automated E2E fixture possible.
- **`AXRoleConstants.h`, `AXActionConstants.h`** — re-swept; no new role/action constants found
  since their prior full enumerations (Phases 2BJ/2BK).

---

## 6. Candidate List (10 serious candidates — exceeds the ≥10 floor)

| # | Candidate ID | AX API | One-line description |
|---|---|---|---|
| 1 | `ui.read_window_modal_state` | `kAXModalAttribute` | Read whether a semantically-identified window is currently modal. |
| 2 | `ui.read_text_selection_state` | `kAXSelectedTextRangeAttribute` + `kAXNumberOfCharactersAttribute` | Read an editable text element's selection extent — never the selected text itself. |
| 3 | `ui.read_element_action_description` | `AXUIElementCopyActionDescription` | Read the localized description of one of a target's already-discovered supported actions. |
| 4 | `ui.read_scroll_position` | `kAXValueAttribute` of the convenience-referenced `AXScrollBar` | Read-only counterpart to `ui.set_scroll_position`. |
| 5 | `ui.list_ruler_markers` | `kAXMarkerUIElementsAttribute` + per-marker `kAXMarkerTypeAttribute`/`kAXMarkerTypeDescriptionAttribute` | Enumerate a ruler's actual marker objects (not just a bare count). |
| 6 | `ui.read_window_full_screen_state` | `kAXFullScreenAttribute` | Read-only counterpart to `ui.set_window_full_screen`. |
| 7 | `ui.list_element_labeled_by_targets` | `kAXServesAsTitleForUIElementsAttribute` | List every element a given label element is the title for (mirror of `ui.read_element_title_reference`). |
| 8 | `ui.read_element_url` | `kAXURLAttribute` | Read a disk/network-item element's URL. |
| 9 | `ui.list_element_linked_references` | `kAXLinkedUIElementsAttribute` | List other elements a target is semantically linked to. |
| 10 | `ui.read_element_parent_reference` | `kAXParentAttribute`/`kAXTopLevelUIElementAttribute` | Read a single-hop reference to an element's parent/owning window. |

---

## 7. Scoring Methodology

Weights this round: **A. First-class AX/API authority (20) · B. Non-duplication (15) · C.
Autonomous usefulness (20) · D. Contract determinism (10) · E. Resource bounds (10) · F. Privacy
(10) · G. Verification (5) · H. Native E2E feasibility (10)** — sum 100, exactly as specified.

---

## 8. Candidate Scoring Table

| # | Candidate | A /20 | B /15 | C /20 | D /10 | E /10 | F /10 | G /5 | H /10 | **Total** |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `ui.read_window_modal_state` | 19 | 14 | 17 | 10 | 10 | 10 | 5 | 9 | **94** |
| 2 | `ui.read_text_selection_state` | 20 | 14 | 15 | 9 | 10 | 10 | 5 | 8 | **91** |
| 3 | `ui.read_element_action_description` | 18 | 12 | 16 | 9 | 10 | 10 | 5 | 9 | **89** |
| 4 | `ui.read_scroll_position` | 18 | 13 | 15 | 9 | 10 | 10 | 5 | 9 | **89** |
| 5 | `ui.list_ruler_markers` | 17 | 14 | 13 | 9 | 10 | 10 | 5 | 9 | **87** |
| 6 | `ui.read_window_full_screen_state` | 16 | 11 | 13 | 10 | 10 | 10 | 5 | 9 | **84** |
| 7 | `ui.list_element_labeled_by_targets` | 16 | 11 | 11 | 8 | 9 | 10 | 5 | 8 | **78** |
| 8 | `ui.read_element_url` | 15 | 13 | 8 | 9 | 10 | 8 | 5 | 4 | **72** |
| 9 | `ui.list_element_linked_references` | 15 | 9 | 9 | 7 | 7 | 8 | 5 | 6 | **66** |
| 10 | `ui.read_element_parent_reference` | 14 | 6 | 8 | 7 | 4 | 8 | 5 | 7 | **59** |

---

## 9. Duplicate / Rejected Candidates — Rationale

- **`ui.read_element_label` — REMOVED from consideration (resolved, not rejected)**: see Section 4.
  `ui.read_element_title_reference` (Phase 2BN) already returns the referenced label element's own
  title text; a dedicated `ui.read_element_label` would be a pure duplicate.
- **`ui.read_element_url` (#8, 72/100)** — re-examined per the instruction to check for materially
  new evidence before re-scoring a carried-forward candidate; found none. Its Autonomous usefulness
  (8/20) and Native E2E feasibility (4/10) remain the lowest of any live candidate this round — no
  standard, unmodified AppKit control exposes `kAXURLAttribute` without a custom
  `NSAccessibility` override, the same fixture-reliability problem documented since Phase 2BG.
  Kept in the scored table (not silently dropped) for transparency, but not competitive.
- **`ui.list_element_linked_references` (#9, 66/100)** — `kAXLinkedUIElementsAttribute` still has
  no role-specific "required for" documentation anywhere in the header, meaning its real-world
  population remains the least predictable of any candidate — both its AX authority and Native E2E
  scores are capped accordingly. Unchanged from Phase 2BN.
- **`ui.read_element_parent_reference` (#10, 59/100)** — lowest score this round. Bounds risk
  (one hop from an unbounded upward walk) and low non-duplication (re-derives context already
  obtainable by resolving the container directly) both persist unchanged from Phase 2BN.
- **`ui.list_element_labeled_by_targets` (#7, 78/100)** — re-scored with an updated Autonomous
  usefulness rationale now that its mirror capability exists: it is a legitimate, bounded,
  privacy-safe candidate, but the underlying use case (an agent needing the reverse
  "what do I label" direction, given it can already ask "what labels me" via
  `ui.read_element_title_reference`) remains narrower than any of the top 6 candidates. Not
  selected, but a credible alternative — see Section 17.
- **Coordinate/geometry, `AXTextMarker*`, `AXObserver*`, keyboard-simulation candidates**: not
  regenerated this round — all remain excluded for the structural/security reasons recorded in
  prior phases (Section 4), independent of score.

---

## 10. Recommended Capability: `ui.read_window_modal_state`

**Score: 94/100 — highest of all 10 candidates.**

### Contract proposal

- **Capability ID:** `ui.read_window_modal_state`
- **Tool family:** `ui`
- **Risk level:** `.level0ReadOnly` (genuinely read-only: zero mutation, zero approval, zero
  standing authorization; `kAXModalAttribute` itself is documented `Writable? No`, so there is no
  accidental write-capable surface to guard against)
- **Human-readable name:** "Read Window Modal State"
- **Inputs:** `applicationName` (required), plus `windowIdentifier`/`windowTitle` (at least one
  required — the exact same `missingMatchCriteria` discipline as `ui.read_window_default_button`).
- **Output:** `QAXWindowModalStateMetadata { applicationName: String, windowTitle: String?,
  windowIdentifier: String?, isModal: Bool }`.

### Exact resolution path (verbatim reuse)

Identical to `ui.read_window_default_button` (Phase 2BM): `resolveExactRunningApplication(named:)`
→ `collectMatches(root:role:"AXWindow", identifier:, title:)` (via `QAXWindowRolePolicy`, reused
unmodified — no new role policy needed) → `snapshotIfMatches` staleness re-check (search vs. read)
→ read `kAXModalAttribute` → interpret as `Bool`.

### The Load-Bearing Design Decision (distinct from Phase 2BM/2BN's optional-reference pattern)

Unlike `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` or `kAXTitleUIElementAttribute` (all
documented as attributes many elements genuinely lack), `kAXModalAttribute`'s own SDK
documentation states it is **"Required for all window elements"** — there is no genuine, expected
"this window has no modal state" case the way there is for an optional button/title reference.
Therefore this capability's contract makes a deliberately different choice from every prior
optional-reference capability: **`kAXErrorNoValue`/`kAXErrorAttributeUnsupported` are treated as a
genuine read FAILURE here, not a valid absence** — because for a required-for-all-windows
attribute, an unexpected absence is itself an anomaly that must never be silently downgraded to a
guessed `false`. Silently defaulting an unreadable modal state to "not modal" would be exactly the
kind of dangerous silent-downgrade this program's missing-vs-failure discipline exists to prevent
(a planner that believes a window is not blocking-modal when its true state is simply unknown
could make an unsafe next-step decision). This is documented here explicitly per this program's
convention of recording implementation-shaping decisions rather than silently choosing one design
over another.

### Security analysis

- Level 0: no mutation path exists — never calls `AXUIElementSetAttributeValue` or
  `AXUIElementPerformAction`; `kAXModalAttribute` itself is `Writable? No` per its own SDK
  documentation, so there is no write-capable variant to accidentally expose.
- No coordinates, no CGEvent, no keyboard/mouse simulation, no screenshots, no OCR, no network, no
  shell — exactly one additional `AXUIElementCopyAttributeValue` call beyond the existing
  resolve/verify calls every window-scoped read capability already performs.
- Discovered modal state is DATA, not AUTHORIZATION: knowing a window is modal grants no standing
  capability to close, activate, or otherwise act on it or any other window — any subsequent
  mutation must independently pass its own full resolution/role-policy/`QPermissionGate` pipeline.

### Privacy analysis

- Returned field (`isModal: Bool`) is a single structural UI-state boolean — no typed text, no
  document content, no credentials, no OTPs, no payment data, ever exposed.
- Classification: **safe structural metadata** — the same tier as `minimized`/`main` in
  `ui.list_windows`'s own `QAXWindowMetadata`.
- No new privacy mechanism introduced: reuses `QAXWindowRolePolicy`'s existing single-role
  allowlist verbatim.

### Resource bounds

- `maxWindowsResolved = 1`; `maxElementsInspected = 1` (the window itself — no reference-follow
  hop, unlike the button/title-reference capabilities); `maxTraversalDepth = 0`;
  `maxChildren = 0`; `maxActionsPerformed = 0`; `maxPolling = 0`; `maxRetries = 0`;
  `maxReturnedRecords = 1`; no string-length bound applies (the only returned content-bearing
  fields are the window's own already-established `windowTitle`/`windowIdentifier`, echoed via the
  same pattern `ui.read_window_default_button` already uses).

### Verification strategy

New `QVerificationStrategy` case:
`.windowModalStateReadSucceeded(applicationName: String, windowTitle: String?, isModal: Bool)`.
Evaluates `result.success`; evidence string
`"application=<name> window=<title> isModal=<bool> status=verified"` — the boolean itself carries
no privacy risk (it is the capability's entire structural purpose, not per-item content), so unlike
button/label text it is safe to include directly in evidence, mirroring
`elementTitleReferenceReadSucceeded`'s inclusion of its own `hasTitleReference` boolean.

### Native E2E feasibility — genuinely exercised, not theoretical

`NSApplication.beginModalSession(for:)` / `endModalSession(_:)` are current, public, non-deprecated
AppKit APIs that begin and end a real modal session **without blocking the calling thread** (unlike
`-runModalForWindow:`/`NSAlert.runModal()`, which would block an async test indefinitely) — this
makes a genuine, non-fabricated fixture possible: create a real `NSWindow`, call
`NSApp.beginModalSession(for: window)`, read `kAXModalAttribute` (expect `true`), call
`NSApp.endModalSession(session)`, read again (expect `false`) — both states proven against a real,
live `AXUIElement`, TCC-guarded like every other real-fixture test in this codebase.

### Duplication analysis

Confirmed via `grep -rn "kAXModalAttribute" leanring-buddy/ leanring-buddyTests/` — zero matches
anywhere in the tree before this proposal. `ui.list_windows`'s `QAXWindowMetadata` carries
`minimized`/`main` but never `isModal`; `ui.read_window_default_button` reads a window's
default/cancel button references, an entirely different attribute pair. No existing capability
reads any window's modal state.

### Why preferable to the runner-up

The runner-up, `ui.read_text_selection_state` (91/100), scores nearly as high but has lower
Non-duplication headroom relative to `ui.read_element_range` (both are "read a bounded numeric/
boolean fact already partially adjacent to an existing role family") and a more involved E2E
fixture (requires first-responder/field-editor plumbing to establish a live text selection,
scored 8/10 on Native E2E vs. this candidate's genuinely non-blocking modal-session fixture,
scored 9/10). `ui.read_window_modal_state` also has the single highest AX/API authority score of
any candidate (19/20 — `kAXModalAttribute`'s SDK documentation is unusually explicit and
unconditional: "Required for all window elements"), the smallest possible implementation surface
(zero reference-follow hops, a single boolean field, no new struct beyond the metadata wrapper
itself), and directly composes with the already-implemented `ui.read_window_default_button`
(Phase 2BM) to build a fuller picture of window-blocking semantics before any window-affecting
mutation is proposed — advancing exactly the "safe observation" and "bounded reasoning" priorities
this phase's objective names.

---

## 11. Top 3 Alternatives (full detail)

### Alternative 1 — `ui.read_text_selection_state` (91/100)

- **AX API:** `kAXSelectedTextRangeAttribute` (`AXValueRef` of `kAXValueTypeCFRange`) +
  `kAXNumberOfCharactersAttribute` (`CFNumberRef`). Deliberately excludes
  `kAXSelectedTextAttribute` (the actual selected string) to stay privacy-safe.
- **Contract:** `{applicationName, role, selectionLocation: Int, selectionLength: Int,
  totalCharacterCount: Int}`, mirroring `QAXElementRangeMetadata`'s (Phase 2BJ) "numeric facts
  only, never content" design.
- **Why it lost:** Non-duplication (14/15) is capped slightly below this round's winner because it
  sits in similar territory to `ui.read_element_range`'s existing "bounded numeric fact" pattern;
  Native E2E (8/10) requires first-responder/field-editor plumbing, a more involved fixture than
  the winner's non-blocking modal session.

### Alternative 2 — `ui.read_element_action_description` (89/100)

- **AX API:** `AXUIElementCopyActionDescription(element, action, &description)` — a genuinely
  fresh C API surface (its sibling `AXUIElementCopyActionNames` has been in production since Phase
  2BK; this function has never been called anywhere in this codebase).
- **Contract:** given a resolved element (reusing `QAXElementReadRolePolicy` verbatim) and a
  caller-supplied `actionName` (expected to have been discovered via a prior
  `ui.list_element_actions` call, though this capability independently re-validates it rather than
  trusting that provenance), return `{applicationName, role, actionName, description: String?}`.
  `kAXErrorActionUnsupported` maps to a dedicated failure (never silently `nil`, since an
  unsupported action name is a caller/contract error, not a graceful absence).
- **Why it lost:** Non-duplication (12/15) is the lowest driver — it is an enrichment/detail layer
  on top of an existing capability (`ui.list_element_actions`) rather than a wholly new
  relationship or state category, and its usefulness is conditional on the caller already having
  performed that prior call. A very strong candidate for a future phase, particularly once
  `ui.list_element_actions` sees real autonomous usage patterns that would justify the enrichment.

### Alternative 3 — `ui.read_scroll_position` (89/100)

- **AX API:** `kAXValueAttribute` (`CFNumberRef`, 0.0–1.0) of the `AXScrollBar` resolved via the
  exact `AXScrollArea` → `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute`
  convenience-reference path `ui.set_scroll_position`'s mutation already uses.
- **Contract:** `{applicationName, orientation: "horizontal"|"vertical", currentValue: Double}`,
  reusing `QAXScrollAreaRolePolicy` and the existing `targetNotAScrollBar` error case verbatim.
- **Why it lost:** identical reasoning to Phase 2BN's own assessment — Non-duplication (13/15) is
  the lowest-scoring dimension, since it is architecturally a direct read-only mirror of an
  existing mutation's own resolution path rather than a new information category.

**Fourth-place note:** `ui.list_ruler_markers` (87/100) is a strong, fully fresh structural
enumeration gap (see Section 5) but scores lower on Autonomous usefulness (13/20) than the top
three — rulers are a narrower AppKit feature (drawing/layout/publishing-style apps) than window
modal state, text selection, action descriptions, or scroll position, all of which apply broadly
across almost any application. Recorded here as the strongest candidate outside the top 3, not
silently dropped.

---

## 12. Implementation-Not-Started Declaration

No production code, test code, capability registry, schema, execution logic, verification logic,
permission logic, recovery logic, persistence, or security infrastructure was modified to produce
this document. The only repository change made during this discovery phase is this file itself.

---

## 13. Scope Gate

```
$ git status --short
?? docs/PHASE_2BO_CAPABILITY_ROADMAP.md
$ git diff --stat
(empty — no tracked file was modified)
```

Exactly one new, untracked file. No production, test, registry, schema, execution, verification,
permission, recovery, or persistence file was created or modified during this discovery phase.

**No commit was made.** This is discovery only.

---

## 14. Final Discovery Report

- Baseline confirmed: commit `5125a62`, capability count 62, clean tree — all matched.
- 62 capabilities inventoried directly from source; confirmed no duplicate/overlapping
  implementations exist among them.
- Reviewed all 28 existing `PHASE_2A*`/`PHASE_2B*_CAPABILITY_ROADMAP.md` documents (earliest
  present: `2AI`); identified that the long-carried-forward `ui.read_element_label` gap is now
  RESOLVED by Phase 2BN's `ui.read_element_title_reference` and removed it from further
  consideration; re-examined all other carried-forward and previously-rejected candidates for
  materially new evidence (found none for any rejected candidate).
- Fresh SDK research this round covered `kAXModalAttribute` (fully documented, "Required for all
  window elements," completely unused), the ruler-marker attribute cluster
  (`kAXMarkerUIElementsAttribute` and siblings, completely unused), and
  `AXUIElementCopyActionDescription` (a fresh C API surface, completely unused despite its sibling
  `AXUIElementCopyActionNames` being in production since Phase 2BK), plus confirmed
  `NSApplication.beginModalSession(for:)`/`endModalSession(_:)` as a genuine, non-blocking native
  E2E fixture path.
- 10 serious candidates generated and scored on the specified 8-part, 100-point rubric.
- Winner selected: **`ui.read_window_modal_state`** (94/100) — reads `kAXModalAttribute`, the
  highest-authority AX evidence of any candidate this round, with the smallest possible
  implementation surface, a genuinely non-blocking native E2E fixture, and a distinct
  missing-vs-failure design decision (required attribute → absence is failure, never a silent
  `false` default) documented explicitly.
- Top 3 alternatives fully specified: `ui.read_text_selection_state` (91),
  `ui.read_element_action_description` (89), `ui.read_scroll_position` (89) — with
  `ui.list_ruler_markers` (87) noted as the strongest candidate outside the top 3.
- Scope gate passed: only `docs/PHASE_2BO_CAPABILITY_ROADMAP.md` is new/modified; `git diff --stat`
  confirms zero tracked-file changes.
- No commit created.
- **Implementation: NOT STARTED.**

Phase 2BO — DISCOVERY COMPLETE
Awaiting review

---

## Addendum: Implementation Status

`ui.read_window_modal_state` was approved and implemented. See
`docs/PHASE_2BO_SEMANTIC_WINDOW_MODAL_STATE.md` for the full implementation contract, test
results, and release-build verification. Capability count: 62 → 63.

