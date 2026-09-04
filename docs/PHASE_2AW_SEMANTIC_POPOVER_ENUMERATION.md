# Phase 2AW — Semantic Popover Enumeration (`ui.list_popovers`)

## Overview

Phase 2AW introduces native semantic discovery and enumeration of macOS popover containers (`AXPopover` / `NSAccessibilityPopoverRole`) across running applications. This capability allows agents to deterministically discover lightweight, transient or persistent contextual popover dialogs, inspector popovers, and floating transient surfaces presented by AppKit and SwiftUI apps via standard Accessibility primitives.

- **Capability Identifier**: `ui.list_popovers`
- **Security Level**: Level 0 (Read-Only)
- **Role Allowlist**: `["AXPopover"]` (`kAXPopoverRole` / `NSAccessibilityPopoverRole`)
- **Primary AX Attributes**: `kAXChildrenAttribute`, `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`, `kAXIdentifierAttribute`, `kAXModalAttribute`
- **Mutability**: Read-only observation (no UI mutation performed)
- **Approval Model**: None (Level 0 Read-Only)
- **Recovery Model**: N/A (read-only snapshot; subsequent actions independently resolve fresh live targets)

---

## Technical Architecture

### Target Resolution & Containment Model

In macOS AppKit/Accessibility architecture, popovers (`NSPopover`) are exposed as accessibility elements with role `AXPopover`. They may be anchored directly as children of their presenting window or floating at the application level.

Target resolution proceeds strictly as follows:
1. **Application Resolution**: Deterministic resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`. Rejects zero matches and ambiguous matches.
2. **Window Resolution**: If `windowTitle` or `windowIdentifier` is provided, resolves the exact matching window. If unspecified, traverses the application's windows or application-level root AX elements.
3. **Bounded Direct Traversal**:
   - Inspects candidate elements and direct children of windows / application.
   - Enforces `maxDirectPopoversCount = 16`. If a malicious or unbounded tree exposes > 16 popovers, fails closed with `QAXInteractionError.popoverCollectionExceedsSafeBound`.
4. **Strict Role Verification**: Confirms `role == "AXPopover"` via `QAXPopoverRolePolicy.isAllowedPopoverRole`. Any non-popover role triggers `QAXInteractionError.disallowedPopoverRole`.
5. **Optional Matching**: Filters by `popoverIdentifier` (case-sensitive) and/or `popoverTitle` (case-insensitive substring match).

### Closed-Loop Verification

Verification is performed via `QVerificationStrategy.popoverEnumerationSucceeded(applicationName:popoverCount:)`.
- The verifier validates that execution succeeded.
- Produces structured aggregate evidence: `application=<appName> popoverRole=AXPopover popoverCount=<count> status=verified`.
- **Privacy Assurance**: Summaries and verification evidence deliberately omit individual popover titles or identifiers, preserving user privacy.

---

## Security & Privacy Invariants

- **No Synthetic Input**: Zero reliance on `CGEvent`, `NSEvent`, mouse coordinates, keyboard simulation, `osascript`, `AppleScript`, or shell subprocesses.
- **Resource Bounds**: Strict limit of 16 popovers per query (`maxDirectPopoversCount = 16`), preventing traversal runaway or denial of service.
- **No Raw Pointer Persistence**: `AXUIElement` handles are never serialized or retained across queries.
- **Fail Closed**: Any unexpected role, ambiguous application resolution, or traversal breach fails closed with descriptive error codes (`AX_DISALLOWED_ROLE`, `AX_POPOVER_COLLECTION_EXCEEDS_SAFE_BOUND`, etc.).

---

## Test Verification

- **Focused Unit Suite**: `QSemanticPopoverEnumerationTests` (19 passed, 0 failed, 0 skipped).
- **Relevant Suites**:
  - `QSemanticSheetDialogEnumerationTests` (15 passed, 0 failed, 0 skipped).
  - `QSemanticBrowserColumnEnumerationTests` (19 passed, 0 failed, 0 skipped).
  - `QSemanticSplitPaneEnumerationTests` (19 passed, 0 failed, 0 skipped).
- **Full Regression (3 consecutive runs)**:
  - Run 1: 2885 passed, 0 failed, 0 skipped (53.1s)
  - Run 2: 2885 passed, 0 failed, 0 skipped (55.0s)
  - Run 3: 2885 passed, 0 failed, 0 skipped (53.6s)
- **ARM64 Release Validation**: `scripts/prepare-release.sh` generated binary with `arm64` architecture, code signed, and satisfying designated requirements.

---

## Known Limitations

- Real macOS live AppKit popover discovery requires active popover presentation by the target host application and accessibility trust (`AXIsProcessTrusted()`).
- Popovers that have dismissed or faded out prior to AX query execution will not appear in the snapshot. Agents must execute queries while popovers remain presented.
