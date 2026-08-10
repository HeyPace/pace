# natural-language-automation-routing Specification

## Purpose
Allow Pace to select and create reusable automations from ordinary local text
transcripts while preventing ambiguous language from silently executing work.
## Requirements
### Requirement: Ordinary transcripts can select catalog automations
The system SHALL evaluate an ordinary completed transcript against locally
available automation names, descriptions, authored triggers, and invocation
examples before sending the turn to the general planner.

#### Scenario: Exact authored trigger
- **WHEN** a transcript exactly matches one automation's authored trigger after normalization
- **THEN** Pace selects that automation without an embedding or generative-model call

#### Scenario: Unique high-confidence semantic request
- **WHEN** local matching produces one candidate above the dispatch threshold and sufficiently ahead of the runner-up
- **THEN** Pace dispatches that candidate through its existing source-specific execution path

#### Scenario: Weak match
- **WHEN** no candidate clears the dispatch threshold
- **THEN** Pace executes no catalog automation
- **AND** the transcript continues through the existing non-catalog routing path

#### Scenario: Ambiguous match
- **WHEN** leading semantic candidates are within the ambiguity margin
- **THEN** Pace may ask the on-device language model to select, decline, or request clarification
- **AND** Pace executes only a candidate identifier present in the bounded local candidate set
- **AND** unavailable or invalid model output executes no catalog automation

#### Scenario: Exact alias collision
- **WHEN** multiple candidates share the same exact authored alias
- **THEN** Pace asks the user to clarify
- **AND** no language model silently breaks the tie

### Requirement: Matching remains local and fail-safe
The system SHALL keep automation metadata and transcript matching on the Mac
and SHALL treat matcher failure as a normal planner fallthrough rather than an
execution signal.

#### Scenario: Local embedder unavailable
- **WHEN** the configured local embedding chain cannot produce valid vectors
- **THEN** only an exact authored trigger remains available to the catalog matcher
- **AND** token overlap does not authorize execution

#### Scenario: Off-device planner selected
- **WHEN** the user has selected a non-local general planner tier
- **THEN** catalog metadata is not added to that planner's prompt or request

#### Scenario: Matching failure
- **WHEN** catalog discovery or local similarity computation fails
- **THEN** Pace executes no catalog automation because of the failure
- **AND** the original transcript continues through existing routing

### Requirement: Natural-language creation prefers deterministic definitions
The system SHALL accept an explicit natural-language create request and attempt
to represent it as a fixed typed automation using only locally allowed tools.

#### Scenario: Fully representable request
- **WHEN** every proposed step maps completely to allowed typed local calls with concrete arguments
- **THEN** Pace validates and persists a user-authored deterministic automation
- **AND** subsequent runs use the existing typed compiler without a planner

#### Scenario: Unknown, forbidden, or partial call
- **WHEN** any proposed step uses an unknown, destructive, opaque, networked, scripted, recursive, or partially parsed call
- **THEN** Pace does not persist a typed automation
- **AND** no partial definition is installed or executed

#### Scenario: Contextual workflow
- **WHEN** the requested workflow cannot be represented as fixed typed calls but contains actionable natural-language steps
- **THEN** Pace saves it through the existing planner-grounded teachable-skill path
- **AND** discloses that it will use the local planner when run

#### Scenario: Structuring model unavailable
- **WHEN** the privacy-pinned local structuring planner is unavailable
- **THEN** Pace may use its deterministic skill structurer
- **AND** it does not invent typed calls or use an off-device provider

### Requirement: User-authored deterministic definitions are isolated and validated
The system SHALL store user-created typed definitions separately from bundled
resources and SHALL validate them before catalog discovery and every execution.

#### Scenario: Valid saved definition
- **WHEN** a saved user definition decodes, validates, and compiles completely
- **THEN** it appears in the unified catalog as deterministic local

#### Scenario: Invalid saved definition
- **WHEN** a saved user definition is malformed, unsupported, or no longer compiles against the current tool registry
- **THEN** it is omitted from the executable catalog
- **AND** bundled definitions and other user automations remain available

#### Scenario: Name collision
- **WHEN** a proposed user automation normalizes to the name of an existing catalog entry
- **THEN** Pace does not overwrite the existing entry silently

### Requirement: Transcript fixtures precede voice testing
The routing and creation behavior SHALL be exercisable using text transcripts
without microphone, speech-recognition, screen-recording, or Accessibility
permission dependencies.

#### Scenario: Text routing fixture
- **WHEN** a test supplies a transcript and a deterministic embedding fixture
- **THEN** the selected, ambiguous, or fallthrough outcome is observable without audio input

#### Scenario: Text creation fixture
- **WHEN** a test supplies a create transcript and structured local-planner output
- **THEN** persistence, validation, or skill fallback is observable without audio input
