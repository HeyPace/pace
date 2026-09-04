# Phase 2BC — Semantic Ruler Enumeration (`ui.list_rulers`)

## Overview

Phase 2BC introduces `ui.list_rulers`, providing secure, read-only semantic enumeration of ruler views and markers (`NSRulerView` / `AXRuler` / `AXRulerMarker`) across macOS application accessibility hierarchies.

## Baseline & Context

- **Baseline Commit**: `78de5e1` (`feat: add semantic combo box enumeration`)
- **Capability Identifier**: `ui.list_rulers`
- **Security Level**: `Level 0` (Read-Only)
- **Authoritative Capability Count**: `50` → `51`

## Accessibility Contract & Architecture

- **AX Role**: `kAXRulerRole` (`"AXRuler"`)
- **AX Role Policy**: `QAXRulerRolePolicy` strictly restricts target elements to `"AXRuler"`.
- **Supported Attributes**:
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `kAXTitleAttribute`
  - `kAXDescriptionAttribute`
  - `kAXHelpAttribute`
  - `kAXIdentifierAttribute`
  - `kAXOrientationAttribute` (e.g. `"AXHorizontalOrientation"`, `"AXVerticalOrientation"`)
  - `kAXUnitDescriptionAttribute` (e.g. `"Inches"`, `"Centimeters"`, `"Points"`, `"Picas"`)
  - `kAXChildrenAttribute` (ruler markers `AXRulerMarker`)
  - `kAXEnabledAttribute` (Bool)
- **Target Resolution**: Deterministic single-match via `QBridgeAccessibility.resolveExactRunningApplication(named:)`.
- **Closed-Loop Verification**: `QVerificationStrategy.rulerEnumerationSucceeded(applicationName:rulerCount:)` with structured count validation.

## Security & Resource Guarding

- **Read-Only / Non-Mutating**: Zero mutation or state changes.
- **Traversal Limits**:
  - `maxDepth = 12`
  - `maxNodes = 600`
  - `maxDirectRulersCount = 32`
- **Zero Physical Automation**: No `CGEvent`, `NSEvent`, mouse/coordinate clicking, `osascript`, `AppleScript`, or shell process invocation.
- **Privacy & Memory Safety**: No raw `AXUIElement` persistence or sensitive text retention.

## Verification & Test Strategy

- **Test Suite**: `QSemanticRulerEnumerationTests.swift` (19 test cases)
- **Coverage Areas**:
  - Schema registration and Level 0 classification
  - Role policy enforcement (`AXRuler` permitted, foreign roles rejected)
  - Metadata parsing, orientation, unit description, marker count, enabled state, and identification
  - Traversal bounds and collection capping
  - Application resolution (exact single match, zero match, ambiguity)
  - Closed-Loop verification strategy matching and mismatch handling
  - Execution dispatch and error handling
  - Real AppKit `NSRulerView` fixture and live AX E2E test
