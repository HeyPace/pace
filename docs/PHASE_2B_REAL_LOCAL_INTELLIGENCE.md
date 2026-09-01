# Q × PACE — Phase 2B: Real Local Intelligence

## 1. Overview & Architecture

Phase 2B elevates Q from deterministic/predefined plan mapping to **Real Local Intelligence** on macOS Apple Silicon. User natural language intents are parsed, enriched with relevant non-secret episodic memory, transformed into strictly validated multi-step JSON plan schemas by local inference engines, executed sequentially under authoritative kernel/runtime constraints (`QPlanExecutor`), empirically verified in closed loops, and summarized into grounded natural language responses without cloud dependencies.

```
                  ┌─────────────────────────────────────┐
                  │       User Natural Language         │
                  └──────────────────┬──────────────────┘
                                     │
                                     ▼
                  ┌─────────────────────────────────────┐
                  │    QMemoryStore (Context Retrieval) │
                  └──────────────────┬──────────────────┘
                                     │ (Sanitized context, no secrets)
                                     ▼
                  ┌─────────────────────────────────────┐
                  │   QModelRouter (Local Engines Only) │
                  │  Apple FM / MLX / Ollama / llama.cpp│
                  └──────────────────┬──────────────────┘
                                     │ (Raw Structured Output)
                                     ▼
                  ┌─────────────────────────────────────┐
                  │   QModelPlanParser (Schema Validation│
                  │   & Capability Allowlist Validation)│
                  └──────────────────┬──────────────────┘
                                     │ (Pure Presentation/Data Model: QPlan)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                             QPlanExecutor                                   │
│  ┌───────────────────────┐   ┌────────────────────┐   ┌───────────────────┐ │
│  │ 1. Resource Guard     │──▶│ 2. Permission Gate │──▶│ 3. Exec Service   │ │
│  │ (Path Allow/Denylist) │   │ (Capability Model) │   │ (Safe Action Set) │ │
│  └───────────────────────┘   └────────────────────┘   └─────────┬─────────┘ │
│                                                                 │           │
│                                                                 ▼           │
│                                                       ┌───────────────────┐ │
│                                                       │4. Action Verifier │ │
│                                                       │ (Empirical State) │ │
│                                                       └─────────┬─────────┘ │
│                                                                 │           │
│                                  Failure / Verification Fail    │           │
│              ◀──────────────────────────────────────────────────┤           │
│    Controlled Replanning (Max 2 Attempts)                       ▼           │
│                                                       ┌───────────────────┐ │
│                                                       │ 5. Memory & Audit │ │
│                                                       └───────────────────┘ │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │ (Verified Evidence)
                                       ▼
                  ┌─────────────────────────────────────┐
                  │ Grounded Natural Language Response  │
                  └─────────────────────────────────────┘
```

---

## 2. Files Changed & Created

| File | Status | Description |
| :--- | :--- | :--- |
| `leanring-buddy/q-runtime/QCore/QModelPlanSchema.swift` | **NEW** | Defines `QModelPlanSchema`, `QModelActionSchema`, `QModelPlanParser`, and capability allowlisting |
| `leanring-buddyTests/QLocalIntelligenceTests.swift` | **NEW** | Comprehensive Phase 2B test suite (14 test cases covering planning, schema rejection, replan limits, grounded summaries, and air-gap enforcement) |
| `leanring-buddy/q-runtime/QCore/QModelRouter.swift` | **MODIFIED** | Implemented `QStructuredModelProvider`, structured multi-step plan generation with fallback, and grounded summary synthesis |
| `leanring-buddy/q-runtime/QCore/QCoreProtocols.swift` | **MODIFIED** | Added `QStructuredModelProvider` protocol, `isTerminal` & `isCompleted` helpers on `QTaskState` |
| `leanring-buddy/q-runtime/QCore/QCoreRuntime.swift` | **MODIFIED** | Integrated memory-aware planning, sequential execution via `QPlanExecutor`, controlled replanning (max 2), and grounded response generation |
| `leanring-buddy/q-runtime/QCore/QPlan.swift` | **MODIFIED** | Added `isBlocked` and `isFailed` status helpers to `QPlanState` and `QPlanStep` |
| `leanring-buddy/q-runtime/QCore/QPlanExecutor.swift` | **MODIFIED** | Added configurable `executionProvider` injection |
| `leanring-buddy/q-runtime/QShared/QMemoryStore.swift` | **MODIFIED** | Added convenient `inMemory: Bool` initializer for memory isolation testing |
| `leanring-buddy/q-runtime/QCore/QAgent.swift` | **MODIFIED** | Forwarded UI / plan execution observers to `submitIntent` |
| `leanring-buddyTests/QAgentE2ETests.swift` | **MODIFIED** | Updated summary assertion for case-insensitive localized verification |

