# Phase 2BK — Capability Roadmap

## DISCOVERY ONLY — NO IMPLEMENTATION

**No implementation occurred in this phase.** This document records discovery, candidate
scoring, and a proposed (not built) contract for the next capability. No production source file,
registry entry, executor, bridge, verification strategy, or test file has been created or
modified as part of this phase.

## Baseline
- **Commit**: `fad56c1`
- **Branch**: `q-secure-foundation`
- **Working Tree**: `CLEAN`
- **Previous Phase**: Phase 2BJ (Semantic Element Range Read — `ui.read_element_range`)
- **Authoritative capability count**: **58**, confirmed by direct source extraction (`grep -oE '"[a-z_]+\.[a-z_]+": \("[a-z]+", \.[a-zA-Z0-9]+\)' | wc -l` against `QModelPlanParser.registeredCapabilities`), not any historical report.

---

## Fresh SDK Discovery Evidence

This phase took a **different investigative angle** than Phases 2BG–2BJ. Those four rounds each swept `AXRoleConstants.h`/`AXAttributeConstants.h`/`AXActionConstants.h` — the *attribute*-and-*action*-*constant* surface — progressively more exhaustively (roles, then attributes, then a targeted `Writable? Yes` sweep). By this point that surface has been swept four times; re-sweeping it a fifth time would not be genuine fresh discovery. Instead, this phase inspected **`AXUIElement.h` directly** — the C API surface itself, as opposed to the string-constant headers — and separately inspected **AppKit's own `NSAccessibility*.h` headers** (`NSAccessibility.h`, `NSAccessibilityProtocols.h`, `NSAccessibilityElement.h`, `NSAccessibilityCustomRotor.h`, `NSAccessibilityConstants.h`, `NSAccessibilityColor.h`, `NSAccessibilityCustomAction.h`) — the modern, Swift/ObjC-facing side of the accessibility API this program's discovery has not previously examined as its own source.

### Decisive finding — `AXUIElementCopyActionNames`/`AXUIElementCopyActionDescription` are a wholly unused, parallel API surface
`AXUIElement.h` defines action-related functions distinct from `AXActionConstants.h`'s fixed vocabulary of named constants:

```
extern AXError AXUIElementCopyActionNames(AXUIElementRef element, CFArrayRef __nullable * __nonnull names);
  @abstract Returns a list of all the actions the specified accessibility object can perform.

extern AXError AXUIElementCopyActionDescription(AXUIElementRef element, CFStringRef action, CFStringRef __nullable * __nonnull description);
  @abstract Returns a localized description of the specified accessibility object's action.

extern AXError AXUIElementPerformAction(AXUIElementRef element, CFStringRef action);
  @abstract Requests that the specified accessibility object perform the specified action.
```

All three are documented, stable, non-obsolete APIs (`AXUIElementCopyActionNames`/`AXUIElementPerformAction` date to macOS 10.3; no deprecation annotation anywhere in the header). Every one of this program's 58 shipped capabilities that performs an action does so by **hard-coding** a specific action constant (`kAXPressAction`, `kAXIncrementAction`, `kAXDecrementAction`) chosen per-role by the implementation — confirmed by direct source grep (`grep -rn "AXUIElementCopyActionNames\|AXUIElementCopyActionDescription" leanring-buddy/` → zero matches). **No capability has ever asked an element what actions it actually supports.** This is architecturally significant: `AXUIElementPerformAction` accepts *any* action string, including app-defined custom actions no fixed role-based policy could anticipate — but this program has no way to discover what those custom action names even are.

### Corroborating finding — `NSAccessibilityCustomAction` is a real, modern, first-class AppKit API for exposing exactly this
`NSAccessibilityCustomAction.h` defines a public class (macOS 10.13+) that lets any `NSView`/`NSAccessibilityElement`-conforming object expose named, custom, VoiceOver-actionable commands (e.g., "Reply", "Archive", "Mark as Read") beyond the fixed press/increment/decrement vocabulary — attached via `setAccessibilityCustomActions(_:)`. These custom actions surface through the exact same `AXUIElementCopyActionNames` call. This gives a genuine, standard, non-fabricated AppKit fixture path for testing action discovery beyond the trivial "a button supports AXPress" case.

