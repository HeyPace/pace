# Phase 2I — Semantic AX Text Entry (`ui.set_text_value`)

Q's second controlled UI-interaction capability: a Level 2, reversible write of a single,
semantically-identified, currently-focused Accessibility (AX) text field's value. It never
targets screen coordinates, never falls back to CGEvent or keyboard simulation, never sends
Return/Tab/submit, and never claims goal success from a successful AX write alone. It is the
direct extension of Phase 2H's `ui.click_element` — reusing the identical target-resolution and
observation-binding discipline for a value *write* instead of a *press* — with two additional
preconditions unique to writing content: a strict AX-role allowlist, and a live focus check.

## Capability contract

Registered in `QModelPlanParser.registeredCapabilities` as `"ui.set_text_value": ("ui",
.level2UserApproval)`. Parameters (via `QModelActionSchema.parameters`):

| Parameter | Required | Meaning |
| --- | --- | --- |
| `applicationName` | yes | The running application to search, matched against `NSRunningApplication.localizedName`/`bundleIdentifier`. |
| `role` | yes | The AX role to match — MUST be `AXTextField` or `AXTextArea` (`QAXTextEntryRolePolicy.allowedRoles`); any other value, including `AXSecureTextField`, is rejected before any tree walk. |
| `identifier` | one of `identifier`/`title` | Matched against the element's `AXIdentifier` attribute. |
| `title` | one of `identifier`/`title` | Matched against `AXTitle`. |
| `value` | yes | The literal string to write. Declared sensitive in `QSensitiveArgumentPolicy` — see Privacy below. |

Supplying neither `identifier` nor `title`, or an unrecognized role, fails closed
(`AX_MISSING_MATCH_CRITERIA` / `AX_TARGET_ROLE_NOT_ALLOWED`) before any AX call is made. A
model attempting to self-declare a risk level other than Level 2 is rejected by the same
anti-downgrade check every other capability gets.

## Why an allowlist, not a denylist, and why focus is required

The Phase 2I privacy pre-check (`docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md`) recommended an
explicit role allowlist over denylisting `AXSecureTextField`: a denylist cannot cover an unknown
or custom-drawn secure field claiming an unexpected role, while an allowlist of exactly two
well-understood roles (`AXTextField`, `AXTextArea`) rejects everything else — known-secure,
unknown, or custom — by the same default-deny check (`QAXTextEntryRolePolicy`,
`QTextEntrySecurityContracts.swift`).

