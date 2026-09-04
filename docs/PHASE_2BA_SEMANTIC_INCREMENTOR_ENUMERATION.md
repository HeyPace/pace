# Phase 2BA — Semantic Stepper / Incrementor Enumeration (`ui.list_incrementors`)

## Overview

Phase 2BA introduces `ui.list_incrementors`, providing secure, read-only semantic enumeration of stepper / incrementor controls (`NSStepper` / `AXIncrementor`) across macOS application accessibility hierarchies.

## Baseline & Context

- **Baseline Commit**: `0ad7f0f` (`feat: add semantic level indicator enumeration`)
- **Capability Identifier**: `ui.list_incrementors`
- **Security Level**: `Level 0` (Read-Only)
- **Authoritative Capability Count**: `48` → `49`

## Accessibility Contract & Architecture

- **AX Role**: `kAXIncrementorRole` (`"AXIncrementor"`)
- **AX Role Policy**: `QAXIncrementorRolePolicy` strictly restricts target elements to `"AXIncrementor"`.
- **Supported Attributes**:
  - `kAXRoleAttribute`
  - `kAXSubroleAttribute`
  - `kAXTitleAttribute`
  - `kAXDescriptionAttribute`
  - `kAXHelpAttribute`
  - `kAXIdentifierAttribute`
  - `kAXValueAttribute` (Double / Number)
  - `kAXMinValueAttribute` (Double / Number)
  - `kAXMaxValueAttribute` (Double / Number)
  - `kAXEnabledAttribute` (Bool)
- **Children Structure**: `AXIncrementArrow` / `AXDecrementArrow` sub-controls (observed semantically).
- **Target Resolution**: Deterministic single-match via `QBridgeAccessibility.resolveExactRunningApplication(named:)`.
- **Closed-Loop Verification**: `QVerificationStrategy.incrementorEnumerationSucceeded(applicationName:incrementorCount:)` with structured count validation.

## Security & Resource Guarding

- **Read-Only / Non-Mutating**: Zero mutation or state changes.
- **Traversal Limits**:
  - `maxDepth = 12`
  - `maxNodes = 600`
  - `maxDirectIncrementorsCount = 32`
- **Zero Physical Automation**: No `CGEvent`, `NSEvent`, mouse/coordinate clicking, `osascript`, `AppleScript`, or shell process invocation.
- **Privacy & Memory Safety**: No raw `AXUIElement` persistence or sensitive text retention.

## Verification & Test Strategy

- **Test Suite**: `QSemanticIncrementorEnumerationTests.swift` (19 test cases)
- **Coverage Areas**:
  - Schema registration and Level 0 classification
  - Role policy enforcement (`AXIncrementor` permitted, foreign roles rejected)
  - Metadata parsing, values, min/max range limits, enabled state, and identification
  - Traversal bounds and collection capping
  - Application resolution (exact single match, zero match, ambiguity)
  - Closed-loop verification strategy matching and mismatch handling
  - Execution dispatch and error handling
  - Real AppKit `NSStepper` fixture and live AX E2E test
