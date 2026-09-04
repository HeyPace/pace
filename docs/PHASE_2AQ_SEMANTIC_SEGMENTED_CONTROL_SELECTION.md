# Phase 2AQ — Semantic Segmented Control Item Selection (`ui.select_segmented_control_item`)

## Executive Summary

`ui.select_segmented_control_item` is Q's thirtieth controlled UI-interaction capability, and its **eleventh semantic mutation primitive at the application surface** (following `ui.click_element`, `ui.set_element_value`, `ui.set_element_state`, `ui.select_menu_item`, `ui.set_slider_value`, `ui.focus_element`, `ui.select_popup_item`, `ui.toggle_disclosure`, `ui.select_tab`, `ui.select_table_row`, `ui.select_outline_row`, `ui.set_window_minimized`, `ui.set_window_main`, `ui.close_window`, `ui.set_scroll_position`, and `ui.activate_application`).

This capability forms the direct operational pair to Phase 2AM's `ui.list_segmented_control_items`. When an agent inspects an `AXSegmentedControl` and discovers direct segment items (such as "List", "Icons", "Columns", or "Left", "Center", "Right"), `ui.select_segmented_control_item` allows the agent to semantically select exactly one specified segment item with deterministic targeting, stale-state protection, single-use Level 2 user authorization, idempotent no-op handling, and independent closed-loop verification.

---

## 1. Capability Contract & Security Classification

- **Capability Name**: `ui.select_segmented_control_item`
- **Tool Family**: `"ui"`
- **Risk Level**: `QRiskLevel.level2UserApproval` (Level 2 — User Approval Required, Reversible Local UI Action)
- **Schema & Arguments**:
  - `applicationName` (String, required): Exact running application target, resolved via `QBridgeAccessibility.resolveExactRunningApplication(named:)`.
  - `role` (String, optional, defaults to `"AXSegmentedControl"`): Must satisfy `QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole(role)`.
  - `controlIdentifier` / `identifier` (String, optional): Exact accessibility identifier of the segmented control.
  - `controlTitle` / `title` (String, optional): Exact title or label of the segmented control.
  - `windowTitle` (String, optional): Exact window title to narrow control search root.
  - `windowIdentifier` (String, optional): Exact window identifier to narrow control search root.
  - `segmentIdentifier` (String, optional): Exact accessibility identifier of the direct segment item.
  - `segmentTitle` / `segmentLabel` / `segment` (String, optional): Exact title/label/description of the direct segment item.
  - `desiredSelected` (Bool, optional, defaults to `"true"`): Must be `"true"`. Deselection is explicitly unsupported and fails closed (`AX_SEGMENT_DESELECTION_UNSUPPORTED`).

---

## 2. Canonical AX Hierarchy & Role Policy

### Canonical AX Tree
```
AXApplication (resolved via QBridgeAccessibility.resolveExactRunningApplication)
  └── AXWindow (optional exact container window resolved by title or identifier)
        └── AXSegmentedControl (canonical container role; AXRadioGroup and AXTabGroup strictly excluded)
              └── Direct Segment (AXRadioButton | AXButton; subrole AXTabButton strictly excluded)
```

### Role Policy Rules
1. **Container Role**: Reuses `QAXSegmentedControlRolePolicy.allowedRoles = ["AXSegmentedControl"]`.
   - `AXRadioGroup` is rejected (`AX_DISALLOWED_ROLE`), owned exclusively by `ui.list_radio_group_items` / `ui.set_element_state`.
   - `AXTabGroup` is rejected (`AX_DISALLOWED_ROLE`), owned exclusively by `ui.list_tab_items` / `ui.select_tab`.
2. **Direct Segment Role**: Filtered strictly from direct children (`Self.childrenAttribute(of: targetControlElement)`):
   - Allowed roles: `AXRadioButton`, `AXButton` (`allowedDirectSegmentRoles`).
   - Strict tab exclusion: Any direct child where `subrole == "AXTabButton"` (`NSAccessibilityTabButtonSubrole`) is excluded (`AXTabButton` is owned exclusively by `ui.select_tab`).
3. **No Arbitrary Descendants**: Traversal inspects direct child elements only; nested trees, popups, submenus, and generic containers are never traversed.

---

## 3. Exact Targeting & Stale Target Protection

