## Purpose

Turn a demonstration into a versioned, evidence-bearing flow that replays
deterministically, survives safe drift, becomes repairable rather than
disposable when it breaks, and can be presented to a human instead of executed.

## ADDED Requirements

### Requirement: Recorded flows are versioned and evidence-bearing
The system SHALL persist a versioned flow whose steps may retain the recorded
application and window identity, a structural Accessibility locator with
ancestor evidence, optional crop, optical-character-recognition label, landmark,
and coordinate fallback evidence, a risk class, bounded pre- and
postconditions, whether model-assisted grounding is permitted, provenance, and
an integrity digest.

#### Scenario: New flow is recorded
- **WHEN** a flow is recorded after this change
- **THEN** it is written with an explicit schema version
- **AND** each step carries at least the evidence needed for exact-identity or unique structural resolution

#### Scenario: Stored flow is altered out of band
- **WHEN** a stored flow's content no longer matches its integrity digest
- **THEN** Pace reports the flow as unverifiable
- **AND** does not replay it as though it were intact

#### Scenario: Step forbids model-assisted grounding
- **WHEN** a step's policy forbids model-assisted grounding
- **THEN** replay never attempts it for that step

### Requirement: Existing flows keep working
The system SHALL load previously recorded flows that carry no schema version,
SHALL treat them as the earlier version, and SHALL replay them without behavior
drift.

#### Scenario: Earlier flow is loaded
- **WHEN** a flow file with no schema version is loaded
- **THEN** it is interpreted as the earlier version and upgraded in memory with empty evidence

#### Scenario: Earlier flow is replayed
- **WHEN** an upgraded earlier flow is replayed
- **THEN** it resolves only through exact-identity or unique structural matching
- **AND** its observable behavior matches the behavior before this change, except that ambiguity and unresolvable targets now refuse instead of acting

#### Scenario: Earlier flow is not modified
- **WHEN** an earlier flow is loaded and replayed but not re-taught
- **THEN** its file on disk is unchanged

### Requirement: Compilation is conservative and refuses partial results
The system SHALL compile a demonstration by removing incidental input, grouping
consecutive typing, suppressing content captured under secure conditions, and
inferring only conservative literal parameters, and SHALL refuse the whole
compilation rather than emit an incomplete or ambiguous flow.

#### Scenario: Incidental input is present
- **WHEN** a demonstration contains focus-only clicks or no-op modifier presses
- **THEN** they are omitted from the compiled flow

#### Scenario: Typing is demonstrated
- **WHEN** the user types a run of characters
- **THEN** the compiled flow contains one grouped typing step rather than per-character steps

#### Scenario: Secret is typed during a demonstration
- **WHEN** input occurs while the target is a secure field or system secure input mode is active
- **THEN** the compiled flow stores a redacted placeholder
- **AND** never stores the characters

#### Scenario: A step cannot be compiled with sufficient evidence
- **WHEN** any step lacks evidence sufficient for exact-identity or unique structural resolution
- **THEN** the whole compilation is refused
- **AND** no partial flow is saved

#### Scenario: Parameter inference
- **WHEN** a literal value in the demonstration appears verbatim in the accompanying instruction
- **THEN** it may become a typed parameter placeholder
- **AND** no other value is generalized

### Requirement: Safe drift is survived through retained evidence
The system SHALL resolve a step through the strongest evidence still valid, and
SHALL succeed across appearance changes, relocated controls, and safe label
drift when retained evidence independently identifies the target.

#### Scenario: Appearance changes
- **WHEN** the target application's theme changes but its Accessibility identity is unchanged
- **THEN** the step resolves and the flow continues

#### Scenario: Control moves within its window
- **WHEN** the target control's position changes but its identity and structural locator are unchanged
- **THEN** the step resolves without using recorded coordinates

#### Scenario: Label changes safely
- **WHEN** a control's visible label changes while an identifier or unique structural locator still matches
- **THEN** the step resolves through that stronger evidence

#### Scenario: Recorded screenshot evidence is stale
- **WHEN** retained image evidence no longer matches the screen but stronger evidence resolves the target
- **THEN** the step resolves through the stronger evidence
- **AND** stale image evidence alone never resolves a step

### Requirement: Drift produces a reviewable repair candidate
The system SHALL report what was expected, what was found, and the exact halted
step, SHALL let the user point at the corrected target to produce a repair
candidate, and SHALL NOT modify the active flow before explicit promotion.

#### Scenario: Replay halts on drift
- **WHEN** a replay halts because a target cannot be resolved
- **THEN** Pace reports the expected evidence, the observed state, and the halted step

#### Scenario: User re-points at the corrected target
- **WHEN** the user indicates the corrected target
- **THEN** a repair candidate is produced as a separate reviewable object
- **AND** the active flow is unchanged

#### Scenario: Candidate is promoted
- **WHEN** a repair candidate is promoted
- **THEN** a deterministic regression replay of the flow must succeed first
- **AND** only then is the active flow updated

#### Scenario: Candidate is rejected
- **WHEN** a repair candidate is rejected or its regression replay fails
- **THEN** the active flow remains exactly as it was

### Requirement: Compiled flows can be presented instead of performed
The system SHALL provide a guide presentation over the same compiled flow that
points at and narrates one step at a time and performs no action.

#### Scenario: Guided run
- **WHEN** the user asks to be guided through a flow
- **THEN** Pace points at and narrates each step in order
- **AND** posts no input events

#### Scenario: Guided step cannot be resolved
- **WHEN** a step cannot be resolved during a guided run
- **THEN** Pace reports that it cannot locate the step
- **AND** does not skip silently to the next step

#### Scenario: Same source of truth
- **WHEN** a flow is guided and later replayed
- **THEN** both use the same compiled flow and the same resolution rules
- **AND** no separate guide-only format is stored

### Requirement: Flow behavior is measurable and testable from fixtures
The system SHALL make capture, compilation, resolution, execution outcomes, and
repair observable through fixtures that require no microphone, live desktop
control, or terminal build, and SHALL report the evaluation metrics over that
corpus.

#### Scenario: Fixture corpus
- **WHEN** the fixture corpus is run
- **THEN** it covers at least two windows from one process, two same-label siblings, moved controls, renamed controls, theme drift, Accessibility-sparse or canvas surfaces, stale image evidence, display scaling, multi-monitor coordinates, secure fields, occlusion, surprise dialogs, missing permission, and user cancellation

#### Scenario: Metrics are reported
- **WHEN** the corpus is evaluated
- **THEN** correct completion, silent incorrect completion, safe halt, unnecessary halt, resolution rung used, action-to-evidence latency, planner and vision-model calls on healthy replay, and peak memory with retained artifact size are reported

#### Scenario: Healthy corpus makes no model call
- **WHEN** the healthy-path corpus is evaluated
- **THEN** the reported planner and vision-model call count is zero
