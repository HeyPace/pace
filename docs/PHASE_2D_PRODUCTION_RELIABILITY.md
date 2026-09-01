# Q × PACE — Phase 2D: Production-Grade Local Agent Reliability & Recovery

## 1. Executive Summary

Phase 2D transforms the Q local AI agent into a crash-resilient, production-grade autonomous agent. The execution lifecycle evolves from:

$$\text{Intent} \to \text{Plan} \to \text{Execute} \to \text{Verify} \to \text{Evaluate} \to \text{Replan}$$

into an end-to-end durable loop:

$$\text{Intent} \to \text{Durable Task} \to \text{Plan} \to \text{Execute} \to \text{Observe} \to \text{Verify} \to \text{Evaluate} \to \text{Replan} \to \text{Persist} \to \text{Recover} \to \text{Resume} \to \text{Complete}$$

Q is now guaranteed to survive:
1. **Application restart and crash** (mid-planning, mid-execution, or post-execution).
2. **Task interruption** and process termination.
3. **Execution, model, or verification failures** without lost audit trails or orphaned tasks.
4. **Duplicate events and replay attacks** through deterministic execution identity fingerprinting.
5. **Infinite loops / resource exhaustion** through fail-closed execution budgets.

All recovery mechanisms uphold the zero-cloud and security-first core invariants: **Persisted state is untrusted data**, **standing grants are suspended on tainted context**, **model outputs never become execution authority**, and **physical effects are never blindly repeated**.

---

## 2. Core Architecture & Components