1. **Exact Application Resolution**:
   - `QBridgeAccessibility.resolveExactRunningApplication(named: applicationName)`
   - 0 matches: `AX_APPLICATION_NOT_AVAILABLE`
   - 1 match: target `processIdentifier`
   - >1 matches: `AX_AMBIGUOUS_TARGET`
2. **Exact Window / Control Resolution**:
   - Matches collected via `collectMatches(root:role:identifier:title:)`.
   - Snapshot verification immediately before enumeration/dispatch: `snapshotIfMatches`.
   - If snapshot drifted between search and verification: `AX_STALE_TARGET`.
3. **Direct Segment Resolution**:
   - Matching priority: Exact `segmentIdentifier` or exact `segmentTitle`.
   - If both are provided, both must agree on the same element; conflicting/disagreeing criteria fail closed.
   - Ambiguous matches (multiple segments with identical matching attributes): `AX_AMBIGUOUS_TARGET`.
   - Target disabled check: If `isEnabled == false`, fails closed with `AX_TARGET_DISABLED`.
4. **Value Drift Check**:
   - Target selection state is read at discovery (`isSelectedSearch`).
   - Target selection state is re-read immediately before dispatch (`isSelectedVerify`).
   - If state changed between discovery and dispatch: `AX_VALUE_DRIFT_DETECTED`.

---

## 4. Selection & Mutation Semantics

1. **Selection Only (Not a Toggle)**:
   - The capability expresses: target selection = `true`.
   - `desiredSelected: false` is rejected before any mutation (`AX_SEGMENT_DESELECTION_UNSUPPORTED`).
2. **Idempotent No-Op**:
   - If the target segment is already selected (`isSelectedVerify == desiredSelected`):
     - Returns `QAXSegmentedControlSelectionOutcome(changeKind: .alreadyDesired, ...)` immediately.
     - Zero mutation calls (`AXUIElementPerformAction`) are issued.
     - No user approval grant is consumed.
3. **Semantic AX Mutation**:
   - `AXUIElementPerformAction(targetSegment, kAXPressAction as CFString)`
   - Zero physical input simulation (`CGEvent`, `NSEvent`, mouse, keyboard, coordinates).
   - Zero external scripts (`AppleScript`, `osascript`, shell, subprocesses).

---

## 5. Closed-Loop Verification

Mutation acceptance (`.success` from `AXUIElementPerformAction`) is **not** proof of completion.

1. **Independent Verification Strategy**:
   - `QVerificationStrategy.axSegmentedControlSelectionMatchesDesired(...)`
   - Re-resolves application, window, segmented control, and segment fresh via `QBridgeAccessibility.observeSegmentedControlSelectionEvidence(...)`.
   - Reads authoritative selection state (`kAXSelectedAttribute` or `kAXValueAttribute` radio state).
2. **Verification Outcomes**:
   - `.resolved(currentSelected)`:
     - `currentSelected == desiredSelected` -> `.verified`
     - `currentSelected != desiredSelected` -> `.failed`
   - `.stateUnreadable` -> `.failed` (unreadable state fails closed)
   - `.targetUnavailable` -> `.failed` (missing or ambiguous element fails closed)

---

## 6. Authorization Architecture

- Reuses existing security components: `QApprovalCoordinator`, `QPermissionGate`, `QExecutionIdentity`.
- **Single-Use**: Approval grant is bound to exact `executionIdentity.stepFingerprint` and consumed upon execution.
- **Non-Persistent**: In-memory grants never survive restart, crashes, or recovery replay.
- **Strict Risk Enforcement**: Level 2 cannot be bypassed or downgraded by the model.

---

## 7. Observation-First Recovery

In `QTaskRecoveryManager.resolveUncertainStep`:
1. **Crash before mutation**: Target segment remains unselected; observation fails verification; task is marked `.pending` requiring fresh execution and fresh Level 2 approval.
2. **Crash after mutation**: Independent observation confirms `currentSelected == desiredSelected`; step is recognized as verified without blind replay.
3. **Uncertain / Unresolvable state**: Falls closed to `.pending`; never blindly replays the press.

---

## 8. Privacy & Data Safety

- **Ephemeral Output Only**: Segment titles and identifiers remain in ephemeral `outputData` for agent reasoning.
- **Durable Snapshot Safety**: `QDurablePlanStepSnapshot` excludes `outputData`; raw segment metadata is never written to SQLite WAL memory or durable audit logs.
- **Aggregate Summary**: Result summaries report aggregate information only (`"Segmented control item selection attempted for ..."`).

