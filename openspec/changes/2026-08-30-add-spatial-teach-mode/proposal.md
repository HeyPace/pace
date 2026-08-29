## Why

Pace can record a demonstration and replay it, but the recording keeps almost
no evidence about what was demonstrated and the replay cannot prove it acted on
the recorded target. `PaceRecordedStep.axPress` persists only a role path and a
label. Worse, `PaceFlowReplayer.performAXPress` cannot thread the live
`AXUIElement` through `PaceAXPressResolution`, so it re-resolves the press by
reading `CGEvent(source: nil)?.location` — the user's current physical cursor.
A replay therefore presses whatever happens to be under the pointer, and the
source comment says so.

Everything else this issue asks for — spatial capture, an evidence-rich flow
schema, a fail-closed resolver ladder, repair, guide mode — is built on top of
a target identity that the runtime currently throws away before dispatch. That
identity/dispatch gap has to close first, and it is worth closing on its own.

Teach-by-demonstration is still listed as deferred in
[the teachable-skills PRD](../../../docs/product/prds/teachable-skills.md), and
`programmable-teachable-skills` explicitly excluded generalizing a recorded
Accessibility flow. This change is the first proposal to take that seam on.

This is not one change. It is a multi-week arc, and this proposal sequences it
into eight independently shippable slices so the owner can approve, reduce, or
stop it at any boundary. Slice 1 has standalone value even if slices 2-8 are
never built.

## What Changes

- Carry the resolved Accessibility target through flow dispatch as an opaque
  execution handle, so a replayed press acts on the resolved element instead of
  the current cursor position.
- Separate a typed **action fact** (confirmed / partial / unverifiable /
  suspected-noop / refused) from a typed **postcondition** result (satisfied /
  unsatisfied / unknown), and only let `satisfied` advance a dependent
  consequential step.
- Make ambiguity a refusal. Multiple eligible windows or elements return a typed
  refusal before any input is posted; they never fall through to a weaker
  resolution rung.
- Add a versioned `PaceRecordedFlow` v2 carrying app/window identity, a
  structural AX locator with ancestor evidence, optional crop/OCR/landmark
  fallback evidence, risk class, bounded pre/postconditions, model-fallback
  policy, provenance, and an integrity digest — while v1 files on disk keep
  loading and replaying without behavior drift.
- Add a short-lived, bounded `PaceSpatialContextPacket` produced by a
  hold-to-highlight chord: sampled trail, named `this`/`there` regions, exact
  hovered window identity, AX/selected-text evidence, tight crop plus local
  Vision OCR, the local transcript, and per-field provenance and privacy flags.
- Compile a demonstration into a v2 flow: drop incidental input, group typing,
  suppress secrets, infer only conservative literal parameters, and refuse
  partial or ambiguous output rather than emitting a guess.
- Add repair candidates on drift — show expected vs found at the exact halted
  step, let the user re-point, and promote only after a deterministic regression
  replay. The active flow is never silently mutated.
- Add Guide mode as presentation over the same compiled flow: point and narrate
  one step at a time without acting.
- Add an eight-metric evaluation matrix and a fixture corpus covering at least
  twelve classes, all runnable through `bash scripts/test-pace.sh`.
- Keep everything on-device. No cloud STT/VLM/LLM path, no private-API
  background input, no local screen-serving server, no new daemon or production
  dependency, and no copied third-party detector weights.

## Slices

Each slice ships on its own, has its own acceptance, and has a stated condition
under which it is not worth continuing. Full acceptance and kill criteria are in
[design.md](./design.md); the work breakdown is in [tasks.md](./tasks.md).

| # | Slice | Standalone value | Issue ACs |
| --- | --- | --- | --- |
| 1 | Resolved-target dispatch | Replay stops pressing whatever is under the cursor | 7 |
| 2 | Typed outcomes and ambiguity refusal | Replay halts honestly instead of guessing | 8, 9, 11 |
| 3 | Flow v2 schema and migration | A place to put evidence, with v1 unchanged | 6 |
| 4 | Spatial capture packet and highlight chord | "What is this?" / "click this" without recording | 2, 3, 4, 5 |
| 5 | Evidence-rich compilation and rungs 3-5 | Demonstrations survive drift | 10, 14 |
| 6 | Repair candidates and promotion | Broken flows become fixable, not disposable | 12 |
| 7 | Guide mode | Teaching a human, with zero action risk | 13 |
| 8 | Evaluation matrix and gate | Numbers that can refuse a release | 15 |

Acceptance criterion 1 — this proposal — is satisfied by landing this change.

## Capabilities

### New Capabilities

- `deterministic-flow-execution`: Resolve a recorded step to an exact live
  target inside an exact window, dispatch to that target, and return typed
  action-fact and postcondition outcomes that fail closed on ambiguity.
- `spatial-context-capture`: Produce a bounded, interaction-scoped, on-device
  spatial context packet from a hold-to-highlight gesture, with explicit
  provenance and secure-content exclusion.
- `evidence-rich-recorded-flows`: Persist, migrate, compile, repair, and present
  versioned demonstration flows carrying redundant target evidence and bounded
  conditions.

### Modified Capabilities

- None. No existing capability spec covers recorded flows or replay;
  `programmable-teachable-skills` named recorded-flow generalization as a
  non-goal and that boundary still holds — a compiled flow is not a Pace
  Program and does not gain program authority.

## Impact

- Runtime: `PaceFlowReplayer.swift` (the resolution/dispatch seam and
  `performAXPress`), `PaceFlowReplay.swift` (schema), `PaceFlowRecorder.swift`
  and `PaceFlowStore.swift` (capture and persistence),
  `CompanionManager+DemonstrationFlow.swift` (routing), plus new capture,
  resolver, compiler, repair, and guide sources beside them.
- Existing execution: reuses `PaceAXTargeter`, the annotation/cursor overlay,
  `PaceVisionOCRClient`, `CompanionScreenCaptureUtility`, action approval,
  observation, undo, and audit. It does not add a second action executor.
- Test seam: `PaceAXTreeSource` and `PaceAXPressResolution` change shape. The
  existing `Equatable` marker used by tests is preserved; the live element
  travels beside it as an opaque handle that test code cannot construct.
- Storage: v1 flow JSON continues to load. Whether v2 is written in place or
  beside v1 is an open owner decision (see design.md).
- Privacy: adds a screenshot-derived crop retention decision that Pace does not
  currently have. Full-screen and full-window captures stay ephemeral; only
  approved crops persist, and secure fields are excluded from capture and
  serialization.
- Permissions: the highlight chord needs Accessibility (listen-only event tap);
  crops need Screen Recording. Both can be revoked or silently disabled at
  runtime and must be surfaced rather than degraded into a no-op.
- Dependencies and deployment: no new dependency, entitlement, network path,
  production configuration, or release action. No terminal `xcodebuild`; all
  automated verification goes through `bash scripts/test-pace.sh`.
