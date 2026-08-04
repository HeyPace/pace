## Why

Pace's legacy screen-dependent agent loop waits a fixed 600 ms after every
action sequence, while click verification waits a separate fixed 200 ms before
checking AX state. Fast applications pay unnecessary latency and slow
applications still receive no state-based guarantee, so the first FastPath
slice should replace both timing guesses with one bounded observation contract.

## What Changes

- Add a reusable action-to-observation waiter that compares lightweight macOS
  Accessibility state against a pre-action baseline at a short polling cadence.
- Return immediately when a meaningful AX state change is observed; otherwise
  preserve the current 200 ms click-verification and 600 ms agent-loop bounds as
  conservative timeout fallbacks.
- Route click-candidate verification and legacy multi-step loop settling through
  the same waiter.
- Keep ScreenCaptureKit streaming, pixel-frame wakeups, transactional typed
  outcomes, input locking, and MCP session reuse out of this first slice.
- Add deterministic unit coverage for immediate changes, delayed changes,
  timeout, and cancellation without controlling the live desktop.

## Capabilities

### New Capabilities

- `action-state-observation`: Bounded state-driven settling between a local
  action and the next verification or screen-dependent planner step.

### Modified Capabilities

None.

## Impact

- Runtime: `PaceActionExecutor+Mouse.swift` and
  `CompanionManager+AgentLoop.swift` replace fixed sleeps with the shared waiter.
- New source: a small observation policy/waiter beside the action executor.
- Tests: focused XCTest coverage for the pure observation policy and async
  waiter using injected state and sleep seams.
- Documentation: `docs/development/key-files.md` receives the required new-file
  entry; the FastPath architecture article remains the long-term design.
- Dependencies and deployment: no new dependency, network path, entitlement,
  migration, production configuration, or release action.
