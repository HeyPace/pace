# Q × PACE — Phase 2E: Controlled Real-World Actions

## 1. Objective

Phase 2D left Q's own plannable tool vocabulary capped at Level 0 (read-only) and
Level 1 (safe local action) — `QModelPlanParser.registeredCapabilities` had no
Level 2 or Level 3 entries, and `QPlanExecutor`/`QCoreRuntime` had no way to
resolve a `.requireApproval` halt and resume the step it was blocking. A plan
that reached a Level 2/3 step would halt in `.awaitingApproval` and dead-end —
there was no code path that could ever move it forward again.

Phase 2E closes that gap: it introduces the **first two controlled, mutating
capabilities** above Level 1, and the **approval-resolution architecture**
required to safely execute them — without weakening any Phase 2D invariant and
without giving the model itself execution authority. The model still only
*proposes* structured intent; every mutating action still passes through
`QResourceGuard → QPermissionGate → (approval) → QPlanExecutor →
QExecutionService`, exactly as the existing pipeline already required.

## 2. Scope

**In scope — minimal, auditable capability set:**

- `system.clipboard.write` (**Level 2** — reversible local action): overwrites
  the system pasteboard with model-supplied text. Reversible by definition
  (the user can copy anything else); no filesystem or app-state mutation.
- `app.quit` (**Level 3** — mutating action with meaningful user impact):
  terminates a running application via `NSRunningApplication.terminate()`.
  Chosen specifically because it is easy to verify empirically (absence from
  `NSWorkspace.runningApplications`), safely re-executable (quitting an
  already-quit app is a no-op success), and demonstrable end-to-end with a
  harmless target app — exactly the "safely demonstrable" bar the mission set.

**Out of scope, explicitly:**

- No AX-tree click/type/keypress capabilities. Pace's own `PaceActionExecutor`
  already covers those at Level 2/3 via `QActionAuthorizer`, in a completely
  separate pipeline from Q's own `QModelPlanParser`-driven plans; wiring the
  two together is a materially larger change than "the smallest safe
  extension" and was not attempted.
- No live Pace notch/panel UI for presenting a Q-level approval to the user.
  The approval architecture (§4) is fully implemented and tested at the
  runtime/API layer (`QCoreRuntime.resolveApproval`, `QAgent.approve`); a
  visual approval surface is future work and is *not* claimed as built.
- No new filesystem-mutating (`fs.move_sandbox`, `fs.delete_sandbox`, etc.) or
  network-mutating capabilities. The two capabilities above are the complete
  Phase 2E set.

## 3. Architecture

```
Model output (untrusted)
        │
        ▼
QModelPlanParser.parse
  — capability allowlist (QModelPlanParser.registeredCapabilities)
  — risk level is ALWAYS the registered value for that tool; a declared
    risk that does not exactly match is rejected outright (closes a
    downgrade path — see §5)
        │
        ▼
QPlanExecutor.execute (per step)
  — QResourceGuard path validation
  — QExecutionIdentity(taskId, planId, stepId, actionName, targetResources)
  — QApprovalCoordinator.consumeGrantIfPresent(fingerprint) — fast path when
    resuming after a real prior approval for THIS exact step
  — else QToolAuthorizationRequest → QPermissionGate.evaluate
        ├─ .allow            → execute (Level 0/1, unchanged)
        ├─ .deny             → blocked, no replan (unchanged)
        └─ .requireApproval  → QApprovalCoordinator.recordPending(req)
                                 halt, return plan in .waitingForPermission
        │
        ▼ (only after a human approves)
QCoreRuntime.resolveApproval(taskId, approvalId, decision)
  — task must currently be .awaitingApproval in durable storage
  — QApprovalCoordinator.resolve(approvalId, decision)
      .approved → single-use grant minted, keyed by step fingerprint
      .denied   → task fails, no grant minted
  — on grant: reloads the persisted plan snapshot and resumes it through the
    SAME QPlanExecutor.execute() path, which now finds and consumes the grant
        │
        ▼
QExecutionService (system.clipboard.write / app.quit dispatch)
        │
        ▼
QActionVerifier — empirical, closed-loop verification
  (.customCheck clipboard read-back / .appNotRunning NSWorkspace check)
        │
        ▼
QGoalEvaluator — evidence-first goal satisfaction (unchanged)
```

### New/changed components

