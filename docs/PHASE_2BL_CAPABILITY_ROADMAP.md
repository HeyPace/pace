# Phase 2BL — Capability Roadmap

## DISCOVERY ONLY — NO IMPLEMENTATION

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) contract for the next capability. No production source file,
registry entry, executor, bridge, verification strategy, or test file has been created or
modified as part of this phase.

## Baseline
- **Commit**: `d18174b` (full: `d18174b960b56c4e1a4b54cbd05d0dd3b859a5da`)
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BK (Semantic Element Action Enumeration — `ui.list_element_actions`)
- **Authoritative capability count**: **59**, confirmed by direct source extraction (`grep -c '": ("'` against `QModelPlanParser.registeredCapabilities`), not any historical report.

---

## Fresh SDK Discovery Evidence

Phases 2BG–2BJ swept `AXAttributeConstants.h`/`AXRoleConstants.h`/`AXActionConstants.h` (the string-constant headers) with progressively finer methodology. Phase 2BK shifted to `AXUIElement.h`'s *action*-related functions (`AXUIElementCopyActionNames`/`AXUIElementCopyActionDescription`/`AXUIElementPerformAction`) plus AppKit's own `NSAccessibility*.h` headers. This phase completes that sweep: **every single extern function declared in `AXUIElement.h`** was enumerated and individually assessed — not just the action-related trio Phase 2BK already touched.

### Complete `AXUIElement.h` function inventory (35 extern declarations, all confirmed present in the installed SDK)

