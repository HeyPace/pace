# Phase 2H — Semantic AXUIElement Click (`ui.click_element`)

Q's first controlled UI-interaction capability: a Level 2, reversible click on a single,
semantically-identified Accessibility (AX) element. It never targets screen coordinates, never
falls back to a CGEvent click, and never claims goal success from a successful AX press alone.

## Capability contract

Registered in `QModelPlanParser.registeredCapabilities` as `"ui.click_element": ("ui",
.level2UserApproval)`. Parameters (via `QModelActionSchema.parameters`):

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search, matched against `NSRunningApplication.localizedName`/`bundleIdentifier`. |
| `role` | yes | The AX role to match (e.g. `AXButton`). |
| `identifier` | one of `identifier`/`title` | Matched against the element's custom `AXIdentifier` attribute (exact match). |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`, falling back to `AXDescription` when title is empty (see below). |

A step supplying neither `identifier` nor `title` — or supplying raw coordinates instead — fails
closed with `AX_MISSING_MATCH_CRITERIA` at execution time; there is no coordinate parameter in the
schema at all. A model attempting to self-declare a risk level other than the registered Level 2
is rejected by the same anti-downgrade check every other capability already gets
(`QModelPlanParser.parse`).

## Why `AXIdentifier`, and why title falls back to description

Empirical probing of a real, running Calculator.app (raw `AXUIElementCreateApplication` /
`AXUIElementCopyAttributeValue` calls against the live app) found:

- `kAXTitleAttribute` is **empty** on every stock digit/operator button.
- `kAXDescriptionAttribute` is populated and human-readable (`"Seven"`, `"All Clear"`, …).
- A custom, raw-string attribute `"AXIdentifier"` (no `kAX...` Swift constant exists for it) is
  populated and stable (`"Seven"`, `"AllClear"`, …) — the same attribute Pace's own
  `PaceAXTargeter` inspects for other purposes.
- `kAXValueAttribute` is empty for these controls — unusable for before/after diffing.

`QBridgeAccessibility`'s matching (`QBridgeAdapters.swift`) therefore treats `identifier` as the
preferred, most reliable key, and falls back from title to description exactly the way Pace's
existing AX code already does, rather than inventing a second convention.

## AX resolution & observation binding

A fresh, narrowly-scoped, Q-owned bounded tree walker (`QBridgeAccessibility.clickElement` /
`observeElement` in `QBridgeAdapters.swift`) — it does not reuse or extend Pace's own
coordinate-anchored `PaceAXTargeter` / `PaceAXScreenReader`, which serve a structurally different
(hit-test-by-point) pipeline.

Traversal is bounded on every axis: max depth 12, max 3,000 visited nodes, and a 1.5s wall-clock
budget, matching more than five matches short-circuits the walk. Every AX call is synchronous,
blocking IPC, so the whole resolve/verify/press sequence runs inside `Task.detached`, mirroring
`QBridgeVision`'s existing pattern for the same reason (this module defaults to MainActor
isolation).

Per the mission's observation-binding requirement, before any press:

1. The bounded walk resolves the AX tree and finds candidate matches (role + identifier/title).
2. Zero matches → `AX_NO_MATCHING_ELEMENT`. More than one → `AX_AMBIGUOUS_TARGET` (never guesses).
3. The single match's identity/state is captured as a `QAXElementSnapshot` (role, identifier,
   title-or-description, enabled) at search time.
4. The *same* `AXUIElement` reference is re-read immediately before dispatch. If it's no longer
   readable at all, or its snapshot no longer matches what was captured in step 3, the click is
   refused with `AX_STALE_TARGET` — the target changed (or vanished) between observation and
   dispatch, so it fails closed rather than pressing a target that may no longer be the one that
   was identified.
5. Disabled elements (`kAXEnabledAttribute == false`) fail with `AX_TARGET_DISABLED`.
6. Only then is `AXUIElementPerformAction(element, kAXPressAction)` invoked. `.actionUnsupported`
   → `AX_ACTION_UNSUPPORTED`; any other non-success code → `AX_PRESS_FAILED`.

Every failure mode is a deterministic `QAXInteractionError` (mirrors `QScreenCaptureError`'s
pattern), caught in `QExecutionService.executeClickElement` and converted into a non-throwing
`QActionResult(success: false, error: <code>)`. Nothing here ever falls back to coordinates or a
CGEvent click, and nothing fabricates a result.

## Testing limitation: the live observation-binding race

Step 4 above is checked, but the search (step 1–3) and the re-verify (step 4) happen back-to-back
inside one synchronous `Task.detached` closure with no `await` between them — that's intentional
(a smaller window between observation and dispatch is itself part of the safety property). It also
means a *genuine* race — the target mutating in the few microseconds between those two reads —
cannot be triggered deterministically through the public API without adding an artificial delay
seam to production code purely for testing, which was deliberately not done (out of scope, and
itself a small safety regression). `QSemanticClickTests` instead unit-tests the exact comparison
primitive the guard relies on (`QAXElementSnapshot` equality) directly and deterministically, and
documents this limitation here rather than fabricating a flaky race test.

## Approval & authorization

`ui.click_element` carries no special-cased authorization path — it flows through the same
`QResourceGuard → QPermissionGate → QApprovalCoordinator → QPlanExecutor → QExecutionService`
pipeline as every other capability, unmodified. Being Level 2, `QPlanExecutor` halts the plan at
`.requireApproval` before any AX call is ever made — permission-layer tests (approval required,
deny, abandoned/cancelled approval, budget exhaustion) do not depend on Accessibility permission at
all, since they never reach the AX layer. Approval grants are single-use and bound to the exact
`QExecutionIdentity` (`taskId:planId:stepId:actionName`) of the step that requested them — an
approval for one click can never authorize a different click, and the same grant can never be
consumed twice (existing `QApprovalCoordinator` invariants, unmodified).

