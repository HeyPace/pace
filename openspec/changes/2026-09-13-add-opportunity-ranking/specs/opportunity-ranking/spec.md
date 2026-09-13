# opportunity-ranking Specification

## Purpose
Define the deterministic, evidence-backed selection layer that coalesces
equivalent proactive-nudge candidates, enforces per-category cooldowns, ranks
survivors, and caps simultaneous emission — implementing
`proactive-companion-policy`'s existing "resists repetition" requirement.

## Requirements

### Requirement: Equivalent candidates are coalesced
The system SHALL treat candidates sharing the same category within the
configured coalescing window as equivalent and SHALL retain only the
highest-scored one for emission, recording the rest as coalesced rather than
silently discarding their existence from the evidence trail.

#### Scenario: Two generators fire the same category in one tick
- **WHEN** two candidate opportunities share the same category within the
  coalescing window
- **THEN** the system emits at most one of them and records the other as
  coalesced evidence

### Requirement: Category cooldowns are enforced independently of the global cooldown
The system SHALL track a last-emitted timestamp per category and SHALL
suppress a new candidate in the same category before its cooldown elapses,
independent of `PaceRestraintGate`'s existing global cooldown.

#### Scenario: Same category fires again inside its cooldown window
- **WHEN** a candidate's category was last emitted less than the configured
  category-cooldown interval ago
- **THEN** the system suppresses the new candidate and records the
  suppression reason as evidence

### Requirement: Survivors are ranked by explicit, retained factors
The system SHALL score each surviving candidate using relevance (against the
current activity/goal state), urgency, confidence, interruption cost, and
recent acceptance/rejection history where real data exists, and MUST record
which factors were available versus unavailable (never fabricate a factor
that has no real data source).

#### Scenario: Acceptance-history data does not exist yet for a candidate's kind
- **WHEN** no real outcome data exists for a candidate's opportunity kind
- **THEN** the system scores that factor as neutral/inert and marks it as
  unavailable in the evidence trail rather than presenting a fabricated
  value

### Requirement: At most one opportunity is emitted per evaluation tick
The system SHALL cap the number of opportunities selected for emission in a
single evaluation tick to the configured limit and SHALL expire any
candidate whose own relevance window has already elapsed before scoring it.

#### Scenario: Multiple independent generators produce candidates in the same tick
- **WHEN** more candidates than the configured cap pass coalescing and
  cooldown filtering
- **THEN** the system selects only the highest-ranked candidates up to the
  cap and records the rest as not selected, with the ranking evidence that
  produced that outcome

### Requirement: Every ranking decision is queryable evidence
The system SHALL expose a read-only query returning the full evidence trail
for a ranking decision (inputs, scores, coalescing/cooldown/cap outcomes)
without mutating any state.

#### Scenario: A caller asks why a candidate was or was not emitted
- **WHEN** a caller requests the evidence for a specific ranking decision
- **THEN** the system returns the retained inputs and outcome without
  altering the ranker's internal state

### Requirement: Ranking never widens what the restraint gate already approved
The system MUST NOT emit a candidate that `PaceRestraintGate.decide` did not
already resolve to `.speak` or `.queueUntilIdle` for its own evaluation
context. Ranking may only narrow (coalesce, suppress, cap) the set of
already-gate-approved candidates.

#### Scenario: A candidate the gate refused is never emitted by ranking
- **WHEN** a candidate's own restraint-gate evaluation resolved to
  `.stayQuiet`
- **THEN** the ranking layer never considers it as an emission candidate,
  regardless of its score