| Function | Used by this codebase? | Assessment |
|---|:---:|---|
| `AXUIElementCopyAttributeValue` | ✅ (extensively) | Core primitive every capability already uses. |
| `AXUIElementSetAttributeValue` | ✅ (extensively) | Core mutation primitive every Level 2 capability already uses. |
| `AXUIElementIsAttributeSettable` | ✅ | Used for range/writability pre-checks. |
| `AXUIElementPerformAction` | ✅ (extensively) | Core action-dispatch primitive. |
| `AXUIElementCopyActionNames` | ✅ (Phase 2BK) | `ui.list_element_actions`. |
| `AXUIElementCopyActionDescription` | ❌ | Considered this phase (see Candidates) — scored, not selected. |
| `AXUIElementCreateApplication` | ✅ (extensively) | Core resolution primitive. |
| `AXUIElementCreateSystemWide` | ✅ (`ui.read_focused_element`) | |
| `AXUIElementGetPid` | ✅ (`ui.read_application_state`) | |
| `AXUIElementGetTypeID` | not directly needed | Type-checking utility, not a capability surface. |
| **`AXUIElementCopyAttributeNames`** | ❌ | **Decisive finding — see below.** |
| `AXUIElementGetAttributeValueCount` | ❌ | Count-only variant of an array attribute read; every existing enumeration already gets a count for free once it enumerates — no standalone value beyond a micro-optimization internal to a future enumeration capability, not a capability of its own. |
| `AXUIElementCopyAttributeValues` | ❌ | Paginated bulk-fetch of one array attribute's values — a performance primitive, not a new semantic surface. |
| `AXUIElementCopyMultipleAttributeValues` | ❌ | Bulk-fetch of several attributes' values for one element in a single round-trip — again a performance primitive (reduces IPC round-trips), not a new capability surface; every existing capability's own sequence of individual `AXUIElementCopyAttributeValue` calls already reaches the same authoritative data, just less efficiently. |
| `AXUIElementCopyParameterizedAttributeNames` | ❌ | Discovers which *parameterized* attributes (range-indexed, e.g. text-range queries) an element supports — pairs with the next entry; rejected for the same reason. |
| `AXUIElementCopyParameterizedAttributeValue` | ❌ | Requires a parameter (typically a text range or position) — the concrete parameterized attributes this API would be used for (`kAXAttributedStringForRangeParameterizedAttribute`, `kAXStringForRangeParameterizedAttribute`, etc.) all resolve to arbitrary text *content*, the same privacy territory `kAXSelectedTextAttribute` was rejected for in Phase 2BG. Rejected on identical grounds. |
| **`AXUIElementCopyElementAtPosition`** | ❌ | **Rejected — explicitly coordinate-based.** Its own doc comment: `@param x The horizontal position. @param y The vertical position.` This is screen-coordinate hit-testing built into the AX framework itself — directly forbidden by this program's hard architectural rule against coordinate targeting, regardless of it being an "AX-native" API. Noted explicitly so a future phase does not mistake its AX-framework origin for architectural permission. |
| `AXUIElementSetMessagingTimeout` | not applicable | IPC tuning, not a semantic capability. |
| **`AXUIElementPostKeyboardEvent`** | ❌ | **Rejected — explicitly keyboard simulation.** Its own signature (`keyChar`, `virtualKey`, `keyDown` parameters) is a keyboard-event injection API embedded directly in the Accessibility framework. Directly forbidden by this program's hard rule against keyboard simulation. Noted explicitly for the same reason as the position-based lookup above. |
| `AXMakeProcessTrusted` / `AXIsProcessTrustedWithOptions` / `AXAPIEnabled` | not applicable | Accessibility-*permission* management (requesting/checking Trust itself), not an element-inspection capability — out of scope for the capability-registry model; this program's existing `AXIsProcessTrusted()` checks (already used by all 59 capabilities) are the read-only variant already in use. |
| `AXTextMarkerCreate` / `AXTextMarkerGetLength` / `AXTextMarkerRangeCreate*` / `AXTextMarkerRangeCopyStartMarker` / `AXTextMarkerRangeCopyEndMarker` / `AXTextMarkerGetTypeID` / `AXTextMarkerRangeGetTypeID` | ❌ | An opaque, complex text-position/range API family used for fine-grained text navigation (primarily by rich-text engines and WebKit). Ultimately exists to extract or navigate arbitrary text *content* — the same privacy territory already rejected for `kAXSelectedTextAttribute`/parameterized text attributes. Rejected on identical privacy grounds, compounded by high implementation complexity (opaque `CFTypeRef`-based markers with no simple scalar representation). |
| `AXObserverCreate` / `AXObserverCreateWithInfoCallback` / `AXObserverAddNotification` / `AXObserverRemoveNotification` / `AXObserverGetRunLoopSource` | ❌ | The *push*-notification/observer API family — re-confirms Phase 2BK's own rejection of "accessibility notification observation": this requires a persistent observer registered against a `CFRunLoop` receiving asynchronous callbacks, an execution model no existing capability uses (every one of the 59 shipped capabilities is "resolve target, do one bounded synchronous operation, return"). Would require a genuinely new, out-of-scope architectural mechanism (an observer/callback subsystem), not a single capability addition — explicitly excluded per this phase's own instruction not to introduce "a new unsafe architectural mechanism." |

### Decisive finding — `AXUIElementCopyAttributeNames` is the direct, unused sibling of Phase 2BK's own winner
`AXUIElementCopyActionNames` (Phase 2BK) answers "what can this element **do**?" `AXUIElementCopyAttributeNames` — declared four lines earlier in the identical header, same vintage, same non-obsolete status — answers "what can I **ask** this element?" (i.e., which attribute names, such as `"AXValue"`, `"AXTitle"`, `"AXEnabled"`, `"AXMinValue"`, it actually supports). Every existing read capability in this codebase (`ui.read_element_value`, `ui.read_element_range`, `ui.read_focused_element`, `ui.read_application_state`) *assumes* which attributes a role supports based on hard-coded, role-keyed logic written by this program's own implementers — none of them, and no capability at all, has ever asked an element to self-report its actual supported attribute vocabulary. Confirmed unused by direct source grep (`grep -rn "AXUIElementCopyAttributeNames" leanring-buddy/` → zero matches).

---

## Existing Capability Coverage (verified against source)

Full 59-capability registry re-confirmed via direct extraction. Coverage map for the families most relevant to this phase's candidates:

| Capability ID | Level | Read/Mutation | Semantic Target | AX Role | AX Attribute/Action |
|---|---|---|---|---|---|
| `ui.read_element_value` | L0 | Read | Element's own value | `QAXElementReadRolePolicy` allowlist | `kAXValueAttribute` (assumed present, hard-coded reader) |
| `ui.read_element_range` | L0 | Read | Numeric bounds | `AXSlider`/`AXIncrementor`/`AXSplitter` | `kAXMinValueAttribute`/`kAXMaxValueAttribute` (assumed present) |
| `ui.list_element_actions` | L0 | Read | Action vocabulary | `QAXElementReadRolePolicy` allowlist | `AXUIElementCopyActionNames` (self-reported, not assumed) |
| `ui.read_focused_element` | L0 | Read | Systemwide focused element | any (resolution) | `kAXFocusedUIElementAttribute` |
| `ui.read_application_state` | L0 | Read | App hidden/frontmost/window refs | `AXApplication` (via pid) | `kAXHiddenAttribute`/`kAXFrontmostAttribute`/`kAXMainWindowAttribute`/`kAXFocusedWindowAttribute` |
| `ui.list_table_columns` | L0 | Read | Column headers | `AXTable` | `kAXColumnHeaderUIElementsAttribute` |
| `ui.list_*` (24 total) | L0 | Read | Container enumeration | per-family role policy | `kAXChildrenAttribute`/family-specific |

**Critical confirmation**: no capability — read, enumerate, or mutate — has ever asked an element to self-report its own supported *attribute* vocabulary via `AXUIElementCopyAttributeNames`. This is the precise, verified gap this phase's selected candidate closes, and it is structurally distinct from `ui.list_element_actions` (attribute names vs. action names — two different, parallel C-API surfaces serving two different questions).

---

## Gap Analysis — Systematic Review of Under-Covered Areas

Per this phase's own required checklist:

