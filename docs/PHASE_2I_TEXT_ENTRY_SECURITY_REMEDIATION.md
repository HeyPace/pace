# Phase 2I — Text-Entry Privacy Boundary (Security Remediation)

**Historical record of the pre-implementation privacy remediation.** This document describes the
six structural gaps a Phase 2I privacy pre-check confirmed (`PHASE 2I PRE-CHECK: NO-GO`) and the
remediation that closed them — written and landed *before* `ui.set_text_value` itself existed, so
its future implementation would inherit a safe durable-persistence, memory, HUD, and verification
boundary from day one. `ui.set_text_value` has since been implemented on top of this contract; see
[`PHASE_2I_SEMANTIC_TEXT_ENTRY.md`](./PHASE_2I_SEMANTIC_TEXT_ENTRY.md) for the capability itself.
No keyboard input, CGEvent, or browser automation was added by this remediation, and no new risk
level was introduced.

## Confirmed privacy gaps (pre-check findings)

The pre-check traced a hypothetical `ui.set_text_value(target="Notes", value="SECRET_TEST_VALUE")`
through the full Q pipeline and found:

1. **Durable persistence (FAIL)** — `QDurablePlanStepSnapshot.init(from:)` copied
   `step.action.arguments` verbatim into an unencrypted on-disk SQLite store
   (`QDurableTaskStore`), with no redaction at all. This is a *pre-existing, generic* mechanism
   that already applies to every capability's raw input arguments today, not something a future
   capability's executor could avoid by writing careful code.
2. **`QMemoryStore` (FAIL)** — `QPlanExecutor`'s plan-completion `QMemoryRecord.content` was built
   directly from `finalSummary` with zero redaction — a second, independent durable SQLite store
   with no protection at all, unlike audit (`QAuditRecord.executionSummary`, which already
   redacts) or the durable plan snapshot's `resultSummary`/`verifiedEvidence` fields.
3. **No verification-representation contract** — nothing constrained a future text-entry
   executor/verifier to avoid embedding the literal value in `QActionResult.summary`,
   `outputData`, or verification evidence strings, all of which have confirmed downstream paths
   into audit, durable storage, and the local model's own context
   (`QGoalEvaluator` → `generateGroundedSummary` / `QReplanController`).
4. **Approval HUD (FAIL)** — `QApprovalRequest.expectedEffect` (rendered verbatim by
   `PaceTurnHUDState`, `"Q wants to: \(expectedEffect)"`) was built, at **four independent
   construction sites**, from the model's own free-text step description
   (`QToolAuthorizationRequest.literalAction` / `QPlanStep.description`) with no template
   enforcement — nothing stopped a future text-entry step's model-authored description from
   including the literal value pre-approval.
5. **No secure-field / role policy in Q's own AX bridge** — `QBridgeAccessibility`
   (`QBridgeAdapters.swift`) had zero secure-field or role-allowlist awareness. The only existing
   precedent (`PaceFlowRecorder.elementIsSecureTextField`) lives in an unrelated Pace-native
   module and is a denylist (`AXSecureTextField` only), not an allowlist.
6. **No recovery-readback scoping contract** — nothing constrained a future recovery/idempotency
   check's live `kAXValueAttribute` readback to stay ephemeral (boolean-only) rather than crossing
   into logged/persisted state.

## What changed

### 1. Durable snapshot boundary

`QSensitiveArgumentPolicy` (new, `leanring-buddy/QSensitiveArgumentPolicy.swift`) is a single,
canonical table of per-tool-name sensitive argument keys. Today it declares exactly one entry —
`"ui.set_text_value": ["value"]` — a pre-declaration of the redaction contract that capability's
future implementation must honor, not a grant of any execution authority (the tool name is still
absent from `QModelPlanParser.registeredCapabilities`).

`QDurablePlanStepSnapshot.init(from:)` (`QDurablePlanSnapshot.swift`) now builds its `arguments`
field via `QSensitiveArgumentPolicy.redactedArguments(toolName:arguments:)`, which masks only the
declared-sensitive keys with a length-preserving placeholder
(`[REDACTED_SENSITIVE_ARGUMENT:length=N]`) and leaves every other key untouched. For every
capability actually registered/executable today, this table has no entries, so
`redactedArguments` is a byte-for-byte no-op — **zero behavior change for any existing
capability's persisted arguments.**

### 2. Memory boundary

`QPlanExecutor`'s plan-completion `QMemoryRecord.content` (`QCoreRuntime`-adjacent,
`QPlanExecutor.swift`) is now `QSecretRedactor.redact(finalSummary)` instead of raw
`finalSummary` — the same canonical redactor already applied, at construction, to
`QAuditRecord.executionSummary` and `QDurablePlanStepSnapshot.resultSummary`/`verifiedEvidence`.
This is a defense-in-depth backstop, not a general-purpose redactor: `QSecretRedactor` only
strips secret-*shaped* substrings (API keys, PEM blocks, password/token assignments) — it cannot
generically identify arbitrary sensitive free text such as a dictated message or a typed value.
The structural guarantee that a future capability's literal input never reaches `finalSummary` in
the first place must come from that capability's own executor honoring the verification contract
below.

