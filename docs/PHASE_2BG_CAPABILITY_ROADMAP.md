# Phase 2BG — Capability Roadmap (DISCOVERY ONLY)

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) test plan for the next capability. See the explicit
statement at the end of this file.

## Baseline
- **Commit**: `27e42d2`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BF (Semantic Stepper / Incrementor Step Mutation — `ui.step_incrementor`)

---

## Authoritative Capability Inventory
The repository contains exactly **54 authoritative registered capabilities** in `QModelPlanParser.registeredCapabilities` (`leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift`), confirmed by direct source inspection (`grep -c '": ("'`), not any historical report. Full enumeration cross-referenced during discovery (28 Level 0, 3 Level 1, 22 Level 2, 2 Level 3 = 54 wait — precise breakdown below).

- **Level 0 Read-Only** (28): `system.running_apps`, `system.clipboard.read`, `screen.ocr`, `fs.read`, `test.noop`, `accessibility.read`, `ui.read_element_value`, `ui.list_windows`, `ui.list_menu_items`, `ui.list_popup_items`, `ui.list_table_rows`, `ui.list_outline_items`, `ui.list_tab_items`, `ui.list_radio_group_items`, `ui.list_toolbar_items`, `ui.list_segmented_control_items`, `ui.list_sheet_dialogs`, `ui.list_sheet_actions`, `ui.list_split_panes`, `ui.list_browser_columns`, `ui.list_popovers`, `ui.list_color_wells`, `ui.list_progress_indicators`, `ui.list_level_indicators`, `ui.list_incrementors`, `ui.list_combo_boxes`, `ui.list_rulers`, `ui.list_combo_box_items`
- **Level 1 Safe Local Action** (3): `ui.open_app`, `fs.write_sandbox`, `ui.activate_application`
- **Level 2 User Approval Required** (21): `system.clipboard.write`, `ui.click_element`, `ui.set_text_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_application_hidden`, `ui.set_scroll_position`, `ui.set_window_main`, `ui.select_segmented_control_item`, `ui.set_window_full_screen`, `ui.set_splitter_position`, `ui.select_combo_box_item`, `ui.step_incrementor`
- **Level 3 High Risk** (2): `app.quit`, `ui.close_window`

**Total**: 28 + 3 + 21 + 2 = **54** ✓ (matches source-derived count and expected baseline)

---

## SDK & Architecture Discovery

