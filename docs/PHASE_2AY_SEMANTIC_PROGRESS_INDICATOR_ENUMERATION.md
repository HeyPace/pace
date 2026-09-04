# Phase 2AY: Semantic Progress Indicator Enumeration (`ui.list_progress_indicators`)

## 1. Executive Summary

Phase 2AY introduces **Semantic Progress Indicator Enumeration** (`ui.list_progress_indicators`), an authoritative Level 0 (Read-Only) semantic Accessibility capability for discovering, inspecting, and observing progress indicator elements (`AXProgressIndicator` and `AXBusyIndicator`) within macOS application hierarchies.

In AppKit, `NSProgressIndicator` controls expose either `AXProgressIndicator` (determinate mode) or `AXBusyIndicator` (indeterminate / spinning mode). By supporting both roles under strict semantic policy and bounds, `ui.list_progress_indicators` enables agents to reliably discover determinate progress meters (with value, min, max, percentage) and indeterminate activity spinners without relying on coordinate scraping or fragile OCR.

---

## 2. Capability Specification

- **Capability Identifier**: `ui.list_progress_indicators`
- **Domain**: `ui`
- **Security Level**: `Level 0 (Read-Only)`
- **Human Approval**: Not required (Read-Only observation)
- **Primary AX Roles**: `AXProgressIndicator`, `AXBusyIndicator`
- **Primary AX Attributes**:
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `kAXTitleAttribute`
  - `kAXDescriptionAttribute`
  - `kAXIdentifierAttribute`
  - `kAXValueAttribute` (progress value, e.g. `Double`)
  - `kAXMinValueAttribute` (minimum value)
  - `kAXMaxValueAttribute` (maximum value)
  - `kAXEnabledAttribute`
  - `kAXVisibleChildrenAttribute` / `kAXChildrenAttribute` / `kAXWindowsAttribute`
- **Primary AX Actions**: None (Read-Only observation)
- **Deterministic Identity**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)` requiring exact single match.

---

## 3. Architecture and Implementation

### 3.1 Model Plan Schema Registration
Registered in `QModelPlanSchema.swift`:
```swift
"ui.list_progress_indicators": ("ui", .level0ReadOnly)
```

### 3.2 Role Policy & Bound Safety
In `QBridgeAdapters.swift`:
- `QAXProgressIndicatorRolePolicy`: Allows `AXProgressIndicator` and `AXBusyIndicator`.
- Max direct indicator count bound: `maxDirectProgressIndicatorsCount = 32`.
- Max hierarchy traversal depth bound: `maxProgressIndicatorTraversalDepth = 10`.
- Max visited elements bound: `maxProgressIndicatorTraversalElements = 150`.

### 3.3 Structured Metadata
`QAXProgressIndicatorMetadata`:
- `role`: String (`AXProgressIndicator` or `AXBusyIndicator`)
- `identifier`: Optional<String>
- `title`: Optional<String>
- `description`: Optional<String>
- `value`: Optional<Double> (determinate progress value)
- `minValue`: Optional<Double>
- `maxValue`: Optional<Double>
- `isIndeterminate`: Bool
- `isEnabled`: Bool

`QAXProgressIndicatorCollectionMetadata`:
- `applicationName`: String
- `processIdentifier`: pid_t
- `progressIndicators`: [QAXProgressIndicatorMetadata]
- `count`: Int

### 3.4 Verification Strategy
Registered in `QActionVerification.swift` and `QPlanExecutor.swift`:
- `QVerificationStrategy.progressIndicatorEnumerationSucceeded(applicationName:indicatorCount:)`
- Verifies exact application name match and non-negative indicator count consistency in plan execution logs.

---

## 4. Security & Safety Properties

1. **Zero Physical Automation**: No `CGEvent`, `NSEvent`, mouse/keyboard synthesis, coordinates, AppleScript, or shell commands.
2. **Deterministic Targeting**: Rejects empty, zero-match, or ambiguous application targets.
3. **Fail-Closed Safety**: Any unexpected role, cyclic structure, or unbounded tree triggers safe containment and fail-closed handling.
4. **Privacy First**: No raw `AXUIElement` pointers or sensitive text content persisted across executions.
5. **No Standing Grants**: Read-only observation with zero privilege escalation.

---

## 5. Verification & Test Evidence

- **Focused Test Suite**: `QSemanticProgressIndicatorEnumerationTests.swift` (19 test cases)
  - Application resolution (exact, zero match, ambiguity)
  - Role policy enforcement (`AXProgressIndicator`, `AXBusyIndicator`, disallowed roles)
  - Determinate progress indicator metadata extraction (value, min, max)
  - Indeterminate busy indicator metadata extraction
  - Resource bounds enforcement (result limit, depth limit)
  - Verification strategy matching and failure handling
  - Privacy and forbidden API scanning
- **Relevant Regression Suites**:
  - `QSemanticColorWellEnumerationTests`
  - `QSemanticPopoverEnumerationTests`
  - `QSemanticSheetDialogEnumerationTests`
- **Release Build**: Validated arm64 Mach-O binary and code signature.
