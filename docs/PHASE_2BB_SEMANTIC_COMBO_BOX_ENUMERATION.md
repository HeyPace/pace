# Phase 2BB — Semantic Combo Box Enumeration (`ui.list_combo_boxes`)

## Overview

Phase 2BB introduces `ui.list_combo_boxes`, providing secure, read-only semantic enumeration of combo box controls (`NSComboBox` / `AXComboBox`) across macOS application accessibility hierarchies.

## Baseline & Context

- **Baseline Commit**: `b6b950c` (`feat: add semantic incrementor enumeration`)
- **Capability Identifier**: `ui.list_combo_boxes`
- **Security Level**: `Level 0` (Read-Only)
- **Authoritative Capability Count**: `49` → `50`

## Accessibility Contract & Architecture

- **AX Role**: `kAXComboBoxRole` (`"AXComboBox"`)
- **AX Role Policy**: `QAXComboBoxRolePolicy` strictly restricts target elements to `"AXComboBox"`.
- **Supported Attributes**:
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `kAXTitleAttribute`
  - `kAXDescriptionAttribute`
  - `kAXHelpAttribute`
  - `kAXIdentifierAttribute`
  - `kAXValueAttribute` (String representation)
  - `AXPlaceholderValue` (String representation)
  - `kAXEnabledAttribute` (Bool)
- **Settable Attribute Check**: `AXUIElementIsAttributeSettable` on `kAXValueAttribute`.
- **Target Resolution**: Deterministic single-match via `QBridgeAccessibility.resolveExactRunningApplication(named:)`.
- **Closed-Loop Verification**: `QVerificationStrategy.comboBoxEnumerationSucceeded(applicationName:comboBoxCount:)` with structured count validation.

## Security & Resource Guarding

- **Read-Only / Non-Mutating**: Zero mutation or state changes.
- **Traversal Limits**:
  - `maxDepth = 12`
  - `maxNodes = 600`
  - `maxDirectComboBoxesCount = 32`
- **Zero Physical Automation**: No `CGEvent`, `NSEvent`, mouse/coordinate clicking, `osascript`, `AppleScript`, or shell process invocation.
- **Privacy & Memory Safety**: No raw `AXUIElement` persistence or sensitive text retention.

## Verification & Test Strategy

- **Test Suite**: `QSemanticComboBoxEnumerationTests.swift` (19 test cases)
- **Coverage Areas**:
  - Schema registration and Level 0 classification
  - Role policy enforcement (`AXComboBox` permitted, foreign roles rejected)
  - Metadata parsing, text value, placeholder, enabled state, settable state, and identification
  - Traversal bounds and collection capping
  - Application resolution (exact single match, zero match, ambiguity)
  - Closed-Loop verification strategy matching and mismatch handling
  - Execution dispatch and error handling
  - Real AppKit `NSComboBox` fixture and live AX E2E test
