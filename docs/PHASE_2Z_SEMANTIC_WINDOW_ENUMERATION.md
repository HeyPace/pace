# Phase 2Z — Semantic Window Enumeration (`ui.list_windows`)

Q's nineteenth controlled UI-interaction capability, and its **first read-only, Level 0 capability
at the window layer**. Enumerates the windows belonging to exactly ONE named, currently running
application. No mutation, no approval, no recovery.

## Why this capability, and why now

Every window-level mutation capability shipped so far (Phase 2U `ui.set_window_minimized`, 2V
`ui.set_application_hidden`, 2W `ui.set_scroll_position`, 2X `ui.set_window_main`, 2Y
`ui.close_window`) requires the caller to already know a target window's *exact* title or
identifier — but no capability in this codebase could discover that in the first place.
`accessibility.read` only reads the single currently-focused element; `system.running_apps` only
enumerates applications, not their windows. `ui.list_windows` closes that gap.

## Exact macOS AX semantics

Confirmed directly against `AXAttributeConstants.h`: `kAXWindowsAttribute` is listed under
"application element-specific attributes" — the same terse, bare-`#define`, no-discussion-block
documentation style as `kAXMenuBarAttribute` (already used reliably in this codebase since
Phase 2L). Since this capability only ever **reads** the attribute, the "don't assume writability"
caution that governs every prior phase's mutation primitive does not apply here — there is nothing
to misjudge about writability for a read.

## Capability contract