| Component | Change |
| --- | --- |
| `QApprovalCoordinator` (new) | In-memory-only approval ledger. Tracks pending `QApprovalRequest`s and single-use, execution-identity-bound grants. Deliberately never persisted — see §6. |
| `QApprovalRequest` | Gained `expectedEffect`, `isReversible`, `executionIdentity`, and a **deterministic id** derived from the execution identity's fingerprint (`QApprovalRequest.deterministicId`) so two independent constructions of "the same approval" (the original halt vs. a reconstruction on resume) always resolve to the same id. |
| `QToolAuthorizationRequest` | Gained an optional `executionIdentity`, forwarded into any resulting `QApprovalRequest`. |
| `QCapabilityLevel` | Gained `isConsideredReversible` (Level 0-2 = true, Level 3+ = false) and `QCapabilityLevel.parse(_:)`, a strict string→level parser used to reject (not silently coerce) any risk string a model declares. |
| `QModelPlanParser.registeredCapabilities` | +`system.clipboard.write` (Level 2), +`app.quit` (Level 3). |
| `QDurablePlanSnapshot.validate` | Default capability allowlist now derives from `QModelPlanParser.registeredCapabilities.keys` instead of a second hand-maintained list, so it can never drift out of sync with what live planning is allowed to produce. |
| `QPlanExecutor` | Computes a `QExecutionIdentity` per step; checks `QApprovalCoordinator` for a one-time grant before falling through to `QPermissionGate.evaluate`; audits both the approval-required halt and the granted-resume execution. |
| `QExecutionService` | Dispatches `system.clipboard.write` (`NSPasteboard`) and `app.quit` (`NSRunningApplication.terminate()`, with a bounded ~1s poll for the process to actually leave `runningApplications` before returning, so the immediately-following verifier does not race normal app teardown). |
| `QActionVerification` | +`.appNotRunning(appName:)` strategy. |
| `QCoreRuntime` | +`resolveApproval(taskId:approvalId:decision:)`. `executeResumedPlan` (shared by crash recovery and approval resume) now (a) surfaces a fresh `.awaitingApproval` state if the resumed plan halts on *another* approval-gated step instead of silently failing, and (b) checks and records `QAgentBudget` — see §8. |
| `QAgent` | +`approve(taskId:approvalId:decision:)`, mirroring the existing `run`/`resume` pass-throughs. |

## 4. Approval model

Every `QApprovalRequest` produced by a real (non-recovery-placeholder) halt
exposes: `toolName` (action), `affectedResources` (target), `toolFamily` via
the tool name (capability), `riskLevel`, `reason`, `expectedEffect`,
`isReversible`, and `executionIdentity` — the full set the mission's
"APPROVAL ARCHITECTURE" section requires be visible before execution.

- **Deterministic, not random, ids.** `QApprovalRequest.id` is derived from
  `SHA256(executionIdentity.stepFingerprint)` when an execution identity is
  present. This is what lets `QCoreRuntime.resolveApproval` find "the same"
  approval a plan halted on, without needing to plumb a request object through
  the plan-state enums.
- **Bound to one exact attempt.** `QExecutionIdentity.stepFingerprint =
  "taskId:planId:stepId:actionName"`. A grant is minted only for that exact
  fingerprint and can only ever unblock that exact step — never a different
  action, a different step, or a different task (`QControlledActionsTests`
  test 6).
- **Single-use.** `QApprovalCoordinator.consumeGrantIfPresent` removes the
  grant on first successful consumption; a second attempt for the same
  fingerprint returns `false` (test 12).
- **No blanket approval.** There is no "approve all" API surface anywhere in
  this phase — only `resolve(approvalId:decision:)` for one specific,
  previously-recorded request id.
- **Deny is terminal.** `.denied` never mints a grant; the task fails
  immediately (test 15b).

## 5. Security invariants

