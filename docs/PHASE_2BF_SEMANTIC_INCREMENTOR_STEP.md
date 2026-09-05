# Phase 2BF — Semantic Stepper / Incrementor Step Mutation (`ui.step_incrementor`)

## Overview
- **Capability Identifier**: `ui.step_incrementor`
- **Tool Family**: `ui`
- **Risk Level**: Level 2 User Approval Required (`.level2UserApproval`)
- **Baseline Commit**: `c58127e`
- **Pre-Phase Capability Count**: `53`
- **Post-Phase Capability Count**: `54`
- **Mutability**: Mutating Local Action (Reversible Local Action)
- **User Approval**: Explicit single-use user approval bound to exact execution identity
- **Recovery Requirement**: Observe-first recovery before replay; fresh verification after change.

---

## Semantic Accessibility & AppKit Contract
- **Target Element**: `AXIncrementor` (`kAXIncrementorRole`) — the AX role reported by `NSStepper`.
- **Role Policy**: `QAXIncrementorRolePolicy.allowedRoles = ["AXIncrementor"]` (reused unmodified from Phase 2BA — strictly fails closed on any other role, including `AXSlider`).
- **Target Attributes**:
  - `kAXRoleAttribute`
  - `kAXTitleAttribute` / `kAXDescriptionAttribute`
  - `AXIdentifier`
  - `kAXValueAttribute` (current numeric value, read before and after mutation)
  - `kAXMinValueAttribute` / `kAXMaxValueAttribute` (bound used for idempotency and clamped-stop detection)
  - `kAXEnabledAttribute`
