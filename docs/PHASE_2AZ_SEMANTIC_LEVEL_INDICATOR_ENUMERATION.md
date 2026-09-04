# Phase 2AZ: Semantic Level Indicator Enumeration (`ui.list_level_indicators`)

## 1. Executive Summary

Phase 2AZ introduces **Semantic Level Indicator Enumeration** (`ui.list_level_indicators`), an authoritative Level 0 (Read-Only) semantic Accessibility capability for discovering, inspecting, and observing level indicator and relevance indicator elements (`AXLevelIndicator` and `AXRelevanceIndicator`) within macOS application hierarchies.

In AppKit, `NSLevelIndicator` controls expose `AXLevelIndicator` (discrete/continuous capacity, rating, tier) and `AXRelevanceIndicator` (relevance and search ranking meters). By supporting both roles under strict semantic policy and bounds, `ui.list_level_indicators` enables agents to reliably inspect level values, min/max ranges, warning/critical thresholds, titles, and identifiers without relying on coordinate scraping or fragile OCR.

---

## 2. Capability Specification

- **Capability Identifier**: `ui.list_level_indicators`
- **Domain**: `ui`
- **Security Level**: `Level 0 (Read-Only)`
- **Human Approval**: Not required (Read-Only observation)
- **Primary AX Roles**: `AXLevelIndicator`, `AXRelevanceIndicator`
- **Primary AX Attributes**:
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `kAXTitleAttribute`
  - `kAXDescriptionAttribute`
  - `kAXIdentifierAttribute`
  - `kAXValueAttribute` (current level value, e.g. `Double`)
  - `kAXMinValueAttribute` (minimum value)
  - `kAXMaxValueAttribute` (maximum value)
  - `kAXWarningValueAttribute` (warning threshold value)
  - `kAXCriticalValueAttribute` (critical threshold value)
  - `kAXEnabledAttribute`
  - `kAXVisibleChildrenAttribute` / `kAXChildrenAttribute` / `kAXWindowsAttribute`
- **Primary AX Actions**: None (Read-Only observation)
- **Deterministic Identity**: Exact application resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)` requiring exact single match.

---

## 3. Architecture and Implementation

### 3.1 Model Plan Schema Registration
Registered in `QModelPlanSchema.swift`:
```swift
"ui.list_level_indicators": ("ui", .level0ReadOnly)
```

### 3.2 Role Policy & Bound Safety
In `QBridgeAdapters.swift`:
- `QAXLevelIndicatorRolePolicy`: Allows `AXLevelIndicator` and `AXRelevanceIndicator`.
- Max direct indicator count bound: `maxDirectLevelIndicatorsCount = 32`.
- Max hierarchy traversal depth bound: `maxLevelIndicatorTraversalDepth = 10`.
- Max visited elements bound: `maxLevelIndicatorTraversalElements = 150`.

### 3.3 Structured Metadata
`QAXLevelIndicatorMetadata`:
- `role`: String (`AXLevelIndicator` or `AXRelevanceIndicator`)
- `identifier`: Optional<String>
- `title`: Optional<String>
- `description`: Optional<String>
- `value`: Optional<Double> (numeric level value)
- `minValue`: Optional<Double>
- `maxValue`: Optional<Double>
- `warningValue`: Optional<Double>
- `criticalValue`: Optional<Double>
- `isEnabled`: Optional<Bool>

`QAXLevelIndicatorCollectionMetadata`:
- `applicationName`: String
- `processIdentifier`: pid_t
- `windowTitle`: Optional<String>
- `indicators`: [QAXLevelIndicatorMetadata]
- `indicatorCount`: Int

### 3.4 Verification Strategy
Registered in `QActionVerification.swift` and `QPlanExecutor.swift`:
- `QVerificationStrategy.levelIndicatorEnumerationSucceeded(applicationName:indicatorCount:)`
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

- **Focused Test Suite**: `QSemanticLevelIndicatorEnumerationTests.swift` (19 test cases)
  - Application resolution (exact, zero match, ambiguity)
  - Role policy enforcement (`AXLevelIndicator`, `AXRelevanceIndicator`, disallowed roles)
  - Determinate level indicator metadata extraction (value, min, max, warning, critical)
  - Resource bounds enforcement (result limit, depth limit)
  - Verification strategy matching and failure handling
  - Privacy and forbidden API scanning
- **Relevant Regression Suites**:
  - `QSemanticProgressIndicatorEnumerationTests`
  - `QSemanticColorWellEnumerationTests`
  - `QSemanticPopoverEnumerationTests`
- **Release Build**: Validated arm64 Mach-O binary and code signature.