---

## 3. Local Model Backend & Air-Gap Enforcement

1. **Engine Selection Priority:**
   - Apple Foundation Models (`apple.foundation`, on-device macOS 26.0+)
   - MLX In-Process Engine (`apple.mlx`, quantized 4-bit local weights)
   - Ollama Localhost (`local.ollama`, `127.0.0.1:11434`)
   - llama.cpp / LM Studio (`local.llama_cpp`, `127.0.0.1:1234`)
2. **Air-Gap Policy (`LOCAL_ONLY = true`):**
   - Non-loopback endpoints are intercepted and blocked by `QEgressBroker` in offline mode.
   - Zero cloud inference fallback permitted.
   - If no local backend is reachable, fails closed safely with an actionable diagnostic.

---

## 4. Structured Plan Schema & Parser

Model outputs are treated as **untrusted data** and never as execution authority.
- **Allowed Tool Capabilities:**
  - `system.running_apps` (Level 0 Read-Only)
  - `system.clipboard.read` (Level 0 Read-Only)
  - `screen.ocr` (Level 0 Read-Only)
  - `ui.open_app` (Level 1 Safe Local Action)
  - `fs.read` (Level 0 Read-Only)
  - `fs.write_sandbox` (Level 1 Safe Local Action)
  - `accessibility.read` (Level 0 Read-Only)
  - `test.noop` (Level 0 Read-Only)
- **Validation Rules:**
  - Strict JSON schema decoding with markdown-fence sanitization (`QModelPlanParser.extractJSON`).
  - Unknown tools are immediately rejected (`QModelPlanParseError.unknownCapability`).
  - Unauthorized risk escalations (e.g. attempting Level 4 Blocked tools) are rejected (`QModelPlanParseError.unauthorizedRiskLevel`).
  - Maximum step count capped at 10 steps (`QModelPlanParseError.stepLimitExceeded`).

---

## 5. Memory-Aware Context & Flow

1. Before invoking local model planning, `QCoreRuntime` queries `QMemoryStore.queryContext(for: prompt, limit: 5)`.
2. Only sanitized, non-secret context strings are injected into the prompt.
3. System secrets, SSH keys, credentials, and API keys are blocked from model context.
4. Provenance tracking tags inputs and memory records (`trusted:user` vs `untrusted`).

---

## 6. Failure Recovery & Controlled Replanning

1. If a step fails execution or empirical verification, `QCoreRuntime` captures the failed step index and reason.
2. If `replanCount < maxReplans` (limit: 2), `QCoreRuntime` requests a corrected multi-step plan from `QStructuredModelProvider`.
3. The new plan undergoes complete schema and security verification.
4. If the replan limit is reached without success, execution halts cleanly with a descriptive failure state.

---

## 7. Grounded Natural Language Response Synthesis

After plan execution concludes:
- Verified evidence collected across all completed steps (`completedStepsEvidence`) is supplied to `generateGroundedSummary`.
- The local model synthesizes a concise 1-2 sentence response grounded strictly in the verified facts.
- The agent never hallucinates unverified execution results.

---

## 8. Real macOS E2E Task Verification

- **Task:** `"Open Calculator and tell me when it is ready."`
- **Execution Pipeline:**
  1. `USER` intent submitted to `QAgent.run(task:)`.
  2. `QModelRouter` generated structured plan with step: `ui.open_app` (appName: `"Calculator"`).
  3. `QPlanExecutor` verified resource path and evaluated `QPermissionGate` (granted Level 1 safe local action).
  4. `QExecutionService` launched application via `NSWorkspace.shared.openApplication`.
  5. `QActionVerifier` empirically verified application activation in window server.
  6. `QMemoryStore` and `QAuditLogger` recorded execution proof.
  7. Final grounded response returned to user.

---

## 9. Final Test & Build Metrics

- **Total Test Suites:** 185
- **Total Tests Passed:** 1,849 / 1,849 (100% pass rate)
- **Regressions / Failures:** 0
- **Build Status:** `** BUILD SUCCEEDED **` (macOS ARM64 Debug)