Unlike a click (which lands on a specific, already-described target), a text write changes
*content*, so this capability additionally requires the resolved target to already be the
system's genuinely focused Accessibility element (`AXUIElementCreateSystemWide` +
`kAXFocusedUIElementAttribute`, the same read Pace-native's own `PaceActionExecutor+Keyboard.swift
setTextValue` already uses) before ever writing. It never clicks or otherwise focuses a field
itself — an unfocused target fails closed with `AX_TARGET_NOT_FOCUSED` rather than guessing or
auto-focusing.

## AX resolution, focus verification, and mutation

`QBridgeAccessibility.setTextValue` (`QBridgeAdapters.swift`) reuses the exact bounded tree walker
(`collectMatches`/`snapshotIfMatches`, max depth 12, 3,000 nodes, 1.5s budget) and observation-
binding re-verify discipline `clickElement` already established, then adds:

1. Role-allowlist check (before any search — an unauthorized role never even becomes a search
   criterion).
2. Zero/ambiguous match handling identical to click (`AX_NO_MATCHING_ELEMENT`/`AX_AMBIGUOUS_TARGET`).
3. Observation-binding re-verify of the same element reference immediately before mutation
   (`AX_STALE_TARGET` on drift), and a disabled check (`AX_TARGET_DISABLED`).
4. **Focus verification**: the resolved element must `CFEqual` the system-wide focused element
   (`AX_TARGET_NOT_FOCUSED` otherwise).
5. **Ephemeral read** of the current `kAXValueAttribute` — exists only in `setTextValue`'s own
   local scope, used solely to compute a length and a SHA-256 hash.
6. **Idempotency**: if the current value's hash already equals the intended value's hash, no AX
   write is performed at all — a deliberate no-op, not a failure.
7. Otherwise, `AXUIElementSetAttributeValue(element, kAXValueAttribute, newValue)` — the only
   mutation API this capability ever calls.

Every failure mode is a deterministic `QAXInteractionError`, caught in
`QExecutionService.executeSetTextValue` and converted into a non-throwing `QActionResult`.

## Privacy: the literal value never crosses a persisted or displayed boundary

This is the capability the entire Phase 2I remediation (`QSensitiveArgumentPolicy`,
`QSafeTextEntryVerificationEvidence`, `QAXTextValueMutationOutcome`) was built ahead of time to
support:

- **Execution → result**: `setTextValue` returns `QAXTextValueMutationOutcome` — a type with no
  field capable of holding the literal, only lengths, non-secret target identity, and SHA-256
  hashes. `executeSetTextValue`'s `summary`/`outputData` are built exclusively from it.
- **Verification**: `QVerificationStrategy.axTextValueChanged` re-resolves the target and compares
  only hashes (`observeTextValueHashAndLength`) — the plaintext is never read into the verification
  layer at all.
- **Durable persistence**: `QDurablePlanStepSnapshot.init(from:)` masks `arguments["value"]` via
  `QSensitiveArgumentPolicy.redactedArguments` before it ever reaches `QDurableTaskStore`'s SQLite
  file.
- **Memory**: `QMemoryStore`'s plan-completion write is redaction-passed (`QSecretRedactor`), and —
  because evidence strings never carry the literal in the first place — has nothing to redact.
- **Audit**: `rawArguments` is hashed (never stored raw); `executionSummary`/`error` never contain
  the literal because nothing upstream ever put it there.
- **Approval HUD**: the four live construction sites of `QApprovalRequest.expectedEffect`/
  `literalAction` all route through `QSensitiveArgumentPolicy.approvalSafeLiteralAction`, which
  builds "Allow Q to enter text into “‹application› → ‹target›”?" from non-secret targeting
  metadata only, never the model's free-text description.
- **Model/replan context**: `QGoalEvaluator`'s evidence collection and `generateGroundedSummary`
  only ever see the safe evidence strings above.

`leanring-buddyTests/QSemanticTextEntryTests.swift` test 18 proves this end-to-end with a real
executed plan and a real literal test secret, checking durable state, memory, and audit directly.

## Idempotency & crash recovery

`ui.set_text_value` gets no dedicated observation-first recovery branch in
`QTaskRecoveryManager` — like `ui.click_element`, it relies on the default fail-closed-to-pending
behavior every unrecognized tool gets. What makes a resumed retry safe is that `setTextValue`
itself *always* re-observes the current value and compares it to the intended value before ever
writing — a step resumed after a crash where the write already landed is a no-op on retry, not a
duplicate mutation.

## Verification: a successful write is not goal success

`QActionVerifier`'s `.axTextValueChanged` case deliberately diverges from `.axElementStateChanged`
in one respect: an unresolvable target *after* the write is treated as `.failed`, not `.verified`.
A button's identity commonly and expectedly changes as a direct result of being pressed; a text
field disappearing after having its value set is a more concerning signal (window closed, app
crashed, field removed) and is never assumed to be a success.

## Real macOS test coverage

`leanring-buddyTests/QSemanticTextEntryTests.swift` (20 tests, gated on `AXIsProcessTrusted()` and
real focus establishment, no-opping honestly rather than fabricating a pass when either is
absent — mirroring `QSemanticClickTests`): registration/anti-downgrade, valid AXTextField/
AXTextArea writes, disallowed/unknown role rejection, zero/ambiguous match, wrong-focus fail-
closed (with a field-content-unchanged assertion ruling out any hidden fallback), idempotent
no-op, the full approve/deny/abandon/reuse/cross-authorize approval lifecycle, closed-loop
verification (including a deliberate mismatch case), budget exhaustion, uncertain-step recovery,
and full-pipeline redaction across durable state, memory, and audit.

## Excluded capabilities (explicitly out of scope for this phase)

Keyboard simulation, CGEvent, coordinate-based interaction, Return/Tab/submit injection, browser
automation, password/OTP/card/payment fields (structurally excluded by the role allowlist),
filesystem mutation, sending messages, destructive actions, security-setting changes, arbitrary
shell execution, and any new network/cloud dependency. None of these were added.

## Known limitations

- Matching is exact-string (role must be exactly `AXTextField`/`AXTextArea`; identifier/title
  exact match) — no fuzzy matching, by design.
- The observation-binding re-verify covers the gap between resolution and dispatch within one
  synchronous call; it does not (and structurally cannot, without an artificial delay) protect
  against a mutation landing in the sub-millisecond window between the two reads themselves —
  the same, deliberate limitation documented for `ui.click_element`.
- Focus verification trusts `AXUIElementCreateSystemWide`'s `kAXFocusedUIElementAttribute` read —
  the same AX API trust boundary every other read-only AX/TCC check in this codebase already
  relies on (e.g. `AXIsProcessTrusted()`).
- Hash-based verification (SHA-256) cannot distinguish two different values that happen to
  collide, which is cryptographically negligible, and is the same trade-off `QAuditRecord
  .argumentsHash` already accepts elsewhere in this codebase in exchange for never storing
  plaintext.
