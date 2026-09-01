# Q × PACE — Phase 2D: Architecture Audit & Reliability Strategy

## 1. Current State Model & Ownership Audit

### 1.1. Where State Currently Lives
- **Task Lifecycle State**: Resides in `QCoreRuntime.tasks` dictionary in memory (`[String: QTask]`). State is lost when the host process terminates.
- **Plan State**: Resides in the local stack variable `currentPlan` / `executedPlan` (`QPlan`) within `QCoreRuntime.submitIntent()`.
- **Step Execution State**: Contained inside `executedPlan.steps` (`[QPlanStep]`) managed transiently by `QPlanExecutor.execute()`.
- **Replan Counters**: In-memory instance variable inside `QReplanController(maxReplans: 2)` instantiated per `submitIntent()` call.
- **Goal Evaluation State**: Evaluated ephemerally by `QGoalEvaluator.shared.evaluate()`, returned as a transient `QGoalEvaluation` struct.
- **Memory Persistence**: Persisted in SQLite WAL (`QSQLiteMemoryStore`) storing semantic/episodic memory records (`QMemoryRecord`) and task completion summaries.
- **Audit Events**: Persisted in `QAuditLogger.shared` ring buffer and printed to os_log / standard output.

---

## 2. Identified Vulnerabilities & Recovery Gaps

1. **Volatile Task & Plan Lifecycles**:
   - If the application crashes during step execution (e.g. while launching an app, reading files, or executing system queries), the entire task context, plan, and progress are lost.
   - Upon restart, the agent has no record of the in-flight task or its execution state.

2. **Uncertainty & Idempotency Blindspots**:
   - If a process terminates immediately after dispatching a tool action (e.g. `ui.open_app`) but before recording step completion or verification, a simple resume could trigger duplicate physical execution.
   - There is currently no `QExecutionIdentity` tying specific step attempts to verifiable empirical system states.

3. **Model Availability & Failure Handling**:
   - If local inference fails mid-run (timeout, schema violation, backend unreachable), `QCoreRuntime` fails the task immediately without creating a recoverable or paused checkpoint.

4. **Absence of Explicit Resource & Step Budgets**:
   - While replans are bounded to 2 attempts, there is no overall step budget, wall-clock timeout budget, or model call attempt budget across the lifetime of a long-running task.

5. **Untrusted Persisted State Security Boundary**:
   - Any persisted state loaded from disk after a crash must be treated as untrusted input. Prior authorization decisions cannot be blindly trusted; capabilities must be validated against `QPermissionGate` and `QResourceGuard`.

---

## 3. Proposed Phase 2D Architecture

```
                 ┌──────────────────────────────────────────────────┐
                 │                 User / Recovery                  │
                 └─────────────────────────┬────────────────────────┘
                                           │
                                           ▼
                 ┌──────────────────────────────────────────────────┐
                 │              QTaskRecoveryManager                │
                 │  - Discovers Incomplete Tasks in SQLite          │
                 │  - Validates Schema & Re-runs Security Checks    │
                 └─────────────────────────┬────────────────────────┘
                                           │
                                           ▼
                 ┌──────────────────────────────────────────────────┐
                 │       Observation-First Re-Verification          │
                 │  - Inspects Empirical System State               │
                 │  - Checks QExecutionIdentity & Verifier Evidence │
                 │  - Resolves Uncertain Step (Complete vs Pending) │
                 └─────────────────────────┬────────────────────────┘
                                           │
                       ┌───────────────────┴───────────────────┐
                       ▼                                       ▼
             [Step State Verified]                    [Step Not Verified]
                       │                                       │
                       ▼                                       ▼
            Resume Remaining Plan                   Execute Once Safely
                       │                                       │
                       └───────────────────┬───────────────────┘
                                           │
                                           ▼
                 ┌──────────────────────────────────────────────────┐
                 │          QCoreRuntime (Budgeted Loop)            │
                 │  - Updates QDurableTaskStore on Each Transition  │
                 │  - Enforces QAgentBudget (Steps/Time/Replans)    │
                 │  - Appends Immutable QTaskLifecycleEvents        │
                 └──────────────────────────────────────────────────┘
```

---

## 4. Migration & Integration Strategy

1. **`QDurableTaskState` & `QDurablePlanSnapshot`**:
   - Pure Codable/Sendable data models containing strictly sanitized, non-executable representations of task and plan progress.
2. **`QDurableTaskStore`**:
   - SQLite-backed durable task and event store using WAL journaling (`q_tasks`, `q_plans`, `q_lifecycle_events`).
3. **`QExecutionIdentity` & Idempotency**:
   - Uniquely identifies execution attempts (`taskId`, `planId`, `stepId`, `attemptId`) and inspects runtime state before executing.
4. **`QTaskRecoveryManager`**:
   - Recovers interrupted tasks safely, validates state transitions, enforces fail-closed guarantees on corrupted data, and performs observation-first re-verification.
5. **`QAgentBudget`**:
   - Enforces max steps (default 20), max duration (300s), max replans (2), max model attempts (3), and max consecutive failures (3).
6. **Air-Gap & Zero Cloud Invariants**:
   - Maintained throughout all recovery and execution paths.