- **Mutation Mechanism**:
  - Native action dispatch: `AXUIElementPerformAction(targetElement, kAXIncrementAction)` / `AXUIElementPerformAction(targetElement, kAXDecrementAction)` — the purpose-built AX actions for this role (confirmed directly against the live SDK's `AXActionConstants.h`). **Never** `AXUIElementSetAttributeValue(kAXValueAttribute)` directly — that is the combo box/slider/splitter mutation model; an incrementor's real state-change handling fires in response to its own dedicated action, not a raw value write (the same reasoning `ui.set_element_state`, Phase 2K, already applies to `kAXPressAction`).
  - `direction` (`"increment"` / `"decrement"`) is required and explicit on every call — never a blind toggle.
  - `steps` is bounded to the closed range `[1, 20]`; each individual step re-checks the reported min/max bound and stops early if the incrementor reaches it before the requested count is exhausted (`performedSteps` may be less than `requestedSteps`, and is reported honestly either way).
  - Idempotent: if the current value is already at the bound implied by the requested direction (per `kAXMinValueAttribute`/`kAXMaxValueAttribute`), returns `changeKind: .alreadyAtBound` and performs **zero** AX actions.
  - Value drift protection: pre-flight re-read ensures the current value has not changed between search and dispatch.
  - Stale target protection: snapshot check guarantees element identity remains identical immediately before dispatch.
  - Post-mutation verification: independent, separate re-read of `kAXValueAttribute` (never reusing the dispatch loop's own last observation) confirms the value moved strictly in the requested direction.

---

## Deterministic Targeting & Execution Model
1. **Application Resolution**: Exact matching via `QBridgeAccessibility.resolveExactRunningApplication(named:)` (no new resolver — reused unmodified). Fails closed on zero matches (`applicationNotAvailable`) or multiple matches (`ambiguousTarget`).
2. **Window Resolution**: Optional exact window resolution by `windowTitle` or `windowIdentifier`.
3. **Control Resolution**: Target incrementor matching by `role` (must be `AXIncrementor`), and at least one of `identifier` or `title`. Fails closed on missing match criteria (`AX_MISSING_MATCH_CRITERIA`) or multiple matching elements (`AX_AMBIGUOUS_TARGET`).
4. **Direction & Step Validation**: `direction` must parse to exactly `.increment` or `.decrement` (`AX_INVALID_STEP_DIRECTION` otherwise); `steps` must parse to an integer in `[1, 20]` (`AX_INVALID_STEP_COUNT` otherwise) — both validated before any AX call.
5. **Execution Identity**: Computed from capability name, application name, window title, control identifier/title, and requested direction/steps. Tokens are single-use with zero standing grants.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.axIncrementorValueMovedAsDesired(applicationName: String, role: String, matchIdentifier: String?, matchTitle: String?, targetIdentity: String, direction: QAXIncrementorStepDirection, previousValue: Double, changeKind: QAXIncrementorStepChangeKind)`
- **Evaluation**: Re-resolves the target incrementor fresh and re-reads `kAXValueAttribute`.
  - For `changeKind: .changed` — `.verified` requires the freshly observed value to differ from `previousValue` strictly in the requested `direction` (increment: greater than; decrement: less than).
  - For `changeKind: .alreadyAtBound` — `.verified` requires the freshly observed value to still equal `previousValue` (confirming the no-op claim).
- **Evidence**: `target=<targetIdentity> currentValue=<val> previousValue=<val> direction=<increment|decrement> status=verified` (or `status=verified-noop` for the already-at-bound path; fails closed as `status=failed` if the target becomes unavailable or the value did not move as expected).

---

## Approval, Recovery & Resource Bounds
- **Approval**: Explicit single-use approval bound to `QExecutionIdentity` — no standing grant, no persisted authorization, no automatic reauthorization after restart.
- **Recovery**: Observe-first — a retry independently re-reads the current value before deciding whether any further action is needed, never blindly replaying steps.
- **Resource Bounds**: Single target element only (no traversal/enumeration in the mutation path); `steps` capped at 20 per call; each step re-checks the control's own reported bound and stops early rather than spinning past it.

---

## Privacy & Security Architecture
- **No Durable Pointer Leaks**: `targetIdentity` contains application name, window title, role, identifier, and label only — never raw pointers, memory addresses, or screen coordinates.
- **Fail-Closed Permissions**: AX trusted process check (`AXIsProcessTrusted()`) enforced before any AX tree interaction.
- **Zero Physical Automation**: Strictly NO `CGEvent`, `NSEvent`, keyboard simulation, mouse clicking, coordinate clicking, AppleScript, `osascript`, `Process(`, or `/bin/sh`.

---

## Test Coverage (`QSemanticIncrementorStepTests.swift`)
32 focused unit tests:
1. `ui.step_incrementor` registered under toolFamily `ui`
2. Level 2 User Approval Required classification
3. Plan parsing with valid `direction=increment`
4. Plan parsing with valid `direction=decrement` and `steps`
5. Rejection of risk level override
6. Missing application name fails closed
7. Non-existent application fails closed
8. Missing match criteria fails closed
9. Missing `direction` fails closed (`AX_INVALID_STEP_DIRECTION`)
10. Malformed `direction` fails closed
11. `steps=0` fails closed (`AX_INVALID_STEP_COUNT`)
12. `steps=21` (exceeds bound) fails closed
13. Malformed `steps` string fails closed
14. Disallowed role `AXSlider` rejected
15. Disallowed role `AXButton` rejected
16. `QAXIncrementorRolePolicy` strict enforcement (reused from Phase 2BA)
17. `QAXIncrementorStepOutcome` structure and change kinds
18. `QAXIncrementorStepDirection` raw value contract
19. `QAXIncrementorValueEvidence` enum cases
20. Verification strategy closed-loop evaluation (target unavailable)
21. Plan executor verification strategy mapping
22. Permission gate explicit approval requirement
23. Denied approval halts task, never dispatches mutation
24. Durable state privacy boundary
25. Non-existent window target fails closed
26. Task recovery manager observation-first model
27. Idempotent `alreadyAtBound` outcome handling
28. Live AppKit `NSStepper` increment (real AX dispatch or guarded no-op)
29. Live AppKit `NSStepper` decrement (real AX dispatch or guarded no-op)
30. Live AppKit `NSStepper` idempotent no-op at maximum bound
31. Real macOS accessibility trust probe
32. Forbidden physical automation audit

---

## Real macOS E2E — Known Environmental Limitation
Tests 28–30 build a real `NSStepper` inside a live `NSWindow` and dispatch through `QBridgeAccessibility.shared.stepIncrementor` end-to-end. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`, `CODE_SIGNING_ALLOWED=NO`), `AXIsProcessTrusted()` evaluates `false` — the ephemeral unsigned test binary has never been granted Accessibility permission — so each of these three tests takes the `guard AXIsProcessTrusted() else { return }` early-exit path and passes trivially without exercising the real dispatch. This was confirmed directly from the `.xcresult` bundle: all three completed in ~0.2ms, far too fast to have created a window, slept 150ms, and performed a real `AXUIElementPerformAction` round-trip. This is consistent with every prior phase's own documented finding for this exact isolated test environment (e.g. Phase 2X's two-window exclusivity observation test) — reported honestly here rather than claimed as a passing real-world verification.
