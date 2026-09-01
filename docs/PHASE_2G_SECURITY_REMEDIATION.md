# Q × PACE — Phase 2G: Audit Boundary Security Remediation

**This is a security remediation, not the Phase 2G "make `screen.ocr` real"
milestone itself.** `QBridgeVision.performOCR` remains exactly the fabricated
stub it was in Phase 2B — no `ScreenCaptureKit` or `Vision.framework` code was
added. This work exists solely to close the gap the Phase 2G pre-check found
before any real OCR implementation is attempted.

## 1. Objective

Guarantee that screen/perception-derived action results — the data path a
future real `screen.ocr` implementation would populate — cannot reach durable
persistence, audit storage, or user-facing diagnostic text unredacted,
without weakening any existing security check, without introducing a second
logging system, and without treating redaction as authorization.

## 2. The weakness (from the Phase 2G pre-check)

`QExecutionService.executeScreenOCR` builds `QActionResult.summary` by
interpolating the recognized text directly: `"Captured screen N and
recognized: \(ocr.detectedText)"`. Tracing every consumer of that string
found one confirmed, unredacted path into durable state:

```
QActionResult.summary
  → QPlanStepResult.summary            (QPlanExecutor, in-memory)
  → QDurablePlanStepSnapshot.resultSummary  (QDurablePlanSnapshot.init(from:))
  → QDurableTaskStore.savePlan(...)    (persisted, plaintext JSON)
```

This bypassed `QSecretRedactor` entirely — that construction path never
routes through `QAuditRecord.init` (the only place redaction was previously
applied). The audit-log path itself (`QAuditRecord.executionSummary`) was
already safe for this specific tool, but only incidentally: `screen.ocr` has
no dedicated verification strategy, so the generic evidence string that
reaches `QAuditLogger` never happened to contain the raw text — a property of
today's stub, not a designed protection.

## 3. Data flow — before

```
QBridgeVision.performOCR → QVisionOCRResult.detectedText
        │
        ▼
QActionResult.summary = "...recognized: <raw text>"     (interpolated inline)
        │
        ├─► QAuditRecord.executionSummary   → QSecretRedactor.redact  → safe (incidentally)
        ├─► QMemoryRecord.content           → generic evidence string → safe (incidentally)
        ├─► QTaskContext (.untrustedScreen) → raw, on-device only     → correct, intended
        │
        └─► QPlanStepResult.summary → QDurablePlanStepSnapshot.resultSummary
              → QDurableTaskStore   ◄── UNREDACTED. Confirmed gap.
```

## 4. Data flow — after

```
QBridgeVision.performOCR → QVisionOCRResult.detectedText   (still the Phase 2B stub)
        │
        ▼
QActionResult.summary = "...recognized: <raw text>"
        │
        ├─► QPlanExecutor step G (Layer 1 — source redaction):
        │     isScreenDerivedStep = actionName == "screen.ocr" || toolFamily == "perception"
        │     sanitizedResultSummary = isScreenDerivedStep
        │                              ? QSecretRedactor.redact(actionResult.summary)
        │                              : actionResult.summary
        │       │
        │       ├─► stepEvidence (else-branch) ← sanitizedResultSummary
        │       ├─► QPlanStepResult.summary    ← sanitizedResultSummary
        │       ├─► QAuditRecord.executionSummary (uses stepEvidence — sanitized either way,
        │       │     plus QAuditRecord's own existing redaction as a second pass)
        │       └─► QMemoryRecord.content (via completedStepsEvidence — sanitized either way)
        │
        └─► QTaskContext.append(content: actionResult.summary [RAW, unchanged],
              provenance: .untrustedScreen, ...)   ← on-device-only, never logged/persisted,
                                                       unchanged from before — see §6
        │
        ▼
QDurablePlanStepSnapshot.init(from: step)  (Layer 2 — durable-boundary backstop, UNCONDITIONAL):
  resultSummary     = QSecretRedactor.redact(step.result?.summary)
  verifiedEvidence  = QSecretRedactor.redact(step.result?.verifiedEvidence)
  state's embedded reason (.failed/.blocked/.waitingForPermission/.skipped)
                    = QSecretRedactor.redact(reason)
        │
        ▼
QDurableTaskStore.savePlan(...)  ← guaranteed sanitized regardless of source, tool, or whether
                                     Layer 1 correctly classified the step
```

Two layers, both reusing the existing `QSecretRedactor` — no parallel
sanitization system was introduced:

- **Layer 1 (source, targeted):** applied inside `QPlanExecutor`, gated on the
  *same* predicate the codebase already uses to decide `.untrustedScreen`
  taint (`actionName == "screen.ocr" || toolFamily == "perception"`) — this
  is the intent-revealing fix, tying redaction to the same classification
  taint already relies on rather than inventing a second one.
- **Layer 2 (durable boundary, universal backstop):** applied inside
  `QDurablePlanStepSnapshot.init(from:)`, unconditionally, to every step
  regardless of tool. This is the "no alternate path" guarantee: even a
  future code path that constructs a `QPlanStep.result` directly — bypassing
  `QPlanExecutor` entirely — cannot write unredacted content into the durable
  store. `QSecretRedactor.redact` is idempotent on already-clean or
  already-redacted text, so this layer never double-transforms or degrades
  data Layer 1 already sanitized, and never alters ordinary non-screen
  summaries that contain nothing secret-shaped.

## 5. Redaction guarantees