## Execution → verification: a successful press is not goal success

`QExecutionService.executeClickElement` returns the pre-click `QAXElementSnapshot` via
`QActionResult.outputData` (`preClickIdentifier`, `preClickTitleOrDescription`, `preClickEnabled`).
`QPlanExecutor.determineVerificationStrategy` reconstructs a `QVerificationStrategy
.axElementStateChanged` from the step's own arguments plus that snapshot, and
`QActionVerifier.verify` re-resolves the *same* semantic target after the press and diffs it
against the pre-click snapshot:

- If the target is no longer uniquely resolvable by the same criteria (0 or 2+ matches now) —
  common for a control whose own identity changes as a direct result of being pressed — that
  counts as an observed state change: `.verified`.
- If the target still resolves and its snapshot is byte-for-byte identical to the pre-click one —
  nothing observably changed — the strategy returns `.failed`, and the *step* (and therefore the
  task) fails, even though the AX press itself returned success. `QVerificationOutcome` has only
  `.verified`/`.failed` (no third "uncertain" case); "preserve uncertainty" maps to `.failed`.

This is exercised for real: `QSemanticClickTests` wires one test button to change its own AX
identifier when pressed (completes, evidence shows the change) and a second, inert button that
does nothing when pressed (the press succeeds, but the task fails — proving dispatch success is
never conflated with goal success).

## Idempotency & crash recovery

`ui.click_element` gets no dedicated observation-first recovery branch in
`QTaskRecoveryManager` — it relies on the same default fail-closed-to-pending behavior every
unrecognized/non-special-cased tool already gets (mirrors `app.quit`, which has the identical
default). An uncertain in-flight click is never marked complete on a guess; it resets to `pending`
for exactly one safe re-execution, which itself goes through the full observation-binding /
re-verify sequence above before ever pressing anything.

## Taint, provenance, and redaction

AX observations are untrusted external state exactly like screen OCR content, but this capability
never turns them into trusted model instructions — the model only ever supplies the *target
criteria* (application/role/identifier/title) up front; the executor resolves and verifies
everything else itself, and a model-supplied identifier/title can only ever narrow a search, never
grant execution authority on its own. `QDurablePlanStepSnapshot`'s unconditional
`QSecretRedactor.redact` backstop (added Phase 2G, applies to `resultSummary`/`verifiedEvidence`
for every tool, not just perception-tagged ones) covers this capability's evidence strings
automatically — no new redaction gate was needed. In practice the surfaced strings are limited to
role/identifier/title-or-description (never `kAXValueAttribute`, which is deliberately never
read), so the exposure surface for this capability is inherently narrow — a text field's typed
*value* is never inspected, only its label/role.

## macOS Accessibility (AX) TCC behavior

Mirrors Phase 2G's Screen Recording finding for `QBridgeScreenCapture`: `AXIsProcessTrusted()` is a
read-only status check (never triggers a system prompt, never requests access), and every
AX-dependent test branches on its live value rather than assuming either state. Empirically, on
this development machine, the isolated `scripts/test-pace.sh` XCTest runner **is** AX-trusted
(unlike the Screen Recording case, where it was denied) — all 18 tests in `QSemanticClickTests`,
including the real self-window fixtures and the Calculator E2E, ran for real rather than
no-opping. This can differ on another machine or CI runner; every gated test documents and
tolerates the untrusted case by no-opping rather than fabricating a pass, so the suite stays green
either way.

## Excluded capabilities (explicitly out of scope for this phase)

Coordinate-based clicking, CGEvent fallback, keyboard typing/text entry/key presses, browser
automation, filesystem mutation, sending messages, purchases/payments, destructive actions,
security-setting changes, arbitrary shell execution, and any new network/cloud dependency. None of
these were added; `ui.click_element` is the only new capability introduced in this phase.

## Known limitations

- Matching is exact-string (role + identifier, or role + title-or-description) — no fuzzy/partial
  matching, by design (deterministic matching only; ambiguity fails closed rather than picking the
  "best" match).
- The observation-binding re-verify covers the gap between resolution and dispatch within a single
  call; it does not (and structurally cannot, without an artificial delay) protect against a
  mutation that lands in the sub-millisecond window between the two reads themselves — see the
  testing-limitation section above.
- Traversal bounds (depth 12 / 3,000 nodes / 1.5s) are fixed constants, not currently
  model-configurable or budget-integrated beyond the existing per-step `QAgentBudget` bounds that
  already gate whether this step runs at all.

## Real macOS E2E smoke test

`QSemanticClickTests.realMacOSE2ESemanticClickOnCalculator` (gated on `AXIsProcessTrusted()`):
opens Calculator, primes it into the "Clear" state by pressing a digit via raw AX (test scaffolding
only, not the capability under test — the same empirically-confirmed real behavior that motivated
this design), then runs the full autonomous Q path — propose → validate → authorize → halt for
approval → approve → execute → observe → verify → goal-evaluate — against Calculator's real
Clear button, and confirms it reverted to "AllClear" afterward. No destructive control, no
coordinates, no CGEvent anywhere in the path. See also
`docs/operations/release-smoke-checklist.md` for the hardware smoke-test entry.