- **`AXWindow` attributes not yet exposed**: `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` remain unimplemented (carried forward as a scored candidate — see below). → **Valid candidate, not selected this round.**
- **`AXApplication` state not yet exposed**: fully covered by `ui.read_application_state` (Phase 2BH); no further gap identified. → **Duplicate/already covered.**
- **`AXUIElement` metadata not yet exposed**: `AXUIElementCopyAttributeNames` — the selected winner. → **Valid, selected.**
- **Selection/range-related attributes**: numeric range covered by `ui.read_element_range` (Phase 2BJ); `kAXSelectedTextAttribute`/`kAXSelectedTextRangeAttribute` remain rejected on privacy grounds (Phases 2BG/2BJ). → **Duplicate or unsafe, per prior rejections, re-confirmed.**
- **Text-related semantic attributes that remain privacy-safe**: `kAXNumberOfCharactersAttribute` (character count) and `kAXInsertionPointLineNumberAttribute` (cursor line number) are genuinely privacy-safe (metadata *about* text, never the text itself) — identified fresh this phase, but judged too narrow in standalone value (an agent that wants to know a field's content already has `ui.read_element_value`; knowing only a count or line number without the content serves few realistic planning needs) to elevate to a scored candidate. → **Insufficient standalone value; noted, not scored.**
- **Table/list/grid structures**: exhaustively covered (Phases 2AE, 2BI); `AXGrid`/`AXCell` remain rejected for `NSCollectionView`'s unreliable role emission (Phases 2BH–2BK, re-confirmed, no new evidence). → **Duplicate/unsafe (fixture-unreliable), re-confirmed.**
- **Browser structures**: `ui.list_browser_columns` covers `AXBrowser`; no further gap. → **Duplicate/already covered.**
- **Toolbar/control structures**: `ui.list_toolbar_items` covers `AXToolbar`; `kAXOverflowButtonAttribute` is a minor enrichment field, not a standalone capability. → **Insufficient standalone value.**
- **Ruler/marker structures**: `ui.list_rulers` covers rulers; `ui.list_ruler_markers` (carried forward, `kAXMarkerUIElementsAttribute`) remains unimplemented. → **Valid candidate, not selected this round.**
- **Menu/action structures**: menus fully covered (`ui.list_menu_items`/`ui.select_menu_item`); actions now covered generically by `ui.list_element_actions` (Phase 2BK). `AXUIElementCopyActionDescription` considered fresh this phase as its natural extension. → **Scored candidate, not selected (see below).**
- **Accessibility custom actions**: covered by `ui.list_element_actions` (Phase 2BK). → **Already covered.**
- **Popovers/sheets/dialog-related state**: enumeration fully covered (`ui.list_popovers`/`ui.list_sheet_dialogs`/`ui.list_sheet_actions`); `kAXModalAttribute`-based dialog/subrole classification remains flagged (Phases 2BH–2BJ) as an enrichment to `ui.list_windows`'s own output, not a standalone capability — unchanged this phase. → **Insufficient standalone value, re-confirmed.**
- **Collection relationships**: `kAXTitleUIElementAttribute` (`ui.read_element_label`, carried forward) remains the one live candidate in this area; `kAXLinkedUIElementsAttribute`/`kAXSharedFocusElementsAttribute` inspected fresh this phase and found to have no concrete, bounded use case beyond what `ui.read_element_label`/`ui.read_focused_element` already serve. → **Valid candidate, not selected this round; siblings insufficiently differentiated.**
- **Notification-independent semantic state**: this describes exactly the pollable, synchronous, non-observer-based model every Level 0 capability already uses — `AXUIElementCopyAttributeNames` fits this precisely (a single synchronous call, no observer, no callback). → **Confirms the winner's architectural fit.**
- **AppKit controls with authoritative AX representations not yet covered**: `NSDatePicker` (`AXDateField`/`AXTimeField` — rejected for multi-subfield parsing complexity since Phase 2BF, re-confirmed), `NSPathControl` and `NSTokenField` inspected fresh this phase — neither maps to a single, dedicated AX role (a path control typically exposes as a row of buttons; a token field typically exposes as a text field with embedded, non-standardly-addressable token children) — no clean, authoritative single-role target exists for either. → **No viable candidate identified.**

No obsolete, undocumented, or SDK-unavailable symbol was proposed as a target this phase — every function/attribute/role referenced above was confirmed present in the installed SDK by direct inspection.

---

## Candidates

### 1. `ui.list_element_attributes` — SELECTED
1. **Capability ID**: `ui.list_element_attributes`
2. **Level**: 0 (Read-Only)
3. **AX role**: any role on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim — no broader, arbitrary-role allowlist introduced).
4. **AX attribute/action**: `AXUIElementCopyAttributeNames` (the discovery call itself).
5. **Native AppKit counterpart**: any standard control — e.g. a plain `NSButton` reports a stable, predictable attribute-name vocabulary (`AXRole`, `AXTitle`, `AXEnabled`, `AXHelp`, etc.).
6. **Current coverage status**: zero overlap — no capability discovers attribute *names* dynamically; every existing reader assumes a fixed, hard-coded attribute per role.
7. **Target resolution**: identical to `ui.read_element_value`/`ui.list_element_actions` — exact application resolution (`resolveExactRunningApplication`, unmodified), then exactly one element by role + (`identifier` or `title`) via `collectMatches`/`snapshotIfMatches`. Zero/ambiguous matches fail closed.
8. **Verification strategy**: the read's own success/failure — a well-formed, bounded array of attribute-name strings was obtained, or it wasn't.
9. **Privacy implications**: attribute *names* are an even more constrained vocabulary than action names — almost universally drawn from Apple's own fixed `kAX*Attribute` constant set (custom, app-defined *attributes* are far rarer in practice than custom *actions*, which AppKit explicitly supports via `NSAccessibilityCustomAction`). Arguably the lowest-risk read-capability output surface proposed across all six discovery phases to date.
10. **Resource bounds**: single element, one `AXUIElementCopyAttributeNames` call, result capped at a defensive ceiling (proposed 32 — real elements typically report low-double-digit attribute counts, somewhat more than the 16-action ceiling `ui.list_element_actions` uses, since attributes outnumber actions on any given control) — zero traversal.
11. **Approval requirement**: none — Level 0.
12. **Recovery behavior**: observation-first, trivially — a read has no side effects.
13. **Native E2E feasibility**: HIGH — any plain `NSButton`/`NSTextField` fixture reliably and deterministically reports a real, non-empty, predictable attribute-name set.
14. **Why it provides meaningful new capability**: lets the model discover *what facts it can ask* about an element before guessing — directly complementary to `ui.list_element_actions`'s "what can I do" answer, completing a natural pair of self-orientation primitives for the same underlying `AXUIElementRef`.

