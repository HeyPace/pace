# Phase 2AX — Semantic Color Well Enumeration (`ui.list_color_wells`)

## Overview

Phase 2AX introduces native semantic discovery and enumeration of macOS color well controls (`AXColorWell` / `NSAccessibilityColorWellRole`) across running applications. This capability allows agents to deterministically discover color pickers, palettes, swatches, and color selection wells presented by AppKit and SwiftUI apps via standard Accessibility primitives.

- **Capability Identifier**: `ui.list_color_wells`
- **Security Level**: Level 0 (Read-Only)
- **Role Allowlist**: `["AXColorWell"]` (`kAXColorWellRole` / `NSAccessibilityColorWellRole`)
- **Primary AX Attributes**: `kAXRoleAttribute`, `kAXSubroleAttribute`, `kAXTitleAttribute`, `kAXDescriptionAttribute`, `axIdentifierAttributeName` (`"AXIdentifier"`), `kAXValueAttribute`, `kAXEnabledAttribute`
- **Mutability**: Read-only observation (no UI mutation performed)
- **Approval Model**: None (Level 0 Read-Only)
- **Recovery Model**: N/A (read-only snapshot; subsequent actions independently resolve fresh live targets)

---

## Technical Architecture

### Target Resolution & Containment Model

In macOS AppKit/Accessibility architecture, color wells (`NSColorWell`) are exposed as accessibility elements with role `AXColorWell`. They reside within windows, content views, toolbars, or inspector panels.

Target resolution proceeds strictly as follows:
1. **Application Resolution**: Deterministic resolution via `QBridgeAccessibility.resolveExactRunningApplication(named:)`. Rejects zero matches and ambiguous matches.
2. **Window Resolution**: If `windowTitle` or `windowIdentifier` is provided, resolves the exact matching window. If unspecified, traverses the application root and window hierarchy.
3. **Bounded Traversal**:
   - Traverses candidate elements and direct view hierarchies up to bounded depth (depth <= 8).
   - Enforces `maxDirectColorWellsCount = 32`. If a malicious or unbounded tree exposes > 32 color wells, fails closed with `QAXInteractionError.colorWellCollectionExceedsSafeBound`.
4. **Strict Role Verification**: Confirms `role == "AXColorWell"` via `QAXColorWellRolePolicy.isAllowedColorWellRole`. Any non-color-well role triggers `QAXInteractionError.disallowedColorWellRole`.
5. **Optional Matching**: Filters by `colorWellIdentifier` (case-sensitive) and/or `colorWellTitle` (case-insensitive substring match).

### Closed-Loop Verification

Verification is performed via `QVerificationStrategy.colorWellEnumerationSucceeded(applicationName:colorWellCount:)`.
- The verifier validates that execution succeeded.
- Produces structured aggregate evidence: `application=<appName> colorWellRole=AXColorWell colorWellCount=<count> status=verified`.
- **Privacy Assurance**: Summaries and verification evidence deliberately omit individual color values, titles, or identifiers, preserving user privacy.

---

## Security & Privacy Invariants

- **No Synthetic Input**: Zero reliance on `CGEvent`, `NSEvent`, mouse coordinates, keyboard simulation, `osascript`, `AppleScript`, or shell subprocesses.
- **Resource Bounds**: Strict limit of 32 color wells per query (`maxDirectColorWellsCount = 32`), preventing traversal runaway or denial of service.
- **No Raw Pointer Persistence**: `AXUIElement` handles are never serialized or retained across queries.
- **Fail Closed**: Any unexpected role, ambiguous application resolution, or traversal breach fails closed with descriptive error codes (`AX_DISALLOWED_ROLE`, `AX_COLOR_WELL_COLLECTION_EXCEEDS_SAFE_BOUND`, etc.).

---

## Test Verification

- **Focused Unit Suite**: `QSemanticColorWellEnumerationTests` (19 passed, 0 failed, 0 skipped).
- **Relevant Suites**:
  - `QSemanticPopoverEnumerationTests` (19 passed, 0 failed, 0 skipped).
  - `QSemanticSheetDialogEnumerationTests` (15 passed, 0 failed, 0 skipped).
  - `QSemanticSplitPaneEnumerationTests` (19 passed, 0 failed, 0 skipped).
- **Full Regression (3 consecutive runs)**:
  - Run 1: 2904 passed, 0 failed, 0 skipped (53.9s)
  - Run 2: 2904 passed, 0 failed, 0 skipped (54.5s)
  - Run 3: 2904 passed, 0 failed, 0 skipped (54.3s)
- **ARM64 Release Validation**: `scripts/prepare-release.sh` generated binary with `arm64` architecture, code signed, and satisfying designated requirements.

---

## Known Limitations

- Real macOS live AppKit color well discovery requires active window presentation by the target host application and accessibility trust (`AXIsProcessTrusted()`).
- Color values are read from `kAXValueAttribute` as reported by the host control (e.g. RGB components or system representation).