Registered as `"ui.list_windows": ("ui", .level0ReadOnly)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to enumerate. Exact `localizedName`/`bundleIdentifier` match only — no fuzzy/substring matching, no "all windows on screen." |

Returns, per included window: `title?`, `identifier?`, `minimized?`, `main?` — never raw
`AXUIElement` references, never window content.

## Application resolution — exact, ambiguity fails closed

`NSWorkspace.shared.runningApplications` is filtered (not merely `.first(where:)`, unlike most
prior capabilities) for exact matches; zero matches throws `applicationNotAvailable`, and **more
than one** match throws `ambiguousTarget(count:)` — reused directly from the generic
target-resolution vocabulary every prior capability already shares. This ambiguity check is new
relative to most prior window capabilities' own application-resolution code (which use a bare
`.first(where:)`), added specifically because this phase's own contract explicitly requires it;
it does not weaken anything else.

## Bounded, direct-child-only enumeration — never recursive

`AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute)` is read exactly once. The
returned value is treated as **untrusted external data**:

- A failed or absent read is a **legitimate empty result** (e.g. a headless/background-only
  application genuinely has no windows) — never an error.
- A value that cannot be cast to `[AXUIElement]` throws `windowsCollectionMalformed` — a hard
  failure, since success from the copy call is never itself sufficient proof of a well-formed
  collection.
- The raw array's size is checked against `QBridgeAccessibility.maxWindowEnumerationCount` (64)
  **before** any per-element read — `windowCollectionExceedsSafeBound` throws if exceeded. A real
  application's window count is always naturally small; this exists purely as a defensive bound
  against a hostile or corrupted AX responder.

Per returned element, at most five direct attribute reads occur (`kAXRoleAttribute`,
`kAXTitleAttribute`, `AXIdentifier`, `kAXMinimizedAttribute`, `kAXMainAttribute`) — **no**
`kAXChildrenAttribute` read, no `collectMatches` call, no recursion of any kind. This is
structurally distinct from every semantic-target-resolution capability in this codebase (which all
use the bounded-but-recursive `collectMatches` tree walker) — this capability performs a flat,
direct-children-only enumeration instead.

## Role validation and optional metadata

Only elements whose own `kAXRoleAttribute` reports exactly `AXWindow` are included — a wrong-role
or unreadable-role element is silently excluded (`continue`, never `throw`), never failing the
whole enumeration merely because one returned item is not genuine. Every other field
(`title`/`identifier`/`minimized`/`main`) is independently optional: a missing one is never an
error and never excludes the window — represented as `nil` in `QAXWindowMetadata`, the established
codebase convention for unreadable-but-non-fatal attributes.

## Verification — a meaningful check, not a bypass

`QVerificationStrategy.windowEnumerationSucceeded` deliberately does **not** fall through to the
generic `.customCheck { true }` bypass. There is no independent physical state to re-observe after
a stateless read (unlike every mutation capability's verification, which exists specifically to
confirm a real side effect independent of the mutation call's own return value) — the read's own
success/failure, established entirely inside `listWindows`, already is the ground truth. This
strategy checks the execution result's own `success` flag as a genuine assertion, so a step that
somehow reached verification without a successful read is still correctly reported `.failed`. Its
evidence string carries only the application name and a window **count** — never any individual
window's title or identifier.

## No idempotency question, no recovery

A read-only snapshot has no "already satisfied" question to ask — every invocation is a fresh
point-in-time observation. Level 0 reads are never persisted as an in-flight uncertain step, so
`QTaskRecoveryManager` gained no new branch — matching every other existing Level 0 capability
(`system.running_apps`, `ui.read_element_value`, `accessibility.read`) exactly, none of which have
one either.

## Staleness — explicit, and load-bearing

The returned list is a point-in-time snapshot. Windows may appear or disappear immediately
afterward; titles/identifiers/states may change; array **ordering is never treated as meaningful**
— no frontmost/z-order/main-window inference is ever drawn from a window's position in the result.
`QAXWindowMetadata` carries no `AXUIElement` reference of any kind, so a caller cannot use a
returned entry to re-invoke any AX call directly against it. **This result is never itself an
actionable target reference** — every subsequent mutation capability
(`ui.set_window_minimized`/`ui.set_window_main`/`ui.close_window`/etc.) must independently perform
its own fresh, exact target resolution and its own approval flow, completely independent of
anything this capability observed.

## Privacy — the persistence pipeline itself, not just the AX bridge

This phase's privacy analysis required inspecting `QDurablePlanStepSnapshot.init(from:)` (in
`QDurablePlanSnapshot.swift`) directly, rather than only the AX bridge layer. That initializer
reads only `step.result.summary` and `step.result.verifiedEvidence` (both `String`) — **never**
`step.result.outputData` — confirmed by direct source inspection and re-verified empirically in
this phase's own test suite (`durableSnapshotHasNoOutputDataField`, which constructs a real
completed step carrying sensitive window titles in `outputData` and confirms the resulting durable
snapshot contains none of them). The structured per-window list `ui.list_windows` returns
therefore structurally cannot reach durable storage, audit logs, replanning state, or long-term
memory through the generic persistence pipeline — no new redaction machinery was needed for a
field the architecture never serializes in the first place.

`QActionResult.summary` — the one string field that *does* cross into
`resultSummary`/`verifiedEvidence`/audit-log persistence — is therefore deliberately kept to an
aggregate window **count** only (`"Enumerated N window(s) for application 'X'."`); it never embeds
any individual window's title or identifier, so that boundary stays clean on this capability's own
side too, independent of the `outputData` fact above. Audit records additionally SHA-256-hash
`rawArguments` before storage (a pre-existing, capability-agnostic guarantee, not something this
phase added) — `applicationName` never appears in plaintext in the audit log either.

No window contents, document text, descendant labels, OCR, or screenshots are ever read — the
capability's only reads are `kAXWindowsAttribute` plus the five bounded per-element attributes
listed above.

## Provenance, budget

- `toolFamily: "ui"` — no new taxonomy.
- `QAgentBudget`/`QResourceGuard` apply generically, exactly as for every other capability;
  `QPlanExecutor`'s budget check has no risk-level branch, so a Level 0 read still counts against
  the same per-task step budget as any mutation.

## Real macOS AX E2E

`AXIsProcessTrusted() == false` was confirmed in this session's isolated XCTest runner, consistent
with every phase since 2N. All `AXIsProcessTrusted()`-gated real-AX tests in
`QSemanticWindowEnumerationTests.swift` — including `realMacOSE2EMultipleWindowsFixture` (two real
`NSWindow` fixtures, one minimized, distinct identifiers, verifying the enumeration's metadata
matches each fixture exactly) — honestly no-op in this environment rather than fabricate a pass.
Deterministic unit-test confidence: HIGH (33/33 focused tests pass). Apple API documentation
confidence: MEDIUM (bare `#define`, no discussion block for `kAXWindowsAttribute` itself), offset
by `kAXMenuBarAttribute`'s already-proven reliability in this exact codebase. Real macOS
session/hardware confidence: UNVALIDATED pending a trusted environment — reported honestly rather
than fabricated.

## Forbidden mechanisms — explicitly absent

No `AXUIElementSetAttributeValue`, no `AXUIElementPerformAction` (zero mutation primitives of any
kind), no `kAXChildrenAttribute` read (no recursive descent), no `CGWindowListCreateImage`, no
Vision-framework/OCR symbol, no `CGEvent`/`NSEvent`, no AppleScript, no shell, no network — verified
via source-level review and a grep-based forbidden-symbol audit of the full Phase 2Z diff
(production code and tests).
