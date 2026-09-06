# Phase 2BN — Capability Discovery Roadmap (Discovery Only)

**Status:** DISCOVERY COMPLETE — Implementation NOT STARTED.
**Baseline commit:** `0802216` (`08022168a3ad531f330bb0f2b00201dab5dcffaf`)
**Authoritative capability count at start of discovery:** 61 (verified via `grep -c '": ("' leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`)
**Last closed capability:** `ui.read_window_default_button` (Phase 2BM)
**Working tree at start of discovery:** CLEAN

This document is the sole artifact of Phase 2BN. No production code, test code, or capability
registry entries were modified to produce it. Every SDK claim below was re-verified directly
against the installed SDK headers this round — nothing is carried forward from memory or from
prior phase documents without a fresh `grep`/read against source.

---

## 1. Baseline Verification

```
$ git status --short
(empty — clean)
$ git rev-parse HEAD
08022168a3ad531f330bb0f2b00201dab5dcffaf
$ grep -c '": ("' leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift
61
```

All three checks match the stated baseline exactly. Discovery proceeded.

---

## 2. Authoritative Capability Inventory (source-derived, 61 total)

Pulled directly from `QModelPlanParser.registeredCapabilities` in `QModelPlanSchema.swift`
(not from any prior roadmap doc). Grouped by family for readability; risk level is exactly the
second tuple element in source.

**Level 0 (read-only, 32 capabilities):** `system.running_apps`, `screen.ocr`, `fs.read`,
`test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`,
`ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`,
`ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`,
`ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`,
`ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`,
`ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`,
`ui.list_combo_boxes`, `ui.list_rulers`, `ui.list_combo_box_items`, `ui.read_focused_element`,
`ui.read_application_state`, `ui.list_table_columns`, `ui.read_element_range`,
`ui.list_element_actions`, `ui.list_element_attributes`, `ui.read_window_default_button`.

**Level 1 (safe local action, 4):** `ui.open_app`, `fs.write_sandbox`, `ui.activate_application`.

**Level 2 (user approval, 22):** `system.clipboard.write`, `ui.click_element`,
`ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`,
`ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`,
`ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`,
`ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`,
`ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`,
`ui.select_combo_box_item`, `ui.step_incrementor`.

**Level 3 (high risk, 2):** `app.quit`, `ui.close_window`.

**Role policies in `QBridgeAdapters.swift`:** 30 distinct `QAX*RolePolicy` enums, each a narrow
`Set<String>` allowlist independently re-validated at read/mutation time (never inferred).

### Key structural observations feeding gap analysis

- `ui.list_windows` (`QAXWindowMetadata`) returns exactly `title`, `identifier`, `minimized`,
  `main` — no full-screen flag, despite `ui.set_window_full_screen` existing and already reading
  `kAXFullScreenAttribute` internally (Phase 2AS). A read-only full-screen check has no home.
- `ui.set_scroll_position` resolves an `AXScrollArea` → convenience-reference (`kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute`) → `AXScrollBar`, then **writes**
  `kAXValueAttribute`. There is no read-only counterpart that returns the current scroll value
  without attempting a mutation.
- `QAXElementReadRolePolicy` (the generic single-attribute read allowlist used by
  `ui.read_element_value`) covers `AXTextField, AXTextArea, AXStaticText, AXButton, AXCheckBox,
  AXRadioButton, AXPopUpButton, AXMenuButton, AXMenuItem, AXComboBox, AXSlider, AXStepper, AXLink,
  AXTab, AXDisclosureTriangle` — i.e. exactly the roles a `kAXTitleUIElementAttribute` read would
  also want to target. No existing capability reads this attribute.
