# Q × PACE — Phase 2F: Approval UI Bridge

## 1. Objective

Phase 2E built a complete, tested approval-resolution API
(`QApprovalCoordinator`, `QCoreRuntime.resolveApproval`, `QAgent.approve`) —
but explicitly documented that no live Pace UI called it. Discovery for
Phase 2F (no formal spec existed in the repository; see the discovery report
in conversation history) found something more specific than "no UI exists":
Pace already has a **live, rendering** Allow/Deny affordance for exactly this
purpose — `CompanionManager+QAgent.swift`, dated "Phase 2A.2" (i.e. it
predates Phase 2B) — but it was wired to a pre-2E, dead-end mechanism that
could flip HUD text and mint a standing capability grant, and could never
actually resume or complete a halted task, because `QCoreRuntime.submitIntent`
(since Phase 2C/2D) returns immediately on a permission halt rather than
blocking in place for a UI callback.

Phase 2F's objective: **make that existing HUD affordance actually resolve a
real Phase 2E approval**, end to end, without introducing a parallel
authorization mechanism, a new UI surface, or any change to Phase 2D/2E
security invariants.

## 2. Scope

**In scope (the proposed minimal scope from discovery):**

1. Give the UI layer enough data to reconstruct and display a real
   `QApprovalRequest` (action, target, risk level, expected effect,
   reversibility, execution identity) from what it already observes.
2. Replace the stale standing-grant mechanism in `resolveQPermissionApproval`
   with a real call into `QAgent.approve` / `QCoreRuntime.resolveApproval`.
3. Distinct Level 2 vs. Level 3 HUD copy.
4. Explicit denial and expiry handling in the HUD path.
5. Dedicated tests proving an Allow click through the real HUD path actually
   resumes and completes a Level 2 and a Level 3 task end to end — something
   no test in the repository could previously prove, because the wiring
   didn't exist to prove it against.