### Other AppKit accessibility headers inspected, with findings
- **`NSAccessibilityCustomRotor.h`**: defines VoiceOver "rotor" navigation (letting a screen-reader user jump between headings, links, etc.). This is a screen-reader-navigation-UX concept with no clean AX-attribute-level representation an `AXUIElementRef`-based agent could query directly (rotors are populated via a delegate protocol at VoiceOver-request time, not exposed as a static, readable attribute) — not a viable capability target; noted and rejected, not silently skipped.
- **`NSAccessibilityColor.h`**: defines `NSAccessibilityCustomAction`'s sibling for color descriptions — a helper for making custom color values speakable by VoiceOver (e.g., naming an arbitrary RGB value "sea green"). `ui.list_color_wells` already enumerates `AXColorWell` elements; this header offers no attribute-level surface beyond what a color well's own value already exposes — not a fresh capability, an implementation detail of existing color-well accessibility support.
- **`NSAccessibilityElement.h`**/**`NSAccessibilityProtocols.h`**: define the Swift/ObjC-side protocol conformance surface AppKit controls implement to back the exact same `kAX*Attribute` constants already fully catalogued in Phases 2BG–2BJ — confirmed no new attribute-level surface exists here that the C-header sweeps missed; this is the implementation side of attributes already known, not a new source of them.
- **`NSAccessibilityConstants.h`**: re-declares priority/notification-related constants for accessibility notifications (e.g., `NSAccessibilityPriorityKey`) used for VoiceOver announcements — a *push* mechanism apps use to proactively notify assistive technology, not a *pull* API this program's read-only, on-demand capability model could use (this codebase has no notification-observer architecture at all, and adding one would be a significant, out-of-scope architectural change, not a single-capability addition).

No obsolete, undocumented, or SDK-unavailable symbol was proposed as a target this phase — every attribute/action/API referenced above was confirmed present in the installed SDK by direct `grep`.

---

## Existing Capability Coverage (verified against source)

Compact coverage map for capabilities most relevant to this phase's own overlap analysis (full 58-capability registry re-confirmed via direct extraction; only the semantic families intersecting this phase's candidates are itemized below for brevity):

| Capability ID | Risk | Semantic Target | AX Role(s) | Primary AX Attribute/Action | Read/Mutation |
|---|---|---|---|---|---|
| `ui.click_element` | L2 | Press a button/control | any (search-time) | `kAXPressAction` (hard-coded) | Mutation |
| `ui.set_element_state` | L2 | Checkbox/radio state | `AXCheckBox`/`AXRadioButton` | `kAXPressAction` (hard-coded) | Mutation |
| `ui.step_incrementor` | L2 | Stepper value | `AXIncrementor` | `kAXIncrementAction`/`kAXDecrementAction` (hard-coded) | Mutation |
| `ui.set_slider_value` | L2 | Slider/incrementor value | `AXSlider`/`AXStepper`* | `kAXValueAttribute` (set) | Mutation |
| `ui.read_element_value` | L0 | Element's own value | `QAXElementReadRolePolicy` allowlist | `kAXValueAttribute` (read) | Read |
| `ui.read_focused_element` | L0 | Systemwide focused element | any (resolution), gated (value) | `kAXFocusedUIElementAttribute` | Read |
| `ui.read_element_range` | L0 | Numeric bounds | `AXSlider`/`AXIncrementor`/`AXSplitter` | `kAXMinValueAttribute`/`kAXMaxValueAttribute` | Read |
| `ui.list_*` (24 capabilities) | L0 | Container enumeration | per-family role policy | `kAXChildrenAttribute`/family-specific | Read |
| `ui.select_*` (7 capabilities) | L2 | Selection state | per-family role policy | `kAXPressAction`/`kAXValueAttribute` (hard-coded) | Mutation |

*`"AXStepper"` confirmed in Phase 2BJ to have no backing SDK role constant; `QAXSliderRolePolicy`'s inclusion of it is a pre-existing, harmless inert entry, unchanged this phase.

**Critical distinction confirmed**: every mutation capability above dispatches a **specific, hard-coded** action or attribute-write chosen by the implementation based on role — none of them, and no read capability either, ever calls `AXUIElementCopyActionNames` to ask an element what it *actually* supports. This is the precise, verified gap this phase's selected candidate closes.

---

## Candidate Discovery

### 1. `ui.list_element_actions` — SELECTED
1. **Capability ID**: `ui.list_element_actions`
2. **Risk level**: Level 0 (Read-Only)
3. **AX role**: any role on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim, not forked) — the same roles `ui.read_element_value` already trusts, which already excludes `AXSecureTextField`.
4. **AX attribute/action**: `AXUIElementCopyActionNames` (the discovery call itself — not `kAXPressAction` or any fixed constant).
5. **AppKit control or UI concept**: any standard control (a plain `NSButton` reports `["AXPress"]`) plus, distinctively, any view with `NSAccessibilityCustomAction`s attached (e.g., a mail-message row exposing "Reply"/"Archive"/"Mark as Read" beyond the fixed press vocabulary).
6. **Why it is not already covered**: every existing mutation capability hard-codes its action per role; no capability discovers an element's actual, possibly app-defined action vocabulary.
7. **Target resolution**: identical to `ui.read_element_value` — exact application resolution (`resolveExactRunningApplication`, unmodified), then exactly one element by role + (`identifier` or `title`) via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives. Zero/ambiguous matches fail closed exactly as every prior read capability already does.
8. **Independent verification**: the read's own success/failure — a well-formed, bounded array of action-name strings was obtained, or it wasn't — the identical "stateless read's own success IS the ground truth" discipline every Level 0 capability's verification already uses.
9. **Privacy implications**: action names are structural UI-affordance labels (a fixed AX vocabulary like `"AXPress"`/`"AXShowMenu"`, or a short app-defined custom label like `"Reply"`) — never user-entered content, never typed values. Deferring `AXUIElementCopyActionDescription` (localized descriptions, potentially longer arbitrary app-authored text) to a documented open question rather than including it in v1, out of conservative caution.
10. **Resource bounds**: single element, one `AXUIElementCopyActionNames` call, result capped at a defensive ceiling (proposed 16 — real controls essentially always expose a single-digit action count) — zero traversal.
11. **Approval required**: none — Level 0.
12. **Recovery**: observation-first, trivially — a read has no side effects, an uncertain step always safely retries.
13. **Native AppKit fixture feasibility**: HIGH — a plain `NSButton` (baseline `["AXPress"]` case) plus an `NSView` with a real `NSAccessibilityCustomAction` attached via `setAccessibilityCustomActions(_:)` (the distinctive, novel case this capability uniquely serves) are both real, standard, modern (10.13+) public AppKit APIs.

### 2. `ui.read_window_default_button` — carried forward from Phases 2BG/2BH/2BI/2BJ, still unimplemented
Unchanged from four prior discovery phases' own assessment — re-verified this phase with no new evidence changing it. `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` on `AXWindow`, Level 0, narrow "what activates on Enter/Escape" utility.

### 3. `ui.list_ruler_markers` — carried forward from Phases 2BI/2BJ, still unimplemented
Unchanged from prior assessment. `kAXMarkerUIElementsAttribute`/`kAXMarkerTypeAttribute` on `AXRuler`, Level 0, complements the already-shipped `ui.list_rulers`.

### 4. `ui.read_element_label` — carried forward from Phases 2BH/2BI/2BJ, still unimplemented
Unchanged from prior assessment. `kAXTitleUIElementAttribute`, Level 0, narrower value than the winner since the same fact is often reachable today if the label's own identifier is known.

### Rejected this phase (fresh, not carried forward)
- **VoiceOver custom rotor discovery** (`NSAccessibilityCustomRotor`) — rejected: rotors are populated via a delegate protocol at VoiceOver-request time, not exposed as a static, `AXUIElementCopyAttributeValue`-readable attribute at all — there is no authoritative, on-demand pull API for this program's execution model to call. Not a viable capability target under this program's architecture.
- **Accessibility notification observation** (`NSAccessibilityConstants.h`'s priority/notification keys) — rejected: this is a *push* mechanism (apps proactively notify observers) requiring an observer/callback architecture this program does not have and which would be a significant architectural addition, not a single capability. Also raises an unbounded-polling-adjacent concern (an agent "waiting" for a notification event) explicitly out of scope per this phase's own rejection criteria.
- **`AXUIElementCopyActionDescription` as its own capability, or bundled into v1 of the winner** — considered and deliberately deferred rather than included: action descriptions are localized, app-authored free text (distinct from the fixed, short action-name vocabulary), carrying a materially different privacy profile closer to arbitrary content than a structural label. Flagged as an open question for a future enhancement decision, not silently included.
- **Still-rejected, re-confirmed with no new evidence**: `ui.read_element_url` (fixture-availability), `ui.list_grid_items` (`AXGrid` role-emission unreliability), `ui.list_rating_indicators` (no public `NSRatingIndicator` class), `AXSwitch`/`AXToggle` role-policy extension (would duplicate `ui.set_element_state`, not a new capability).

All rejected candidates that require coordinates, `CGEvent`, keyboard/mouse simulation, screenshots, OCR, timing-dependent scraping, fuzzy matching, unbounded traversal/polling, browser/JavaScript automation, network/cloud access, fabricated roles, or obsolete/SDK-unavailable symbols were excluded before reaching candidate-list status at all — none of the four scored candidates above require any of these.

---

## Scoring (0–100 per dimension, explicit weights per this phase's own model)

Weights: Semantic authority/AX support 20, Deterministic verification 15, Security/fail-closed compatibility 15, Architectural reuse 10, User utility 10, Privacy safety 10, Resource boundedness 5, Testability w/ native AppKit fixture 10, Non-duplication/roadmap value 5 (sum = 100).

| Dimension | Weight | `ui.list_element_actions` | `ui.read_window_default_button` | `ui.list_ruler_markers` | `ui.read_element_label` |
|---|:---:|:---:|:---:|:---:|:---:|
| 1. Semantic authority / AX support | 20 | 95 → 19.00 | 82 → 16.40 | 78 → 15.60 | 78 → 15.60 |
| 2. Deterministic verification | 15 | 85 → 12.75 | 85 → 12.75 | 78 → 11.70 | 80 → 12.00 |
| 3. Security / fail-closed compatibility | 15 | 95 → 14.25 | 90 → 13.50 | 92 → 13.80 | 86 → 12.90 |
| 4. Architectural reuse | 10 | 88 → 8.80 | 85 → 8.50 | 85 → 8.50 | 85 → 8.50 |
| 5. User utility | 10 | 65 → 6.50 | 50 → 5.00 | 40 → 4.00 | 55 → 5.50 |
| 6. Privacy safety | 10 | 92 → 9.20 | 88 → 8.80 | 90 → 9.00 | 75 → 7.50 |
| 7. Resource boundedness | 5 | 95 → 4.75 | 92 → 4.60 | 92 → 4.60 | 88 → 4.40 |
| 8. Testability w/ native AppKit fixture | 10 | 92 → 9.20 | 85 → 8.50 | 62 → 6.20 | 68 → 6.80 |
| 9. Non-duplication / roadmap value | 5 | 98 → 4.90 | 90 → 4.50 | 95 → 4.75 | 78 → 3.90 |
| **Weighted Total** | **100** | **89.35** | **82.55** | **78.15** | **76.60** |

**Ranking**: `ui.list_element_actions` (89.35) > `ui.read_window_default_button` (82.55) > `ui.list_ruler_markers` (78.15) > `ui.read_element_label` (76.60). No manipulation was applied to force this outcome — the winner's advantage is concentrated in the two highest-weighted dimensions (semantic authority, 20% weight; security, 15% weight), both scored on genuine, verified evidence (a real, non-obsolete, previously-untouched C API; a read-only capability with zero mutation surface reusing an already-vetted role policy).

---

## Selected Capability

**Capability**: `ui.list_element_actions`
**Risk**: Level 0 (Read-Only)
**Score**: 89.35 / 100

### Semantic target
Exactly one semantically-identified element on `QAXElementReadRolePolicy`'s existing allowlist (reused verbatim). No new AX hierarchy — the target is any single element already reachable by this program's existing search primitives, exactly as `ui.read_element_value` already resolves its own target.

### Inputs
`applicationName` (required), `role` (required — a search criterion, matching `ui.read_element_value`'s exact contract shape), `identifier` **or** `title` (at least one required). No `windowTitle` scoping needed beyond what `collectMatches`'s existing bounded search already provides.

### Resolution
1. Role policy check: `role` must be on `QAXElementReadRolePolicy.allowedRoles` — checked before any AX call.
2. Accessibility trust: `AXIsProcessTrusted()` checked before application resolution.
3. Application resolution: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero/ambiguous matches fail closed.
4. Target resolution: `collectMatches`/`snapshotIfMatches` bounded search for the one element by role + identifier-or-title — zero/ambiguous matches fail closed, staleness re-checked immediately before the read.

### AX operation
`AXUIElementCopyActionNames(targetElement, &names)` — a single call, cast the returned `CFArray` to `[String]`, cap at a defensive ceiling (proposed 16), independently re-validate the cast succeeded (treat the returned collection as untrusted external data, mirroring `ui.list_windows`'s own `windowsCollectionMalformed`-style discipline). `AXUIElementCopyActionDescription` deliberately **excluded from this proposed contract** (see Rejected Candidates — deferred, not silently dropped).

### Verification
Proposed named strategy: `QVerificationStrategy.elementActionsReadSucceeded(applicationName: String, role: String, actionCount: Int)` — checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`. Independent of any mutation by construction (there is no mutation — this is Level 0). Evidence: `application=<name> role=<role> actionCount=<n> status=verified`, never the individual action-name strings themselves (matching `ui.read_element_range`'s own more conservative evidence-privacy pattern).

### Approval
None required — Level 0, routed by `QPermissionGate.evaluate` straight to `.allow`, not a special-cased bypass (to be proven directly in the eventual test suite, mirroring every prior Level 0 capability's own proof).

### Recovery
Observation-first, trivially: a read has no side effects; an uncertain in-flight step fails closed to `pending`, and a retry is always safe.

### Privacy
**May leave the immediate reasoning boundary** (i.e., may be returned to the model): the bounded list of action-name strings (fixed AX vocabulary or short custom labels) and an aggregate count. **Must never be persisted/audited beyond identity + count**: the individual action-name strings themselves are kept out of durable verification evidence (per the proposed evidence string above) — a deliberately more conservative choice than some prior Level 0 capabilities (e.g. `ui.list_incrementors`'s own min/max-in-evidence precedent), justified because action names could, in principle, be app-defined arbitrary short strings rather than a fully fixed vocabulary, and the extra caution costs nothing.

### Resource bounds
- Elements: **1** (the resolved target only).
- Traversal depth: **0** (no descent beyond the resolved element — `kAXChildrenAttribute` is never read).
- Children: **0**.
- Actions performed: **0** (this is a discovery-only read; `AXUIElementPerformAction` is never called).
- Polling: **0** (a single synchronous call).
- Returned records: **≤ 16** action-name strings (defensive ceiling; exceeding it fails closed rather than silently truncating, mirroring every prior `list_*` capability's identical bound-enforcement discipline).

### E2E fixture
A plain `NSWindow` containing (a) an `NSButton` (baseline case — expected to report `["AXPress"]`) and (b) an `NSView` with a real `NSAccessibilityCustomAction` (e.g., named `"Reply"`) attached via `setAccessibilityCustomActions(_:)` — the distinctive case this capability uniquely serves, demonstrating discovery of an action name no existing hard-coded capability could have anticipated.

---

## Security Rejection Analysis

- **Can an LLM abuse it to escape semantic boundaries?** No — this capability is strictly read-only, returns only short action-name strings, and grants no new authority; it cannot itself perform any action, and no existing capability accepts an arbitrary model-supplied action name to invoke (every mutation capability still dispatches its own hard-coded action, unchanged by this addition).
- **Can it target an unintended application?** No — reuses `resolveExactRunningApplication` unmodified; fails closed on zero/ambiguous matches, identical to all 58 shipped capabilities.
- **Can ambiguity occur?** Handled identically to `ui.read_element_value`'s own target resolution — zero or 2+ matches fail closed, never `.first`.
- **Can stale AX state cause an unsafe action?** No unsafe action is possible at all — this capability never performs an action; staleness at worst produces an inaccurate informational read (mitigated by the same observation-binding staleness check every prior capability already applies), never a physical side effect.
- **Can authorization survive recovery?** Not applicable — Level 0, no authorization exists to survive.
- **Can raw AX objects/pointers escape into durable state?** No — the output is a bounded array of `String` only; no `AXUIElement`-typed field is ever constructed in the output type.
- **Can the capability expose sensitive user content?** No — action names are UI-affordance labels (e.g., `"AXPress"`, `"Reply"`), never user-entered values; the reused `QAXElementReadRolePolicy` additionally excludes `AXSecureTextField` from ever being a valid target at all.
- **Can the capability be abused as a hidden physical-input fallback?** No — it never calls `AXUIElementPerformAction`; it only calls the two read-only discovery functions (`AXUIElementCopyActionNames`, and — deliberately excluded from this contract — `AXUIElementCopyActionDescription`).
- **Is there any reason it should be Level 3 instead?** No — there is no mutation surface, no irreversibility, no elevated blast radius of any kind; Level 0 is the correct and only defensible classification.

No unresolved security risk was identified. The candidate is not rejected on security grounds.

---

## Explicit Implementation Deferral

**Implementation: NOT STARTED.** This document is discovery-only. No production source file, registry entry, executor, bridge, verification strategy, or test file has been created or modified as part of this phase. The proposed contract above (semantic target, inputs, resolution, AX operation, verification strategy name, approval/recovery behavior, privacy boundary, resource bounds, and E2E fixture) is a design proposal for a future, separately-approved implementation phase — not a description of code that exists today.

Phase 2BK — DISCOVERY COMPLETE

---

*(Post-discovery note: implementation has since been completed under separate explicit approval — see [`PHASE_2BK_SEMANTIC_ELEMENT_ACTION_ENUMERATION.md`](./PHASE_2BK_SEMANTIC_ELEMENT_ACTION_ENUMERATION.md) for the full implementation contract, test results, and security/privacy audit. The proposed contract above was implemented as designed, with `AXUIElementCopyActionDescription` remaining deliberately excluded from v1 exactly as this document proposed.)*
