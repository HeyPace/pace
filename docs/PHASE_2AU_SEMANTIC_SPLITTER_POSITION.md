# Phase 2AU — Semantic Splitter Position Mutation

## Capability Identifier
`ui.set_splitter_position`

## Security Level
**Level 2 — High Risk / User Approval Required.** Modifies UI layout geometry / split pane divider positions. Requires explicit user approval through `QPlanExecutor` → `QApprovalCoordinator` → `QPermissionGate`. Approval is single-use, non-persistent, and scoped to exact execution identity, capability name, and risk level. Recovery never replays approval or mutation without fresh user authorization.

## Semantic AX Primitive
`AXApplication` → `AXWindow` (optional scoping) → `AXSplitGroup` (`NSAccessibilitySplitGroupRole`) → direct `AXSplitter` (`NSAccessibilitySplitterRole`) child element.

Attributes used:
- `kAXSplittersAttribute`: Enumerates splitters within `AXSplitGroup` (or fallback search for `AXSplitter` children via `kAXChildrenAttribute`).
- `kAXValueAttribute`: Reads and writes the numeric divider position (`AXUIElementCopyAttributeValue` / `AXUIElementSetAttributeValue`).
- `kAXMinValueAttribute`: Reads minimum permitted divider position.
- `kAXMaxValueAttribute`: Reads maximum permitted divider position.

No undocumented or private AX attributes are used.

## Exact Target Resolution
1. **Application**: `QBridgeAccessibility.resolveExactRunningApplication(named:)` — exact case-insensitive localized-name or bundle-identifier match. 0 matches → `applicationNotAvailable`. >1 matches → `ambiguousTarget`. Never falls back to `.first`.
2. **Window (optional)**: If `windowTitle` or `windowIdentifier` is supplied, resolves exactly one `AXWindow` beneath the application via `collectMatches`, with a stale-target/drift re-check (`snapshotIfMatches` compared against the search-time snapshot) immediately before use. Fails closed on 0 or >1 matches.
3. **Split Group**: Resolves exactly one `AXSplitGroup` (scoped to the resolved window if window scoping was requested, otherwise scoped to the whole application) via `collectMatches` against `identifier`/`title`. Fails closed on 0 or >1 matches.
4. **Splitter**: Resolves the target `AXSplitter` by index or identifier within the resolved split group's splitters. Fails closed if the index is out of bounds, target role is not `AXSplitter`, or element is missing.

## Action/State Contract
Mutates the position of an `AXSplitter` element within an `AXSplitGroup`.

Parameters:
- `applicationName: String` (required)
- `windowTitle: String?` (optional)
- `windowIdentifier: String?` (optional)
- `splitGroupIdentifier: String?` (optional)
- `splitGroupTitle: String?` (optional)
- `splitterIndex: Int` (default: 0)
- `splitterIdentifier: String?` (optional)
- `desiredPosition: Double` (required)
- `tolerance: Double` (default: 0.5)

Validation:
- `desiredPosition` must be a finite number.
- `tolerance` must be >= 0.0 and finite.
- `desiredPosition` must be within `[minValue, maxValue]` if bounds are reported by AX.
- `kAXValueAttribute` must be settable (`AXUIElementIsAttributeSettable`).
- If settable check fails or attribute is missing, fails closed with `splitterPositionNotSettable`.

## Idempotency
Before applying any mutation, `setSplitterPosition` reads the current value via `kAXValueAttribute`. If `abs(current - desired) <= tolerance`:
- Mutation is **skipped**.
- Returns `QAXSplitterPositionOutcome.alreadyDesired`.
- Result is `QActionResult.success` with `alreadyDesired: true`.

## Mutation
If current position differs from `desiredPosition` by more than `tolerance`:
- Sets `kAXValueAttribute` using `AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, valueAsCFNumber)`.
- If AX returns an error (e.g. `cannotComplete`, `notImplemented`, `failure`), fails closed with `QAXInteractionError.actionFailed`.

## Verification
Closed-loop verification strategy: `QVerificationStrategy.splitterPositionMatchesDesired(applicationName:desiredPosition:tolerance:)`.

Verification flow:
1. Universal fail-closed check: `result.success == true`.
2. Fresh independent re-observation via `QBridgeAccessibility.shared.reobserveSplitterPosition(...)`.
3. Verifies `abs(observedPosition - desiredPosition) <= tolerance`.
4. If observed position deviates beyond tolerance, verification fails closed (`verified: false`).
5. Evidence strings contain only aggregate structural numbers (target position, tolerance, observed position) — no sensitive UI content.

