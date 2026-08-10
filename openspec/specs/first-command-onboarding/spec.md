# first-command-onboarding Specification

## Purpose
Turn Pace's first launch into a memorable but honest path from local promise to
one real successful command.
## Requirements
### Requirement: First launch begins with a skippable ignition scene
The system SHALL introduce Pace with one focused full-window scene whose signal
visual connects the product promise to the physical notch.

#### Scenario: New user launches Pace
- **WHEN** the current onboarding version has not been completed
- **THEN** Pace opens the ignition scene with immediate Continue and Skip controls
- **AND** communicates that requests run on the Mac by default

#### Scenario: Existing user launches Pace
- **WHEN** the current onboarding version was already completed
- **THEN** Pace does not show the first-run window automatically
- **AND** normal menu-bar startup remains unchanged

#### Scenario: User replays onboarding
- **WHEN** the user chooses Replay Introduction from Help or the Command Center
- **THEN** Pace opens the journey without clearing permissions, data, or completion history

### Requirement: Core permission setup is truthful and resumable
The system SHALL explain Accessibility, Screen Recording, and Microphone as
separate permission channels backed by live macOS permission state.

#### Scenario: Permission is not granted
- **WHEN** a required permission channel is unavailable
- **THEN** onboarding explains the user-visible benefit and privacy boundary
- **AND** uses the existing permission request or System Settings deep link

#### Scenario: Permission changes outside Pace
- **WHEN** the user grants a permission in System Settings and returns
- **THEN** the corresponding channel updates from the shared permission service
- **AND** the user's progress does not reset

#### Scenario: User skips setup
- **WHEN** the user skips a permission or the entire journey
- **THEN** Pace records the current onboarding checkpoint
- **AND** the everyday interface continues to report the missing capability honestly

### Requirement: Onboarding reaches a real first command
The system SHALL let the user speak or type one command and SHALL submit it
through the same finalized-transcript path used after onboarding.

#### Scenario: User submits the suggested command
- **WHEN** the user explicitly submits the suggested safe command
- **THEN** Pace sends that exact text through the production transcript handler
- **AND** displays real planning, approval, action, and outcome state

#### Scenario: User enters a different command
- **WHEN** the user replaces the suggestion with another supported request
- **THEN** Pace submits the user's text unchanged through the same production path
- **AND** the journey does not require a special onboarding command grammar

#### Scenario: Runtime is not ready
- **WHEN** permissions, model readiness, action enablement, or another production precondition prevents execution
- **THEN** onboarding shows the real unmet precondition and a direct recovery action
- **AND** does not play the success or completion transition

### Requirement: Completion hands off into the everyday product
The system SHALL make the final onboarding transition visually and behaviorally
continuous with the real notch and quick panel.

#### Scenario: First command completes
- **WHEN** the production path reports a successful response or action outcome
- **THEN** the full-window signal contracts toward the notch-shaped anchor
- **AND** the onboarding window closes into the real ready panel state

#### Scenario: First command does not mutate the Mac
- **WHEN** the submitted request produces an answer but no action
- **THEN** that truthful response still counts as first value
- **AND** the completion copy does not claim that Pace moved or changed an app

#### Scenario: Completion is persisted
- **WHEN** the user finishes or skips the journey
- **THEN** Pace stores a versioned completion value
- **AND** later onboarding revisions can choose whether a lightweight new-feature scene is warranted without resetting first-launch data

### Requirement: Onboarding remains operable without cinematic motion
The system SHALL preserve the entire first-run task under Reduce Motion,
keyboard-only input, and VoiceOver.

#### Scenario: Reduced-motion onboarding
- **WHEN** Reduce Motion is enabled
- **THEN** scene changes use opacity or immediate replacement rather than signal travel or scale collapse
- **AND** the same first command and completion controls remain reachable

#### Scenario: Keyboard-only onboarding
- **WHEN** the user does not use a pointer
- **THEN** focus order follows scene content, primary and skip actions are visible, and Return submits only the focused eligible action

#### Scenario: VoiceOver reads progress
- **WHEN** VoiceOver is active
- **THEN** the current step, permission states, request state, and outcome are announced as semantic labels
- **AND** decorative signal geometry is hidden from the accessibility tree