**Out of scope, explicitly (unchanged from Phase 2E's exclusions, still
applicable):** no AX click/type capabilities, no new Level 2/3 tools, no
merging `QActionAuthorizer`'s (Pace's own action executor) authorization path
with `QModelPlanParser`'s, no new filesystem/network capabilities. Also out of
scope for this phase specifically: a dedicated modal/alert-style approval
surface (Pace's `PaceActionApproval` NSAlert pattern) — the existing
notch/panel clarification-chip HUD was reused instead, since it already
renders live and already had the Allow/Deny affordance; a stronger,
purpose-built visual treatment for Level 3 (distinct color/icon, not just
copy) is a design decision explicitly left for a follow-up with human visual
review, not attempted here.

## 3. Architecture

```
QPlanExecutor halts on Level 2/3           (Phase 2E, unchanged)
  → QApprovalCoordinator.recordPending(req)
  → observer.stepDidTransition / observer.planDidUpdate(plan)   (existing 2A.2 wiring)
        │
        ▼
CompanionManager.planDidUpdate(plan:)                            (existing, unchanged)
  → activeQPlanSnapshot = QRuntimeUISnapshot.from(plan: plan)
        │
        ▼
QRuntimeUISnapshot.pendingApproval  ◄── NEW (Phase 2F)
  reconstructs the exact QApprovalRequest QPlanExecutor recorded, using the
  same deterministic execution-identity-derived id (QApprovalRequest
  .deterministicId) — safe for display AND for resolution; the reconstruction
  itself carries no authority, QApprovalCoordinator's live record is always
  re-validated when resolution is attempted
        │
        ▼
CompanionManager.applyPlanSnapshotToHUD / agentDidTransition       MODIFIED
  → PaceTurnHUDState.qApprovalRequest(request)   ◄── NEW risk-aware HUD copy
    (falls back to the old plain clarification only if pendingApproval isn't
    reconstructable yet — never a hard failure)
        │
        ▼  user clicks "Allow" / "Deny" (PaceTurnHUDView, unchanged)
        │
        ▼
CompanionManager.resolveClarification(option:)                    MODIFIED
  → denial: sets HUD feedback synchronously (nothing is executing, no wait)
  → both outcomes: Task { await resolveQPermissionApproval(approved:) }
        │
        ▼
CompanionManager.resolveQPermissionApproval(approved:)             REWRITTEN
  → await QAgent.shared.approve(taskId:, approvalId: request.id, decision:,
                                 observer: self)
  → intermediate execute/verify HUD states arrive via the SAME
    QAgentStateObserver/QPlanExecutionObserver callbacks executeQAgentTurn
    already relies on — no new observation plumbing needed
  → final result: chatSession.appendCompletedTurn + TTS speak, exactly
    mirroring executeQAgentTurn's existing shape
        │
        ▼
QAgent.approve → QCoreRuntime.resolveApproval → QApprovalCoordinator.resolve
  (Phase 2E, completely unchanged — this is the first caller to actually
  reach it from a live UI path)
```

### New/changed components

| Component | Change |
| --- | --- |
| `QRuntimeStepSnapshot` | +`riskLevelValue: QCapabilityLevel`, +`targetResources: [String]` (both defaulted, additive — existing test constructors unaffected). |
| `QRuntimeUISnapshot` | +`pendingApproval: QApprovalRequest?` (computed, not stored — derived from `planState`/`steps` at read time, so both existing construction sites — `.from(plan:)` and `stepDidTransition`'s manual rebuild — stay correct without needing to separately maintain it). |
| `PaceTurnHUDState` | +`qApprovalRequest(_:)` — risk-aware Allow/Deny clarification copy (⚠️ prefix + explicit reversibility note for Level 3; plainer copy for Level 2). Reuses the existing `.needsClarification` status and `PaceTurnHUDView` rendering — no new SwiftUI view code. |
| `CompanionManager+QAgent.swift` | `agentDidTransition`'s `.requestingPermission` case and `applyPlanSnapshotToHUD`'s `.waitingForPermission` case both now prefer `activeQPlanSnapshot?.pendingApproval` for the rich rendering, falling back to the old plain copy only if it isn't available. `resolveQPermissionApproval` is now `async`, throws away the standing-grant hack, and actually calls `QAgent.shared.approve(...)`. |
| `CompanionManager+AgentLoop.swift` | `resolveClarification`'s Q-permission branch sets immediate synchronous HUD feedback for denial (no execution to wait for), then dispatches the real resolution via `Task { await resolveQPermissionApproval(...) }` for both outcomes. |

No changes were made to `QCoreRuntime`, `QApprovalCoordinator`, `QPermissionGate`, `QPlanExecutor`, `QExecutionService`, or any other Phase 2D/2E security-layer file — this phase is purely a UI-facing bridge onto the existing, unmodified 2E API.

## 4. Why the standing-grant replacement matters

The pre-2F `resolveQPermissionApproval` minted a `QCapability` grant scoped to
`toolFamily`/`toolName` with `maxRiskLevel: .level2UserApproval`, a 5-minute
TTL, and `.global` scope. That grant would have authorized **any** future
Level ≤2 call to that tool name, not just the one specific action the user
actually saw and clicked Allow on — the exact "blanket approval" pattern
Phase 2E's approval architecture was built specifically to avoid ("Approval
for action A cannot authorize action B", "No blanket approve-all mechanism").
It also silently capped everything at Level 2, so a Level 3 `app.quit`
request routed through this code path would have been granted a Level-2-only
capability that `QPermissionGate` would then correctly refuse to match against
a Level 3 request — meaning the old path was not just architecturally wrong,
it was *also* non-functional for the one new capability (`app.quit`) Phase 2E
added. And because nothing ever called back into a live, still-running task
(there wasn't one), the grant was frequently created after the only task that
could have used it had already terminated.

The Phase 2F replacement mints nothing itself — it hands the *exact* approval
id off to `QApprovalCoordinator` (via `QCoreRuntime.resolveApproval`), which
is the only thing that ever mints a single-use, execution-identity-bound
grant, exactly as Phase 2E designed.

## 5. Security invariants

All Phase 2D/2E invariants are unchanged and were re-verified against this
phase's changes:

- **Model output remains untrusted; no parallel authorization system.** The
  UI layer never grants anything itself — `resolveQPermissionApproval` only
  ever calls `QAgent.approve`, which is the same tested Phase 2E entry point.
  `QRuntimeUISnapshot.pendingApproval`'s reconstruction is presentation data
  only; it is explicitly documented (in-code and here) as carrying no
  authority — `QApprovalCoordinator`'s own record is what actually gets
  consulted when resolution is attempted, regardless of what the UI
  reconstructed or displayed.
- **Execution identity / single-use / no cross-action authorization** — proven
  end to end by `QApprovalHUDTests` tests 1 and 3-5: the reconstructed id
  always matches the deterministic id `QApprovalCoordinator` actually holds
  (test 1), and approving through the real HUD path resumes and completes
  only the exact step it was requested for (tests 3, 5).
- **No persisted authorization / fresh authorization on recovery** — untouched;
  this phase adds no new persistence anywhere. `QApprovalCoordinator` remains
  the sole, unpersisted source of truth for whether an approval is genuinely
  live.
- **Fail-closed** — `resolveQPermissionApproval` fails closed (a `.failed`
  HUD state, no execution) when there is no reconstructable pending approval
  (test 7) and when the approval has expired (test 6) — reactively, on the
  next resolution attempt, exactly matching Phase 2E's existing `.expired`/
  `.notFound` handling in `QCoreRuntime.resolveApproval`. No new proactive
  expiry-driven UI timer was added (see §7).
- **Budget, resource guard, permission gate, goal verification, no-replan-
  around-security-block, local-only execution** — none of these paths were
  touched; they are exercised exactly as Phase 2E left them, since
  `QAgent.approve` is the same unmodified 2E code.

## 6. UX behavior

- **Denial feels instant.** Nothing is executing when the user denies, so
  `resolveClarification` sets the "denied" HUD state synchronously before
  dispatching the real (async) resolution — the durable task and
  `QApprovalCoordinator` still record the actual denial in the background,
  but the user doesn't wait on a round trip for something that isn't running.
- **Approval shows a "resuming" state immediately**, then the existing
  `QAgentStateObserver` callbacks (`.executing`, `.verifying`, `.completed`/
  `.blocked`) drive the HUD exactly as they already do for a normal (non-
  approval) turn — no new intermediate-state plumbing was needed.
- **An ignored approval simply stays `.awaitingApproval`** in durable state
  indefinitely (or until its 5-minute `expiresAt` is reached and a later
  resolution attempt fails closed) — consistent with how Pace's other
  clarification types (`pendingIntentClarification`,
  `pendingClickTargetClarification`) already behave: single active slot, no
  queue, resolved only by the next matching user action.
- **Level 2 vs. Level 3 are visually distinguished** by copy only (a ⚠️
  prefix and an explicit reversibility statement for Level 3) — see §2 for
  why a stronger visual (color/icon) treatment was deliberately not attempted
  here.

## 7. Known limitations

- **Single active approval slot.** Like Pace's other clarification types,
  `activeQPlanSnapshot` is a single `@Published` property — if a second,
  unrelated Q turn runs before the user resolves a pending approval,
  `activeQPlanSnapshot` is overwritten and the original approval becomes
  unreachable from the HUD (though it remains genuinely resolvable via
  `QAgent.approve(taskId:approvalId:...)` directly, since the coordinator and
  durable state still hold it — only the *UI's reference* to it is lost).
  This is an existing, accepted limitation of Pace's clarification model in
  general, not something newly introduced here, and Pace's turn dispatch is
  largely serial in practice (per `docs/architecture/systems.md`'s "Pace
  deliberately does not run complete turns in parallel").
- **No proactive expiry countdown.** Expiry is handled reactively (on the
  next resolve attempt), not with a UI timer that counts down or auto-fails
  a stale approval. Building that was judged bigger than "smallest safe
  extension" and wasn't part of the proposed scope.
- **Text-only Level 2/3 distinction.** No new color, icon, or layout — see §2
  and §6. A stronger visual treatment needs human visual review (per this
  project's own UI-change convention) and is left for a follow-up.
- **No dedicated approval modal.** The existing notch/panel clarification-chip
  surface was reused rather than building something closer to Pace's own
  `PaceActionApproval` NSAlert pattern (used for Pace's *separate* action
  executor). Whether a consequential Level 3 action deserves a heavier,
  harder-to-fat-finger surface than an inline HUD chip is an open product
  question, not a technical constraint.

## 8. Test matrix

`leanring-buddyTests/QApprovalHUDTests.swift`, 8 tests, all real (no
mocked `QApprovalCoordinator`/`QDurableTaskStore` — see the file for how
`QDurableTaskStore.shared`'s process-wide in-memory instance and the global
`QApprovalCoordinator.shared`/`QRuntimeBootstrap.shared` singletons are used
safely and deterministically without controlling what a real local model
would plan):

| Test | Proves |
| --- | --- |
| 1 | `pendingApproval`'s reconstructed id matches the deterministic id derived independently from the same execution identity. |
| 1b | `pendingApproval` is `nil` when the plan isn't actually halted. |
| 2 | Level 2 vs. Level 3 HUD copy is genuinely distinct. |
| 3 | **Approving a real Level 2 clipboard write through `resolveQPermissionApproval` actually writes it** and marks the durable task completed — the thing that was structurally impossible to prove before this phase. |
| 4 | Denying through `resolveClarification` (the actual production entry point the HUD button calls) never executes, and the durable task ends up failed. |
| 5 | Real macOS E2E — approving a Level 3 `app.quit` through the HUD path actually terminates the target app (uses "Stickies," not Calculator or Dictionary, to avoid contending with other suites — see the 2E doc's identical reasoning). |
| 6 | An expired approval fails closed even if the user eventually clicks Allow, and never executes. |
| 7 | No crash / fails closed cleanly when there's nothing pending to resolve. |

## 9. Validation

```
Dedicated Phase 2F tests:  8/8 passed (QApprovalHUDTests), 0 failed
Existing UI observation:   QPlanUIObservationTests unchanged and still
                            passing (6/6) — including the pre-existing
                            denial-fails-closed test, unmodified
Full regression:           see conversation record for the exact count run
                            after this phase's changes
```

Run via `scripts/test-pace.sh` (isolated DerivedData) per `CLAUDE.md` — never
raw `xcodebuild` against the interactive app's DerivedData path.
