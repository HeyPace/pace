# Phase 2N — Semantic Application Activation (`ui.activate_application`)

Q's seventh controlled UI-adjacent capability, and the first that is **Level 1** (no user-approval
gate) rather than Level 2/3 like every semantic AX capability from Phase 2H onward. It activates
one already-running application by its exact `localizedName`, deliberately without touching
Accessibility (`AXUIElement`/`AXIsProcessTrusted()`) at all — the entire point of this capability
is that it works without that permission grant.

## Capability contract

Registered as `"ui.activate_application": ("app", .level1SafeLocalAction)` in
`QModelPlanParser.registeredCapabilities`. Parameters:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The exact `localizedName` of an already-running application. |

No `role`, `identifier`, `title`, coordinate, or window-targeting parameter exists.

## Level 1, not Level 2 — and never gated by a special-cased bypass

Application-level activation is real-but-modest external state change (the same "safe local
action" band `ui.open_app` already occupies), not a per-element UI mutation. This is enforced the
same way every other level is enforced: `QPermissionGate.evaluate` already routes Level 0/1
straight to `.allow` under its default local-safety policy (see `QPermissionGate.swift`); Level
2/3 is the only branch that ever constructs a `QApprovalRequest` and calls
`QApprovalCoordinator.shared.recordPending`. Registering this capability's risk level correctly is
therefore sufficient on its own — no code path was added, modified, or special-cased to make this
tool skip approval; it simply never reaches the branch that would create one.

## Exact resolution contract — a hard security boundary

Resolution operates against `NSWorkspace.shared.runningApplications`, matched by
`candidate.localizedName == requestedName` — plain `==`, never a normalized, trimmed, lowercased,
or otherwise transformed comparison value. Rules, all fail-closed:

- **Missing/empty/whitespace-only name**: rejected before any resolution attempt
  (`applicationName missing`). The whitespace check only decides *whether* to reject; the value
  used for the actual `==` comparison is never trimmed or otherwise normalized.
- **Substring/prefix/suffix/case-insensitive/fuzzy match**: never accepted. There is no fallback
  matching tier — a request that isn't an exact match is treated identically to zero matches.
- **Zero exact matches**: `APP_NOT_RUNNING`.
- **More than one exact match**: `APP_AMBIGUOUS_MATCH` — refused rather than arbitrarily picking
  the first result.

## Activation mechanism

`NSRunningApplication.activate()` only (the modern, no-options API; `activate(options:)` is
deprecated on this project's macOS 26 deployment target) — never `AXUIElement`, `CGEvent`,
keyboard/mouse simulation, coordinates, `AppleScript`/`osascript`, or shell automation.

## Idempotency

The resolved target's **`processIdentifier`** — not `localizedName` — is compared against
`NSWorkspace.shared.frontmostApplication?.processIdentifier` to decide idempotency. If they match,
no `activate()` call is made at all; the result carries `changeKind: "alreadyFrontmost"`. A pid
comparison (rather than a name comparison) is deliberate: it is the stable identity that
distinguishes the exact resolved process instance from a different, later process that might
happen to share the same `localizedName` — the same TOCTOU-resistant reasoning behind using pid
for the closed-loop verification identity below.

## Verification: `.processIsFrontmost`

A new `QVerificationStrategy.processIsFrontmost(applicationName:targetProcessIdentifier:)`
re-queries `NSWorkspace.shared.frontmostApplication` independently of whatever
`executeActivateApplication`'s own bounded poll already observed, and compares its
`processIdentifier` against the resolved target's pid. A successful `activate()` call — or an
idempotent already-frontmost no-op — is **never** itself treated as proof of success; this
independent re-observation is the sole source of truth. No frontmost application observable at all
is `.failed`, never assumed benign.

## Recovery: observation-first, no blind replay

`QTaskRecoveryManager.resolveUncertainStep` gained a `case "ui.activate_application"` branch
mirroring `ui.open_app`'s existing pattern exactly: re-checks whether the requested target is
already frontmost (exact-name match, exactly one candidate, matched by pid) before ever
considering a replay. If yes, the step is marked completed via real observation. If no — ambiguous,
absent, or simply not yet frontmost — the step falls through to `verified = false` and is reset to
`pending`; a resumed execution mints a **fresh** `QExecutionIdentity` (via `QPlanExecutor`, the
same as every other capability) and re-attempts through the normal policy path exactly once. No
persisted state is ever treated as implicit authorization.

## Provenance & privacy

Registered under `toolFamily: "app"` — the same family `ui.open_app`/`app.quit` already use, no
taint-propagation or trust-upgrade behavior attached. The application name is not a secret and is
never masked (per `QSensitiveArgumentPolicy`, this tool has no entry). Audit records and durable
plan snapshots carry only: the application name, the resolved `processIdentifier`/
`bundleIdentifier`, and `changeKind` (`"alreadyFrontmost"` or `"activated"`) — no window titles, no
AX tree content, no unrelated process internals.

## Files touched

- `QModelPlanSchema.swift` — capability registry entry.
- `QExecutionService.swift` — `executeActivateApplication` dispatch + implementation.
- `QActionVerification.swift` — `.processIsFrontmost` strategy + verification.
- `QPlanExecutor.swift` — verification-strategy reconstruction branch.
- `QTaskRecoveryManager.swift` — observation-first recovery branch.
- `leanring-buddyTests/QSemanticApplicationActivationTests.swift` — new focused suite (15 tests).

`QPermissionGate`, `QApprovalCoordinator`, `QResourceGuard`, `QExecutionIdentity`, `QAgentBudget`,
`QGoalEvaluator`, `QReplanController`, and `QProvenance` are all unmodified.
`QBridgeAdapters.swift` was **not** touched — this capability needs no Accessibility bridge at all.

## Real macOS E2E — result and an honest environment finding

`QSemanticApplicationActivationTests.realMacOSE2EActivateDistinctApplication` launches a real,
distinct TextEdit process in the background, drives the full `ui.activate_application` plan
through `QCoreRuntime.submitIntent`, and asserts `NSWorkspace.shared.frontmostApplication` becomes
the target — deliberately **not** gated behind `AXIsProcessTrusted()`, since this capability needs
no Accessibility permission.

In the isolated-DerivedData test-runner environment used to validate this phase,
`NSWorkspace.shared.frontmostApplication` was found permanently pinned to `"loginwindow"`
(pid 408) — i.e. this session has no interactive WindowServer/login session at all. Under that
condition, **no process can ever be observed becoming frontmost**, regardless of how correct the
implementation is: `NSRunningApplication.activate()` cannot change window-server frontmost status
without an active login session. This is a genuine environment limitation of the isolated test
runner, not a defect in `ui.activate_application` — and it is, in fact, a positive confirmation
that the fail-closed design works correctly: when the real transition cannot happen, the
independent `.processIsFrontmost` verification step correctly refuses to report success (observed
directly during implementation: a self-targeted activation attempt was correctly marked
unverified and triggered the normal replan path rather than a fabricated completion).

The E2E test detects this exact condition (`frontmostApplication.localizedName == "loginwindow"`)
and returns early rather than asserting a transition this session cannot structurally produce —
the same honest, silent-fallback convention every prior AX-gated phase in this codebase already
uses for `AXIsProcessTrusted() == false`. **Real, interactive-hardware validation (a normal logged-in
GUI session) remains an outstanding requirement** before this capability's frontmost-transition
behavior should be considered hardware-validated, exactly analogous to Phase 2K/2L/2M's own
outstanding AX-trust hardware-validation notes.

Every deterministic, non-session-dependent test — registration, input validation, exact-match
resolution, substring/fuzzy rejection, not-running rejection, ambiguous-match rejection (via a real
`createsNewApplicationInstance` duplicate-process launch), approval-never-required, recovery
(both branches), verification independence (mismatched-pid fails), provenance, budget enforcement,
and safe-evidence audit/durable-state content — ran for real and passed in this environment.

## Known limitations

1. Exact `localizedName` matching only — no fuzzy/substring/prefix/suffix/case-insensitive
   fallback, and no bundle-identifier input contract in this phase.
2. Duplicate `localizedName`s among running processes are rejected as ambiguous, never guessed.
3. Application-level activation only — no window-level targeting, title, or ID exists.
4. Level 1 activation carries an inherent UX/focus-stealing tradeoff: any already-running
   application can be raised to frontmost without a per-action approval prompt (by design — the
   same tradeoff `ui.open_app` already accepts for launching).
5. `ui.open_app`'s `activates = false` semantics are unchanged — that is a separate, still-open
   architectural gap, not addressed by this phase.
6. Real, interactive-hardware validation of the frontmost-transition path (a normal logged-in GUI
   session, not an isolated/headless test runner) remains outstanding — see the E2E section above.
7. The resolved `NSRunningApplication` reference (not just its pid) is held from resolution
   through the `activate()` call itself with no intervening `await`, so that call cannot target a
   different process than the one resolved. The independent closed-loop verification step,
   however, re-queries `NSWorkspace.shared.frontmostApplication` up to ~1s later and compares by
   pid alone — the same inherent OS-level pid-reuse window every pid-based identity check in this
   codebase (e.g. `app.quit`'s verification) already accepts, not a new gap introduced here.
