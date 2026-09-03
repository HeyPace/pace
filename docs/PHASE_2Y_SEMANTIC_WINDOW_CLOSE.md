# Phase 2Y — Semantic Window Close (`ui.close_window`)

Q's eighteenth controlled UI-interaction capability, and its **first genuinely one-way, high-risk
(Level 3) semantic UI capability**. Closes exactly ONE semantically-identified `AXWindow`. Unlike
every prior capability in this codebase (all reversible boolean/value writes or selections), a
window close cannot be undone by re-running the capability in reverse — there is no "un-close."

## Exact macOS AX semantics — confirmed against the authoritative SDK header

Confirmed directly against `AXAttributeConstants.h`:

> `kAXCloseButtonAttribute` — *"A convenience attribute so assistive apps can quickly access a
> window's close button element. Value: An AXUIElementRef of the window's close button element.
> Writable? No. Required for all window elements that have a close button."*

There is no writable "closed" attribute and no dedicated window-level close action — the only
correct native mechanism is: resolve the window, follow this read-only convenience reference to
the actual close-button `AXButton` element, and press it via `AXUIElementPerformAction(kAXPressAction)`.

## Why Level 3, not Level 2

Every other window-level capability in this codebase (`ui.set_window_minimized`,
`ui.set_application_hidden`, `ui.set_window_main`) is a trivially reversible boolean-attribute
write — re-running the capability with the opposite argument restores the prior state exactly.
Closing a window has no such inverse: if the target application does not autosave/version
documents, the action can cause genuine, irreversible data loss. This capability is therefore
classified `.level3HighRisk` — the same tier as `app.quit`, whose blast radius (the whole
application) this capability strictly narrows to one window, but whose irreversibility risk is
comparably real. `QCapabilityLevel.level3HighRisk.isConsideredReversible == false`,
`.requiresExplicitApproval == true` — deliberately **not** downgraded to Level 2.

## Capability contract