**SDK sources inspected** (live, at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`):
- `ApplicationServices.framework` → `HIServices.framework`: `AXRoleConstants.h` (51 roles, re-verified against the full 54-capability registry), `AXAttributeConstants.h` (full attribute list — ~140 constants enumerated), `AXActionConstants.h` (10 actions, all already accounted for by existing capabilities: `kAXPressAction`, `kAXIncrementAction`/`kAXDecrementAction` used; `kAXConfirmAction`/`kAXCancelAction`/`kAXShowAlternateUIAction`/`kAXShowDefaultUIAction`/`kAXRaiseAction`/`kAXShowMenuAction`/`kAXPickAction` remain unused — none found to anchor a clean new capability this phase, see rejected-candidates notes below), `AXUIElement.h`, `AXValue.h`.

**Architecture inspected**: `QModelPlanSchema.swift` (full registry), `QBridgeAdapters.swift` (10,000+ lines — read `readElementValue`, `focusElement`'s systemwide-focus verification block, `QAXElementReadRolePolicy`, `QAXTextEntryRolePolicy`, table-row enumeration), `QExecutionService.swift`, `QActionVerification.swift`, `QPlanExecutor.swift`, and existing test suites `QSemanticElementReadTests.swift`, `QSemanticElementFocusTests.swift`, `QApplicationResolutionHardeningTests.swift`.

**Key finding**: `kAXFocusedUIElementAttribute` (read via `AXUIElementCreateSystemWide()`) is **already used internally** in this codebase — but only as a *verification* primitive inside `ui.focus_element` and `ui.set_text_value` (to confirm an already-known target became/was focused). It has **never been exposed as its own discovery primitive** that reports *which* element currently has focus back to the reasoning layer. Every one of the 54 existing capabilities requires the model to already know an identifier/title/role before it can act or read — none let the agent ask "what's focused right now?" This is the most significant fresh gap found.

Other findings: `kAXColumnHeaderUIElementsAttribute`/`kAXRowHeaderUIElementsAttribute` (table structure, unused), `kAXURLAttribute` (unused; `AXLink` is already an allowed *read* role per `QAXElementReadRolePolicy` but its URL is never read), `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (window default/cancel button identity, unused), `kAXSelectedTextAttribute`/`kAXSelectedTextRangeAttribute` (text selection, unused — but privacy-flagged, see below), `kAXZoomButtonAttribute` (present but **no** paired boolean "zoomed" state attribute exists anywhere in `AXAttributeConstants.h` — flagged as a verification-authority problem, see rejected candidates), `kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute` (scroll bar sub-elements, largely redundant with the already-shipped `ui.set_scroll_position`'s own internal resolution).

---

## Candidates

### 1. `ui.read_focused_element` — SELECTED
- **Purpose**: Reports the identity (and, where safe, value) of whichever element currently holds keyboard focus in a named application — the first capability that requires **zero** prior knowledge of a target's identifier/title/role.
- **Level**: 0 (Read-Only)
- **AX role(s)**: any (focus can land on any control); value exposure gated by `QAXElementReadRolePolicy` (reused unmodified from Phase 2J).
- **AX attribute(s)**: `kAXFocusedUIElementAttribute` (on `AXUIElementCreateSystemWide()`), then `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`/`kAXDescriptionAttribute`, `AXIdentifier`, `kAXValueAttribute` (gated), `kAXEnabledAttribute`.
- **AX action(s)**: none.
- **Semantic API**: `AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute, ...)`, then direct attribute reads on the returned element.
- **Target resolution**: `applicationName` resolved exactly via `resolveExactRunningApplication(named:)` (unmodified); the system-wide focused element's owning process ID (`AXUIElementGetPid`) is then checked against the resolved app's `processIdentifier` — a mismatch fails closed (the focused element belongs to a different app than the one asked about). Optional `windowTitle` further scopes/verifies.
- **Independent verification**: Level 0 — verification confirms the read itself succeeded and returned a well-formed, role-consistent snapshot (mirroring the "EnumerationSucceeded" discipline every other Level 0 capability already uses, never a bare `{ true }`).
- **Mutation**: none.
- **Approval**: none required (Level 0).
- **Recovery implications**: none (no mutation, no replay).
- **Resource-bound strategy**: a single fixed attribute read on the system-wide element, then a fixed handful of direct attribute reads on exactly one resolved element — **zero tree traversal**, the most tightly bounded read of any capability proposed to date. Value payload truncated at the same length ceiling `ui.read_element_value` already applies.
- **Privacy implications**: reuses `QAXElementReadRolePolicy` and the `AXSecureTextField` exclusion (`secureFieldReadDenied`) unmodified — identical privacy boundary to the already-shipped `ui.read_element_value`, extended to a system-discovered target instead of a pre-known one. No new exposure class introduced.
- **Why not already covered**: `kAXFocusedUIElementAttribute` is used today only as an internal equality check inside `ui.focus_element`/`ui.set_text_value`'s verification step — never surfaced as a return value to the reasoning layer.
- **Known macOS limitations**: some poorly-AX-instrumented apps (certain cross-platform toolkits) may report no focused element or an uninformative one; treated as a valid, honestly-reported "no focused element" fail-closed outcome, never fabricated.
- **Real-E2E fixture strategy**: `NSWindow` + `NSTextField`, `window.makeFirstResponder(textField)` on `@MainActor`, then confirm the capability resolves that exact element's `AXIdentifier`.
- **Implementation complexity**: LOW — simplest capability shape proposed yet (no tree walk, no new role policy, reuses two existing policies verbatim).
- **Security risk**: LOW — read-only, zero mutation surface, tightest resource bound yet.

### 2. `ui.list_table_columns` — Runner-up
- **Purpose**: Enumerates a table's column headers (titles), complementing the already-shipped `ui.list_table_rows`.
- **Level**: 0 (Read-Only)
- **AX role(s)**: `AXTable` (target), `AXColumn` (children read).
- **AX attribute(s)**: `kAXColumnHeaderUIElementsAttribute`, `kAXColumnsAttribute`, `kAXTitleAttribute`, optionally `kAXSortDirectionAttribute` per column.
- **AX action(s)**: none.
- **Semantic API**: `AXUIElementCopyAttributeValue` on the resolved `AXTable`'s column/header attributes.
- **Target resolution**: identical pattern to `ui.list_table_rows` — exact app/window resolution, then exactly one `AXTable` by identifier/title.
- **Independent verification**: read-succeeded evidence (aggregate column count only), same discipline as every other `list_*` capability.
- **Mutation**: none. **Approval**: none. **Recovery**: none.
- **Resource-bound strategy**: bounded column-count ceiling (e.g. 32), same style as existing `list_*` ceilings.
- **Privacy implications**: column header titles are structural metadata, not user content — low risk.
- **Why not already covered**: `ui.list_table_rows` enumerates rows/cells but never surfaces column headers, leaving the model unable to know what a given column represents without guessing from cell content alone.
- **Known macOS limitations**: some tables (especially single-column lists) report no distinct header row; a zero-column result is valid, not an error.
- **Real-E2E fixture strategy**: `NSTableView` with 2+ `NSTableColumn`s, each with a distinct header title, inside a plain `NSWindow`.
- **Implementation complexity**: LOW-MEDIUM (mirrors `ui.list_table_rows`' existing traversal shape closely).
- **Security risk**: LOW.
- **Why it loses to #1**: still requires the model to already know a table exists and have its identifier before it can be used — narrower, dependent capability rather than the foundational, zero-prior-knowledge self-orientation primitive `ui.read_focused_element` provides. Lower product/capability-value score (8 vs. 10) drives the aggregate gap.

### 3. `ui.read_window_default_button`
- **Purpose**: Reports the identity of a window's designated default/cancel button (what activates on Enter/Escape).
- **Level**: 0. **AX role(s)**: `AXWindow` (target), `AXButton` (returned identity only).
- **AX attribute(s)**: `kAXDefaultButtonAttribute`, `kAXCancelButtonAttribute`.
- **Semantic API**: `AXUIElementCopyAttributeValue` on the resolved window.
- **Target resolution**: exact app + exact window resolution (existing `AXWindow`-role pattern, unmodified).
- **Verification**: read-succeeded evidence. **Mutation/Approval/Recovery**: none.
- **Resource bound**: single window, two fixed attribute reads.
- **Privacy**: button title/identifier only — low risk.
- **Why not already covered**: no existing capability surfaces which button is default/cancel; `ui.click_element` requires already knowing the target.
- **Known limitations**: not every window has a default/cancel button (a valid empty result, not an error).
- **Real-E2E fixture**: `NSWindow` with an `NSButton` set as `window.defaultButtonCell`.
- **Complexity**: LOW. **Security risk**: LOW.
- **Why it loses**: narrow, edge-case utility (mainly "what does pressing Enter do") — lower product value (6/10) than both candidates above.

### 4. `ui.read_element_url`
- **Purpose**: Reads the `kAXURLAttribute` of a semantically-identified element (links, some images/fields).
- **Level**: 0. **AX role(s)**: primarily `AXLink` (already an allowed read role in `QAXElementReadRolePolicy`), potentially `AXImage`/`AXStaticText` where apps expose it.
- **AX attribute(s)**: `kAXURLAttribute`.
- **Semantic API**: `AXUIElementCopyAttributeValue` on a target resolved exactly like `ui.read_element_value`.
- **Target resolution**: identical to `ui.read_element_value` (app/window/role/identifier-or-title).
- **Verification**: read-succeeded evidence. **Mutation/Approval/Recovery**: none.
- **Resource bound**: single element, single attribute read.
- **Privacy**: URLs are generally low-sensitivity, but can occasionally embed session tokens or query-string secrets — minor caveat, not disqualifying.
- **Why not already covered**: `ui.read_element_value` reads `kAXValueAttribute`, never `kAXURLAttribute`.
- **Known limitations**: `AXURL` support outside WebKit/`AXLink` contexts is inconsistent across native AppKit controls — authoritativeness varies by app.
- **Real-E2E fixture**: harder than the others — a plain `NSTextField`/`NSButton` does not natively expose `kAXURLAttribute`; would likely require an `NSTextView` with an `NSAttributedString` link attribute, whose AX exposure of `kAXURLAttribute` at the *element* level (versus a sub-range text attribute) needs empirical confirmation before implementation — flagged as a real fixture-strategy risk.
- **Complexity**: LOW-MEDIUM (fixture uncertainty raises real risk despite simple code). **Security risk**: LOW.
- **Why it loses**: narrower applicability (mainly links) and a real open question about whether a clean native-AppKit-only fixture exists at all — lower product value and higher fixture risk than candidates #1–#3.

### 5. `ui.list_scroll_bars` — REJECTED (duplication-adjacent / low incremental value)
- **Purpose**: Enumerate `AXScrollBar` sub-elements (`kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute`) of a scroll area.
- **Level**: 0.
- **Rejection reason**: `ui.set_scroll_position` (already shipped) must already resolve these same scroll-bar sub-elements internally to perform its mutation. Surfacing them as a standalone capability exposes an implementation detail rather than filling a fresh gap — the model can already achieve everything this would offer via `ui.set_scroll_position` + `ui.read_element_value`. Aggregate score 83.8/100 — respectable, but the lowest product-value dimension (4/10) of any accepted-shape candidate.

### 6. `ui.read_text_selection` — REJECTED (privacy)
- **Purpose**: Reads `kAXSelectedTextAttribute`/`kAXSelectedTextRangeAttribute` of a named text field/area.
- **Level**: 0 (would be — but see rejection).
- **AX attribute(s)**: `kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`.
- **Rejection reason (hard privacy gate, not merely a low score)**: this directly exposes **arbitrary user-selected text content** to the reasoning layer — precisely the category Section 7 requires rejecting ("arbitrary user-entered content"). A user could select and thereby expose a password pasted into a non-secure field, a credit-card number, an OTP code, or any other sensitive string, regardless of the target role's presence on `QAXElementReadRolePolicy` (that policy gates *which control types* are safe to read a fixed/typed value from — it says nothing about arbitrary *runtime user selections* within them, which is a fundamentally different, much less bounded exposure surface). Aggregate score 75.0/100 looks competitive, but is overridden by this hard privacy rejection.

### 7. `ui.set_window_zoomed` — REJECTED (non-authoritative verification)
- **Purpose**: Toggle a window's "zoom" (green-button maximize, distinct from Full Screen) via `kAXZoomButtonAttribute`'s button element.
- **Level**: 2 (would be — but see rejection).
- **AX attribute(s)**: `kAXZoomButtonAttribute` (yields a pressable button reference only).
- **Rejection reason (hard verification-authority gate)**: unlike every other Level 2 window capability in this codebase (`ui.set_window_full_screen`, `ui.set_window_minimized`, `ui.set_window_main`), there is **no boolean "zoomed" state attribute anywhere in `AXAttributeConstants.h`** to set an explicit `desiredState` against or independently re-read for closed-loop verification. The only observable signal is a window frame/size change, which is heuristic and app-dependent, not an authoritative boolean compare. This also breaks the established "explicit desired state, never a blind toggle" contract every prior mutation capability enforces, and makes a crash-safe idempotency check impossible (a retry could double-toggle back to the original state). Aggregate score 63.6/100, driven by a hard 3/10 on deterministic verification — disqualifying regardless of the rest of the profile.

---

## Scoring Matrix (9-Dimension Model, weights sum to 100%)

| Dimension | Weight | `ui.read_focused_element` | `ui.list_table_columns` | `ui.read_window_default_button` | `ui.read_element_url` | `ui.list_scroll_bars` | `ui.read_text_selection` | `ui.set_window_zoomed` |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic API authority | 12% | 10 (12.0) | 9 (10.8) | 8 (9.6) | 8 (9.6) | 8 (9.6) | 9 (10.8) | 6 (7.2) |
| 2. Deterministic targeting | 12% | 10 (12.0) | 9 (10.8) | 9 (10.8) | 9 (10.8) | 9 (10.8) | 9 (10.8) | 8 (9.6) |
| 3. Deterministic verification | 12% | 9 (10.8) | 9 (10.8) | 8 (9.6) | 8 (9.6) | 8 (9.6) | 8 (9.6) | 3 (3.6) |
| 4. Security / risk suitability | 12% | 10 (12.0) | 10 (12.0) | 10 (12.0) | 9 (10.8) | 10 (12.0) | 6 (7.2) | 7 (8.4) |
| 5. Architectural fit | 10% | 10 (10.0) | 9 (9.0) | 8 (8.0) | 9 (9.0) | 7 (7.0) | 8 (8.0) | 5 (5.0) |
| 6. Recovery / crash-safety fit | 10% | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 4 (4.0) |
| 7. Resource-bounding feasibility | 10% | 10 (10.0) | 9 (9.0) | 10 (10.0) | 10 (10.0) | 10 (10.0) | 8 (8.0) | 9 (9.0) |
| 8. Privacy characteristics | 12% | 8 (9.6) | 9 (10.8) | 9 (10.8) | 8 (9.6) | 9 (10.8) | 3 (3.6) | 9 (10.8) |
| 9. Product / capability value | 10% | 10 (10.0) | 8 (8.0) | 6 (6.0) | 6 (6.0) | 4 (4.0) | 7 (7.0) | 6 (6.0) |
| **Total** | **100%** | **96.4** | **91.2** | **86.8** | **85.4** | **83.8** | **75.0** | **63.6** |

**Rejected for duplication / low incremental value**: `ui.list_scroll_bars` (83.8 — near-duplicate of information already reachable via the shipped `ui.set_scroll_position` + `ui.read_element_value`).
**Rejected because verification is not authoritative**: `ui.set_window_zoomed` (63.6 — no boolean state attribute exists to verify against; hard-disqualified independent of aggregate score).
**Rejected because of privacy exposure**: `ui.read_text_selection` (75.0 — exposes arbitrary user-selected content; hard-disqualified independent of aggregate score).
**No candidate rejected for unsafe/nondeterministic API** this round (all 7 candidates use documented, stable AX primitives — the closest case, `ui.set_window_zoomed`, was rejected on verification-authority grounds specifically, not API safety).

---

## Selected Candidate: `ui.read_focused_element`

**Why it wins**: highest score on 7 of 9 dimensions, including a perfect 10/10 on deterministic targeting (a system-wide focused element is a singleton by OS definition — zero ambiguity is possible, a first for any capability proposed in this program) and the tightest resource bound of any capability yet (zero tree traversal, exactly one element ever touched). It is also the only proposed capability that requires **no prior knowledge whatsoever** of a target — every one of the 54 shipped capabilities, and every other candidate this round, still requires the model to already know an identifier, title, or role before it can act. This closes a whole-surface self-orientation gap none of the prior 54 phases addressed.

**Why the runner-up loses**: `ui.list_table_columns` (91.2) is a solid, low-risk Level 0 candidate that cleanly complements `ui.list_table_rows`, but it remains a *dependent* capability — the model must already know a table exists and have its identifier before using it, the same limitation every other existing capability shares. Its product/capability-value score (8/10) is genuinely good but not foundational the way focus-discovery is, which accounts for the full scoring gap.

---

## Security Assessment (Section 5 Gate Walk-Through)

All gates evaluated conceptually against `ui.read_focused_element`:

| Gate | Status |
|---|---|
| Exact application resolution | ✅ `resolveExactRunningApplication(named:)` reused unmodified; the system-wide focused element's owning PID is additionally cross-checked against the resolved app — a mismatch fails closed |
| Exact window resolution where applicable | ✅ optional `windowTitle` scoping/verification supported |
| Exact semantic element resolution | ✅ — resolution *is* the read itself (system-wide focus is a singleton); result captured as an immutable point-in-time snapshot, same "informational only" contract every Level 0 capability already carries |
| Fail-closed on zero matches | ✅ no focused element / unreadable focus → fail closed, never defaulted to a fabricated empty-success |
| Fail-closed on ambiguous matches | N/A — system-wide focus cannot be ambiguous by OS definition |
| No fuzzy targeting | ✅ exact attribute read only |
| No index-only identity where unsafe | N/A — no index-based addressing involved |
| No coordinate targeting / CGEvent / keyboard / mouse simulation | ✅ pure AX attribute read |
| No raw AX pointer persistence | ✅ same snapshot-then-discard discipline as all 54 shipped capabilities |
| No authorization persistence / standing grants | N/A — Level 0, no approval involved at all |
| Level 2/3 explicit approval, single-use, bound to execution identity | N/A — Level 0 |
| Recovery observation-first | N/A — no mutation, no replay |
| Uncertain physical state fails closed | ✅ unreadable/ambiguous focus state is always a failure, never assumed |
| Independent post-mutation verification | N/A for a read, but the equivalent "read genuinely succeeded" discipline (never a bare `{ true }`) is preserved, matching every other Level 0 capability's verification strategy |
| No security bypass through replanning | ✅ read-only; can never itself substitute for an approved mutation, grants no new authority |

All applicable gates pass. No gate is violated or requires a design compromise.

---

## Privacy Assessment
- Reuses `QAXElementReadRolePolicy` (Phase 2J, unmodified) to gate whether a *value* is included at all in the response — identity fields (role, subrole, title/description, identifier) are always safe to return regardless of role, matching the existing convention that structural metadata carries lower risk than typed content.
- `AXSecureTextField` is explicitly excluded from value exposure via the same `secureFieldReadDenied` check `ui.read_element_value` already applies — passwords/OTP fields typed as secure fields are never exposed, focused or not.
- Does **not** read or expose: raw `AXUIElement` pointers, memory addresses, screen coordinates (`kAXPositionAttribute`/`kAXSizeAttribute` are never read by this capability), or arbitrary user *selections* (unlike the rejected `ui.read_text_selection`).
- Residual risk is identical to, and no larger than, the already-accepted boundary of `ui.read_element_value`: a non-secure-flagged field could coincidentally contain sensitive text in a poorly-built app. This capability introduces no *new* exposure class — it only extends the exact same accepted boundary to a system-discovered target instead of a pre-known one.
- Value payload, where present, must be truncated at the same length ceiling `ui.read_element_value` enforces (confirm exact constant at implementation time).

---

## Resource Bounds (concrete, pre-committed)
- **Max traversal depth**: 0 — no tree walk of any kind.
- **Max node count**: 1 — exactly one element is ever touched (the system-wide focused element itself).
- **Max direct children read**: 0 — children are never enumerated.
- **Max actions per call**: 0 — read-only, no `AXUIElementPerformAction` calls.
- **Max polling duration**: 0 — a single synchronous attribute read, no polling loop.
- **Max returned items**: 1 — a single element snapshot.
- **Max payload size**: value string (when present and role-allowed) capped at the same truncation ceiling `ui.read_element_value` already uses (to be confirmed and reused verbatim at implementation time, not reinvented).

---

## Proposed Test Plan (NOT IMPLEMENTED)

### Focused tests (Level 0 minimum: 15+; proposing 20)
1. Registration under toolFamily `ui`, Level 0 Read-Only by default
2. Parser accepts valid step with only `applicationName`
3. Parser accepts valid step with optional `windowTitle` scoping
4. Risk level override rejected (fails closed)
5. Missing `applicationName` fails closed
6. Non-existent application fails closed (`AX_APPLICATION_NOT_AVAILABLE` / `AX_PERMISSION_DENIED`)
7. No currently-focused element fails closed with a distinct code (e.g. `AX_NO_FOCUSED_ELEMENT`) — never silently reported as a fabricated empty success
8. Focused element belongs to a different application than requested → fails closed (cross-app mismatch guard)
9. Optional `windowTitle` mismatch (focused element's window differs from requested) → fails closed
10. Focused element is an `AXSecureTextField` → value withheld, but role/identifier/title still safely returned (mirrors `ui.read_element_value`'s existing contract)
11. Focused element's role is not on `QAXElementReadRolePolicy` → value withheld, identity still returned
12. Focused element's role is allowed and has a value → value present in output, correctly bounded
13. `QAXElementReadRolePolicy` reuse sanity check (no new/modified policy introduced)
14. Verification strategy — read-succeeded evidence structure (never a bare `{ true }`)
15. `QPlanExecutor` strategy mapping for `ui.read_focused_element`
16. Durable state boundary excludes raw pointers, memory addresses, and screen coordinates
17. Payload truncation enforced for a very long focused value
18. No approval gate is invoked for this Level 0 capability (dispatch proceeds directly)
19. Real macOS accessibility trust guard probe runs safely without crashing
20. Forbidden physical automation API audit (no `CGEvent`/`NSEvent`/keyboard/mouse/`osascript`/`AppleScript`/`Process(`)

### Related regression suites that must remain green
- `QSemanticElementReadTests.swift` (shares `QAXElementReadRolePolicy` and the secure-field exclusion contract)
- `QSemanticElementFocusTests.swift` (shares the `AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute` primitive)
- `QApplicationResolutionHardeningTests.swift` (shares `resolveExactRunningApplication(named:)`)
- Full regression suite (`scripts/test-pace.sh`, currently 3077/3077 green as of Phase 2BF)

### Real macOS E2E strategy
Build a plain `NSWindow` with an `NSTextField` (`setAccessibilityIdentifier` set for deterministic matching), call `window.makeFirstResponder(textField)` on `@MainActor`, then invoke the new bridge method scoped to the current test-host application and confirm it resolves that exact `NSTextField`'s identity (role `AXTextField`, matching identifier).

### TCC limitation (anticipated)
Based on this exact isolated/unsigned test host's behavior in every prior phase (most recently confirmed for Phase 2BF via `.xcresult` timing evidence), `AXIsProcessTrusted()` is expected to evaluate `false` in this environment. The proposed E2E test would take the existing `guard AXIsProcessTrusted() else { return }` early-exit path and pass trivially without exercising the real dispatch — to be honestly reported as **BLOCKED**, not fabricated as a real-world pass, exactly as Phase 2BF's own three live fixture tests were.

---

## Implementation Constraints (for the eventual implementation phase, not now)
- Reuse `QAXElementReadRolePolicy` and the `secureFieldReadDenied` check verbatim — do not create a new role policy.
- Reuse `resolveExactRunningApplication(named:)` verbatim — no new resolver.
- Reuse the exact `AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute` read pattern already present in `focusElement`'s verification code — do not reinvent.
- No new forbidden-API surface: no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, `AppleScript`/`osascript`, or `Process(`-based fallback.
- Confirm and reuse `ui.read_element_value`'s existing value-length truncation constant rather than introducing a new bound.

---

## Explicit Statement

**Implementation is NOT part of Phase 2BG.** This document is discovery-only. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase.

*(This statement describes this document's own discovery phase and is preserved verbatim as the historical record of that phase. Implementation has since been completed under separate explicit approval — see [`PHASE_2BG_SEMANTIC_FOCUSED_ELEMENT_READ.md`](./PHASE_2BG_SEMANTIC_FOCUSED_ELEMENT_READ.md) for the full implementation contract, test results, and security/privacy audit.)*
