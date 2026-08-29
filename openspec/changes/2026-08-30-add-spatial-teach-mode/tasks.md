## 0. Owner Gate

- [ ] 0.1 Owner answers D1 (which slices are in scope) and D13 (how existing flows that begin refusing are handled) in [design.md](./design.md) before slice 1 merges.
- [ ] 0.2 Record the answers in this change and adjust the slice list rather than starting work past the approved boundary.

## 1. Slice 1 — Resolved-Target Dispatch

- [ ] 1.1 Add a non-`Equatable`, test-inconstructible execution handle to `PaceAXPressResolution` and keep `debugLabel` as the only equality participant so existing replayer tests stay valid.
- [ ] 1.2 Fill the handle in `PaceFrontmostAppAXTreeSource` and rewrite `PaceFlowReplayer.performAXPress` to press the carried handle, deleting the `CGEvent(source: nil)?.location` re-resolution.
- [ ] 1.3 Return a typed refusal when a resolution arrives without a handle; never fall back to the pointer or to `tryClickViaAccessibility(atGlobalCGPoint:)`.
- [ ] 1.4 Add fixtures asserting the pressed element is the resolved one while the synthetic pointer sits over a different element, plus a handle-less refusal fixture, and confirm the existing replayer suite is unchanged.
- [ ] 1.5 Evaluate the stop condition: if the live element cannot cross the `PaceAXTreeSource` seam without machine-specific fixtures, or previously passing flows now refuse in a way D13 does not cover, return to the owner before continuing.

## 2. Slice 2 — Typed Outcomes And Ambiguity Refusal

- [ ] 2.1 Add the action-fact type (`confirmed`, `partial`, `unverifiable`, `suspectedNoop`, `refused`) carrying the rung used and the evidence that justified it.
- [ ] 2.2 Add the separate postcondition type (`satisfied`, `unsatisfied`, `unknown`) with bounded structural checks only — no model inference, no arbitrary process reads.
- [ ] 2.3 Implement rungs 1 and 2 scoped to the exact recorded PID and `CGWindowID`, with descent only on zero candidates and a typed ambiguity refusal on two or more.
- [ ] 2.4 Implement prefix-preserving halt: dependent consequential steps advance only on `satisfied`, and the unattempted suffix is left untouched with no partial rollback.
- [ ] 2.5 Add fixture classes for two windows from one PID, two same-label siblings, wrong app or window, missing permission, and user cancellation, each asserting no later dependent step was attempted.
- [ ] 2.6 Evaluate the stop condition: if strict window-scoped targeting produces unnecessary halts on ordinary single-window apps, the ladder premise is wrong — return to the owner.

## 3. Slice 3 — Flow v2 Schema And Migration

- [ ] 3.1 Add the versioned v2 flow and step model with app/window identity, structural AX locator and ancestor evidence, optional crop/OCR/landmark evidence, risk class, bounded pre/postconditions, model-fallback policy, provenance, and integrity digest.
- [ ] 3.2 Read a v1 file with no `schemaVersion` as implicit version 1 and upgrade it in memory with empty evidence and a risk class derived from the existing `PaceFlowReplayPlanner` pause-before-send heuristic.
- [ ] 3.3 Never rewrite a v1 file in place under the default assumed in D5; write v2 only for newly recorded or explicitly re-taught flows.
- [ ] 3.4 Add Codable round trips, byte-identical re-serialization tests for untouched v1 files, digest verification and corruption-detection tests, and a replay-parity fixture proving migrated v1 flows behave exactly as before.
- [ ] 3.5 Evaluate the stop condition: if v1 parity cannot be shown without rewriting v1 files, escalate D5 rather than deciding locally.

## 4. Slice 4 — Spatial Capture Packet And Highlight Chord

- [ ] 4.1 Add `PaceSpatialContextPacket` as a pure versioned value with a per-field provenance and privacy flag and an explicit coordinate-space tag on every geometric field.
- [ ] 4.2 Add the configurable listen-only hold-to-highlight event tap using the chord chosen in D2, with explicit detection and reporting of a disabled, timed-out, or permission-revoked tap.
- [ ] 4.3 Render the sampled, capped trail and named endpoints in the existing non-activating overlay, and exclude Pace's own overlays from capture.
- [ ] 4.4 Bind the trail on release to the exact hovered window (PID, `CGWindowID`, bundle id, name, title, frame) and to the strongest available AX and selected-text evidence, preferring AX over pixels.
- [ ] 4.5 Represent `this` and `there` as two distinct named regions inside one bounded interaction; represent a move request without executing a drag (ambiguity A11).
- [ ] 4.6 Enforce secure exclusion at all three points: system secure input mode, `AXSecureTextField` or secure-marked ancestor, and refusal when secure status is unknown for a text-bearing field.
- [ ] 4.7 Capture tight crops plus local Vision OCR with no disk write for full-screen or full-window captures, and hold crops in memory for the interaction only.
- [ ] 4.8 Route "what is this?" and "click this" through the existing approval path so a gesture narrows intent without granting action authority.
- [ ] 4.9 Add packet fixtures across synthetic multi-monitor layouts with mixed backing scale factors, negative origins, and a non-main primary display; add secure-field refusal, overlay-exclusion, and tap-disabled fixtures.
- [ ] 4.10 Measure the crop-to-AX-frame round-trip error on mixed-scale layouts and evaluate the slice-4 stop conditions before proceeding.

