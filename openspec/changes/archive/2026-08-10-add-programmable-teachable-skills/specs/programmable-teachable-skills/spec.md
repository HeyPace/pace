## Purpose

Allow users to teach reusable workflows containing simple logic while keeping
every installed program local, bounded, inspectable, and deterministic at run
time.

## ADDED Requirements

### Requirement: Teaching chooses the least powerful sufficient representation
The system SHALL classify an explicit teach-or-create request into the least
powerful representation that can preserve the requested behavior completely.

#### Scenario: Fixed sequence is sufficient
- **WHEN** every requested step is a concrete allowed action with no branching or repetition
- **THEN** Pace saves the workflow as a fixed typed automation
- **AND** does not save a programmable skill

#### Scenario: Bounded logic is required
- **WHEN** the request requires supported conditional logic or a literal bounded repetition around otherwise concrete allowed actions
- **THEN** Pace may save it as a deterministic Pace Program
- **AND** tells the user that it was saved as a programmed local automation

#### Scenario: Live judgment is required
- **WHEN** the workflow requires interpreting changing screen content, choosing from open-ended possibilities, or otherwise needs live model judgment
- **THEN** Pace saves it through the planner-grounded skill path when that path can safely preserve the request
- **AND** tells the user that the local planner will be used when it runs

#### Scenario: Requested authority is forbidden
- **WHEN** a request depends on raw script execution, shell access, network access, arbitrary file access, imports, or direct Accessibility control
- **THEN** Pace does not install a program that grants that authority
- **AND** does not disguise the rejected request as a deterministic automation

### Requirement: Pace Programs expose bounded reusable logic
The system SHALL support ordered action nodes, conditional nodes over an
allowlisted pre-run local context, and literal-count repetition nodes.

#### Scenario: Ordered actions
- **WHEN** a valid program contains multiple action nodes
- **THEN** the resulting action plan preserves their declared order

#### Scenario: Contextual branch
- **WHEN** a valid program branches on a supported pre-run local fact
- **THEN** Pace captures that fact before executing actions
- **AND** expands only the matching branch into the run's action plan

#### Scenario: Literal repetition
- **WHEN** a valid program repeats a body a literal number of times within the configured limit
- **THEN** Pace expands the body exactly that many times in the resulting action plan

#### Scenario: Unsupported dynamic behavior
- **WHEN** a program requests a loop without a literal bound, mutable code evaluation, a branch on arbitrary process state, or a branch on an earlier action's untyped output
- **THEN** Pace rejects the program before it can be saved or run

### Requirement: Complete programs are validated before persistence and execution
The system SHALL validate the entire program graph against a versioned schema,
the typed-action allowlist, argument rules, and fixed complexity budgets both
before saving and before every run.

#### Scenario: Inactive branch contains an invalid action
- **WHEN** any branch contains an unknown, forbidden, partially parsed, or invalidly parameterized action
- **THEN** validation rejects the whole program even if that branch would not run in the current context
- **AND** no partial program is saved or executed

#### Scenario: Complexity budget exceeded
- **WHEN** nesting depth, repetition count, source-node count, or maximum expanded action count exceeds its fixed limit
- **THEN** validation rejects the whole program
- **AND** reports that the workflow is too complex for the deterministic program tier

#### Scenario: Previously valid saved program becomes invalid
- **WHEN** a stored program no longer validates against the supported schema or current typed-action registry
- **THEN** it is omitted from executable catalog results
- **AND** other saved automations remain available

### Requirement: Program runs reuse the typed action safety pipeline
The system SHALL compile a valid program into the existing typed action plan
and SHALL retain existing preference checks, user approval policy, ordered
execution, observation, cancellation, and audit behavior.

#### Scenario: Program is invoked
- **WHEN** a user invokes a valid programmed automation
- **THEN** Pace evaluates its bounded logic locally and compiles the selected actions
- **AND** no language model is called to interpret or execute the program

#### Scenario: Compiled action requires approval
- **WHEN** any selected action requires confirmation under the existing action policy
- **THEN** Pace requests confirmation before executing that action plan
- **AND** denial executes none of the pending actions

#### Scenario: Run-time preflight fails
- **WHEN** a required preference, permission, or other existing typed-action precondition is missing
- **THEN** Pace reports the unmet precondition before any action begins
- **AND** the run proceeds only when the existing typed-action safety policy authorizes it

### Requirement: Generated program text grants no new authority
The system SHALL treat all authoring-model output and imported program data as
untrusted data rather than executable host-language source.

#### Scenario: Authoring output contains source code
- **WHEN** the local authoring model returns Lua, JavaScript, shell, AppleScript, JXA, or another source language instead of a valid Pace Program document
- **THEN** Pace does not execute or persist that source as an installed program

#### Scenario: Model invents a capability
- **WHEN** authoring output references a tool, predicate, argument, or node type outside the published program schema
- **THEN** Pace rejects the complete proposed program
- **AND** the model output cannot extend the runtime allowlist

#### Scenario: Future source-language frontend
- **WHEN** a future authoring frontend accepts a source language
- **THEN** its output MUST compile entirely into the same validated Pace Program representation before installation
- **AND** the source language runtime receives no direct host authority

### Requirement: Programmable skills remain local and visibly distinct
The system SHALL store programmed automations separately from bundled
definitions and planner-grounded skill files, and SHALL identify their
execution behavior consistently wherever reusable work is presented.

#### Scenario: Valid program is discovered
- **WHEN** a valid user program is present in Pace Application Support
- **THEN** it appears in the unified automation catalog and teachable-skills surface
- **AND** is labeled as a deterministic program rather than a planner-grounded skill

#### Scenario: Program name collides
- **WHEN** a proposed program's normalized name conflicts with another catalog entry
- **THEN** Pace refuses to overwrite or shadow the existing entry silently

#### Scenario: Off-device planner is configured
- **WHEN** the user has selected an off-device general planner tier
- **THEN** program authoring still uses only the privacy-pinned local authoring model
- **AND** program discovery, validation, context evaluation, and execution remain on the Mac

### Requirement: Program behavior is testable from text and fixtures
The system SHALL make authoring, validation, compilation, and catalog behavior
testable without microphone, screen-recording, or Accessibility dependencies.

#### Scenario: Text authoring fixture
- **WHEN** a test supplies a teach request and fixed structured authoring output
- **THEN** the selected representation and persistence outcome are observable without audio input

#### Scenario: Context compilation fixture
- **WHEN** a test supplies a valid program and a fixed pre-run context
- **THEN** the exact flattened typed-action sequence is deterministic and observable

#### Scenario: Invalid-program fixture
- **WHEN** a test supplies forbidden or over-budget program data
- **THEN** rejection is observable without executing any macOS action