### 2. `ui.read_window_default_button` — carried forward from Phases 2BG–2BK, still unimplemented
Unchanged from five prior discovery phases' own assessment — re-verified this phase with no new evidence changing it. `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` on `AXWindow`, Level 0.

### 3. `ui.list_ruler_markers` — carried forward from Phases 2BI–2BK, still unimplemented
Unchanged from prior assessment. `kAXMarkerUIElementsAttribute`/`kAXMarkerTypeAttribute` on `AXRuler`, Level 0, complements the already-shipped `ui.list_rulers`.

### 4. `ui.read_element_label` — carried forward from Phases 2BH–2BK, still unimplemented
Unchanged from prior assessment. `kAXTitleUIElementAttribute`, Level 0.

### 5. `ui.read_element_action_description` — NEW this phase, scored, not selected
1. **Capability ID**: `ui.read_element_action_description`
2. **Level**: 0 (Read-Only).
3. **AX attribute/action**: `AXUIElementCopyActionDescription` — the natural extension of Phase 2BK's `ui.list_element_actions`, explicitly deferred in that phase's own documentation as an open question rather than silently dropped.
4. **Current coverage status**: no overlap with `ui.list_element_actions` itself (that capability returns action *names* only), but weak differentiated *value* over it: for standard AX actions (`"AXPress"`, `"AXIncrement"`), the description is generic, static, and identical across every app — already implicitly known. For custom actions (`NSAccessibilityCustomAction`), the action's own `name` property is *itself* documented as "a localized name that describes the action... may be displayed to the user" — meaning the name and the description frequently carry near-duplicate information for exactly the case (custom actions) where this capability would otherwise add the most value.
5. **Why not selected**: scored lowest of all five serious candidates (75.55, see Scoring below) — weak marginal utility over the very recently shipped sibling capability, and descriptions are potentially longer, app-authored free text (a materially different, slightly higher privacy profile than the short, fixed-vocabulary-or-custom-label names `ui.list_element_actions` already exposes).

---

## Scoring (0–100 per dimension, explicit weights per this phase's own model)

Weights: Semantic authority/AX support 20, Deterministic verification 15, Security/fail-closed compatibility 15, Architectural reuse 10, User utility 10, Privacy safety 10, Resource boundedness 5, Native AppKit E2E testability 10, Non-duplication/roadmap value 5 (sum = 100).

| Dimension | Weight | `ui.list_element_attributes` | `ui.read_window_default_button` | `ui.list_ruler_markers` | `ui.read_element_label` | `ui.read_element_action_description` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic authority / AX support | 20 | 92 → 18.40 | 82 → 16.40 | 78 → 15.60 | 78 → 15.60 | 80 → 16.00 |
| 2. Deterministic verification | 15 | 85 → 12.75 | 85 → 12.75 | 78 → 11.70 | 80 → 12.00 | 80 → 12.00 |
| 3. Security / fail-closed compatibility | 15 | 96 → 14.40 | 90 → 13.50 | 92 → 13.80 | 86 → 12.90 | 85 → 12.75 |
| 4. Architectural reuse | 10 | 90 → 9.00 | 85 → 8.50 | 85 → 8.50 | 85 → 8.50 | 85 → 8.50 |
| 5. User utility | 10 | 70 → 7.00 | 50 → 5.00 | 40 → 4.00 | 55 → 5.50 | 35 → 3.50 |
| 6. Privacy safety | 10 | 98 → 9.80 | 88 → 8.80 | 90 → 9.00 | 75 → 7.50 | 78 → 7.80 |
| 7. Resource boundedness | 5 | 95 → 4.75 | 92 → 4.60 | 92 → 4.60 | 88 → 4.40 | 90 → 4.50 |
| 8. Native AppKit E2E testability | 10 | 90 → 9.00 | 85 → 8.50 | 62 → 6.20 | 68 → 6.80 | 75 → 7.50 |
| 9. Non-duplication / roadmap value | 5 | 95 → 4.75 | 90 → 4.50 | 95 → 4.75 | 78 → 3.90 | 60 → 3.00 |
| **Weighted Total** | **100** | **89.85** | **82.55** | **78.15** | **76.60** | **75.55** |

