## Purpose

Make a replayed step act on the target Pace actually resolved, inside the exact
window it was recorded in, and refuse rather than guess whenever identity or
result cannot be proven.

## ADDED Requirements

### Requirement: Dispatch acts on the resolved target
The system SHALL carry the resolved live Accessibility target, or an opaque
handle to it, from resolution through dispatch, and SHALL NOT substitute the
current physical cursor position, the frontmost element, or any other
re-derived target.

#### Scenario: Resolved target is not under the pointer
- **WHEN** a recorded step resolves to an element and the pointer is over a different element
- **THEN** the action is performed on the resolved element
- **AND** the element under the pointer is not activated

#### Scenario: Resolution carries no usable handle
- **WHEN** a resolution arrives without a usable execution handle
- **THEN** the step returns a typed refusal
- **AND** no input event is posted

#### Scenario: Test resolution
- **WHEN** a test supplies a synthetic resolution through the injectable Accessibility tree seam
- **THEN** the dispatched target is observable without exposing a live Accessibility element to test code

### Requirement: Resolution is window-scoped and fails closed on ambiguity
The system SHALL resolve a step only within the exact recorded process and
window identity, SHALL descend to a weaker resolution rung only when the current
rung produces no candidate, and SHALL return a typed ambiguity refusal when a
rung produces more than one eligible candidate.

#### Scenario: Unique match in the recorded window
- **WHEN** exactly one element in the recorded process and window satisfies the step's strongest retained evidence
- **THEN** that element is resolved
- **AND** no weaker rung is consulted

#### Scenario: Two eligible windows from one process
- **WHEN** more than one window of the recorded process could satisfy the step
- **THEN** Pace returns a typed ambiguity refusal before any input is posted
- **AND** does not choose a window by recency, position, or focus

#### Scenario: Duplicate labels without independent identity
- **WHEN** two or more sibling elements share the step's label and no retained evidence distinguishes them
- **THEN** Pace returns a typed ambiguity refusal
- **AND** does not fall through to a weaker rung

#### Scenario: Rung produces no candidate
- **WHEN** a rung finds no eligible candidate at all
- **THEN** Pace may attempt the next rung permitted by the step's policy
- **AND** records which rung produced the eventual resolution

#### Scenario: Wrong application is frontmost
- **WHEN** the recorded process or window is absent
- **THEN** Pace halts the run
- **AND** does not resolve against a different application

### Requirement: Healthy replay uses no model
The system SHALL define healthy replay as resolution through exact-identity or
unique structural matching, and SHALL make no planner, language-model, or
vision-model call on that path.

#### Scenario: Healthy replay of a compiled flow
- **WHEN** every step resolves through exact-identity or unique structural matching
- **THEN** the run completes without any planner or vision-model call

#### Scenario: Model-assisted grounding is policy-gated
- **WHEN** stronger rungs produce no candidate and the step's policy permits model-assisted grounding
- **THEN** that grounding may be attempted on-device only
- **AND** the run is not reported as a healthy replay

#### Scenario: Model-assisted grounding is not permitted
- **WHEN** stronger rungs produce no candidate and the step's policy forbids model-assisted grounding
- **THEN** Pace halts and offers re-teaching
- **AND** does not attempt grounding anyway

### Requirement: Action facts and postconditions are separate typed results
The system SHALL return a typed action fact for every mutating step and SHALL
evaluate any required result as a separate typed postcondition, and SHALL NOT
treat a successful dispatch as a satisfied result.

#### Scenario: Mutating step completes
- **WHEN** a mutating step is dispatched
- **THEN** it returns an action fact of confirmed, partial, unverifiable, suspected-noop, or refused
- **AND** the action fact records the resolution rung and the evidence that justified it

#### Scenario: Dependent step needs a proven result
- **WHEN** a step depends on a previous step's required result
- **THEN** it proceeds only when that step's postcondition is satisfied
- **AND** an unsatisfied or unknown postcondition halts before the dependent step

#### Scenario: Confirmed action with unknown result
- **WHEN** an action fact is confirmed but its postcondition cannot be evaluated
- **THEN** the postcondition is unknown
- **AND** any dependent consequential step is not attempted

#### Scenario: Postcondition evaluation stays bounded
- **WHEN** a postcondition is evaluated
- **THEN** it reads only bounded structural state such as an Accessibility attribute, focus, or window presence
- **AND** it does not invoke a model or read arbitrary process state

### Requirement: Failure preserves the completed prefix and stops
The system SHALL leave already-completed steps in place on failure, SHALL leave
every remaining step unattempted, and SHALL report the exact halted step.

#### Scenario: Halt mid-flow
- **WHEN** a run halts at step N
- **THEN** steps before N remain as executed
- **AND** step N and every later step are left unattempted
- **AND** the halted step and its reason are reported

#### Scenario: Occlusion or surprise modal appears
- **WHEN** the recorded target is occluded or an unexpected modal takes focus
- **THEN** Pace halts before the next dependent action
- **AND** does not dismiss the unexpected surface to continue

#### Scenario: Required permission is missing or revoked
- **WHEN** Accessibility or Screen Recording authorization is missing or is revoked mid-run
- **THEN** Pace halts and reports the unmet permission
- **AND** does not report the run as completed

#### Scenario: User cancels
- **WHEN** the user cancels during a run
- **THEN** the run stops at the current step boundary
- **AND** the remaining steps are left unattempted
