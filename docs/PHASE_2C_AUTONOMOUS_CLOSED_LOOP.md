# Q × PACE — Phase 2C: Autonomous Closed-Loop Agent

## 1. Overview & Objective

Phase 2C elevates Q from a sequential plan executor into an **Autonomous Closed-Loop Local Agent** on macOS.

Prior to Phase 2C, Q executed plans in a forward-only pipeline:
$$\text{Intent} \to \text{Plan} \to \text{Execute} \to \text{Verify} \to \text{Summary}$$

Under Phase 2C, Q operates as an **empirical, self-evaluating, closed-loop agent**:
$$\text{Intent} \to \text{Understand} \to \text{Plan} \to \text{Execute} \to \text{Observe} \to \text{Verify} \to \text{Evaluate Goal} \to \text{Replan (if needed)} \to \text{Re-Execute} \to \text{Ground Summary} \to \text{Complete}$$

Q **never** assumes that successful action execution equals goal satisfaction. Untrusted model claims are strictly discarded as proof; only verifiable runtime observations and verifier evidence satisfy the user's objective.

---

## 2. Core Architecture

```
                                  ┌────────────────────────┐
                                  │      User Intent       │
                                  └───────────┬────────────┘
                                              │
                                              ▼
                                  ┌────────────────────────┐
                                  │ QMemoryStore Retrieval │
                                  └───────────┬────────────┘
                                              │
                                              ▼
                                  ┌────────────────────────┐
                                  │  QModelRouter Planner  │
                                  │  (Apple / MLX / LM St) │
                                  └───────────┬────────────┘
                                              │
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ QCoreRuntime Autonomous Execution Loop                                                │
│                                                                                        │
│   ┌───────────────────────┐       ┌──────────────────────┐      ┌──────────────────┐   │
│   │    QResourceGuard     │ ───►  │    QPermissionGate   │ ──► │ QExecutionService│   │
│   │ (Denylist/Path Check) │       │ (Consent/Risk Gating)│      │  (Safe Mac Ops)  │   │
│   └───────────────────────┘       └──────────────────────┘      └────────┬─────────┘   │
│                                                                          │             │
│                                                                          ▼             │
│   ┌───────────────────────┐       ┌──────────────────────┐      ┌──────────────────┐   │
│   │    QGoalEvaluator     │ ◄───  │    QActionVerifier   │ ◄─── │ Runtime Evidence │   │
│   │(Evidence-First Satisf)│       │ (Empirical Verifier) │      │  & Observations  │   │
│   └───────────┬───────────┘       └──────────────────────┘      └──────────────────┘   │
│               │                                                                        │
│               ├─────────────► [State: Satisfied] ──► Grounded Summary ──► Complete     │
│               │                                                                        │
│               ├─────────────► [State: Blocked]   ──► Fail Closed (No Replan) ──► Halt  │
│               │                                                                        │
│               └─────────────► [State: Unsatisfied / Partially Satisfied]               │
│                                           │                                            │
│                                           ▼                                            │
│                               ┌───────────────────────┐                                │
│                               │   QReplanController   │                                │
│                               │(Loop Check/Max 2 Attr)│                                │
│                               └───────────┬───────────┘                                │
│                                           │                                            │
│                     ┌─────────────────────┴──────────────────────┐                     │
│                     ▼                                            ▼                     │
│           [Decision: Allow]                             [Decision: Denied]             │
│                     │                                            │                     │
│                     ▼                                            ▼                     │
│          Generate Corrective Plan                           Halt Task                  │
│             (Failure Context)                                                          │
│                     │                                                                  │
│                     └───────────────────────► Re-Execute                               │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Key Components Implemented

### 3.1. `QGoalEvaluator.swift`
- **Strongly Typed Codable Contract**:
  - `QGoalEvaluationState`: `.satisfied`, `.partiallySatisfied`, `.unsatisfied`, `.blocked`, `.unknown`.
  - `QGoalEvaluation`: Carries empirical satisfaction status, numerical confidence ($0.0 \dots 1.0$), list of satisfied conditions, missing conditions, collected verified evidence, and task provenance.
- **Evidence-First Invariant**:
  - Operates **exclusively** on verified action results (`verifiedEvidence`), verifier observations, and empirical system state.
  - Model self-reports, hallucinated claims, and plain text claims contain **zero authority** and are rejected as evidence.
  - Tainted/untrusted context preserves `.untrusted` provenance across evaluation boundaries.

### 3.2. `QReplanController.swift`
- **Replan Lifecycle & Decision Engine**:
  - `QReplanDecision`: `.allow(QReplanRequest)`, `.denied(reason: String)`.
  - Strictly enforces **maximum 2 replan attempts** per user task.
  - **Loop Detection**: Compares new proposed plans against prior iteration history. Identical plans or repeated tool execution failures trigger immediate replan denial.
  - **Security Barrier**: When a plan is `.blocked` by `QResourceGuard` or `QPermissionGate`, replanning is unconditionally prohibited (fail-closed).

### 3.3. `QCoreRuntime.swift` (Closed-Loop Autonomous Engine)
- Orchestrates the full closed loop.
- Records audit entries for every state transition:
  - `plan.created`
  - `plan.execution.started`
  - `step.verified`
  - `goal.evaluated`
  - `goal.satisfied`
  - `goal.unsatisfied`
  - `replan.requested`
  - `replan.created`
  - `replan.limit_reached`
  - `agent.completed`
  - `agent.blocked`
  - `agent.failed`
- Commits verified outcomes and learnings to `QMemoryStore` upon terminal completion.

### 3.4. `QRuntimeUISnapshot.swift` & Pace HUD State
- Exposes real-time replan telemetry to the Pace notch and panel UI:
  - `replanAttempt: Int` (e.g. 1 of 2)
  - `maxReplanAttempts: Int` (2)
  - `isReplanning: Bool`
  - `goalEvaluationState: String` (`satisfied`, `partially_satisfied`, `re-evaluating`, etc.)

---

## 4. Test Verification & Metrics

### Full Repository Regression Run
```
Total Suites: 188
Total Tests:  1,872
Passed:       1,872 (100%)
Failed:       0
Skipped:      0
Regressions:  0
```

### Dedicated Phase 2C Suites Added
1. `QGoalEvaluatorTests.swift` (7 / 7 passing)
   - Evaluates single/multi-step empirical condition satisfaction.
   - Rejects unverified model claims.
   - Validates resource guard and permission block fail-closed semantics.
   - Ensures tainted provenance propagation.
2. `QReplanControllerTests.swift` (8 / 8 passing)
   - Enforces max 2 replan attempts limit.
   - Detects and halts duplicate plan loops.
   - Halts on repeated step action failures.
   - Prohibits replanning around security blocks.
   - Resets counters cleanly across distinct tasks.
3. `QClosedLoopAgentTests.swift` (8 / 8 passing)
   - Comprehensive multi-step closed-loop integration.
   - Real macOS E2E execution: Intent $\to$ plan $\to$ safe Calculator launch $\to$ empirical verification $\to$ goal evaluation $\to$ grounded natural language response.

---

## 5. Security Invariants Preserved

1. **Air-Gapped Local Intelligence**: Primary Apple Foundation Models / Local MLX / LM Studio on `127.0.0.1`. Zero cloud fallback.
2. **Untrusted Model Data**: Local model outputs remain untrusted text. No capability can be executed without passing `QResourceGuard` and `QPermissionGate`.
3. **No Replanning Around Security**: Security rejections cannot be bypassed or retried by the model.
4. **Finite Autonomous Bounds**: Maximum 2 replan attempts with automated loop detection prevent non-terminating loops.