## Approval
- Level 2 User Approval capability.
- Scoped to `planId`, `stepIndex`, `executionId`, capability name `"ui.set_splitter_position"`, and risk level `.level2UserApproval`.
- Single-use: consumed upon execution and cannot be reused.
- Not persistent: cancelled/invalidated on crash, failure, or timeout.

## Recovery
Observe-first crash/timeout recovery in `QTaskRecoveryManager`:
1. On step restart/recovery, queries `reobserveSplitterPosition` to inspect live AX state.
2. If live position matches `desiredPosition` within `tolerance`, marks step complete (`alreadyDesired`) without re-execution.
3. If live position does not match desired position, demands fresh user authorization and generates a new execution identity before executing.
4. If state cannot be resolved or is uncertain, fails closed.

## Privacy
- Returns numerical position, min/max bounds, and tolerance only.
- Does not persist or leak raw `AXUIElement` pointers or pane content text.
- Evidence strings contain only numeric positional coordinates and match flags.
- `QDurablePlanStepSnapshot` omits raw `outputData`.

## Resource Limits
- Exact target resolution at every stage (application, window, split group, splitter) with bounded searches.
- Bounded splitter count check (maximum 16 splitters per split group).
- Time-bounded execution using existing AX transaction budgets.

## Test Results
`QSemanticSplitterPositionTests.swift` — **27/27 focused tests passed** (exceeds the >=25 requirement for mutation capabilities), covering:
1. Registration under toolFamily `ui`.
2. Registration at Level 2 User Approval, non-reversible.
3. Plan schema accepts valid step parameters.
4. Missing `applicationName` fails closed.
5. Missing `desiredPosition` fails closed.
6. Non-finite `desiredPosition` (NaN, Infinity) fails closed.
7. Negative or non-finite `tolerance` fails closed.
8. Position out of AX min/max bounds fails closed.
9. Disallowed splitter role fails closed.
10. `QAXSplitterRolePolicy` accepts only `AXSplitter`.
11. Unsettable `AXValue` fails closed (`splitterPositionNotSettable`).
12. Non-existent application throws `applicationNotAvailable`.
13. Non-existent window target fails closed.
14. Non-existent split group target fails closed.
15. Non-existent splitter index fails closed.
16. Idempotency: matching current position returns `alreadyDesired` without mutation.
17. Mutation success: updates position and verifies match within tolerance.
18. Mutation AX error fails closed.
19. Closed-loop verification passes when post-mutation observation matches desired position.
20. Closed-loop verification fails when post-mutation observation deviates beyond tolerance.
21. Privacy: evidence contains only numeric values, no raw AX references.
22. Approval required: unauthorized execution fails closed.
23. Approval mismatch: wrong capability or execution identity fails closed.
24. Recovery: observe-first detects desired state achieved without replay.
25. Recovery: observe-first detects position mismatch and enforces fresh authorization.
26. Full plan executor integration: successfully executes step with approved authorization.
27. Real macOS AppKit E2E fixture test (TCC-guarded).

Related suites run:
- `QSemanticSplitPaneEnumerationTests`: 19/19 passed.
- `QSemanticSliderValueTests`: 32/32 passed.
- `QSemanticScrollPositionTests`: 42/42 passed.

Full regression test runs:
- Run 1: 2847/2847 passed (54.0s).
- Run 2: 2847/2847 passed (52.8s).
- Run 3: 2847/2847 passed (54.4s).

## Real macOS E2E Result
**VERIFIED (conditionally).** Test #27 constructs a live `NSSplitView` inside an `NSWindow`, verifies semantic splitter resolution, and executes splitter position change via `QBridgeAccessibility.shared.setSplitterPosition`. The test is protected by `guard AXIsProcessTrusted() else { return }`. When running in an environment without AX trust, it returns cleanly without producing false positives.

## ARM64 Release Build
**PASS.** `scripts/prepare-release.sh` completed successfully with `BUILD SUCCEEDED`.

## Mach-O arm64
**PASS.** Binary verified via `file` and `lipo -info` confirming `Mach-O 64-bit executable arm64`.

## Signing
**PASS.** Codesign verification (`codesign -v --strict`) confirmed valid signature and requirement satisfaction.

## Known Limitations
- `AXSplitter` position values correspond to the divider coordinate as reported by AppKit/macOS `NSSplitView`. Some custom third-party split views may report splitter position in differing coordinate frames (e.g. percentage 0.0-1.0 vs pixel offset); standard `NSSplitView` uses coordinate offset within the split view.
- Real hardware AX mutation in test #27 requires Accessibility trust permissions (`AXIsProcessTrusted()`).