All 17 invariants listed in the Phase 2E mission were checked against the
implementation; none required weakening Phase 2D. One genuine, newly-relevant
gap was found and fixed as part of *correctly* implementing capability/risk
classification (mission: "the execution authority must remain with ...
`QModelPlanParser` → capability allowlist → risk classification"):

- **Model-controlled risk downgrade (fixed).** Before Phase 2E,
  `QModelPlanParser.parse` let a model-declared `riskLevel` string silently
  *override* the tool's registered risk level for any level below 4 — harmless
  while every registered tool topped out at Level 1 (Level 0 vs. Level 1 both
  hit the same auto-allow policy branch), but a real approval-gate bypass the
  moment Level 2/3 tools existed (a model could declare `"level0"` for
  `app.quit` and the approval gate would never fire). Risk classification is
  now **strictly authoritative from the allowlist**: a declared risk that does
  not exactly match the tool's registered level — including any attempt to
  claim Level 4 — is rejected outright, not coerced (`QModelPlanParseError
  .unauthorizedRiskLevel`). Covered by `QControlledActionsTests` tests 1-3.

Everything else composed cleanly with existing Phase 2D machinery: Level 4 is
still hard-rejected at parse time and at `QDurablePlanSnapshot.validate`;
`QResourceGuard`/`QPermissionGate` remain the sole authorization path (no
parallel authorization system was introduced — `QApprovalCoordinator` is a
resolution ledger *for* `QPermissionGate`'s `.requireApproval` outcomes, not a
replacement for it); `QReplanController` already refuses to replan around a
`.blocked` plan state and required no change; `QAgentBudget` and
`QExecutionIdentity` are unchanged in shape and now apply to the resume path
too (§8).

## 6. Durability & recovery behavior

`QApprovalCoordinator` is **deliberately never persisted** to
`QDurableTaskStore`. This is not an oversight — it is how the mission's
durability requirement ("persisted approval is NOT equivalent to fresh
authorization") is satisfied *by construction* rather than by an extra
runtime check that could be forgotten or bypassed:

1. A crash/restart wipes every pending request and every grant.
2. On restart, `QDurableTaskState.lifecycleState == .awaitingApproval` is
   still there (that part *is* persisted, as history/evidence), but
   `QApprovalCoordinator` has no memory of ever having offered it.
3. `QCoreRuntime.resolveApproval` re-validates through the live coordinator on
   every call — it never trusts the durable `awaiting_approval` string as
   proof that a real approval will succeed. Calling it with an id the
   coordinator does not currently hold returns `.notFound` and the task fails
   closed (`QControlledActionsTests` test 8).
4. A task can only leave `.awaitingApproval` through `resolveApproval`, and
   only after `QApprovalCoordinator` itself confirms a live, non-expired,
   not-already-resolved request for that id.

`executeResumedPlan` (used by both plain crash recovery and Phase 2E's
approval resume) now also surfaces a *fresh* `.awaitingApproval` state if the
plan it resumes halts again on a (possibly different) approval-gated step,
instead of the pre-2E behavior of letting goal evaluation quietly turn an
unresolved wait into a generic failure.

## 7. Idempotency

Both new capabilities integrate with `QExecutionIdentity`:

- The one-time approval grant itself is fingerprint-scoped and single-use
  (§4), so approving a step cannot cause it to fire twice.
- `QTaskRecoveryManager.resolveUncertainStep` has no dedicated
  observation-first check for `app.quit` or `system.clipboard.write` (unlike
  `ui.open_app` / `fs.write_sandbox`) — it falls through to the existing
  conservative `default: verified = false` branch, which resets the step to
  `.pending` for exactly one safe re-execution rather than guessing it already
  happened (`QControlledActionsTests` tests 10-11). This is intentionally
  conservative and safe for both new tools: re-quitting an already-quit app is
  a documented no-op success (`executeAppQuit`), and re-writing the same
  clipboard text is harmless.

## 8. Budget interaction

`executeResumedPlan` previously recorded **zero** budget consumption for any
step it executed — crash-recovery resume and (the new) approval resume both
ran through it without ever calling `QAgentBudget.recordStepExecution` or
`evaluateBudget`. Phase 2E fixes this for both paths (not just the new
capabilities): `executeResumedPlan` now checks `evaluateBudget()` before
resuming (fails closed if already exhausted) and records step outcomes for
every step that reaches a terminal state during that resume, persisting the
updated budget back into `QDurableTaskState` on every branch. Verified by
`QControlledActionsTests` test 13 (an approved `system.clipboard.write`
measurably increases `executedStepsCount`).

**Known limitation:** because `submitIntent`'s per-iteration loop already
counts a step that merely reached `.waitingForPermission` (never actually
executed) as one "step execution" with `success: false`, a step that later
gets approved and genuinely executes is counted twice in total across the two
phases (once for the halt, once for the real execution). This is
conservative — it can only make the budget exhaust *earlier* than a perfectly
precise count would, never later — and was left as-is rather than reworking
`submitIntent`'s pre-existing per-step accounting loop, which is materially
wider surgery than "the smallest safe extension."

## 9. Goal verification

`QGoalEvaluator` required no changes. It already treats only `.completed`
steps with genuine `verifiedEvidence`/`summary` as evidence and only
`.completed` (not `.failed`) plan state as satisfiable — a failed `app.quit`
step (e.g. the app blocked termination) is never counted toward goal
satisfaction (`QControlledActionsTests` test 14).

## 10. Test matrix

All 17 scenarios required by the mission are covered in
`leanring-buddyTests/QControlledActionsTests.swift` (16 `@Test` functions —
items 10 and 11 share one test, as do items 4/5's authorization-path check and
the Level-2/Level-3 split across two dedicated tests):

| # | Scenario | Test |
| :-: | --- | --- |
| 1 | Unknown capability → rejected | `unknownCapabilityRejected` |
| 2 | Unknown/mismatched risk level → rejected | `mismatchedRiskLevelRejected` |
| 3 | Level 4 → rejected | `level4DeclarationRejected` |
| 4 | Level 2 action → authorization path enforced | `level2ActionRequiresAuthorization` |
| 5 | Level 3 action → approval required | `level3ActionRequiresApproval` |
| 6 | Approval for action A cannot authorize action B | `approvalDoesNotCrossAuthorizeAnotherAction` |
| 7 | Security denial cannot be bypassed by replanning | `securityDenialNeverReplanned` |
| 8 | Persisted approval does not silently re-authorize after recovery | `persistedApprovalNeverSelfAuthorizes` |
| 9 | Context taint survives recovery | `taintSurvivesRecoveryReconstruction` |
| 10-11 | Crash during action → observation before retry; uncertain state fails closed | `uncertainAppQuitStepFailsClosedToPending` |
| 12 | Execution identity prevents duplicate side effects | `executionIdentityGrantIsSingleUse` |
| 13 | Budget exhaustion / new actions consume budget | `approvedActionConsumesExecutionBudget` |
| 14 | Goal evaluation requires empirical evidence | `goalEvaluationRejectsUnverifiedQuit` |
| 15 | Full autonomous loop works with an approved action | `fullLoopCompletesAfterApproval`, `fullLoopHaltsAfterDenial` |
| 16 | Full regression remains green | validated via `scripts/test-pace.sh` — see §11 |
| 17 | Real macOS E2E, safe reversible action | `realMacOSE2EQuitAfterApproval` |

Test 17 targets **Dictionary.app**, not Calculator: several existing suites
(`QAgentE2ETests`, `QFirstRealRunTests`, `QClosedLoopAgentTests`, ...) open and
assert on real Calculator state, and Swift Testing can run suites
concurrently — quitting a shared app another suite depends on being open
caused two genuine, reproducible cross-suite failures during development
(`QAgentE2ETests.test6_uiActionOpenApp`,
`QFirstRealRunTests.testStep5_openCalculatorAndVerify`), which is why an
uncontended target app was chosen instead.

## 11. Validation gate — results

```
Dedicated Phase 2E tests:  16/16 passed (QControlledActionsTests), 0 failed
Full regression:           1915/1915 passed, 0 failed, 0 skipped
                            (run twice consecutively for stability; both green)
Build:                     scripts/prepare-release.sh — Release, arm64,
                            isolated DerivedData — BUILD SUCCEEDED, ad-hoc
                            signed, valid on disk, satisfies its Designated
                            Requirement
Security:                  see §5 — no invariant weakened; one pre-existing
                            downgrade path closed
Recovery:                  see §6, §7 — tests 8, 10-11
Idempotency:                see §7 — tests 10-11, 12
Persistence:                see §6 — QApprovalCoordinator deliberately
                            unpersisted; QDurablePlanSnapshot allowlist now
                            single-sourced from QModelPlanParser
Concurrency:                no new shared mutable state outside
                            QApprovalCoordinator's existing NSLock-guarded
                            singleton pattern (matches QPermissionGate,
                            QAuditLogger); full suite passed twice
                            consecutively under Swift Testing's default
                            parallel execution
Local-only:                 no new network dependency; both new capabilities
                            (NSPasteboard, NSRunningApplication.terminate)
                            are pure local macOS API calls
Working tree:                clean before/after each command; commit created
                            separately per repository workflow
```

Both regression runs and the dedicated suite were executed via
`scripts/test-pace.sh` (isolated DerivedData, per `CLAUDE.md` — never raw
`xcodebuild` against the interactive app's DerivedData path). The production
build was produced via `scripts/prepare-release.sh` (also isolated
DerivedData) rather than a raw `xcodebuild build` invocation, for the same
TCC-safety reason.

## 12. Known limitations

- No live Pace UI surfaces a Q-level Level 2/3 approval to the user yet —
  `QCoreRuntime.resolveApproval` / `QAgent.approve` are the complete,
  tested programmatic surface; a caller (CLI, test harness, or a future
  notch/panel surface) must invoke it explicitly.
- The budget double-count described in §8 remains; it is conservative
  (fails safe, never fails open) and documented rather than fixed, per
  "smallest safe extension."
- `QTaskRecoveryManager` has no dedicated observation-first check for the two
  new tools (§7) — this is intentionally conservative, not a gap: it defaults
  to the same safe "verify nothing, re-execute once" behavior every
  unrecognized action already gets.
- The two capabilities added here are deliberately the entire Level 2/3
  surface for this phase (§2) — no click/type/keypress, filesystem mutation,
  or network mutation capability was added to Q's own tool vocabulary.

## 13. Explicitly excluded capabilities

Per the mission's "do not automatically enable every Level 2/3 action" and
"minimal, auditable capability set" directives, the following were
deliberately **not** added in this phase, despite being plausible Level 2/3
candidates: `fs.move_sandbox` / `fs.delete_sandbox`, `input.click` /
`input.type` / `input.key` (Pace's own executor already covers these outside
Q's plan schema — see §2), `net.open_url`, `mail.compose`, `net.download`,
and any capability requiring new AX/CGEvent bridging.