### 3. Verification / execution contract

`QSafeTextEntryVerificationEvidence` (new, `QTextEntrySecurityContracts.swift`) has no field
capable of holding literal text — only `valueChanged: Bool`, `previousLength: Int`,
`currentLength: Int`, `targetIdentity: String`, and `verificationStatus:
QSafeTextEntryVerificationStatus`. `toActionResultOutputData()` and `safeEvidenceDescription` are
the only sanctioned ways to turn it into `QActionResult.outputData` / verification-evidence
strings — a future executor/verifier that routes through this type structurally cannot leak the
literal into `QActionResult`, audit, durable persistence, `QMemoryStore`, the HUD, or model/replan
context, because the type has nowhere to carry it. This type is not wired into
`QExecutionService`/`QActionVerification` — no executor exists to consume it yet.

### 4. Approval HUD privacy

`QSensitiveArgumentPolicy.approvalSafeLiteralAction(toolName:arguments:fallbackLiteralAction:)`
builds `"Allow Q to enter text into "<application> → <target>"?"` from non-sensitive targeting
metadata only (`applicationName`, then `identifier`/`title`/`role`) for any tool with declared-
sensitive arguments, and returns `fallbackLiteralAction` unchanged for every other tool. This is
wired into all four places a live, HUD-facing `QApprovalRequest.literalAction`/`expectedEffect`
is built from a step's own description:

- `QPlanExecutor.swift` (the original `QToolAuthorizationRequest` → `QPermissionGate.evaluate`
  path, which also covers the taint-forced-approval branch).
- `QCoreRuntime.swift`'s `submitIntent` halt-handling (line ~315) and `executeResumedPlan`
  halt-handling (line ~849) — two independent reconstructions of the live `.awaitingApproval`
  state that bypass `QPermissionGate.evaluate` entirely.
- `QRuntimeUISnapshot.pendingApproval` — a third independent reconstruction, used where only a
  lightweight `QRuntimeStepSnapshot` (no `arguments` field) is available; this call site passes an
  empty arguments dictionary, so the safe template degrades to a fully generic, argument-free
  form (no dynamic content at all) rather than being skipped.

Two remaining `QApprovalRequest` construction sites (`QCoreRuntime.swift`'s `needsPermission`
recovery case and `QDurableTaskState.toTask()`) were inspected and left untouched — both already
use a hardcoded generic string (`"Recovered action awaiting user permission"` /
`"Recovered action awaiting permission"`), never a step-specific literal.

### 5. AX role allowlist

`QAXTextEntryRolePolicy.allowedRoles = ["AXTextField", "AXTextArea"]`
(`QTextEntrySecurityContracts.swift`) is an explicit allowlist, not a denylist — it rejects
`AXSecureTextField`, `AXStaticText`, and any unrecognized/custom role by the same default-deny
check, per the pre-check's "strictest practical policy" recommendation (a denylist alone cannot
cover an unknown or custom-rolled secure field). A new `QAXInteractionError.disallowedTargetRole`
case (`AX_TARGET_ROLE_NOT_ALLOWED`) was added to the existing error model
(`QBridgeAdapters.swift`) for a future implementation to throw — not yet thrown by any production
code path, since no capability targets AX roles for writing yet.

### 6. Recovery scoping

`QTextEntryRecoveryEqualityResult` (`QTextEntrySecurityContracts.swift`) carries only
`alreadyMatchesIntendedValue: Bool` — no string field at all. A future recovery function must
consume the live `kAXValueAttribute` readback exclusively inside the comparison that produces this
type; because the type has no field that could hold the readback, returning it (rather than the
raw comparison strings) structurally prevents the readback from reaching `QActionResult`,
evidence, logs, persistence, or model/replan context.

## Explicit non-goals (at the time this remediation landed)

- `ui.set_text_value` was not registered or executable at the time this remediation landed — it
  was implemented afterward, on top of this contract; see
  [`PHASE_2I_SEMANTIC_TEXT_ENTRY.md`](./PHASE_2I_SEMANTIC_TEXT_ENTRY.md).
- No keyboard input, CGEvent, or browser automation was added by this remediation.
- No new risk level or capability-level semantics were introduced.
- `QPermissionGate`'s decision logic, `QApprovalCoordinator`'s single-use-grant mechanics,
  `QResourceGuard`, `QExecutionIdentity`, `QAgentBudget`, `QGoalEvaluator`,
  `QReplanController`, `.untrustedScreen` provenance handling, fail-closed defaults, and
  observation-first recovery are all unmodified.
- The two Pace-native (non-Q) approval surfaces
  (`PaceActionApprovalPolicy`/`requestUserApprovalForActionPlan`, covered by the Phase 2H
  remediation) are untouched — this remediation is scoped to Q's own pipeline, where a future
  `ui.set_text_value` would live.
