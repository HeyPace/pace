# typed-local-automation-catalog Specification

## Purpose
Provide an honest local catalog that prefers typed deterministic automations
over planner-driven UI work and clearly labels when model reasoning remains.
## Requirements
### Requirement: Typed automation manifests compile to existing action plans
The system SHALL represent bundled deterministic automations as versioned
manifests containing canonical local tool calls and SHALL compile them through
the existing action parser into `PaceActionExecutionPlan`.

#### Scenario: Valid deterministic manifest
- **WHEN** every tool call names an allowed registered local tool and supplies valid arguments
- **THEN** the compiler produces the same typed action plan as an equivalent planner tool-call block

#### Scenario: Unknown or partially parsed tool call
- **WHEN** any manifest step names an unknown tool or cannot be completely parsed
- **THEN** startup validation fails with the automation identifier and invalid step
- **AND** no partial automation is installed or executed

#### Scenario: Forbidden capability
- **WHEN** a bundled deterministic manifest uses a script, MCP, download, destructive, nested-flow, or opaque Shortcut capability
- **THEN** startup validation rejects the manifest

### Requirement: Catalog entries disclose execution mode
The system SHALL expose one catalog shape over typed automations, recorded
flows, skills, and installed Shortcuts and SHALL label each entry's execution
mode.

#### Scenario: Typed bundled automation is listed
- **WHEN** a valid typed manifest is present
- **THEN** its catalog entry is labeled deterministic local

#### Scenario: Recorded flow is listed
- **WHEN** a saved `PaceRecordedFlow` exists
- **THEN** its catalog entry is labeled deterministic replay

#### Scenario: Skill is listed
- **WHEN** an installed or user-authored skill exists
- **THEN** its catalog entry is labeled planner grounded

#### Scenario: Shortcut is listed
- **WHEN** an installed macOS Shortcut exists
- **THEN** its catalog entry is labeled external opaque

### Requirement: Explicit catalog commands remain model-free
The system SHALL resolve “list my automations” and explicit “run automation
<name>” commands locally before screen capture or planner dispatch.

#### Scenario: Unique exact name match
- **WHEN** the normalized requested name exactly matches one catalog entry
- **THEN** Pace dispatches through that entry's existing source-specific path
- **AND** no model is used merely to select the automation

#### Scenario: No exact match
- **WHEN** no catalog entry has the requested normalized name
- **THEN** Pace reports not-found locally and executes nothing

#### Scenario: Cross-source name collision
- **WHEN** more than one catalog entry has the requested normalized name
- **THEN** Pace reports the conflicting source types locally and executes nothing

### Requirement: Bundled recipes describe real outcomes
The system SHALL ship only bundled automations whose descriptions are fulfilled
by their complete validated steps.

#### Scenario: Existing recipe is fully representable
- **WHEN** an existing recipe's advertised result can be implemented with allowed typed local tools
- **THEN** it is converted to a typed automation and retains only accurate copy

#### Scenario: Existing recipe requires unavailable reasoning or integration
- **WHEN** an existing recipe requires planner judgment, an unavailable external workflow, or an unimplemented system action
- **THEN** it is retired rather than shipped with incomplete behavior
- **AND** the reason is recorded in the failed-approaches documentation

### Requirement: Catalog metadata remains local
The system SHALL NOT add automation names, descriptions, or availability to
planner prompts, conversation memory, MCP calls, or off-device provider
requests.

#### Scenario: Off-device planner is configured
- **WHEN** a Direct API, CLI, or other off-device tier is selected
- **THEN** catalog discovery and exact routing remain local
- **AND** unmatched ordinary requests continue through existing routing without catalog injection

### Requirement: Starter automations remain truthful and bounded
The system SHALL ship a useful starter inventory of typed local automations
whose complete outcomes are represented by their validated native tool calls.

#### Scenario: Reusable native preset
- **WHEN** an automation is a fixed note template, Calendar range, timer duration, Finder location, current-window layout, or media adjustment
- **THEN** it may ship as a typed bundled automation
- **AND** its description states the literal outcome

#### Scenario: Contextual or app-specific work
- **WHEN** reusable work requires planner judgment, current-screen grounding, a recorded app-specific sequence, or an opaque OS workflow
- **THEN** it remains a skill, recorded flow, or Shortcut as appropriate
- **AND** the typed catalog does not claim to replace that executor

#### Scenario: Starter inventory drift
- **WHEN** an indexed starter manifest is missing, malformed, forbidden, or only partially parsed
- **THEN** startup validation fails before the catalog can advertise it
