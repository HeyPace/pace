# action-state-observation Specification

## Purpose
Reduce repeated computer-use latency by advancing from an action as soon as
observable application state changes, while retaining bounded conservative
fallbacks when no reliable state change is available.
## Requirements
### Requirement: Action settling is state-driven and bounded
The system SHALL compare current observable application state with a pre-action
baseline at a bounded polling cadence and SHALL stop waiting when the state
changes, the configured timeout is exhausted, or the task is cancelled.

#### Scenario: State changes before the timeout
- **WHEN** observable application state differs from the pre-action baseline during the configured wait window
- **THEN** the system returns a changed outcome without waiting for the remainder of the window

#### Scenario: State does not change
- **WHEN** observable application state remains equal to the pre-action baseline for the full configured wait window
- **THEN** the system returns a timed-out outcome after preserving the configured fallback duration

#### Scenario: Waiting is cancelled
- **WHEN** the active action task is cancelled while waiting for a state change
- **THEN** the system returns a cancelled outcome and performs no further polls
- **AND** the executor does not dispatch later actions from the cancelled plan

### Requirement: Click verification and agent-loop settling share one contract
The system SHALL use the same action-state observation behavior for candidate
click verification and for settling before the next screen-dependent agent
step, with call-site-specific bounded configurations.

#### Scenario: Candidate click changes application state
- **WHEN** a candidate click produces observable state before the click-verification window expires
- **THEN** the click is accepted without waiting for the full legacy verification duration

#### Scenario: Candidate click produces no observable state
- **WHEN** a candidate click produces no observable state during the click-verification window
- **THEN** the existing next-candidate or click-failure behavior runs after the bounded window

#### Scenario: Agent action changes application state
- **WHEN** an executed action sequence changes observable state before the next screen-dependent step
- **THEN** the agent loop proceeds to its next capture without paying the full legacy settle duration

#### Scenario: Agent action exposes no observable state
- **WHEN** an executed action sequence exposes no observable state during the agent-loop window
- **THEN** the system waits no longer than the existing conservative fallback before taking the next capture