---

## 9. Resource & Budget Bounds

- Bounded child enumeration: `maxDirectSegmentsCount = 32`.
- `QAgentBudget`: Limits step count and replan iterations.
- `QResourceGuard`: Enforces filesystem safety boundaries.
- Zero recursive traversals.

---

## 10. Test Coverage & Verification

### Test Suite: `QSemanticSegmentedControlSelectionTests` (35 Tests)
1. `capabilityRegistrationToolFamily`: Registered under toolFamily "ui"
2. `capabilityRegistrationRiskLevel`: Level 2 User Approval Required
3. `planParserAcceptsValidStep`: Model plan parser accepts valid step
4. `planParserRejectsRiskLevelMismatch`: Parser rejects risk level mismatch
5. `missingApplicationNameFailsClosed`: Missing applicationName fails closed
6. `nonExistentApplicationFailsClosed`: Non-existent app fails closed
7. `missingMatchCriteriaFailsClosed`: Missing segment match criteria fails closed
8. `disallowedContainerRoleFailsClosed`: AXRadioGroup rejected
9. `deselectionUnsupportedFailsClosed`: desiredSelected: false rejected
10. `invalidDesiredSelectedFailsClosed`: Invalid desiredSelected string rejected
11. `rolePolicyAllowsSegmentedControlOnly`: QAXSegmentedControlRolePolicy allowlist
12. `directSegmentRejectsTabButtonSubrole`: AXTabButton subrole excluded
13. `permissionGateRequiresApproval`: Level 2 evaluated by QPermissionGate
14. `approvalSingleUseAndBound`: Single-use consumption bound to fingerprint
15. `wrongExecutionIdentityCannotConsumeGrant`: Execution identity isolation
16. `alreadySelectedIsIdempotentNoOp`: Already selected returns changeKind: .alreadyDesired
17. `disabledSegmentIsRejected`: Disabled segment fails closed with targetDisabled
18. `duplicateTitleAmbiguityFailsClosed`: Duplicate titles fail closed with ambiguousTarget
19. `identifierTitleMismatchFailsClosed`: Disagreeing identifier and title fail closed
20. `actionVerifierVerifiesMatchingEvidence`: Closed-loop verification logic
21. `actionVerifierFailsOnFailedResult`: Verifier fails on failed execution
22. `recoveryVerifiesAlreadySelectedSegment`: Observation-first recovery
23. `durableSnapshotExcludesRawOutputData`: Privacy protection in durable state
24. `planExecutorPausesAwaitingApproval`: Level 2 approval pause in plan executor
25. `realAppKitSegmentedControlSelection`: Real NSSegmentedControl AppKit E2E
26. `targetResolutionWithIdentifierOnly`: Segment resolution with identifier only
27. `targetResolutionWithTitleOnly`: Segment resolution with title only
28. `targetSegmentWithAXButtonRoleIsAllowed`: AXButton segment role supported
29. `missingWindowFailsClosed`: Missing container window fails closed
30. `observeSelectionEvidenceReturnsResolved`: Evidence resolution helper on live fixture
31. `observeSelectionEvidenceReturnsTargetUnavailable`: Missing target returns unavailable
32. `recoveryManagerVerifiesLiveFixture`: Recovery on live AppKit fixture
33. `agentBudgetEnforcement`: QAgentBudget bounds enforcement
34. `resourceGuardEnforcement`: QResourceGuard denylist enforcement
35. `closedLoopVerificationMatchesLiveFixture`: Closed-loop verification with live fixture

---

## 11. Forbidden API Audit

An automated scan of all modified code and tests confirms zero usage of:
- `CGEvent`, `NSEvent`, `CGDisplay`, mouse/keyboard simulation
- `click(at:)`, `move(to:)`, coordinate-based interaction
- `AppleScript`, `osascript`, `Process`, `NSTask`, shell subprocesses
- `NSPasteboard` (for segmented selection), `URLSession`, `NWConnection`
- `ScreenCaptureKit`, `Vision`, `OCR`

---

## 12. Build & Binary Integrity

- **Architecture**: Universal Mach-O (arm64 + x86_64)
- **Build Mode**: ARM64 Release Build (`xcodebuild -configuration Release ...`)
- **Codesigning**: Valid ad-hoc developer signature preserved.
