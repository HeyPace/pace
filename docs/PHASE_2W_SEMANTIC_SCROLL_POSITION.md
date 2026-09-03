# Phase 2W — Semantic Scroll Position (`ui.set_scroll_position`)

Q's sixteenth controlled UI-interaction capability. Sets the **absolute** numeric position of
exactly one semantically-identified scroll bar — never scroll-by-delta, never scroll-to-visible,
never scroll-to-text, never scroll-wheel/mouse/keyboard/coordinate simulation.

## Exact macOS AX semantics — confirmed against the authoritative SDK headers

Confirmed directly against `AXAttributeConstants.h`. This is the strongest documentation basis
found in any Discovery round this session besides `kAXMinimizedAttribute` itself — Apple names
the target role *by name*, not by hedged generality:

| Symbol | Documented semantics (verbatim from the header) |
| --- | --- |
| `kAXValueAttribute` | *"Writable? Generally yes... a **kAXScrollBar's** kAXValueAttribute is writable because it allows an efficient way for the user to get to a specific position in the element being scrolled."* |
| `kAXMinValueAttribute` / `kAXMaxValueAttribute` | *"This is useful for things like **sliders and scroll bars**..."* — both discussion blocks name scroll bars explicitly, the same range-bound pattern `ui.set_slider_value` already established. |
| `kAXHorizontalScrollBarAttribute` / `kAXVerticalScrollBarAttribute` | Real, defined convenience-reference constants (`"AXHorizontalScrollBar"`/`"AXVerticalScrollBar"`) — the same "resolution-only, never mutated" class as every prior convenience-reference attribute already used in this codebase (`kAXParentAttribute` since Phase 2S, `kAXMenuBarAttribute` since Phase 2L). |

## Why the scroll bar is never searched for directly

Raw `AXScrollBar` elements are commonly unlabeled (no `AXTitle`/`AXIdentifier`) in real
applications. Rather than accept fuzzy/positional targeting — forbidden by this codebase's
architecture — resolution anchors on the containing `AXScrollArea` (`QAXScrollAreaRolePolicy`'s
only allowed role, resolved via the exact same unmodified `collectMatches`/`snapshotIfMatches`
exact-match resolver every prior capability already uses) plus an **explicit, never-inferred**
`orientation` parameter (`"horizontal"`/`"vertical"` only). The actual scroll bar is then resolved
via the documented read-only convenience-reference attribute, and its own `kAXRoleAttribute` is
independently re-validated as exactly `"AXScrollBar"` before ever being treated as genuine — the
mere existence of the reference is never sufficient
(`QAXInteractionError.targetNotAScrollBar`/`.scrollBarReferenceUnavailable`).

## Capability contract

Registered as `"ui.set_scroll_position": ("ui", .level2UserApproval)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXScrollArea` — the only allowed search-criterion role. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`, only when `identifier` is absent. |
| `orientation` | yes | Must be exactly `"horizontal"` or `"vertical"` — never inferred from arbitrary metadata. |
| `desiredValue` | yes | A finite numeric absolute position, strictly validated against the scroll bar's own reported range. |

No coordinate, delta, or "scroll until visible" parameter exists, and none is structurally
reachable.

## Why Level 2

Consistent with every other per-element AX mutation capability. A content-view scroll-position
change is a real, user-visible state change, not downgraded merely because it sounds passive.

## Mutation, range validation, and idempotency — reusing `ui.set_slider_value` verbatim

`AXUIElementSetAttributeValue(kAXValueAttribute)` on the resolved scroll bar only — never
`kAXIncrementAction`/`kAXDecrementAction`/`kAXPressAction`. This capability deliberately reuses
`ui.set_slider_value`'s exact validated logic rather than duplicating a subtly different rule:

- **Strict range check** (`desiredValue >= minValueAtSearch, desiredValue <= maxValueAtSearch`) —
  the identical, byte-for-byte expression `setSliderValue` already uses. Out-of-range requests are
  refused *before* any mutation, never silently clamped.
- **`QBridgeAccessibility.sliderValuesAreEqual`** — the exact same public tolerance function
  (absolute `1e-6`, relative `1e-9`) used for idempotency, drift detection, *and* closed-loop
  verification, called directly rather than re-implemented.
- **Idempotency**: read-before-write against the resolved scroll bar's own current value; already
  at the desired position (within tolerance) is a verified no-op, no attribute write performed.
- **Drift detection**: min/max/current re-read immediately before dispatch on the *same* scroll-bar
  element reference; any change refuses the mutation (`valueDriftDetected`).

## Independent verification and recovery

A new `QVerificationStrategy.scrollPositionMatchesDesired` re-resolves the **entire identity
chain** fresh — scroll area, then the orientation convenience-reference, then the scroll bar's own
role — and re-reads `kAXValueAttribute`, comparing via the identical tolerance rule. A successful
attribute-set call is never itself treated as proof. `QTaskRecoveryManager` gained a matching
observation-first recovery branch, reusing the same `observeScrollPositionEvidence` primitive —
notably, `ui.set_slider_value` itself has **no** recovery branch (a pre-existing gap, left
untouched per this phase's scope), but this phase's own explicit requirement for observation-first
recovery is honored with a genuine implementation rather than inherited as a gap.

## Provenance & privacy

Registered under `toolFamily: "ui"`. Only a bounded numeric position/range + non-secret scroll-area
identity metadata + orientation ever cross into audit/durable-state/HUD — never the scrolled
content, never a screenshot, never OCR, never descendant AX tree content. This capability reads
only `kAXRoleAttribute`, `kAXValueAttribute`, `kAXMinValueAttribute`, `kAXMaxValueAttribute`,
`kAXEnabledAttribute`, and the two scroll-bar convenience-reference attributes — it never inspects
document/content elements to decide where to scroll.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QBridgeAdapters.swift` — `QAXScrollAreaRolePolicy`, `QAXScrollPositionChangeKind`,
  `QAXScrollPositionOutcome`, `QAXScrollPositionEvidence`, `setScrollPosition`,
  `observeScrollPositionEvidence`, and four new `QAXInteractionError` cases
  (`disallowedScrollAreaRole`, `invalidOrientation`, `scrollBarReferenceUnavailable`,
  `targetNotAScrollBar`) — every other error case (`missingMatchCriteria`, `noMatchingElement`,
  `ambiguousTarget`, `staleTarget`, `targetDisabled`, `invalidDesiredValue`, `rangeReadFailed`,
  `invalidRange`, `desiredValueOutOfRange`, `valueReadFailed`, `valueDriftDetected`,
  `setValueFailed`, `accessibilityPermissionDenied`, `applicationNotAvailable`) is reused from the
  existing enum, unmodified. Reuses `sliderValuesAreEqual` (public since Phase 2M) and the existing
  `axElementAttribute(_:of:)` helper (already used for `kAXParentAttribute`/`kAXMenuBarAttribute`)
  — no new low-level AX plumbing beyond the two new convenience-attribute constants.
