# Phase 2BD — Semantic Combo Box Item Enumeration (`ui.list_combo_box_items`)

## Overview
- **Capability Identifier**: `ui.list_combo_box_items`
- **Tool Family**: `ui`
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `8b43477`
- **Pre-Phase Capability Count**: `51`
- **Post-Phase Capability Count**: `52`
- **Mutability**: Strictly Non-Mutating / Read-Only Observation
- **User Approval**: None required (Level 0)
- **Recovery Requirement**: Pure observation-only; no approval or state replay across restarts.

---

## Semantic Accessibility & AppKit Contract
- **Target Element**: `AXComboBox` (`kAXComboBoxRole`)
- **Role Policy**: `QAXComboBoxRolePolicy.allowedRoles = ["AXComboBox"]`
- **Target Attributes**:
  - `kAXRoleAttribute`
  - `kAXTitleAttribute` / `kAXDescriptionAttribute`
  - `AXIdentifier`
  - `kAXValueAttribute` (current selected text value)
  - `kAXEnabledAttribute`
  - `kAXExpandedAttribute`
  - `kAXChildrenAttribute` (child `AXList` / `AXMenu` or direct child elements)
  - `kAXSelectedAttribute`
- **Child Items Traversal**:
  - Bounded lookup in direct children or nested `AXList`/`AXMenu` container.
  - Safe extraction of title, index, and selection state.
  - Defensive safe ceiling: `maxDirectComboBoxItemsCount = 128`.

---

## Deterministic Targeting & Execution Model
1. **Application Resolution**: Exact matching via `QBridgeAccessibility.resolveExactRunningApplication(named:)`. Fails closed on zero matches (`applicationNotAvailable`) or multiple matches (`ambiguousTarget`).
2. **Window Resolution**: Optional exact window resolution by `windowTitle` or `windowIdentifier`.
3. **Control Resolution**: Target combo box matching by `role` (must be `AXComboBox`), and at least one of `identifier` or `title`. Fails closed on missing match criteria (`missingMatchCriteria`) or multiple matching elements (`ambiguousTarget`).
4. **Point-in-Time Snapshot**: The returned structure is informational only, bounded, and ephemeral. It does not confer standing authorization and is never persisted into durable storage.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.comboBoxItemEnumerationSucceeded(applicationName: String, itemCount: Int)`
- **Evaluation**: Validates that execution succeeded and captured aggregate count. Evidence string carries aggregate counts only (`application=<name> comboBoxRole=AXComboBox itemCount=<count> status=verified`), never leaking sensitive text values.

---

## Privacy & Security Architecture
- **No Durable Leaks**: Raw items remain ephemeral in `outputData`; neither SQLite WAL, audit logs, memory, nor HUD persist raw items.
- **Fail-Closed**: Non-trusted AX processes receive `accessibilityPermissionDenied`.
- **Zero Physical Automation**: Absolutely no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate clicking, or AppleScript.

---

## Focused Test Coverage (`QSemanticComboBoxItemEnumerationTests.swift`)
20 focused unit tests passing:
1. `ui.list_combo_box_items` registered under toolFamily `ui`
2. Level 0 Read-Only by default
3. Plan parsing with valid parameters
4. Plan parsing without approval requirement
5. Missing application name fails closed
6. Disallowed roles rejected
7. Missing match criteria fails closed
8. Non-existent application throws
9. Non-existent window target fails closed
10. Error enum safety codes
11. Metadata model structures and codable contract
12. Empty combo box items collection handling
13. Verification evidence carries aggregate counts only (privacy boundary)
14. Verification fails closed on unsuccessful result
15. Durable plan step snapshot omits raw outputData
16. Security isolation from mutating capabilities (`ui.click_element`)
17. Sequential plan execution to completion
18. Sequential plan execution on empty combo box
19. Real macOS accessibility probe
20. Forbidden physical automation audit