**Ranking**: `ui.list_element_attributes` (89.85) > `ui.read_window_default_button` (82.55) > `ui.list_ruler_markers` (78.15) > `ui.read_element_label` (76.60) > `ui.read_element_action_description` (75.55). No score was artificially inflated — the winner's margin is concentrated in security (15% weight) and privacy (10% weight), both grounded in the same verified evidence: attribute-name output carries an even narrower, more Apple-fixed vocabulary than the already-shipped `ui.list_element_actions`'s own action-name output.

---

## Selected Capability

**Capability ID**: `ui.list_element_attributes`
**Risk level**: Level 0 (Read-Only)

### Target
Exactly one semantically-identified element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim). No new AX hierarchy.

### Inputs
`applicationName` (required), `role` (required — a search criterion, matching `ui.read_element_value`/`ui.list_element_actions`'s exact contract shape), `identifier` **or** `title` (at least one required).

### Resolution
Identical chain to `ui.list_element_actions`: role policy check (secure field first, then `QAXElementReadRolePolicy` allowlist) → `AXIsProcessTrusted()` → `resolveExactRunningApplication(named:)` (unmodified) → `collectMatches`/`snapshotIfMatches` bounded search by role + identifier-or-title → staleness re-check immediately before the read.

### AX operation
`AXUIElementCopyAttributeNames(targetElement, &names)` — a single call, cast the returned `CFArray` to `[String]`, cap at a defensive ceiling (proposed 32), independently re-validate the cast succeeded (treat the returned collection as untrusted external data, mirroring `ui.list_element_actions`'s own `actionNamesCollectionMalformed`-style discipline).

### Verification
Proposed named strategy: `QVerificationStrategy.elementAttributeNamesReadSucceeded(applicationName: String, role: String, attributeCount: Int)` — checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`, and (mirroring `ui.list_element_actions`'s own precedent) independently re-validates `attributeCount` falls within the permitted bound rather than blindly trusting the dispatch layer. Evidence: `application=<name> role=<role> attributeCount=<n> status=verified` — never the individual attribute-name strings themselves.

### Approval
None required — Level 0, routed by `QPermissionGate.evaluate` straight to `.allow`, not a special-cased bypass.

### Recovery
Observation-first, trivially: a read has no side effects; an uncertain in-flight step fails closed to `pending`, and a retry is always safe. No raw `AXUIElement` pointer is ever persisted.

### Privacy
**May leave the immediate reasoning boundary**: the bounded list of attribute-name strings (near-exclusively the fixed `kAX*Attribute` vocabulary) and an aggregate count. **Must remain ephemeral / never persisted beyond identity + count**: individual attribute-name strings kept out of durable verification evidence, audit records, memory, and recovery/replan state — the identical discipline `ui.list_element_actions` already established and proved via dedicated tests.

### Bounds
- Elements: **1**.
- Traversal depth: **0**.
- Children: **0**.
- Actions performed: **0** (this is a discovery-only read; no action or attribute-write is ever performed).
- Polling: **0** (a single synchronous call).
- Returned records: **≤ 32** attribute-name strings (a slightly wider ceiling than `ui.list_element_actions`'s 16, since real elements typically expose more attributes than actions — to be confirmed against a real fixture's actual count at implementation time).
- String size: each individual attribute-name string bounded to a defensive length ceiling (proposed 256 characters, mirroring `ui.list_element_actions`'s own `maxActionNameLength`), never an arbitrarily large model-visible string.

### E2E
A plain `NSWindow` containing an `NSButton` and a plain `NSTextField` — each expected to report a real, predictable, non-empty attribute-name set (e.g. `AXRole`, `AXTitle`/`AXValue`, `AXEnabled`), demonstrating the capability resolves distinct role families correctly and returns their genuinely different attribute vocabularies (a button and a text field do not expose identical attribute sets).

---

## Security Challenge

1. **Can an untrusted model abuse it?** No — strictly read-only, returns only short attribute-name strings from an near-fixed vocabulary, grants no new authority, and cannot itself cause any element to be read, written, or acted upon.
2. **Can it target the wrong application?** No — reuses `resolveExactRunningApplication` unmodified; fails closed on zero/ambiguous matches, identical to all 59 shipped capabilities.
3. **Can ambiguity occur?** Handled identically to `ui.read_element_value`/`ui.list_element_actions`'s own target resolution — zero or 2+ matches fail closed, never `.first`.
4. **Can stale state cause an unsafe result?** No unsafe result is possible — this capability never performs a mutation; staleness at worst yields an inaccurate informational read of a live control's own attribute vocabulary, mitigated by the same observation-binding staleness check every prior capability already applies.
5. **Can authorization survive a crash/recovery?** Not applicable — Level 0, no authorization exists to survive.
6. **Can raw AX objects escape?** No — the output is a bounded array of `String` only; no `AXUIElement`-typed field is ever constructed in the output type.
7. **Can sensitive content leak?** No — attribute *names* (not values) are returned; `QAXElementReadRolePolicy`'s existing exclusion of `AXSecureTextField` applies unchanged, and even for an allowed role, an attribute *name* string (e.g. `"AXValue"`) carries zero content of the underlying value itself.
8. **Can the capability become a hidden physical-input fallback?** No — it never calls `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `AXUIElementPostKeyboardEvent`, or `AXUIElementCopyElementAtPosition` (both of the latter two confirmed present in the SDK and explicitly rejected earlier in this same document for exactly this reason).
9. **Can an application-defined accessibility object spoof the semantic target?** This risk is **inherited from the existing architecture's already-accepted trust model, not newly introduced or amplified by this capability**: every one of the 59 shipped capabilities already trusts an application's own self-reported `role`/`identifier`/`title` for target resolution (AX metadata is always app-self-reported; macOS does not independently verify it). A hostile or buggy app could in principle misreport its own identifier/title to influence which of its *own* elements gets resolved — but this capability, even under a successfully "spoofed" resolution, can only ever return that (still correctly-resolved, just possibly not the one the caller *intended*) element's attribute-*name* vocabulary — never content, never a mutation, never elevated authority. The bounded blast radius of a worst-case spoof here is strictly smaller than for any existing read/enumerate/mutate capability, since there is no value or state-change surface to exploit even in the spoofed-target case.
10. **Is the proposed risk level (Level 0) actually justified?** Yes — zero mutation surface, zero content exposure beyond a near-fixed short-string vocabulary; Level 0 is clearly correct.

No unresolved security risk was identified. The candidate is not rejected.

---

## Explicit Implementation Deferral

**Implementation: NOT STARTED.** This document is discovery-only. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase. The proposed contract above is a design proposal for a future, separately-approved implementation phase — not a description of code that exists today.

Phase 2BL — DISCOVERY COMPLETE

---

*(Post-discovery note: implementation has since been completed under separate explicit approval — see [`PHASE_2BL_SEMANTIC_ELEMENT_ATTRIBUTE_ENUMERATION.md`](./PHASE_2BL_SEMANTIC_ELEMENT_ATTRIBUTE_ENUMERATION.md) for the full implementation contract, test results, and security/privacy audit. The proposed contract above was implemented as designed.)*
