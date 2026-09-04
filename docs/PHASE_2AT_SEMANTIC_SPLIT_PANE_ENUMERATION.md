# Phase 2AT — Semantic Split Pane Enumeration

## Capability Identifier
`ui.list_split_panes`

## Security Level
**Level 0 — Read-Only.** No approval, no mutation, no press, no focus, no recovery replay. Auto-allowed by `QPermissionGate`'s Level 0/1 policy path (same mechanism `ui.list_windows`, `ui.list_toolbar_items`, and every other read-only discovery capability already uses — no per-capability bypass was introduced).

## Semantic AX Primitive
`AXApplication` → `AXWindow` (optional scoping) → `AXSplitGroup` (`NSAccessibilitySplitGroupRole`, confirmed canonical macOS Accessibility role) → direct children via `kAXChildrenAttribute`, excluding `AXSplitter` divider elements.

`AXSplitGroup` and `AXSplitter` are documented, stable AppKit accessibility roles exposed automatically by `NSSplitView` — no custom or undocumented AX attribute is used.

## Exact Target Resolution
1. **Application**: `QBridgeAccessibility.resolveExactRunningApplication(named:)` — exact case-insensitive localized-name or bundle-identifier match. 0 matches → `applicationNotAvailable`. >1 matches → `ambiguousTarget`. Never falls back to `.first`.
2. **Window (optional)**: If `windowTitle` or `windowIdentifier` is supplied, resolves exactly one `AXWindow` beneath the application via `collectMatches`, with a stale-target/drift re-check (`snapshotIfMatches` compared against the search-time snapshot) immediately before use. Fails closed on 0 or >1 matches.
3. **Split Group**: Resolves exactly one `AXSplitGroup` (scoped to the resolved window if window scoping was requested, otherwise scoped to the whole application) via `collectMatches` against `identifier`/`title`. Fails closed on 0 or >1 matches, with the same stale-target/drift re-check pattern immediately before enumeration.

This is the identical three-stage resolution pattern already used by `ui.list_toolbar_items` (Phase 2AK) and `ui.list_segmented_control_items` (Phase 2AM) — no new resolution logic was introduced.

## Action/State Contract
Pure read. Enumerates the split group's direct children (`kAXChildrenAttribute`), excluding any child whose role is `AXSplitter` (the divider between panes — not a pane itself). Each returned pane reports: `index`, `role`, `subrole`, `title` (or description fallback), `identifier`, `isEnabled`. A pane's own descendant subtree is never expanded.

Unlike every other `list_*` enumeration capability in this codebase (which allowlist a fixed set of direct-child roles, e.g. `AXButton`/`AXPopUpButton`/... for toolbars), split pane content roles are inherently unbounded — a pane can be `AXOutline`, `AXScrollArea`, `AXGroup`, `AXTable`, or any other content container. The enumeration therefore uses an **exclusion** filter (everything except `AXSplitter`) rather than an **allowlist** filter. This is documented explicitly in the `QAXSplitPaneItemMetadata` doc comment.

Bounded by a local defensive ceiling (`maxDirectSplitPanesCount = 16`) — exceeding it throws `QAXInteractionError.splitPaneCollectionExceedsSafeBound` and fails closed rather than truncating silently.