```
┌────────────────────────────────────────────────────────────────────────┐
│                              Q Agent                                   │
│            submit(intent:)  ──►  resume(taskId:)                       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                           Q Core Runtime                               │
│  ┌────────────────────────┐              ┌──────────────────────────┐  │
│  │   QTaskRecoveryManager │              │       QAgentBudget       │  │
│  │ (Observation-First     │              │ (Step, Replan, Timeout,  │  │
│  │  State Reconstruction) │              │  Failure Limits)         │  │
│  └───────────┬────────────┘              └──────────────┬───────────┘  │
│              │                                          │              │
│              ▼                                          ▼              │
│  ┌────────────────────────┐              ┌──────────────────────────┐  │
│  │   QDurableTaskStore    │              │      QPlanExecutor       │  │
│  │   (SQLite WAL Engine)  │              │  (Idempotent Execution)  │  │
│  └───────────┬────────────┘              └──────────────┬───────────┘  │
│              │                                          │              │
│              ▼                                          ▼              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │   Security Perimeter (QPermissionGate + QResourceGuard)          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### A. Durable State Model (`QDurableTaskState`, `QDurablePlanSnapshot`, `QTaskLifecycleEvent`)
- **Schema-Versioned Task State**: Captures `taskId`, `sessionId`, `originalIntent`, `lifecycleState`, `currentPlanId`, `currentStepIndex`, `completedStepIds`, `failedStepIds`, `verificationEvidenceReferences`, and `budgetState`.
- **Serializable Plan Snapshots**: Encodes structured plan steps with explicit allowlisted tool capabilities (`allowedCapabilities`). Unrecognized or Level 4 blocked tools are rejected at decoding time.
- **Event-Sourced Task Timeline**: Persists immutable lifecycle events (`task.created`, `task.planned`, `step.started`, `step.completed`, `step.verified`, `replan.requested`, `task.completed`, `task.failed`, `security.blocked`).
- **No Live Handles**: Persisted state never contains closures, active process tokens, network handles, or authorization credentials.

### B. SQLite WAL Storage (`QDurableTaskStore`)
- High-performance, embedded SQLite storage with `WAL` (Write-Ahead Logging) mode and `busy_timeout = 5000`.
- Tables:
  - `q_durable_tasks`: Primary task records and lifecycle state indexing.
  - `q_durable_plans`: Plan snapshots and associated capability schemas.
  - `q_lifecycle_events`: Chronological append-only event ledger.
- Supports pure in-memory mode for isolated automated test execution.

### C. Task Recovery & Idempotent Resume Engine (`QTaskRecoveryManager`)
- **Discovery**: Queries incomplete tasks in `.running`, `.paused`, or `.recovering` states.
- **Classification (`QRecoveryStatus`)**:
  - `.completed` / `.failed` $\to$ Terminal tasks returned immediately without re-execution.
  - `.corrupted` $\to$ Schema errors or missing plan snapshots fail closed.
  - `.securityBlocked` $\to$ Security violations halt execution.
  - `.needsPermission` $\to$ Sensitive steps re-prompt user for interactive authorization.
  - `.needsVerification` $\to$ Interrupted in-flight steps undergo observation queries before executing.
  - `.recoverable` $\to$ Validated pending steps resume sequentially.
- **Observation-First Verification**:
  - Before resuming an uncertain step (a step left in `running` state when a crash occurred), Q queries current empirical system state (e.g. `NSWorkspace` running applications, sandbox filesystem stat).
  - If the effect **already exists**: marks step `.completed` with verified evidence, advances step pointer, and records `step.verified` lifecycle event without repeating the action.
  - If the effect is **missing**: resets step to `.pending` for safe execution.

### D. Execution Identity & Idempotency (`QExecutionIdentity`)
- Deterministic composite fingerprint: `taskId:planId:stepId:actionName`.
- Guarantees physical actions are executed at most once.

### E. Execution Budgets & Loop Termination (`QAgentBudget`)
- Configurable bounds per task:
  - Max execution steps: `20`
  - Max replanning attempts: `2`
  - Max total wall-clock duration: `300.0s`
  - Max consecutive step failures: `3`
  - Max model planning attempts: `3`
- Evaluates before every step and replan; immediately fails closed if any bound is exhausted.

---

## 3. Security Invariants & Fail-Closed Rules

| Invariant | Enforcement Mechanism |
| :--- | :--- |
| **Untrusted Persisted State** | On recovery, task context, snapshots, and capability requirements are parsed as untrusted data and re-validated against current allowlists. |
| **No Implicit Authorization** | A persisted event claiming `permission.granted` does not grant runtime capability. `QPermissionGate` evaluates all execution requests dynamically. |
| **Context Taint Preservation** | If a task context was tainted prior to crash, the reconstructed context remains tainted, suspending standing grants. |
| **Level 4 Blocked Protection** | Deserialization of plans containing Level 4 blocked capabilities (e.g. `/System/Library`, raw shell execution) throws validation errors and halts task recovery. |
| **Observation Before Action** | Interrupted actions are verified through real system inspection to prevent duplicate physical side-effects. |

---

## 4. Verification & Baseline Status

All 7 required Phase 2D suites and all 188 prior regression suites pass cleanly on macOS ARM64:

```
▶ Pace test runner — isolated DerivedData at /tmp/pace-test-derived-data
✅ Passed — 1899/1899 passed, 0 failed, 0 skipped, 33.5s (195 test suites)
```

### Phase 2D Test Suites:
1. `QDurableTaskStateTests.swift` (5 scenarios): Serialization round-trip, JSON encoding, corrupted schema rejection, and budget reconstruction.
2. `QTaskRecoveryManagerTests.swift` (5 scenarios): Discovery of active tasks, completed task status, missing snapshot corruption, uncertain step classification, and security block detection.
3. `QIdempotencyTests.swift` (3 scenarios): Deterministic execution fingerprinting, parameter hashing, and observation-first step skipping.
4. `QAgentBudgetTests.swift` (5 scenarios): Execution step exhaustion, replanning bound limit, wall-clock timeout, repeated failure threshold, and model call bounds.
5. `QPersistenceSecurityTests.swift` (4 scenarios): Corrupted payload fail-closed, Level 4 blocked tool rejection, persisted fake permission rejection, and tainted context preservation.
6. `QCrashRecoveryTests.swift` (2 scenarios): Recovery after mid-plan creation crash and multi-step task resumption from pending step.
7. `QRecoveryE2ETests.swift` (3 scenarios): Real macOS crash recovery with observation-first resolution, safe single execution, and end-to-end agent resume.