Registered as `"ui.close_window": ("ui", .level3HighRisk)`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search. |
| `role` | yes | Must be `AXWindow` — reuses `QAXWindowRolePolicy` (Phase 2U) unmodified. |
| `identifier` | one of `identifier`/`title` | Matched against `AXIdentifier` — checked first when present. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`/`AXDescription`, only when `identifier` is absent. |

No coordinate, index, "first window," or "active window" parameter exists, and none is
structurally reachable — exact-match resolution only, via the unmodified `collectMatches`/
`snapshotIfMatches` resolver every prior capability shares.

## Mutation — exactly one primitive

`AXUIElementPerformAction(closeButtonElement, kAXPressAction)` on the close button resolved via
`kAXCloseButtonAttribute` — never on the window element itself, never `AXUIElementSetAttributeValue`
(there is no writable close state), never `kAXCloseAction` (no such window action exists in the
SDK), never repeated. The close-button reference's own `kAXRoleAttribute` is independently
re-validated as exactly `AXButton` before ever being pressed — the mere existence of the
convenience reference is never sufficient, by direct analogy to `ui.set_scroll_position`'s
`targetNotAScrollBar` check on its own convenience reference. The press's `AXError` return value is
never itself treated as proof of success.

## Idempotency — absence, carefully distinguished from inability to observe

If the exact target window is already unresolvable at resolution time — with the owning
application independently confirmed running via a fresh `NSRunningApplication` lookup moments
earlier — `changeKind: .alreadyAbsent` is returned with **no** `AXUIElementPerformAction` call.
This is deliberately, structurally distinct from every other failure path:

- **Ambiguous** (`matches.count > 1`) → throws `QAXInteractionError.ambiguousTarget`, never folded
  into absence.
- **Application unresolvable** → throws `QAXInteractionError.applicationNotAvailable`, never
  folded into absence.
- **Accessibility Trust unavailable** → throws `QAXInteractionError.accessibilityPermissionDenied`,
  never folded into absence.

Only a genuine zero-match resolution, with the application's existence independently confirmed
first, counts as "already satisfied."

## Verification — absence-based, a first for this codebase

`QVerificationStrategy.windowCloseVerified` calls `QBridgeAccessibility.observeWindowCloseEvidence`,
which:

1. Independently re-resolves the **owning application** first (a fresh, separate
   `NSRunningApplication` lookup) — application termination and a genuine single-window close are
   never conflated.
2. Independently re-resolves the exact original window identity.

`QAXWindowCloseEvidence` is a deliberate five-way, never-collapsed result:

| Evidence | Meaning | Verification outcome |
| --- | --- | --- |
| `.windowAbsentApplicationRunning` | App confirmed running, window no longer resolves | `.verified` — the ONLY success path |
| `.windowStillPresent` | Window still resolves (close didn't take effect, or a save/discard sheet is blocking it) | `.failed` |
| `.ambiguousTarget(count:)` | Multiple matches now | `.failed` — never assumed absent |
| `.applicationNotRunning` | Owning application no longer running | `.failed` — **never credited as success** (see below) |
| `.permissionUnavailable` | Accessibility Trust unavailable | `.failed` — never assumed absent, never assumed present |

## The application-survival rule

If the owning application is no longer running, this capability's success is **never** credited —
the application may have quit or crashed, a categorically different outcome. This is enforced at
both the idempotency check (in `closeWindow`, application existence is confirmed *before* absence
can be established) and independently again at verification/recovery time (`observeWindowCloseEvidence`
checks the application first, every time, never trusting a prior check).

## Save/discard dialog isolation — absolute rule

`ui.close_window` performs the single close-button press and stops. It never detects which save
option is selected, never clicks Save/Don't Save/Cancel, never presses Return or Escape, never
inspects dialog/sheet text or contents, and never recursively searches descendants to find or
operate on a resulting dialog. If a save/discard sheet appears and the original window remains
resolvable, that is indistinguishable — by design — from `.windowStillPresent`, and verification
correctly reports `.failed`. The dialog itself is entirely outside this capability's scope, left
to the human user.

Because a plain AppKit fixture with no `NSDocument` architecture cannot produce a real save dialog,
the test suite (`QSemanticWindowCloseTests.swift`) uses an `NSWindowDelegate` whose
`windowShouldClose(_:)` unconditionally returns `false` as an **honest, explicitly-labeled proxy**
for "something is blocking this close" — never inspected or acted upon by the capability itself,
used purely to make the block reproducible so the suite can assert the correct `.failed`
verification outcome in exactly the shape a real blocked close would produce.

## Recovery — observation-first, no blind replay

`QTaskRecoveryManager`'s `"ui.close_window"` branch reuses `observeWindowCloseEvidence` directly —
the same primitive verification uses. `verified = true` only on `.windowAbsentApplicationRunning`;
every other evidence value (still-present, ambiguous, application-not-running,
permission-unavailable) falls through to `pending`. A still-resolvable window is never blindly
re-pressed — a resumed retry requires a brand-new `QExecutionIdentity`, a genuinely fresh Level 3
approval grant, fresh target resolution, and fresh close-button resolution.

## No multi-window behavior, no application quit

`collectMatches` is called exactly once per `closeWindow` invocation, scoped to the caller-supplied
criteria, which structurally resolve to exactly one element or fail closed. There is no window
enumeration, no "close all windows," no automatic closing of sheets/dialogs, and no closing of the
application. `ui.close_window` never calls `NSRunningApplication.terminate()` or any `app.quit`
code path — application termination remains a categorically separate capability.

## Provenance, budget, privacy

- `toolFamily: "ui"` — no new taxonomy.
- Reuses `QAgentBudget`/`QResourceGuard` generically; no per-tool wiring, no unbounded
  enumeration/retry, no recursive AX tree traversal beyond the single close-button resolution.
- Only window identity metadata (already-permitted `applicationName`/`role`/`identifier`/`title`)
  plus the change-kind and verification status ever cross persistence/audit/HUD/log boundaries —
  never window contents, document contents, save-dialog text, descendants, screenshots, OCR, or
  user-entered data.

## Real macOS AX E2E

`AXIsProcessTrusted() == false` was confirmed directly in this session's isolated XCTest runner
(consistent with every phase since 2N). All `AXIsProcessTrusted()`-gated real-AX tests in
`QSemanticWindowCloseTests.swift` — including `realMacOSE2ECloseWindow` (a genuine close + absence
verification) and `realMacOSE2EBlockedCloseScenario` (the delegate-blocked-close proxy scenario) —
honestly no-op in this environment rather than fabricate a pass. Deterministic unit-test
confidence: HIGH (48/48 focused tests pass, exercising every fail-closed path via mocked/structural
assertions). Apple API documentation confidence: HIGH (`kAXCloseButtonAttribute`'s discussion block
is unambiguous). Real hardware/session confidence: UNVALIDATED pending a trusted environment —
reported honestly rather than fabricated.

## Forbidden mechanisms — explicitly absent

No `kAXRaiseAction`, no minimize/fullscreen button press, no window title-bar coordinates, no mouse
events, no keyboard shortcuts (Cmd+W), no `CGEvent`/`NSEvent`, no AppleScript, no shell, no direct
`NSWindow` mutation, no `kAXConfirmAction`/`kAXCancelAction` (dialog interaction), and no
`NSRunningApplication.terminate()` — verified via source-level review and a grep-based
forbidden-symbol audit of the full Phase 2Y diff (production code and tests).