## 5. Slice 5 — Evidence-Rich Compilation And Rungs 3-5

- [ ] 5.1 Extend the recorder to write v2 evidence from demonstrations and spatial packets under the crop-retention policy chosen in D4.
- [ ] 5.2 Implement the conservative compiler: drop incidental input, group consecutive typing, suppress secure-condition input as a redacted placeholder, and infer a parameter only for a literal appearing verbatim in the transcript.
- [ ] 5.3 Refuse the whole compilation when any step lacks at least rung-2-viable evidence; never persist a partially compiled flow.
- [ ] 5.4 Implement rung 3 (local crop/template plus OCR and landmark evidence) with the same zero-candidates-only descent and several-candidates refusal rule.
- [ ] 5.5 Implement rung 4 (on-device VLM grounding) only if D3 approves it, strictly gated by step policy and unreachable on the healthy path; otherwise ship a four-rung ladder.
- [ ] 5.6 Implement rung 5 as an explicit halt-and-offer-re-teach outcome rather than a silent failure.
- [ ] 5.7 Add drift fixture classes: moved control, renamed control, safe label drift, theme drift, AX-sparse or canvas UI, stale screenshot, occlusion, and surprise modal — asserting the rung used per fixture.
- [ ] 5.8 Assert zero planner and VLM calls across the healthy-path corpus, and evaluate the slice-5 stop conditions.

## 6. Slice 6 — Repair Candidates And Promotion

- [ ] 6.1 On drift, surface what Pace expected, what it found, and the exact halted step.
- [ ] 6.2 Let the user re-point at the corrected target and build a reviewable repair candidate from a fresh spatial packet, as a separate object from the active flow.
- [ ] 6.3 Require a passing deterministic regression replay of the whole flow before promotion; reject leaves the active flow byte-identical.
- [ ] 6.4 Add fixtures for unchanged-before-promotion, unchanged-after-rejection, and updated-only-after-passing-regression, plus D8's auto-promotion answer.
- [ ] 6.5 Evaluate the stop condition: if regression replay cannot be made deterministic, prefer requiring a re-teach over a non-deterministic promotion gate.

## 7. Slice 7 — Guide Mode

- [ ] 7.1 Walk the compiled v2 flow through the same resolver and present each step with the existing cursor/annotation overlay plus narration.
- [ ] 7.2 Post no input events in guide mode; present an unresolvable step as unresolvable rather than skipping it.
- [ ] 7.3 Implement the surface shape chosen in D10 (distinct mode versus per-run option).
- [ ] 7.4 Add a fixture asserting zero input events for a full guided run and correct presentation of an unresolvable step.

## 8. Slice 8 — Evaluation Matrix And Gate

- [ ] 8.1 Report the eight metrics over the accumulated corpus: correct completion, silent incorrect completion, safe halt, unnecessary halt, resolution rung used, action-to-evidence latency, planner/VLM calls on healthy replay, and peak memory plus retained artifact size.
- [ ] 8.2 Document which matrix cells are required and which are undefined for a given fixture class (ambiguity A9), and mark silent-incorrect-completion as fixture-only (ambiguity A7).
- [ ] 8.3 Apply the thresholds set in D12 so the matrix can fail a release; without thresholds this task does not start.
- [ ] 8.4 Run the matrix through `bash scripts/test-pace.sh` and fail on a threshold breach.

## 9. Documentation And Verification

- [ ] 9.1 Update architecture, capability, key-file, and test-coverage documentation as each slice lands; add a `docs/development/key-files.md` row for every new source file.
- [ ] 9.2 Reconcile [the teachable-skills PRD](../../../docs/product/prds/teachable-skills.md) with the shipped state per D7 — this change annotates the Deferred entry now and moves it only when slice 5 lands.
- [ ] 9.3 Run focused isolated test groups through `bash scripts/test-pace.sh <suite>` after each layer; never run terminal `xcodebuild`.
- [ ] 9.4 Run `openspec validate --strict`, `bash scripts/validate-docs.sh`, and `git diff --check` for every slice.
- [ ] 9.5 Update `PROJECT_STATUS.md` only after a slice's implementation and automated checks establish durable current product truth.
- [ ] 9.6 Exercise each user-visible slice from an Xcode-launched app, record the exact gestures and observed outcomes, and claim no result that was not observed.