- Screen-derived `QActionResult.summary` is sanitized before it can reach
  `QPlanStepResult.summary`, `QDurablePlanStepSnapshot.resultSummary`,
  `QDurableTaskStore` persistence, `QAuditRecord.executionSummary`, or
  `QMemoryRecord.content` — proven end-to-end (real `QPlanExecutor` →
  real `QDurableTaskStore` round trip, not mocked) by
  `QScreenDerivedAuditRedactionTests`.
- Failure/blocked/waiting-for-permission reason strings are redacted at the
  same durable boundary, regardless of source — closing the "failure path"
  question even though no current code path can actually populate OCR text
  into an error today (capture/permission failures necessarily occur before
  recognition happens).
- `rawArguments` was already, and remains, never stored as plaintext at all
  (`QAuditRecord` stores only its SHA-256 hash) — a structurally stronger
  guarantee than redaction for that specific field.
- No debug/console logging call site (`print`/`NSLog`/`os_log`) exists
  anywhere in `QExecutionService.swift`, `QBridgeAdapters.swift`,
  `QPlanExecutor.swift`, or `QCoreRuntime.swift` — there was, and is, no
  alternate console-log leak path to fix.
- Reused, not extended: `QSecretRedactor`'s existing pattern set (API keys,
  Bearer tokens, PEM blocks, password/token/secret-style assignments) is
  unchanged. It remains scoped to credential-shaped secrets — it does not
  and cannot catch general PII (private messages, financial figures, 2FA
  codes shown on screen) — recorded here as an explicit, known limitation,
  not silently assumed away.

## 6. Provenance guarantees

`.untrustedScreen` taint propagation (`QTaskContext.append` inside
`QPlanExecutor`) is **unchanged and deliberately still uses the raw,
unredacted `actionResult.summary`** — this value is on-device-only, never
logged, never persisted, and the local planner needs the real content to
reason about the screen correctly. Redacting it there would degrade the
product's core function for zero privacy benefit, since nothing downstream
of that specific append leaves the device or reaches a logged/durable sink.

Redaction is never treated as, or confused with, authorization: sanitizing
what gets *persisted* does not "clean" a tainted task. Proven directly by
`sanitizationDoesNotWeakenTaintEnforcement` — a plan with a screen-derived
step followed by a Level 2 step still halts for fresh approval
(`QPermissionGate`'s existing taint-forced-approval branch), even though the
screen-derived step's *persisted* summary was already redacted.

## 7. Persistence guarantees

`QDurablePlanStepSnapshot.init(from:)` is the sole construction path from a
live `QPlanStep` into anything `QDurableTaskStore` persists (confirmed: it's
the only call site `QDurablePlanSnapshot.init(from: plan)` uses). With Layer
2 now unconditional there, no production code path can write a `QPlanStep`
result into the durable store without passing through
`QSecretRedactor.redact`. Proven via a real save → reload round trip through
`QDurableTaskStore` (`durableRecoveryContainsOnlySanitizedData`) — not a mock
of the store — including reconstruction back into a live `QPlan` via
`QDurablePlanSnapshot.validate()` (the actual crash-recovery path).

## 8. Fail-safe behavior

Redaction failure mode is fail-safe by construction: `QSecretRedactor.redact`
never throws and never returns `nil` — worst case it fails to match a novel
secret shape and passes text through unchanged (an existing, unchanged
limitation of the pattern-based approach, not a new risk introduced here).
It never *removes* legitimate content beyond matched secret substrings, so
goal-evaluation substring matching (`QGoalEvaluator`) and evidence-based
replanning continue to function normally against sanitized text in the
common case.

## 9. Test matrix

`leanring-buddyTests/QScreenDerivedAuditRedactionTests.swift`, 7 tests, using
a `MockScreenDerivedExecutionProvider` to simulate what a real `screen.ocr`
result would contain (since the real stub's fabricated text never matches a
secret pattern) — no mocking of `QAuditLogger`, `QDurableTaskStore`, or
`QSecretRedactor` themselves, so real serialization/persistence bugs cannot
hide behind a mock:

| Test | Proves |
| --- | --- |
| 1/4/10 | A known secret pattern in a screen-derived result never reaches persisted audit output, via `executionSummary` or `error`. |
| 5 | `rawArguments` structurally cannot leak the secret (hashed, never stored plaintext). |
| 6 | Failure/blocked reason strings are redacted at the durable boundary regardless of source. |
| 3 | Redacting a screen-derived summary for persistence does not weaken taint-forced approval on a later Level 2 step. |
| 7 | A real `QDurableTaskStore` save → reload → `validate()` round trip contains no plaintext secret. |
| 8 | A non-screen-derived step's summary is byte-identical, untouched by the new boundary. |
| — | The durable-boundary backstop is idempotent — a no-op on ordinary, already-clean text. |

Existing tests re-verified unchanged: `QAuditLoggerTests` (redactor itself),
`QPlanExecutionTests` (including its existing screen.ocr taint-propagation
test), `QDurableTaskStateTests`, `QTaskRecoveryManagerTests`,
`QRecoveryE2ETests`, `QGoalEvaluatorTests` — 30/30 pass.

## 10. Explicitly not done

No `ScreenCaptureKit` or `Vision.framework` integration. No change to
`QPermissionGate`, `QApprovalCoordinator`, or any capability level. No new
mutating capability. `QBridgeScreenCapture`/`QBridgeVision` remain exactly
the Phase 2B stubs. This remediation only had to touch the *result-handling*
path (`QPlanExecutor`, `QDurablePlanSnapshot`) — it did not need to, and did
not, touch the authorization/approval layer at all.
