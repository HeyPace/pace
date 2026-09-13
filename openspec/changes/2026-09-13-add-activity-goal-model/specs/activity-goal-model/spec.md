# activity-goal-model Specification

## Purpose
Define the typed, provenance-bearing evidence and derived current-state hypothesis Pace uses to represent the user's active activity/goal.

## Requirements

### Requirement: Activity observations are typed and provenance-bearing
The system SHALL store accepted activity observations with an identifier, timestamp, evidence kind (`observed`, `inferred`, `userStated`, or `authorizedTask`), subject, confidence, provenance (source system and evidence reference id), and optional expiry.

#### Scenario: Frontmost app changes
- **WHEN** the frontmost application changes
- **THEN** the system records an `observed` activity observation naming the new application, its timestamp, and a bounded confidence

### Requirement: Current activity state remains linked to evidence
The system SHALL derive a current activity/goal-state hypothesis from observations and SHALL retain the identifiers of supporting and contradicting observations rather than discarding history.

#### Scenario: A newer activity supersedes an older one
- **WHEN** a higher-confidence observation names a different active subject than the current state
- **THEN** the current state points to the newer subject while the prior observation remains available as history

#### Scenario: Evidence is insufficient
- **WHEN** all supporting observations are expired, contradicted, or below the confidence threshold
- **THEN** the system reports the current activity state as unknown instead of presenting a stale subject as current

### Requirement: Corrections supersede rather than erase evidence
The system SHALL record an explicit user correction as a high-confidence `userStated` observation linked to the state it supersedes, and MUST NOT delete the superseded observation.

#### Scenario: User corrects the inferred activity
- **WHEN** the user states that the current activity is wrong and supplies the correct one
- **THEN** the current state adopts the correction and preserves the earlier observation as superseded history

### Requirement: Activity confidence decays without corroboration
The system SHALL treat an `observed` or `inferred` activity observation as stale once it exceeds its configured freshness window with no corroborating newer observation, and MUST NOT auto-expire `userStated` or `authorizedTask` evidence on that clock.

#### Scenario: Stale observation is not presented as current
- **WHEN** the most recent supporting `observed` observation is older than the freshness window and nothing newer corroborates it
- **THEN** retrieval reports the state as stale or unknown rather than presenting it as the current activity

### Requirement: Activity evidence is bounded and compacted
The system SHALL enforce a fixed retention cap on stored observations per tracked subject and SHALL compact the oldest entries first once the cap is exceeded, without losing the ability to state when compaction occurred.

#### Scenario: Observation count exceeds the cap
- **WHEN** the number of stored observations for a subject exceeds the configured limit
- **THEN** the system compacts the oldest entries and remains within the configured bound

### Requirement: Activity state is queryable with provenance
The system SHALL support retrieval of the current activity/goal state and SHALL return its confidence, evidence kind, and supporting observation ids with the result.

#### Scenario: A consumer asks for the current activity
- **WHEN** a caller requests the current activity/goal state
- **THEN** the system returns the current subject (or unknown), its confidence, and the observation ids that support it
