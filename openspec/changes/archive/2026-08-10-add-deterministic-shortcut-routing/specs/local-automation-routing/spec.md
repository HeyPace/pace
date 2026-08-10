## Purpose

Allow Pace to discover and invoke explicitly named local automations without
model reasoning while retaining the existing action safety and privacy policy.

## ADDED Requirements

### Requirement: Explicit Shortcut commands bypass model reasoning
The system SHALL recognize explicit list and run commands for macOS Shortcuts
before screen capture, VLM inference, or planner dispatch.

#### Scenario: User runs an installed Shortcut by exact name
- **WHEN** the user explicitly asks to run a Shortcut and the normalized requested name exactly matches an installed shortcut
- **THEN** the system routes the original installed display name through the existing `.runShortcut` action path
- **AND** no screenshot, VLM, or planner request is required to resolve the command

#### Scenario: Transcript is not an explicit Shortcut command
- **WHEN** the transcript does not match the bounded Shortcut command grammar
- **THEN** the system leaves it untouched for the existing Pace routing pipeline

#### Scenario: Requested Shortcut is not installed
- **WHEN** the user explicitly names a Shortcut that has no exact normalized catalog match
- **THEN** the system does not execute any shortcut
- **AND** it returns a local not-found response without asking a model to invent an alternative

### Requirement: Shortcut discovery is bounded, local, and failure-aware
The system SHALL discover installed shortcut names through the local macOS
Shortcuts command-line interface and SHALL expose success and failure as
distinct typed outcomes.

#### Scenario: Discovery succeeds
- **WHEN** `/usr/bin/shortcuts list` succeeds
- **THEN** the provider returns non-empty trimmed display names in stable sorted order
- **AND** it may reuse the successful catalog for no longer than five minutes

#### Scenario: Discovery returns no names
- **WHEN** the command succeeds with no non-empty shortcut names
- **THEN** the provider returns a successful empty catalog rather than a failure

#### Scenario: Discovery fails
- **WHEN** the command cannot launch or exits unsuccessfully
- **THEN** the provider returns a bounded local failure description
- **AND** it does not cache that failure as a successful catalog

### Requirement: Existing action policy governs Shortcut execution
The system SHALL route deterministic Shortcut execution through Pace's existing
action-plan preflight, approval, executor, observation, feedback, and audit
surfaces.

#### Scenario: Actions are disabled
- **WHEN** an installed Shortcut matches but Pace actions are disabled
- **THEN** the system records the action as skipped and does not run the Shortcut

#### Scenario: User denies approval
- **WHEN** the Shortcut action requires approval and the user denies it
- **THEN** the system does not invoke the Shortcuts command-line runner
- **AND** it records the denial through the existing action-run surface

#### Scenario: Approved execution completes
- **WHEN** the installed Shortcut matches and the user approves execution
- **THEN** the existing Shortcut executor performs its fresh installed-name validation and runs it
- **AND** Pace reports the executor's success or failure observation

### Requirement: Shortcut metadata remains on-device
The system SHALL NOT append the installed Shortcut catalog to planner prompts,
MCP requests, telemetry, or off-device provider requests.

#### Scenario: Off-device planner tier is configured
- **WHEN** Direct API, CLI, or another off-device planner tier is active
- **THEN** deterministic Shortcut resolution still occurs locally
- **AND** the installed Shortcut names are not included in that provider's request
