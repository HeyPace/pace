# Phase 2AS — Semantic Window Full-Screen State

## 1. Executive Summary

Phase 2AS implements the deterministic semantic capability `ui.set_window_full_screen` in the Q × PACE runtime. This capability allows an authorized agent to transition an exact target application's exact `AXWindow` into an explicit target full-screen state (`desiredFullScreen: Bool`), supporting both directions (`false -> true` and `true -> false`) with strict idempotency, pre-mutation writability validation, closed-loop independent verification, observation-first crash recovery, and Level 2 approval enforcement.

---

## 2. Capability Specification

- **Identifier**: `ui.set_window_full_screen`
- **Security Level**: Level 2 (`level2UserApproval` — User Approval Required)
- **Domain**: `ui`
- **Parameters**:
  - `applicationName: String` (exact application name)
  - `windowTitle: String?` (optional exact window title)
  - `windowIndex: Int?` (optional exact window index)
  - `desiredFullScreen: Bool` (explicit boolean target full-screen state)

---

## 3. Architecture & Resolution Flow

### 3.1 Exact Target Resolution
1. **Application Resolution**:
   Uses the canonical `QBridgeAccessibility.resolveExactRunningApplication(named:)` to resolve the target `NSRunningApplication` by exact localized name or bundle identifier. Fails closed if 0 or multiple ambiguous instances match.
2. **Window Resolution**:
   Uses the canonical exact window resolver matching `kAXWindowRole` (`"AXWindow"`). Rejects elements lacking the `AXWindow` role. Fails closed if 0 or multiple ambiguous candidates match.

### 3.2 State Source & Writability Validation
- **Attribute**: `kAXFullScreenAttribute` (`"AXFullScreen"`).
- **Settability**: Evaluated prior to mutation using `AXUIElementIsAttributeSettable(element, "AXFullScreen" as CFString, &isSettable)`. If not settable, the operation fails closed with `QAXInteractionError.windowFullScreenNotWritable` without attempting mutation.

### 3.3 Semantic Mutation
- **Mutation Path**:
  ```swift
  AXUIElementSetAttributeValue(
      windowElement,
      "AXFullScreen" as CFString,
      desiredFullScreen as CFBoolean
  )
  ```
- **Forbidden Mechanisms**:
  - NO `NSWindow.toggleFullScreen()`
  - NO `CGEvent` or `NSEvent` synthesis
  - NO mouse simulation or coordinate clicking (e.g. green traffic-light zoom button)
  - NO keyboard shortcut simulation (`Cmd+Ctrl+F`)
  - NO AppleScript, `osascript`, or shell process invocations

### 3.4 Idempotency
Before mutation, the current attribute value is read:
- If `observedFullScreen == desiredFullScreen`, returns `.alreadyInDesiredState` immediately without issuing an AX mutation.

### 3.5 Closed-Loop Verification
- Implemented via `QVerificationStrategy.axWindowFullScreenMatchesDesired(applicationName:windowTitle:windowIndex:desiredFullScreen:)`.
- Freshly resolves the application and target `AXWindow`, independently queries `"AXFullScreen"`, and verifies `observed == desiredFullScreen`.
- Returns verified evidence (`QAXWindowFullScreenEvidence`).

---

## 4. Security, Approval & Recovery

### 4.1 Level 2 Approval
- Execution requires explicit user approval through `QPlanExecutor`, `QApprovalCoordinator`, and `QPermissionGate`.
- Approval is strictly single-use and cryptographically bound to the exact capability identifier, risk level (Level 2), and execution identity (`planId` + `stepIndex`).
- Stale or reused approvals fail closed.

### 4.2 Observation-First Recovery
- On recovery after interruption or crash:
  1. `QTaskRecoveryManager` inspects the live environment to observe current `"AXFullScreen"` state.
  2. If `observed == desiredFullScreen`, the step is marked complete without re-executing mutation or requiring new approval.
  3. If not in desired state, a fresh execution identity is generated and new approval is required.
  4. Ambiguous or unresolvable states fail closed.

---

## 5. Privacy & Resource Bounds

- **Privacy**: Retains and logs only minimal structured evidence (`QAXWindowFullScreenEvidence`). Raw `AXUIElement` references are never persisted, serialized, or stored in durable journals.
- **Resource Bounds**: All resolution and verification operations execute with bounded polling and timeouts. Unbounded loops are strictly prevented.

---

## 6. Verification & Test Evidence

### 6.1 Focused Suite (`QSemanticWindowFullScreenStateTests`)
- **Total Tests**: 25
- **Passed**: 25 (100%)
- **Test Categories**:
  - Schema registration & Level 2 security classification
  - Application resolution & error fail-closed handling
  - Window role validation & ambiguity rejection
  - Settability / writability validation
  - Symmetrical state transitions (`false -> true`, `true -> false`)
  - Idempotency & pre-mutation short-circuiting
  - Mutation failure fail-closed handling
  - Independent closed-loop verification & mismatch rejection
  - Execution approval binding & reuse prevention
  - Observation-first crash recovery
  - Privacy / evidence non-leakage
  - Forbidden API static regression verification
  - AppKit fixture real macOS E2E test with honest environment guards

### 6.2 Regression Testing
- **Full Test Suite**: 2607 tests across 233 suites.
- **Consecutive Runs**:
  - Run 1: 2607 passed, 0 failed.
  - Run 2: 2607 passed, 0 failed.
  - Run 3: 2607 passed, 0 failed.

---

## 7. Build & Binary Validation

- **Release Build Target**: `leanring-buddy` (Scheme: `leanring-buddy`, Configuration: `Release`)
- **Architecture**: `arm64`
- **Signing**: Intact project signing configuration.