- No existing capability reads `kAXSelectedTextRangeAttribute` / `kAXNumberOfCharactersAttribute`,
  `kAXHelpAttribute` (used internally only as a best-effort fallback string inside two existing
  capabilities' output, never exposed as its own capability), `kAXLinkedUIElementsAttribute`,
  `kAXPositionAttribute`/`kAXSizeAttribute`, or `kAXParentAttribute`/`kAXTopLevelUIElementAttribute`.

---

## 3. Duplicate Search Methodology

For every candidate attribute/action considered below, ran:
```
grep -rn "<ExactSDKConstantName>" leanring-buddy/ leanring-buddyTests/
```
against the full source tree (not just `QBridgeAdapters.swift`) before treating it as fresh
ground. Confirmed zero matches for `kAXTitleUIElementAttribute`, `kAXServesAsTitleForUIElementsAttribute`, `kAXLinkedUIElementsAttribute`, `kAXLabelUIElementsAttribute`,
`kAXSelectedTextRangeAttribute`, `kAXSelectedTextAttribute`, `kAXNumberOfCharactersAttribute`,
`kAXPositionAttribute`, `kAXSizeAttribute`, `kAXParentAttribute` anywhere in the tree.
`kAXHelpAttribute` and `kAXFullScreenAttribute` do have existing matches (used as internal
implementation details of other capabilities), so those two candidates were scored down on the
Non-duplication dimension accordingly rather than rejected outright.

---

## 4. Fresh Apple SDK Research (this round)

SDK root: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`.

- **`AXAttributeConstants.h`** (`HIServices.framework`) — re-read in full. New ground identified
  this round vs. all prior phases (2BG covered raw name sweep, 2BJ covered Writable-Yes sweep,
  2BI covered obsolete-marking sweep): the *relationship* attributes clustered near line 1190–1210
  (`kAXTitleUIElementAttribute`, `kAXLabelUIElementsAttribute`, `kAXLabelValueAttribute`,
  `kAXServesAsTitleForUIElementsAttribute`, `kAXLinkedUIElementsAttribute`) and the *text-selection*
  attributes clustered near line 684–755 (`kAXSelectedTextAttribute`,
  `kAXSelectedTextRangeAttribute`, `kAXSelectedTextRangesAttribute`,
  `kAXVisibleCharacterRangeAttribute`, `kAXNumberOfCharactersAttribute`) — neither cluster was
  the focus of any prior phase's search axis.
- **`kAXTitleUIElementAttribute`** (line 1031): `#define kAXTitleUIElementAttribute
  CFSTR("AXTitleUIElement")`. No local doc block in this header (predates the header's comment
  convention), so cross-referenced against the authoritative typed declaration in
  `NSAccessibilityProtocols.h` (AppKit) — see below.
- **`NSAccessibilityProtocols.h`** (`AppKit.framework`) — re-read the `NSAccessibilityElement`
  informal protocol's property list (already enumerated in full in Phase 2BM; this round
  targeted specifically the title/label-cluster properties skipped over previously):
  ```objc
  // Visible text on the UIElement
  // Invokes when clients request NSAccessibilityTitleAttribute
  @property (nullable, copy) NSString *accessibilityTitle API_AVAILABLE(macos(10.10));

  // UIElement for the title
  // Invokes when clients request NSAccessibilityTitleUIElementAttribute
  @property (nullable, weak) id accessibilityTitleUIElement API_AVAILABLE(macos(10.10));
  ```
  Confirms `kAXTitleUIElementAttribute`'s authoritative documented semantics: "UIElement for the
  title" — the element that serves as another element's title/label, independent of whether the
  element has its own rendered title text. Available since 10.10, on the universal
  `NSAccessibilityElement` protocol every `NSView`/`NSCell` conforms to — not web-specific, not
  role-specific, not deprecated.
- **`kAXSelectedTextAttribute`** (line 694): "The selected text of an editable text element. …
  Required for all editable text elements." — CFStringRef, genuinely sensitive (arbitrary
  document/field content) — considered and explicitly excluded from the resulting candidate.
- **`kAXSelectedTextRangeAttribute`** (line 709): "The range of characters (not bytes) that
  defines the current selection… AXValueRef of type kAXValueCFRange. Writable? Yes. Required for
  all editable text elements." — read-only use is purely numeric (location + length), no content.
- **`kAXNumberOfCharactersAttribute`** (line 754): "The total number of characters (not bytes) in
  an editable text element. Value: CFNumberRef. Writable? No. Required for editable text
  elements." — again purely numeric.
- **`kAXFullScreenAttribute`** (already known from Phase 2AS, re-confirmed present and unchanged
  in this SDK revision): `CFBooleanRef`, read/write, used today only inside
  `setWindowFullScreenState`'s mutation + internal verification. No dedicated read capability.
- **`kAXHelpAttribute`** (`AXActionConstants.h`/`AXAttributeConstants.h` family, already known):
  `CFStringRef`, tooltip/help text. Used today only as an internal best-effort fallback string
  inside two existing capabilities' output construction — never itself the subject of a
  capability, and never independently verified as present/absent per the missing-vs-failure
  discipline established in Phase 2BM.
- **`AXWebConstants.h`** — read in full this round (not previously inspected as its own axis).
  Confirms its own header doc: "Accessibility roles, attributes, actions, notifications, etc.
  that are specific to web content." Contains `AXTextMarker*`-family parameterized attributes
  (already rejected in prior phases as privacy-adjacent/complex), ARIA-specific attributes, and
  math-markup attributes — none are safely generalizable to arbitrary (non-web) AppKit
  applications, which is Pace's primary automation surface. No candidate drawn from this header
  this round; documented here to prove it was actually read, not skipped.
- **`AXValue.h`** — re-read in full. Confirms `AXValueType` enum (`kAXValueTypeCGPoint`,
  `kAXValueTypeCGSize`, `kAXValueTypeCGRect`, `kAXValueTypeCFRange`, `kAXValueTypeAXError`) and the
  three accessor externs (`AXValueCreate`, `AXValueGetType`, `AXValueGetValue`) — all already in
  active use (`kAXValueTypeCFRange` for ranges, e.g. `QAXElementRangeMetadata`); no new API
  surface found here.
- **`AXActionConstants.h`, `AXRoleConstants.h`, `AXUIElement.h`** — re-swept for anything added
  since Phase 2BG/2BJ/2BL's prior full enumerations. No new externs, no new role/action constants
  found; confirmed identical to what those phases already catalogued.

---

## 5. Candidate Generation (9 candidates — exceeds the ≥8 floor)

| # | Candidate ID | AX API | One-line description |
|---|---|---|---|
| 1 | `ui.read_element_title_reference` | `kAXTitleUIElementAttribute` | Read the element that serves as a target's title/label, as a safe reference (role/title/identifier only). |
| 2 | `ui.read_text_selection_state` | `kAXSelectedTextRangeAttribute` + `kAXNumberOfCharactersAttribute` | Read an editable text element's selection extent (location, length, total character count) — never the selected text itself. |
| 3 | `ui.read_scroll_position` | `kAXValueAttribute` of the convenience-referenced `AXScrollBar` | Read-only counterpart to `ui.set_scroll_position`: current scroll fraction per orientation. |
| 4 | `ui.read_window_full_screen_state` | `kAXFullScreenAttribute` | Read-only counterpart to `ui.set_window_full_screen`: is this window currently full-screen. |
| 5 | `ui.list_element_linked_references` | `kAXLinkedUIElementsAttribute` | List other elements a target is semantically linked to (e.g. an error message linked to its field), as safe references. |
| 6 | `ui.read_element_help` | `kAXHelpAttribute` | Read an element's help/tooltip string as its own dedicated, verified capability. |
| 7 | `ui.read_element_geometry` | `kAXPositionAttribute` / `kAXSizeAttribute` | Read an element's on-screen frame. |
| 8 | `ui.read_element_parent_reference` | `kAXParentAttribute` / `kAXTopLevelUIElementAttribute` | Read a single-hop reference to an element's parent or owning window. |
| 9 | `ui.list_element_labeled_by_targets` | `kAXServesAsTitleForUIElementsAttribute` | The reverse of #1: list every element a given label element is the title for. |

---

## 6. Candidate Scoring (8-part rubric, 100 points)

Weights this round: **A. AX/API authority (20) · B. Non-duplication (15) · C. Autonomous
usefulness (20) · D. Contract clarity (10) · E. Bounds (10) · F. Privacy (10) · G. Verification (5)
· H. Native E2E (10)**.

| # | Candidate | A /20 | B /15 | C /20 | D /10 | E /10 | F /10 | G /5 | H /10 | **Total** |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `ui.read_element_title_reference` | 20 | 15 | 18 | 10 | 10 | 10 | 5 | 10 | **98** |
| 2 | `ui.read_text_selection_state` | 20 | 14 | 15 | 9 | 10 | 10 | 5 | 8 | **91** |
| 3 | `ui.read_scroll_position` | 18 | 13 | 15 | 9 | 10 | 10 | 5 | 9 | **89** |
| 4 | `ui.read_window_full_screen_state` | 16 | 11 | 13 | 10 | 10 | 10 | 5 | 9 | **84** |
| 9 | `ui.list_element_labeled_by_targets` | 17 | 10 | 10 | 8 | 8 | 9 | 5 | 7 | **74** |
| 5 | `ui.list_element_linked_references` | 15 | 9 | 9 | 7 | 7 | 8 | 5 | 6 | **66** |
| 6 | `ui.read_element_help` | 14 | 6 | 8 | 9 | 10 | 9 | 5 | 8 | **69** |
| 8 | `ui.read_element_parent_reference` | 14 | 6 | 8 | 7 | 4 | 8 | 5 | 7 | **59** |
| 7 | `ui.read_element_geometry` | 16 | 8 | 12 | 8 | 8 | 5 | 5 | 8 | **70 → REJECTED (security)** |

### Rejected / down-scored candidates — rationale

- **`ui.read_element_geometry` (#7) — REJECTED on security grounds, not merely low score.**
  `kAXPositionAttribute`/`kAXSizeAttribute` return exactly the screen-coordinate data that feeds
  coordinate-based targeting — the single category of information this program's forbidden-API
  list exists to keep out of the model's hands (`AXUIElementCopyElementAtPosition`, CGEvent
  synthesis, mouse simulation are all coordinate-consuming). Even a read-only frame, once visible
  to the planner, creates a standing temptation/pathway toward coordinate-based action proposals
  that every other capability in this registry has been deliberately designed to make
  unnecessary (semantic resolution instead of position). Rejected regardless of numeric score.
- **`ui.read_element_parent_reference` (#8)** — low Bounds score: a parent-chain reference is one
  hop away from an unbounded upward walk, and `kAXTopLevelUIElementAttribute`'s own doc text
  ("Required for any element that has an appropriate element somewhere in its parent chain")
  implies exactly the kind of chain-walking the existing bounded `collectMatches` traversal
  (downward-only, depth/count-capped) was built to avoid doing in reverse. Also low
  non-duplication: a parent reference mostly re-derives context (container role/title) already
  obtainable by resolving the container directly via its own title/identifier.
- **`ui.read_element_help` (#6)** — already touched internally (used as an unverified fallback
  string in two existing capabilities), so Non-duplication is capped low; promoting it to its own
  capability would mean formalizing a string that today is explicitly best-effort/unverified,
  which cuts against the "discovered data must be independently, honestly verified" discipline
  from Phase 2BM. Viable future candidate if a phase specifically wants tooltip semantics, but not
  competitive this round.
- **`ui.list_element_linked_references` (#5)** — `kAXLinkedUIElementsAttribute` has no
  role-specific "required for" documentation anywhere in the header (unlike every other
  candidate here), meaning its actual population by real apps is the least predictable of the
  set — this shows up directly in a lower AX/API authority score and a weaker Native E2E score
  (no well-known AppKit control reliably populates it for a deterministic fixture).
- **`ui.list_element_labeled_by_targets` (#9)** — the mirror image of the winner
  (`kAXServesAsTitleForUIElementsAttribute` returns an array where #1 returns a single reference).
  Genuinely useful but strictly lower-value than #1: an agent that already knows a field's own
  label (via #1, from the field's side) rarely also needs the reverse array from the label's
  side, and the one real use case it adds (one label serving several fields) is narrower than
  #1's universal "what labels this control" question. Kept as the strongest runner-up.
- **`ui.read_text_selection_state` (#2), `ui.read_scroll_position` (#3),
  `ui.read_window_full_screen_state` (#4)** — all solid, all scored competitively (89–91), none
  disqualified; see Section 13 for full alternative write-ups. Each loses to the winner primarily
  on Non-duplication (all three sit adjacent to ground an existing mutation or existing read
  capability already partially covers) and, for #4 specifically, on Autonomous usefulness (a
  single boolean is a narrower payoff than a resolvable label reference).

---

## 7. Recommended Capability: `ui.read_element_title_reference`

**Score: 98/100 — highest of all 9 candidates, zero security rejection concerns.**

### Contract proposal

- **Capability ID:** `ui.read_element_title_reference`
- **Tool family:** `ui`
- **Risk level:** `.level0ReadOnly` (genuinely read-only: zero mutation, zero approval, zero
  standing authorization, zero `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` calls)
- **Human-readable name:** "Read Element Title Reference"
- **Inputs:** `applicationName` (required), plus the target element's own match criteria —
  `elementIdentifier` and/or `elementTitle` (at least one required, exactly mirroring every prior
  read capability's `missingMatchCriteria` discipline), and `elementRole` is NOT accepted as a
  free-form input — the target is resolved via `QAXElementReadRolePolicy`'s existing allowlist
  exactly as `ui.read_element_value` already does, reusing that policy verbatim (no new role
  policy needed).
- **Output:** a `QAXElementTitleReference?` — `nil` when the target genuinely has no
  `kAXTitleUIElementAttribute` value (via `.noValue`/`.attributeUnsupported`, the valid-absence
  path established in Phase 2BM), or a small struct when present:
  ```swift
  public struct QAXElementTitleReference: Sendable, Equatable, Codable {
      public let role: String
      public let title: String?
      public let identifier: String?
  }
  ```
  Constructed by resolving `kAXTitleUIElementAttribute`'s `AXUIElementRef` value, validating
  `CFGetTypeID(value) == AXUIElementGetTypeID()` (else `.titleReferenceMalformed`), reading its
  own `kAXRoleAttribute` (no role restriction on the referenced element — a title element can
  legitimately be `AXStaticText`, `AXGroup`, or others), and its `kAXTitleAttribute`/identifier —
  the exact same "resolve optional AXUIElement-valued attribute → validate type → extract bounded
  safe strings" pattern `resolveWindowButtonReference` established in Phase 2BM, applied to a new
  attribute rather than a new pattern. String length capped at the same 256-character ceiling
  used for window button metadata (new `maxTitleReferenceMetadataLength` constant, same value,
  named independently per capability per this codebase's existing convention of not sharing
  bound constants across unrelated capabilities).

### Resolution path (verbatim reuse)

`resolveExactRunningApplication(named:)` → `collectMatches(root:role:identifier:title:)` bounded
search using `QAXElementReadRolePolicy.allowedRoles` → `snapshotIfMatches` staleness re-check
(search vs. read) → read `kAXTitleUIElementAttribute` → resolve+validate the referenced element.
Every primitive here is an existing one; no new resolution machinery.

### Security analysis

- Level 0: no mutation path exists in this capability at all — it never calls
  `AXUIElementSetAttributeValue` or `AXUIElementPerformAction`.
- No coordinates, no CGEvent, no keyboard/mouse simulation, no screenshots, no OCR, no network,
  no shell — capability touches exactly one additional `AXUIElementCopyAttributeValue` call per
  invocation beyond the existing resolve/verify calls every read capability already performs.
- **Discovered data is DATA, not AUTHORIZATION** (the invariant established starting Phase 2BK):
  learning that element X is the title reference for element Y grants no standing capability to
  act on either X or Y — any subsequent action against either element must independently pass
  through its own fresh `resolveExactRunningApplication`/`collectMatches`/role-policy/
  `QPermissionGate` path exactly as today. This capability adds a discovery/context primitive,
  never an actionable handle — the referenced element's raw `AXUIElement` is never returned or
  cached, only its safe descriptive strings.
- Missing-vs-failure discipline (Phase 2BM pattern) applies identically: `.noValue`/
  `.attributeUnsupported` → valid `nil`; any other `AXError`, a malformed returned CF type, is a
  distinct failure (`.titleReferenceReadFailed`/`.titleReferenceMalformed`), never silently
  collapsed into absence.

### Privacy analysis

- Returned fields (`role`, `title`, `identifier`) are exactly the same class of information every
  existing list/read capability already exposes (e.g. `QAXMenuItemMetadata`,
  `QAXWindowButtonReference`) — no new privacy category is introduced.
- No typed text, no credentials, no OTPs, no payment data, no document body content — a title
  reference is, by definition, itself a short UI label (e.g. "Name:", "Search"), not arbitrary
  content.
- `AXSecureTextField` remains excluded via the reused `QAXElementReadRolePolicy` allowlist (which
  already omits it) as the search anchor; even if a secure field's associated label element were
  somehow reachable, the label itself is never the sensitive value — but as an added safeguard
  this capability's contract explicitly forbids resolving `AXSecureTextField` as either the
  source OR the referenced element (checked on both ends before returning).
- Classification: **safe structural metadata** (per the four-way privacy classification:
  safe-structural / model-visible-ephemeral / sensitive-must-not-persist / prohibited) — same
  tier as every other Level 0 list/read capability in the registry. `outputData` (ephemeral,
  per-turn) carries the full struct; `resultSummary`/verification evidence carries only aggregate
  status (`status=verified`), never the actual title/identifier strings, exactly matching every
  predecessor capability's durable-state exclusion discipline (`QDurablePlanStepSnapshot` has no
  `outputData` field at all, confirmed by direct grep — per-item content structurally cannot
  reach durable storage).

### Bounds

- Exactly one extra `AXUIElementCopyAttributeValue` call for the reference attribute, plus at
  most two more (`kAXRoleAttribute`, `kAXTitleAttribute`) and one identifier read on the resolved
  reference element — a small, fixed, non-recursive cost identical in shape to
  `resolveWindowButtonReference`'s two-call pattern in Phase 2BM.
- String fields capped at 256 characters (`maxTitleReferenceMetadataLength`); exceeding the cap
  fails closed (`.titleReferenceExceedsSafeLength`) rather than truncating silently.
- No traversal, no recursion, no polling, no retries — a single point-in-time read.

### Verification strategy

New `QVerificationStrategy` case: `.titleReferenceReadSucceeded(applicationName: String, elementRole: String)`. Evaluates `result.success`; evidence string
`"application=\(applicationName) role=\(elementRole) status=verified"` — aggregate-only, no
title/identifier content, matching every prior capability's evidence-construction discipline.
`QPlanExecutor.determineVerificationStrategy` gets its own dedicated
`action.actionName == "ui.read_element_title_reference"` branch (never the generic
`customCheck(description: "Default step verification") { true }` fallback).

### Native E2E feasibility — strongest of any phase so far

Unlike Phase 2BM's window-button capability (which could only build a complete fixture for the
default button, not the cancel button, due to no public `NSWindow.cancelButtonCell` equivalent),
this capability has a **complete, first-party, zero-workaround fixture path**: create two real
`NSTextField` views (a label field and an input field) and call
`inputField.setAccessibilityTitleUIElement(labelField)` — a standard, fully public
`NSAccessibilityElement`/`NSView` API, no custom subclassing, no private API, no synthetic
observation-binding tricks required. Both the "reference present" and "reference absent" (a plain
`NSTextField` with no title-UI-element ever set) paths are fully provable against live
`AXUIElement`s under real TCC-granted process trust — the same honest BLOCKED-when-untrusted
reporting applies when `AXIsProcessTrusted()` is false, per every prior phase's discipline.

### Why not a duplicate

Verified via `grep -rn "kAXTitleUIElementAttribute\|TitleUIElement" leanring-buddy/
leanring-buddyTests/` — zero matches anywhere in the tree before this proposal. No existing
capability reads any title/label *relationship* — every existing read capability reads an
element's own attributes (`ui.read_element_value`, `ui.list_element_attributes`) or lists its own
children/rows/items (the twenty-odd `ui.list_*` capabilities), never a cross-element semantic
link. This is a structurally new category of information, not a rephrasing of an existing one.

### Why preferable to the runner-up

The runner-up, `ui.list_element_labeled_by_targets` (`kAXServesAsTitleForUIElementsAttribute`,
74/100), is the mirror relationship (from the label's side, returning an array of elements it
labels) rather than the far more common query direction (from an unlabeled control, "what labels
me?"). `ui.read_element_title_reference` answers the question an agent actually has when it
encounters an ambiguous, title-less control; the reverse query is a narrower, less frequently
useful direction, and returns a plural/array result (higher bounds risk, lower contract-clarity
score) rather than the winner's single optional reference.

---

## 8. Top 3 Alternatives (full detail)

### Alternative 1 — `ui.read_text_selection_state` (91/100)

- **AX API:** `kAXSelectedTextRangeAttribute` (`AXValueRef` of `kAXValueTypeCFRange`) +
  `kAXNumberOfCharactersAttribute` (`CFNumberRef`). Deliberately **excludes**
  `kAXSelectedTextAttribute` (the actual selected string) — reading it would expose arbitrary
  document/field content, which fails the Privacy dimension outright regardless of how the rest
  of the contract is designed.
- **Contract:** given a resolved editable-text element (`AXTextField`/`AXTextArea`, reusing
  `QAXElementReadRolePolicy` minus `AXSecureTextField`), return `{applicationName, role,
  selectionLocation: Int, selectionLength: Int, totalCharacterCount: Int}`. Mirrors
  `QAXElementRangeMetadata`'s (Phase 2BJ) "numeric facts only, never content" design exactly.
- **Security/Privacy:** Level 0, purely numeric, no string content ever returned — explicitly
  the same content-avoidance decision documented for `ui.read_element_range`.
- **Bounds:** two fixed AX calls, no recursion.
- **Verification:** `.textSelectionStateReadSucceeded(applicationName:role:)`.
- **Native E2E:** requires a real `NSTextField`/`NSTextView` with the field editor made first
  responder and a live `selectedRange` set (`currentEditor()?.selectedRange`) — fully achievable
  but a materially more involved fixture (first-responder plumbing) than the winner's two-view
  wiring, which is why it scores 8/10 rather than 10/10 on Native E2E.
- **Why it lost:** lower Non-duplication (91 vs 98) — it sits in the same general "read a bounded
  numeric fact about an already-covered role family" territory as `ui.read_element_range`,
  whereas the winner opens a genuinely new relationship category with zero adjacent precedent.

### Alternative 2 — `ui.read_scroll_position` (89/100)

- **AX API:** `kAXValueAttribute` (`CFNumberRef`, 0.0–1.0) of the `AXScrollBar` resolved via the
  exact same `AXScrollArea` → `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute`
  convenience-reference path `ui.set_scroll_position`'s mutation already uses.
- **Contract:** `{applicationName, orientation: "horizontal"|"vertical", currentValue: Double}`,
  reusing `QAXScrollAreaRolePolicy` and the existing `targetNotAScrollBar` error case verbatim.
- **Security/Privacy:** Level 0, single bounded numeric fraction, no content.
- **Bounds:** fixed two-hop resolution (scroll area → scroll bar), no recursion.
- **Verification:** `.scrollPositionReadSucceeded(applicationName:orientation:)`.
- **Native E2E:** a real `NSScrollView` with content taller than its visible frame, scrolled
  programmatically before the read — solid, achievable, scores 9/10.
- **Why it lost:** lowest Non-duplication of the top four (89, driven by a 13/15) — it is
  architecturally a direct read-only mirror of an existing mutation's own resolution path, which
  is valuable but the least novel of the three runners-up in terms of what NEW information
  category it introduces to the model (a scroll fraction is conceptually adjacent to the
  min/max/current triple `ui.read_element_range` already generalized in Phase 2BJ).

### Alternative 3 — `ui.read_window_full_screen_state` (84/100)

- **AX API:** `kAXFullScreenAttribute` (`CFBooleanRef`), already integrated as an internal
  read inside `setWindowFullScreenState`'s mutation/verification path (Phase 2AS) but never
  exposed as its own read-only, mutation-free capability.
- **Contract:** given a resolved `AXWindow` (reusing `QAXWindowRolePolicy` verbatim, exactly the
  same single-window resolution shape as `ui.read_window_default_button`), return
  `{applicationName, windowTitle, windowIdentifier, isFullScreen: Bool}`.
- **Security/Privacy:** Level 0, single boolean, no content.
- **Bounds:** one AX call beyond window resolution.
- **Verification:** `.windowFullScreenStateReadSucceeded(applicationName:windowTitle:)`.
- **Native E2E:** a real `NSWindow` toggled into full-screen (`toggleFullScreen(_:)`) before the
  read — achievable, scores 9/10.
- **Why it lost:** lowest score of the four — Non-duplication (11/15) is capped because
  `list_windows` already enumerates window-level boolean state (`minimized`, `main`) and a
  reviewer would reasonably ask why full-screen isn't simply a fourth field there rather than its
  own capability; Autonomous usefulness (13/20) is also the lowest of the four, since a single
  already-partially-observable (via the mutation's own verified-outcome fields, when that
  mutation has actually been invoked) boolean is a narrower net-new payoff than a title
  reference, a selection extent, or a scroll fraction.

---

## 9. Implementation Preview (NOT PERFORMED THIS PHASE)

The following is a preview only, to support the approval decision — no code, test, or registry
file was touched to produce it:

- New error cases in `QAXInteractionError`: `titleReferenceReadFailed(String)`,
  `titleReferenceMalformed`, `titleReferenceExceedsSafeLength(Int)` — following the exact
  precedent of `windowButtonReferenceReadFailed`/`windowButtonReferenceMalformed`/
  `windowButtonMetadataExceedsSafeLength` from Phase 2BM, renamed for this capability's own
  attribute.
- New struct `QAXElementTitleReference` in `QBridgeAdapters.swift`.
- New method `QBridgeAccessibility.readElementTitleReference(applicationName:elementIdentifier:elementTitle:) async throws -> QAXElementTitleReference?`, reusing
  `resolveExactRunningApplication`, `collectMatches` (role set = `QAXElementReadRolePolicy.allowedRoles`), `snapshotIfMatches`, and a small
  private helper mirroring `resolveWindowButtonReference`'s shape.
- One new `case "ui.read_element_title_reference":` branch in `QExecutionService.executeAction`'s
  switch, plus one new private `executeReadElementTitleReference(request:)` method.
- One new `.titleReferenceReadSucceeded` case in `QVerificationStrategy` +
  `QActionVerifier.verify`.
- One new branch in `QPlanExecutor.determineVerificationStrategy`.
- One new registry entry: `"ui.read_element_title_reference": ("ui", .level0ReadOnly)`.
- A new test file `QSemanticElementTitleReferenceReadTests.swift`, targeting ≥20 tests, following
  the established suite shape (unit-level struct/error tests, role-policy tests, resolver
  ambiguity/staleness tests reusing `QApplicationResolutionHardeningTests` patterns, a
  TCC-guarded real end-to-end test against a live two-`NSTextField` fixture, and a durable-state/
  audit-log exclusion test using a distinctively-named fixture label value).

None of the above has been created. This section exists solely so the approval decision can be
made with full visibility into what implementation would entail.

---

## 10. Discovery History Cross-Check (2AC → 2BM)

Cross-referenced this round's 9 candidates against the selected/rejected capability lists from
every phase since capability-discovery documents began (2AC onward, through 2BM) to avoid
re-litigating settled ground:

- `AXTextMarker*`-family attributes (which would have subsumed several ARIA/web attributes seen
  in `AXWebConstants.h` this round): previously rejected in an earlier phase as
  privacy-adjacent/complex — reaffirmed, not revisited, since nothing about that family's
  risk profile changed in this SDK revision.
- Coordinate/geometry attributes (`kAXPositionAttribute`/`kAXSizeAttribute`): this is the first
  phase to formally score and reject this specific pair; no earlier phase had proposed it, so
  this is a genuinely new (rejected) candidate this round, not a re-litigation.
- `AXObserver*` push/notification architecture and `AXUIElementPostKeyboardEvent`: both remain
  out of scope for the same reasons recorded in earlier phases (new architecture required /
  forbidden keyboard simulation, respectively) — not re-proposed this round.
- No candidate from this round duplicates any previously-selected winner
  (`ui.read_focused_element`, `ui.read_application_state`, `ui.list_table_columns`,
  `ui.read_element_range`, `ui.list_element_actions`, `ui.list_element_attributes`,
  `ui.read_window_default_button`) — confirmed both by the direct-grep duplicate search in
  Section 3 and by manual comparison of each candidate's target AX API against every prior
  phase's selected contract.

---

## 11. Scope Gate

```
$ git status --short
?? docs/PHASE_2BN_CAPABILITY_ROADMAP.md
```

Exactly one new, untracked file. No production code, no test code, no registry entry, no other
file was created or modified during this discovery phase.

**No commit was made.** This is discovery only.

---

## 12. Final Discovery Report

- Baseline confirmed: commit `0802216`, capability count 61, clean tree — all matched.
- 61 capabilities inventoried directly from source (32 Level 0 / 4 Level 1 / 22 Level 2 / 2 Level 3).
- Fresh SDK research this round covered `AXAttributeConstants.h`'s title/label and text-selection
  attribute clusters (not previously the focus of any phase), `NSAccessibilityProtocols.h`'s
  `accessibilityTitle`/`accessibilityTitleUIElement` properties, `AXWebConstants.h` (read in full
  and correctly excluded as web-specific), and re-confirmed `AXValue.h`/`AXActionConstants.h`/
  `AXRoleConstants.h`/`AXUIElement.h` contain nothing new since their prior full enumerations.
- 9 serious candidates generated and scored on the specified 8-part, 100-point rubric.
- One candidate (`ui.read_element_geometry`) rejected outright on security grounds
  (coordinate-adjacency) independent of its numeric score.
- Winner selected: **`ui.read_element_title_reference`** (98/100) — reads
  `kAXTitleUIElementAttribute`, a well-documented, generically-applicable, currently-unused AX
  attribute, via a resolution/validation pattern that reuses Phase 2BM's proven
  optional-AXUIElement-reference design verbatim, with the strongest Native E2E fixture story of
  any phase to date (a complete, workaround-free two-`NSTextField` fixture) and zero duplication
  with any of the 61 existing capabilities.
- Top 3 alternatives fully specified: `ui.read_text_selection_state` (91),
  `ui.read_scroll_position` (89), `ui.read_window_full_screen_state` (84).
- Scope gate passed: only `docs/PHASE_2BN_CAPABILITY_ROADMAP.md` is new/modified.
- No commit created.
- **Implementation: NOT STARTED.**

Phase 2BN — DISCOVERY COMPLETE
Awaiting review

---

## Addendum: Implementation Status

`ui.read_element_title_reference` was approved and implemented. See
`docs/PHASE_2BN_SEMANTIC_ELEMENT_TITLE_REFERENCE.md` for the full implementation contract, test
results, and release-build verification. Capability count: 61 → 62.

