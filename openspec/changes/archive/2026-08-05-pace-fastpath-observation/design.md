## Context

See `proposal.md` for motivation and
`specs/action-state-observation/spec.md` for the behavior contract. The two
current callers observe the same application state but encode independent fixed
waits: candidate clicks sleep 200 ms before capturing `PaceClickStateSnapshot`,
and the legacy screen-dependent loop sleeps 600 ms before its next capture.

The first slice must remain small, avoid new dependencies and entitlements, and
use `scripts/test-pace.sh` rather than direct terminal `xcodebuild` so the
interactive app's TCC grants remain untouched.

## Goals / Non-Goals

**Goals:**

- Return early when lightweight AX-visible application state changes.
- Preserve the current 200 ms and 600 ms waits as maximum fallback bounds.
- Give click verification and loop settling one cancellation-aware contract.
- Keep the timing policy deterministic and testable without controlling the
  live desktop.

**Non-Goals:**

- ScreenCaptureKit frame streaming or pixel-driven wakeups.
- Application-specific completion postconditions.
- Typed action success/failure and fail-fast transaction semantics.
- Input locking, MCP process reuse, or latency-reporting UI.

## Decisions

### Use a generic bounded waiter with injected seams

Add `PaceActionObservationWaiter` with a generic `State: Equatable`, a
configuration containing poll interval and maximum poll count, and typed
`changed`, `timedOut`, and `cancelled` outcomes. Callers provide a current-state
closure. Tests provide deterministic integer states and a no-delay or
cancellation-throwing sleep closure.

This keeps AppKit and AX access at the call sites and lets the behavior be tested
without constructing `AXUIElement` values. A click-specific class would
duplicate the same policy when the loop adopts it.

### Check once immediately, then poll

The waiter compares current state before its first sleep. Many AX actions update
synchronously; an initial sleep would preserve unnecessary latency. If state is
unchanged, the waiter sleeps once per configured interval and checks again until
the maximum poll count is reached.

The click configuration uses 25 ms × 8 polls, retaining a 200 ms maximum. The
agent-loop configuration uses 40 ms × 15 polls, retaining a 600 ms maximum.

### Reuse a lightweight `PaceClickStateSnapshot` for high-cadence polls

The existing snapshot covers frontmost application, visible-window count,
focused-window title, focused element, and an up-to-600-node focused AX-tree
fingerprint. The waiter uses a lightweight capture that omits the tree walk so
25–40 ms polling does not create repeated main-thread tree traversal.

Candidate clicks retain one full-tree baseline before dispatch and one full-tree
comparison if the lightweight waiter reaches its 200 ms timeout. This preserves
the existing ability to notice controls that mutate without changing focus or
window metadata while allowing cheap focus/window changes to return early.

Pixel-only applications will usually time out and retain current behavior. A
future session-scoped capture change can add a composite AX + visual state
without changing the waiter's generic contract.

### Capture the loop baseline immediately before execution

The agent loop stores its baseline after approval and cursor-flight settling,
immediately before calling the executor. It invokes the waiter only when the
loop will continue to another screen-dependent planner step. Single-shot
structured output and terminal steps do not pay an observation wait.

### Treat cancellation as a first-class outcome

The default sleep propagates `CancellationError`, which the waiter converts to
`.cancelled`. The agent loop exits promptly. Click verification stops trying
additional candidates and returns a cancelled failure observation so a new turn
cannot inherit further click attempts from the cancelled one. The action-plan
executor also checks cancellation around every dispatch so the same cancelled
turn cannot continue with later actions after observation ends.

## Risks / Trade-offs

- **AX-invisible pixel changes still take the full fallback** → This slice is
  deliberately no-regression for canvas, game, and remote-desktop surfaces;
  ScreenCaptureKit observation remains the next measured extension.
- **Incidental AX churn may return early** → The next agent iteration still
  takes a fresh screenshot and re-grounds; this waiter is a cue to observe, not
  proof that an application-level operation completed.
- **Frequent AX snapshots may add work** → Polling is bounded to 8 or 15 checks
  and runs only while an action is settling. Focused tests and later benchmarks
  will determine whether the cadence needs adjustment.
- **Cancellation can occur after an input event landed** → The waiter never
  replays actions. It stops observation and lets the cancelled turn unwind.

## Migration Plan

1. Add the waiter and deterministic unit tests without changing call sites.
2. Replace click verification's fixed sleep with the click configuration.
3. Capture a pre-execution baseline and replace the loop's fixed sleep with the
   agent-loop configuration.
4. Run the focused isolated test target, Swift parse checks if compilation is
   blocked, documentation validation, and `git diff --check`.

Rollback is local: restore the two fixed sleeps and remove the unused waiter.
There is no persisted data, configuration migration, or compatibility change.
