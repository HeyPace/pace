# transcript-grounded-actions Specification

## Purpose
TBD - created by archiving change adaptive-meeting-notes. Update Purpose after archive.
## Requirements
### Requirement: Action items carry an optional transcript source

Each `PaceMeetingActionItem` SHALL support an optional source reference consisting of
a transcript timestamp and a short verbatim quote identifying where the action was
agreed. The field SHALL be optional so profiles and planners that do not produce
grounding still yield valid notes, and so previously persisted notes decode without
error.

#### Scenario: Grounded action item resolves to a captured turn

- **WHEN** synthesis returns an action item with a quote that matches text in a captured `PaceMeetingTurnRecord`
- **THEN** the action item's source reference carries that turn's timestamp and quote

#### Scenario: Ungrounded action item is still valid

- **WHEN** synthesis returns an action item with no resolvable source
- **THEN** the action item is kept with a nil source reference and no error is raised

#### Scenario: Backward-compatible decode

- **WHEN** a `PaceMeetingNotes` value persisted before this change is decoded
- **THEN** it decodes successfully with all action-item source references nil

### Requirement: Grounding surfaced in panel and retrieval

The meeting panel SHALL render each grounded action item with an affordance to jump
to its transcript source, and the journaled retrieval document text SHALL include the
grounding (timestamp/quote) so recall queries about who-agreed-what improve.

#### Scenario: Panel exposes jump-to-transcript

- **WHEN** the notes card renders an action item that has a source reference
- **THEN** the card shows a control that reveals the referenced transcript turn

#### Scenario: Retrieval text includes grounding

- **WHEN** a meeting with grounded action items is journaled
- **THEN** the retrieval document text contains the action item grounding so it is lexically matchable
