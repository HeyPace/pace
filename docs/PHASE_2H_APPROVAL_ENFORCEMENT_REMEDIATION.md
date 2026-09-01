# Q × PACE — Phase 2H: PaceActionExecutor Approval Enforcement Remediation

**This is a security remediation for Pace's own (non-Q) action-execution pipeline.**
No new Q capability was added, no capability level was changed, `QPermissionGate`
and `QApprovalCoordinator` were not touched, and `ui.click_element` / any new
computer-use capability was **not** implemented. Phase 2H's own real
capability-implementation milestone remains unstarted.

## 1. Confirmed finding

Phase 2H discovery reported a possible gap: `.requireApproval` decisions from
`QActionAuthorizationBridge.preflightAuthorize` might reach execution without
being blocked. This remediation re-traced the complete real execution path
before changing anything, per the mission's explicit instruction not to trust
the discovery report without verification.

**Reproduced: yes.** `PaceActionExecutor+EntryPoint.swift`'s
`executeSingleAction` called `QActionAuthorizationBridge.preflightAuthorize`
and correctly blocked on `case .deny` — but had **no `case .requireApproval`
branch at all**. Every action Q's `QActionAuthorizationBridge
.mapActionToQMetadata` classifies as Level 2/3 fell straight through to
`dispatchSingleAction`, and the resulting audit record then labeled the
outcome `authorizationResult: decision.isAllowed ? "allow" : "approved"` —
hardcoding "approved" for a decision nobody had actually approved.

## 2. Tracing the complete path (before assuming the fix)

1. **Where authorization is evaluated**: `QActionAuthorizationBridge
   .preflightAuthorize(action:)`, called once per action inside
   `executeSingleAction`. It runs `QResourceGuard` for `.finder` paths, then
   `QPermissionGate.shared.evaluate(request:)`.
2. **Where `.requireApproval` is produced**: `QPermissionGate.evaluate`'s
   existing Level 2/3 policy branch (unchanged by this remediation) — for
   EVERY action Q classifies Level 2/3, on EVERY call, since `QPermissionGate`
   is stateless and has no notion of "already approved."
3. **Where the result was consumed**: only the `.deny` case, in
   `executeSingleAction`. `.requireApproval` and `.allow` were handled
   identically — both fell through to dispatch.
4. **Could execution continue before approval?** Yes, confirmed, for every
   Level 2/3 action — this was the bug.
5. **Scope**: **Pace-native actions only.** This pipeline
   (`PaceActionExecutor`/`PaceParsedAction`) is entirely separate from Q's own
   `QModelPlanParser`/`QPlanExecutor`/`QCoreRuntime` pipeline. Q-native
   actions (`app.quit`, `system.clipboard.write`, Phase 2E/2F) go through
   `QPlanExecutor`'s own step-B halt/`QApprovalCoordinator`/resume logic,
   which was independently verified correct in Phase 2E/2F and is
   **completely unaffected** — confirmed by this remediation's full
   regression pass (§9).
6. **Did any caller already rely on the current (buggy) behavior?** This is
   the finding that reshaped the fix (§3): Pace's product design already,
   deliberately, and *documented* (`docs/architecture/systems.md`) auto-permits
   a specific, narrow set of actions without a popup — "Routine local actions
   such as click, scroll, window snap, app/URL open, media, volume,
   brightness, clipboard read, and undo can execute without the popup."
   Making `.requireApproval` unconditionally block would have broken this
   intentional, already-shipped behavior — exactly the "disabling the entire
   action system" failure mode the mission explicitly forbids "fixing" the
   issue by causing.
7. **Existing tests proving approval enforcement?** None — no test exercised
   the `.requireApproval` path at all before this remediation; only `.deny`
   had coverage (`QActionAuthorizerTests`).

## 3. Why the fix is narrower than "block on `.requireApproval`"

Cross-referencing Q's classification (`QActionAuthorizationBridge
.mapActionToQMetadata`) against Pace's own documented "routine, no popup"
list found that **click, double-click, click-candidates, and open-URL are
explicitly, intentionally exempt** — this is real, shipped, documented product
design, not an oversight. But **keyboard input — `.type`, `.setTextValue`,
`.editSelectedText`, `.pressKey` — appears nowhere in that documented list**.
Unlike a click (which lands on a specific, described, already-grounded
target), a keystroke or typed string is indistinguishable at the action-type
level from typing into a password field, a send box, or a payment form. This
is the confirmed, narrow, actionable gap: **keyboard-input actions executed
with zero human approval, and this was never a documented or intentional
carve-out** — unlike click/openURL/etc., which correctly remain untouched.

## 4. The fix

Two changes, reusing existing mechanisms only:

**`PaceActionApproval.swift`** — `PaceActionApprovalPolicy
.requiresExplicitApproval` (the private per-action classifier feeding the
REAL, already-working, blocking `NSAlert`-based plan-level gate,
`requestUserApprovalForActionPlan`) now returns `true` for `.type`,
`.setTextValue`, `.editSelectedText`, and `.pressKey`, alongside the actions
it already covered (`.composeMail`, `.createNote`, `.downloadFile`, etc.).
Click/scroll/openURL/etc. are unchanged. This is the primary fix — it routes
keyboard input through the same real, tested, blocking approval mechanism
that already correctly protects mail/notes/calendar/etc. today.

**`PaceActionExecutor+EntryPoint.swift`** — `executeActionPlan`/
`executeSingleAction` gained a new, required (no default) `approvalAlreadyObtained:
Bool` parameter. `executeSingleAction` now has a real `case .requireApproval`
branch: when `actionsAreEnabled` (real execution, not dry-run simulation) and
`!approvalAlreadyObtained`, the action is refused — a blocked observation is
returned, an honest `authorizationResult: "blocked_no_approval"` audit record
is written, and `dispatchSingleAction` is never reached. This is a
defense-in-depth **backstop**: even if `requiresExplicitApproval` and
`mapActionToQMetadata` ever drift apart again in the future (a new action
added to one list but not the other — the exact class of mistake that
produced this finding), this code-level check still fails closed rather than
silently trusting the list stays in sync forever. Every one of the 7
production call sites (`CompanionManager+AgentLoop.swift` ×5,
`+PostureWatch.swift` ×1, `+TrustSurfacesRuntime.swift` ×1) was individually
traced and passes an explicit, justified value — see §6.

The audit label was also fixed: `authorizationResult` for a
`.requireApproval` decision that legitimately proceeds (because
`approvalAlreadyObtained` is true) is now `"plan_level_approval_or_policy_exempt"`
— honest about what actually happened — instead of the previous, false,
unconditional `"approved"`.

## 5. Why the backstop is gated on `actionsAreEnabled`

Dry-run mode (`actionsAreEnabled == false`) never causes a real side effect —
every dispatch handler (`typeText`, `openApplication`, etc.) independently
checks `actionsAreEnabled` before doing anything mutating, producing a "Would
do X" simulated observation instead. Gating this remediation's block on
`actionsAreEnabled` too means simulated dry-run observations (used by
`PaceActionExecutorDryRunTests` to verify per-action-type summary text) are
never intercepted by an approval concern that has no real-world consequence
to protect against. This mirrors, rather than invents, the executor's
existing mutation-gating pattern.

## 6. Every call site, traced individually

| Call site | `approvalAlreadyObtained` | Justification |
| --- | --- | --- |
| `CompanionManager+AgentLoop.swift:879` (fast path) | `true` | Reached only inside `requestUserApprovalForActionPlan(...)`'s `true` branch — real approval (or no approval needed) just happened. |
| `CompanionManager+AgentLoop.swift:2197`/`2203` (streaming-mail / main branches) | `true` | Same real gate, same `if` block. |
| `CompanionManager+AgentLoop.swift:443` (`resolveClickTargetClarification`) | `true` | The user just made an explicit, real-time choice (selecting this specific clarification option); `.clickCandidates` is also documented-exempt regardless. |
| `CompanionManager+AgentLoop.swift:483` (`dismissPendingClickTargetClarificationWithAutoClick`) | `true` | Same reasoning — dismissal falling back to the top-candidate auto-click; `.clickCandidates` is documented-exempt regardless. |
| `CompanionManager+PostureWatch.swift:260` (`smokeSimulateClickAllFailObservation`) | `true` | Smoke-test-only synthetic simulation, gated behind `PACE_ENABLE_SMOKE_HOOKS`, never reachable from a real voice turn; `.clickCandidates` is documented-exempt regardless. |
| `CompanionManager+TrustSurfacesRuntime.swift:75` (`triggerUndoLastMutation`) | `true` | The user just physically tapped the undo button — the explicit human decision for this specific, single, Level 1 action. |

Two of these (`resolveClickTargetClarification`,
`dismissPendingClickTargetClarificationWithAutoClick`) dispatch `.clickCandidates`
directly, bypassing `requestUserApprovalForActionPlan` entirely — a separate,
pre-existing pattern from the confirmed keyboard-input gap. This is
documented here as a deliberate, narrowly-scoped judgment call (§10 Known
Limitations), not silently assumed safe: `.clickCandidates` is Level 2 in
Q's classification but documented-exempt product policy either way, and the
user's clarification selection is itself a real-time, explicit signal for
that one specific click.

## 7. Security property — before / after

**Before**: `.requireApproval` was indistinguishable from `.allow` at the
`executeSingleAction` level — no fall-through detection, no backstop, and a
factually false "approved" audit label for keyboard-input actions that were
never approved by anyone.

**After**: keyboard-input actions require a real, blocking, human decision
(`requestUserApprovalForActionPlan`'s `NSAlert`) before they can dispatch.
`.deny` continues to unconditionally block, regardless of any approval flag —
verified by test 3 (§9). Every action that proceeds past a `.requireApproval`
classification now does so only because `approvalAlreadyObtained` was
explicitly, individually justified at its specific call site (§6), not by
default or by omission.

## 8. Approval lifecycle & race/concurrency behavior

Pace's approval mechanism (`requestUserApprovalForActionPlan` +
`approvalAlreadyObtained`) is architecturally simpler than Q's
`QApprovalCoordinator` — a **synchronous, blocking, per-call boolean**, not a
persisted, resumable, single-use grant:

- **No persisted authorization**: `approvalAlreadyObtained` is a plain
  function parameter, computed fresh in the same call stack as
  `NSAlert.runModal()`'s return, and never written to `UserDefaults`,
  `QDurableTaskStore`, or any other store. It cannot outlive the call that
  produced it.
- **No expiry concept applies**: because it's never persisted, there is no
  window during which it could go stale — it either accompanies the
  dispatch call it was computed for, or it doesn't exist at all. "Expired
  approval" and "invalid/stale approval," as `QApprovalCoordinator` defines
  them (a grant surviving past its intended lifetime), have no analog here
  to test — there is nothing that persists long enough to expire.
- **No cross-call leakage**: each `executeActionPlan` call requires its own
  explicit argument; nothing is cached or shared between calls. Proven by
  test 6 (an approved call immediately followed by an unapproved call for a
  different action correctly still blocks) and test 7 (repeated calls each
  require their own explicit declaration).
- **No duplicate-execution risk from a single approval**: there is no stored
  grant to reuse or exhaust twice — every dispatch requires its own,
  separately-supplied boolean. This is a materially different (simpler,
  narrower) guarantee than Q's single-use `QExecutionIdentity`-bound grants,
  and is documented as such rather than claimed to be equivalent.
- **No replan/retry bypass**: retrying an unapproved plan produces the
  identical, correctly-blocked outcome every time (test 8) — there is no
  counter, timer, or cached state a retry could exploit.
- **Cancellation while awaiting**: covered by the existing, unmodified
  `PaceActionExecutorDryRunTests.cancelledPlanDoesNotDispatchActions` —
  `Task.isCancelled` is checked before `executeSingleAction` is ever
  invoked, so a cancelled task never reaches this remediation's gate.
- **Approval for A cannot authorize B**: since the argument is per-call, not
  a named/identified grant, this property holds trivially — there is no
  mechanism by which an approval "for" one action could be mistaken for
  approval of a different one, because nothing is looked up by identity at
  all; the caller supplies a fresh, explicit value for exactly the plan it's
  about to dispatch.

## 9. Tests

`leanring-buddyTests/PaceActionApprovalEnforcementTests.swift` (10 tests) —
uses the real `PaceActionExecutor`, `QActionAuthorizationBridge`, and
`QAuditLogger`, no mocking of the authorization layer:

| # | Proves |
| --- | --- |
| 1 | A keyboard action Q classifies as requiring approval is blocked with no approval obtained. |
| 1b | The whole keyboard-input family (`pressKey`, `setTextValue`) is blocked, not just `type`. |
| 2 | With approval obtained, the action reaches dispatch (proven via the dry-run "no observation on success" signal). |
| 3 | A hard `.deny` (ResourceGuard) blocks regardless of `approvalAlreadyObtained`. |
| 6 | No cross-call state leakage between an approved and an unapproved call. |
| 7 | Repeated calls each require their own explicit approval; nothing is cached. |
| 8 | Retrying a blocked plan doesn't bypass the block. |
| 10 | A documented-exempt action (click) still works without `approvalAlreadyObtained: true`. |
| 10b | `PaceActionApprovalPolicy.requiresExplicitApproval` reflects the fix precisely — keyboard input `true`, click/openURL still `false`. |
| — | The audit trail is honest — a genuinely `.allow` action is labeled `"allow"`, never the old false `"approved"`. |

Existing `PaceActionApprovalTests.routineLocalActionsSuppressInitialSpokenFeedback`
needed updating — its example plan included `.pressKey`, relying on the old
"routine" classification `suppressesInitialSpokenFeedback` shares with
`requiresExplicitApproval`. Since a blocking approval dialog now precedes
keyboard input, suppressing the initial spoken acknowledgment for it would be
incoherent (every other approval-required action — mail, notes, calendar —
already doesn't suppress it either); the test was updated to remove
`.pressKey` from its "routine" example and a new test,
`keyboardInputActionsRequiringApprovalDoNotSuppressInitialSpokenFeedback`,
explicitly locks in the new, correct, consistent behavior.

## 10. Recovery / persistence

**Not persisted, by design and by construction** (see §8) — there is nothing
to recover across a restart, because nothing survives past the synchronous
call that produced it. This remediation does not introduce any new
persistence, and per the mission's explicit instruction, none was added.

## 11. Known limitations

- The two click-clarification call sites (§6) bypass
  `requestUserApprovalForActionPlan` entirely and are treated as pre-approved
  based on the user's real-time clarification selection — a deliberate,
  documented judgment call, not an oversight, but a narrower human-in-the-loop
  signal than a full "Allow Once" dialog. Revisiting this is a legitimate
  follow-up, not something this remediation resolved definitively.
- `approvalAlreadyObtained` is a **plan-level**, not per-action, granularity —
  matching Pace's existing `requestUserApprovalForActionPlan` design (one
  alert per plan, not per action within it). This is coarser than Q's
  per-step `QExecutionIdentity` binding and was a deliberate choice to reuse
  Pace's existing approval-identity model rather than introduce a new one
  (per the mission's explicit "do not merge Pace authorization and Q
  authorization into a new ambiguous authority layer").
- Click, double-click, click-candidates, and open-URL remain intentionally
  exempt from any per-action approval step — this remediation preserved that
  documented product decision rather than second-guessing it.