## Verification
Closed-loop, matching the exact template used by all 11 prior `list_*` capabilities: `QVerificationStrategy.splitPaneEnumerationSucceeded(applicationName:, paneCount:)`. Verification requires `QActionResult.success == true` (itself gated by `QActionVerifier.verify`'s universal fail-closed short-circuit on `result.success == false`, before any per-strategy branch runs) plus the aggregate pane count captured at read time. Evidence strings carry aggregate counts only — never any individual pane's title or identifier — verified directly by test #13 (privacy boundary).

## Idempotency
Not applicable — this is a pure read with no mutation to be idempotent about.

## Approval
Not applicable — Level 0, auto-allowed. Verified explicitly by test #16 (`ui.list_split_panes` does not confer authorization for `ui.click_element` or any other capability — permission evaluation is per-capability, never transitively granted).

## Recovery
Not applicable — Level 0 reads have no persisted mutation state to recover from. No `QTaskRecoveryManager` case was added, matching every other `list_*` capability (none of which has one).

## Privacy
- Returns structural metadata only (role/subrole/title/identifier/enabled state) — never a pane's own subtree content.
- Result is an explicit point-in-time snapshot; the execution summary states this and warns that any subsequent action must independently resolve its own fresh target — matching the exact language every other `list_*` capability already uses.
- `QDurablePlanStepSnapshot` never serializes raw `outputData` — verified by test #15.

## Resource Limits
- `maxDirectSplitPanesCount = 16` — fails closed (throws, does not truncate) on overflow.
- Application, window, and split-group resolution each fail closed on 0 or >1 matches — no unbounded or fuzzy search at any stage.
- `traversalTimeBudgetSeconds` (shared, existing constant) bounds AX tree traversal time, as for every other capability.

## Test Results
`QSemanticSplitPaneEnumerationTests.swift` — **19/19 focused tests passed** (exceeds the ≥15 minimum for a read-only capability), covering:
1. Registration under toolFamily `ui`.
2. Registration at Level 0 Read-Only, non-approval, reversible.
3. Plan parser accepts a valid step.
4. Risk-level mismatch (model attempting to claim Level 1/2/3) fails closed.
5. Missing `applicationName` fails closed.
6. Disallowed roles (`AXTable`, `AXButton`, `AXGroup`, `AXWindow`, `AXToolbar`, `AXSplitter`, `AXTabGroup`, `AXSheet`) rejected.
7. `QAXSplitGroupRolePolicy` accepts only `AXSplitGroup` (direct unit check).
8. Non-existent application throws `applicationNotAvailable`.
9. Non-existent window target fails closed.
10. Non-existent split group target fails closed.
11. `QAXSplitPaneItemMetadata`/`QAXSplitGroupMetadata` model round-trip.
12. Empty split group (zero panes) is a valid, non-error result.
13. Verification evidence and result summary carry aggregate counts only (privacy boundary).
14. Verification fails closed when the underlying execution result did not succeed.
15. `QDurablePlanStepSnapshot` omits raw `outputData`.
16. `ui.list_split_panes` confers no authorization for `ui.click_element` (authorization isolation).
17. `QPlanExecutor` executes the step sequentially to completion (mocked).
18. `QPlanExecutor` executes the step to completion when zero panes are found (mocked).
19. Real macOS AppKit E2E — `NSSplitView` pane discovery, confirming returned panes never include an `AXSplitter` role (TCC-guarded).

## Real macOS E2E Result
**VERIFIED (conditionally).** Test #19 builds a real `NSSplitView` with two `NSView` arranged subviews inside a real `NSWindow`, then calls `QBridgeAccessibility.shared.listSplitPanes` (the actual production semantic AX path — never a native AppKit shortcut standing in for it) and asserts the returned pane collection never contains an `AXSplitter`-role element. The test is guarded by `guard AXIsProcessTrusted() else { return }`, matching the codebase's established honest-guard convention: if the running environment lacks Accessibility trust, the test returns early without asserting success or failure — it is not converted into a fake pass. In this implementation session's CI/test environment, Accessibility trust was not confirmed to be granted to the test host process, so this assertion path's real hardware execution status is: **guard present and correct; live macOS AX tree assertion pending on an Accessibility-trusted test host** (identical caveat to every prior read-only `list_*` capability's E2E test in this codebase, e.g. Phase 2AK's `QSemanticToolbarItemEnumerationTests`).

## ARM64 Release Build
**PASS.** `scripts/prepare-release.sh` (isolated Release build, no version bump, no notarization, no publish) succeeded: `BUILD SUCCEEDED`, resulting bundle `codesign`-verified as "valid on disk" and "satisfies its Designated Requirement."

## Mach-O arm64
**PASS.** `file`/`lipo -info` on `Pace.app/Contents/MacOS/Pace` confirm `Mach-O 64-bit executable arm64` (non-fat, single-architecture arm64 — matches the existing project configuration; not altered).

## Signing
**PASS, unaltered.** `scripts/prepare-release.sh` signs ad-hoc by default (`SIGNING_IDENTITY="${PACE_DEVELOPER_ID:--}"`, unchanged from the script's existing behavior) — no signing configuration was modified for this phase.

## Known Limitations
- **Pane content role is unbounded, by design.** Because `ui.list_split_panes` reports every non-`AXSplitter` direct child rather than an allowlisted role set, a caller cannot assume anything about a pane's role in advance — this is the correct, documented tradeoff for a container whose content is inherently a wildcard, not a defect.
- **`ui.set_splitter_position` remains unimplemented.** This phase deliberately implements only the read-only discovery half of the split-view gap identified across Phases 2AL/2AN/2AO/2AR; the mutation half is explicitly deferred to a future phase (see `docs/PHASE_2AT_CAPABILITY_ROADMAP.md`'s Explicitly Deferred Work section), now unblocked by this phase's discovery primitive.
- **Real hardware AX-tree assertion in test #19 is TCC-conditional**, per the Real macOS E2E Result section above — this matches the existing, accepted convention for every other read-only enumeration capability's E2E test in this codebase and is not a new limitation introduced by this phase.
