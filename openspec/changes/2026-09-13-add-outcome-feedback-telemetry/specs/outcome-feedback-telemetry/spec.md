# outcome-feedback-telemetry Specification

## Purpose
Define the typed, bounded record of what happened after Pace suggested or
acted (accepted, dismissed, undone — this proposal's scope), so a future
ranking/learning layer has real evidence to consume instead of inventing
new capture.

## Requirements

### Requirement: Intervention outcomes are typed and provenance-bearing
The system SHALL store accepted outcome records with an identifier,
timestamp, an `interventionKind` (`actionApproval`, `reversibleMutationUndo`
in this proposal's scope), an outcome (`accepted`, `dismissed`, `undone`),
a subject summary, and provenance (source system).

#### Scenario: User allows a risky action
- **WHEN** the user clicks "Allow Once" on the action-approval alert
- **THEN** the system records an `accepted` outcome for `interventionKind`
  `actionApproval` naming the approved action summary

#### Scenario: User cancels a risky action
- **WHEN** the user clicks "Cancel" on the action-approval alert
- **THEN** the system records a `dismissed` outcome for `interventionKind`
  `actionApproval` naming the cancelled action summary

#### Scenario: User taps undo
- **WHEN** the user taps the undo banner after a reversible mutation
- **THEN** the system records an `undone` outcome for `interventionKind`
  `reversibleMutationUndo` that identifies which specific reversible action
  it undoes

### Requirement: Outcome records never carry raw document or secure content
The system SHALL store only structural summary text already shown to the
user in-session (an approval or undo summary) and MUST NOT store document
body content, secure-field content, or raw AXUIElement/CF objects.

#### Scenario: Approval summary is stored, not the underlying content
- **WHEN** an accepted or dismissed outcome is recorded
- **THEN** the stored subject is the human-readable approval summary the
  user already saw in the alert, never the content of the action itself
  (e.g. an email body)

### Requirement: Outcome evidence is bounded per intervention kind
The system SHALL enforce a fixed retention cap on stored outcome records
per `interventionKind` and SHALL compact the oldest entries first once the
cap is exceeded.

#### Scenario: Outcome count exceeds the cap for one intervention kind
- **WHEN** the number of stored outcome records for one `interventionKind`
  exceeds the configured limit
- **THEN** the system compacts the oldest entries for that
  `interventionKind` and remains within the configured bound, without
  affecting the retention of any other `interventionKind`

### Requirement: Outcome history is queryable without mutation
The system SHALL support a read-only query returning outcome counts (and
derived rates) per `interventionKind` and MUST NOT mutate stored state when
answering it.

#### Scenario: A consumer asks for the acceptance rate of an intervention kind
- **WHEN** a caller requests outcome counts for `interventionKind`
  `actionApproval`
- **THEN** the system returns the `accepted` and `dismissed` counts among
  currently retained records without altering the store

#### Scenario: No records exist yet for a queried intervention kind
- **WHEN** a caller requests outcome counts for an `interventionKind` with
  no stored records
- **THEN** the system returns zero counts rather than fabricating a rate
