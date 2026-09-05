# Phase 2BE — Semantic Combo Box Item Selection (`ui.select_combo_box_item`)

## Overview
- **Capability Identifier**: `ui.select_combo_box_item`
- **Tool Family**: `ui`
- **Risk Level**: Level 2 User Approval Required (`.level2UserApproval`)
- **Baseline Commit**: `401c66a`
- **Pre-Phase Capability Count**: `52`
- **Post-Phase Capability Count**: `53`
- **Mutability**: Mutating Local Action (Reversible Local Action)
- **User Approval**: Explicit single-use user approval bound to exact execution identity
- **Recovery Requirement**: Observe-first recovery before replay; fresh verification after change.

---

## Semantic Accessibility & AppKit Contract
- **Target Element**: `AXComboBox` (`kAXComboBoxRole`)
- **Role Policy**: `QAXComboBoxRolePolicy.allowedRoles = ["AXComboBox"]` (strictly fails closed on any other role).
- **Target Attributes**:
  - `kAXRoleAttribute`
  - `kAXTitleAttribute` / `kAXDescriptionAttribute`
  - `AXIdentifier`
  - `kAXValueAttribute` (current selected text value)
  - `kAXEnabledAttribute`
  - `kAXChildrenAttribute` (child item elements for index-based selection)
- **Mutation Mechanism**:
  - Direct value write: `AXUIElementSetAttributeValue(targetElement, kAXValueAttribute, desiredValue)`
  - Direct title selection (`itemTitle`) or index-based resolution (`itemIndex` via child elements).
  - Idempotent: If current `kAXValueAttribute` matches `desiredValue`, returns `changeKind: .alreadySelected` without mutation.
  - Value drift protection: Pre-flight re-read ensures current value has not changed between search and dispatch.
  - Stale target protection: Snapshot check guarantees element identity remains identical immediately before write.
  - Post-mutation verification: Independent immediate re-read of `kAXValueAttribute` confirms change succeeded.

---

## Deterministic Targeting & Execution Model
1. **Application Resolution**: Exact matching via `QBridgeAccessibility.resolveExactRunningApplication(named:)`. Fails closed on zero matches (`applicationNotAvailable`) or multiple matches (`ambiguousTarget`).
2. **Window Resolution**: Optional exact window resolution by `windowTitle` or `windowIdentifier`.
3. **Control Resolution**: Target combo box matching by `role` (must be `AXComboBox`), and at least one of `identifier` or `title`. Fails closed on missing match criteria or multiple matching elements (`ambiguousTarget`).
4. **Child Item Resolution**: If `itemIndex` is specified, direct children and container (`AXList`/`AXMenu`) are traversed to find the item at the target index (bounded ceiling: 128 items), and its semantic title is extracted.
5. **Execution Identity**: Computed from capability name, application name, window title, control identifier/title, and requested item title/index. Tokens are single-use with zero standing grants.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.axComboBoxValueMatchesDesired(applicationName: String, role: String, matchIdentifier: String?, matchTitle: String?, targetIdentity: String, requestedItemTitle: String)`
- **Evaluation**: Re-resolves target combo box fresh and verifies `kAXValueAttribute == requestedItemTitle`.
- **Evidence**: `target=<targetIdentity> currentValue=<val> requestedItemTitle=<val> status=verified` (fails closed as `status=failed` if target becomes unavailable).

---

## Privacy & Security Architecture
- **No Durable Pointer Leaks**: `targetIdentity` contains application name, window title, role, identifier, and label only — never raw pointers, memory addresses, or screen coordinates.
- **Fail-Closed Permissions**: AX trusted process check (`AXIsProcessTrusted()`) enforced before any AX tree interaction.
- **Zero Physical Automation**: Strictly NO `CGEvent`, `NSEvent`, keyboard simulation, mouse clicking, coordinate clicking, AppleScript, `osascript`, `Process(`, or `/bin/sh`.

---

## Test Coverage (`QSemanticComboBoxSelectionTests.swift`)
26+ focused unit tests:
1. `ui.select_combo_box_item` registered under toolFamily `ui`
2. Level 2 User Approval Required classification
3. Plan parsing with valid `itemTitle`
4. Plan parsing with valid `itemIndex`
5. Rejection of risk level override
6. Missing application name fails closed
7. Non-existent application fails closed
8. Missing selection criteria fails closed
9. Malformed `itemIndex` parameter fails closed
10. Disallowed role `AXPopUpButton` rejected
11. Disallowed role `AXButton` rejected
12. `QAXComboBoxRolePolicy` strict enforcement
13. `QAXComboBoxSelectionOutcome` structure and change kinds
14. `QAXComboBoxValueEvidence` enum cases
15. Verification strategy closed-loop evaluation
16. Plan executor verification strategy mapping
17. Permission gate explicit approval requirement
18. Single-use execution approval token
19. Execution identity binding
20. Durable state privacy boundary
21. Non-existent window target fails closed
22. Task recovery manager observation-first model
23. Idempotent `alreadySelected` outcome handling
24. Audit logging with Level 2 risk
25. Real macOS accessibility probe
26. Forbidden physical automation audit