- `QExecutionService.swift` — `executeSetScrollPosition` dispatch + implementation.
- `QActionVerification.swift` — `.scrollPositionMatchesDesired` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch (new for this phase; the
  sibling `ui.set_slider_value` has none).
- `leanring-buddyTests/QSemanticScrollPositionTests.swift` — new focused suite (42 tests).

`ui.set_slider_value` is unmodified except for the fact that this capability reuses its public
`sliderValuesAreEqual` function verbatim (already public, no signature change).

## Real macOS AX E2E — result

`QSemanticScrollPositionTests.realMacOSE2ESetScrollPosition` (and every other AX-trust-gated test
in the suite) uses a real, live `NSScrollView` — already a genuine `AXScrollArea`-role AXUIElement
via default AppKit Accessibility bridging, the same favorable fixture position `ui.set_slider_value`'s
real `NSSlider` and `ui.set_window_minimized`'s real `NSWindow` already enjoy; no custom
`NSAccessibility` role override is needed for the primary fixture. Following
`QSemanticSliderValueTests`' own established precedent, genuinely hard-to-construct-live edge
cases (an internally inconsistent range, a misqualified scroll-bar reference) are documented via
source-level review rather than forced through an elaborate synthetic fixture.

In the isolated test-runner environment used to validate this phase, `AXIsProcessTrusted()` was
confirmed `false` (consistent with every prior AX capability in this codebase, Phase 2H through
2U). **Real AX E2E was therefore NOT exercised in this session** — every AX-trust-gated test
no-op'd via its `guard AXIsProcessTrusted() else { return }` rather than fabricating a pass. Every
deterministic, non-AX-dependent test (42/42 in this phase's suite) ran for real and passed,
including the full schema/registration, role-policy gate, input validation (orientation,
non-finite values), approval lifecycle, recovery structure, verification-strategy independence,
and structural forbidden-API/no-content-inspection checks.

**This phase's specific hardware-validation question, honestly unresolved this session**: whether
a real `NSScrollView` actually exposes `kAXHorizontalScrollBarAttribute`/
`kAXVerticalScrollBarAttribute` when scrolling is genuinely available — dependent on both
`AXIsProcessTrusted()` (unavailable) and on whether AppKit instantiates live `NSScroller` objects
for a window that is never truly rendered by WindowServer in this headless-adjacent test runner.
`QSemanticScrollPositionTests.realMacOSE2ESetScrollPosition` explicitly checks
`scrollView.verticalScroller != nil` as a first-order proxy and reports honestly rather than
assuming either way — this remains open for a genuinely trusted, interactive session to confirm.

## Known limitations

1. **Whether real production scroll areas (as opposed to this session's fixture) reliably expose
   the two convenience-reference attributes when scrolling is available is unconfirmed** — the
   central hardware-validation question this phase's Discovery specifically flagged, still open
   pending a trusted interactive session.
2. **A misqualified scroll-bar reference (wrong role) and an internally inconsistent
   min/max range cannot be constructed live** with a real `AXScrollBar`/`NSScroller` through public
   API — the same class of limitation `QSemanticSliderValueTests` already accepts for `NSSlider`'s
   own range invariants; both are covered by documented, source-reviewed tests instead.
3. Horizontal-orientation real hardware validation was not separately exercised this session
   beyond the vertical path (the same `AXIsProcessTrusted()` blocker applies identically to both).
4. The value/range observation-binding re-verify cannot protect against a mutation landing in the
   sub-millisecond window between its own two internal reads — the same documented, honest
   limitation every prior AX capability in this codebase already accepts.
5. Multi-axis (simultaneous horizontal+vertical) scrolling in one call is out of scope — exactly
   one orientation, one scroll bar, one value per invocation.
