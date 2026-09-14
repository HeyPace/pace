# Consolidation-plan dogfood gate (Gap #1/#2/#3)

This is the dogfood protocol for `docs/current/plans/autonomous-companion-consolidation.md`'s
recommended-order items 3-5 (outcome/feedback telemetry, the typed
activity/goal model, and opportunity ranking — all shipped
2026-09-13/14) before Gap #5 (product-surface consolidation: Now / Working /
Memory) is designed. Mirrors `companion-mode-dogfood.md`'s protocol: this
page records what was measured and when, and is explicit about what has
**not** been performed yet. No row here is represented as passed until dated
evidence backs it.

**Status as of 2026-09-14: AUTOMATED ACCEPTANCE — PASS. HUMAN DOGFOOD — NOT
YET PERFORMED.** Every one of the three layers is exercised only by unit
tests and static/code-review evidence so far; none has been exercised by a
real user during real work. See the full findings report in the session that
produced this page for the reasoning behind every row below.

## Gap #5 readiness (surface projection foundation)

**Status as of 2026-09-14: plumbing — AUTOMATED PASS. UI/UX design — NOT
STARTED (deliberately deferred, see below).**

`PaceSurfaceProjection.swift` + `CompanionManager+SurfaceProjection.swift`
(committed alongside this update) implement the deterministic, read-only data
layer Gap #5's Now/Working/Memory surfaces need, without building the surfaces
themselves:

- **Now** `<-` `PaceActivityGoalStore` (Gap #1) + the opportunity-ranking
  Slice 3 evidence query (Gap #2's `mostRecentRankingResult`) — current
  activity subject (or none, never fabricated) and at most one active
  opportunity, reusing the exact `spokenText` already judged safe to speak
  aloud.
- **Working** `<-` `PaceBackgroundAgentRunner` (pre-existing, never
  UI-consumed before this) — task list capped at 20, literal
  `resultSummary`/failure-detail text deliberately excluded (`hasResult: Bool`
  only).
- **Memory** `<-` `PaceEpisodicFactStore` — durable facts capped at 50,
  sensitive-topic facts re-filtered independently of the caller as defense in
  depth.

This is composition over existing, already-accepted models — no new
persistence, no new durable state, no new capture surface. It was justified
without further human/product input because every field it exposes was
already produced and privacy-reviewed by a prior, owner-confirmed proposal;
nothing here introduces new subjective UX surface area.

**Genuinely deferred, not done here:** the actual Now/Working/Memory panel
UI — what it looks like, where it lives in the menu-bar surface, how a user
dismisses/forgets an item — is a real product/UX decision this session did
not have standing to make unilaterally, and depends on the seven-day human
dogfood evidence this page tracks. `PaceSurfaceProjection.swift`'s own header
comment states this explicitly so a future agent does not mistake the
plumbing for the finished feature.

Evidence level: automated only (17 new tests in
`PaceSurfaceProjectionTests.swift` + 3 in
`PaceProactiveNudgeFrameworkTests.swift`, all Swift-Testing/XCTest unit
tests — pure value types and functions, no AX/AppKit surface, so no native
E2E applies). No human dogfood performed on this projection specifically
(nothing renders it yet).

## Dogfood matrix

Classification legend: **AUTOMATABLE** (a unit/integration test can prove
this without a human), **HUMAN-ONLY** (requires a person using the real app
during real work — cannot be faked without violating "no fabricated dogfood"),
**HYBRID** (the mechanism is automatable; whether it is actually *useful* in
practice is not).

| # | Item | Classification | Automated evidence today | What still needs a human |
| --- | --- | --- | --- | --- |
| A | Goal creation / goal lifecycle | HYBRID | `PaceActivityGoalModelTests` (19 tests): schema round-trip, supersession, retention, cap | Does a real goal actually reflect what the user is doing? |
| B | Activity transitions | HYBRID | `PaceActivityGoalProducerTests` (6 tests): producer wiring, store correlation | Real multi-app session realism, transition timing |
| C | Opportunity generation | HYBRID | 3 existing generator test files (focus-fatigue, calendar-pre-meeting, watch-mode) | Real triggers (an actual 45-min focus stretch, a real meeting) |
| D | Opportunity ranking | AUTOMATABLE | `PaceOpportunityRankingTests` (13 tests): coalesce/score/cap, pure function | — |
| E | Global cooldown | AUTOMATABLE | `PaceRestraintGateFocusModeTests` + existing restraint-gate tests | — |
| F | Category cooldown | AUTOMATABLE | `PaceOpportunityRankingTests` + `PaceProactiveNudgeOrchestratorRankingTests` (5 tests) | — |
| G | Coalescing | AUTOMATABLE | `PaceOpportunityRankingTests`: same-category-picks-highest-scored | — |
| H | Negative/feedback handling | **BLOCKED BY DESIGN** | N/A — `acceptanceHistory` is honestly `.unavailable` (D1, `openspec/changes/2026-09-13-add-opportunity-ranking/design.md`); no nudge-level accept/dismiss producer exists | Cannot be dogfooded until a real producer is built — separate future proposal |
| I | Proactive nudges | HYBRID | Generator + orchestrator wiring tests | Are they timely and welcome, or annoying? |
| J | Outcome recording | AUTOMATABLE (mechanism) / HUMAN-ONLY (real decisions) | `PaceInterventionOutcomeModelTests` (12) + `PaceOutcomeFeedbackTelemetryProducerTests` (7) | Real accept/dismiss/undo decisions during real use |
| K | Recovery | HYBRID | Persistence round-trip tests (corrupt-file, nil-fileURL, restore-reapplies-cap) for both new stores | Real app relaunch behavior on real hardware |
| L | Persistence | AUTOMATABLE (mechanism) | Same persistence tests; both stores use the atomic-JSON pattern | Real multi-day disk growth |
| M | Restart behavior | HUMAN-ONLY | N/A — genuine `Cmd+R` relaunch cannot be simulated in isolated-DerivedData unit tests | Full restart + inspect durable state |
| N | Model failure / unavailable backend | AUTOMATABLE | `PaceCompanionWakeGateTests` and existing local-model-unavailable coverage (pre-existing, unmodified) | — |
| O | Permission denial | AUTOMATABLE (mechanism) / HUMAN-ONLY (live TCC) | Existing `BLOCKED — TCC` pattern throughout the AX capability suites | Live revoke/restore in System Settings |
| P | Resource limits | AUTOMATABLE (bounds) / HUMAN-ONLY (real measurement) | 200-per-subject / 200-per-interventionKind caps proven in unit tests | Real CPU/memory/disk over hours, mirroring `companion-mode-dogfood.md`'s threshold table |
| Q | Privacy boundaries | AUTOMATABLE | Reflection-based field-set tests on both new record types (`PaceActivityObservation`, `PaceInterventionOutcomeRecord`) | Spot-check real persisted files (see Privacy Findings) |
| R | Duplicate prevention | AUTOMATABLE | Coalescing tests, dedup tests, per-subject/per-kind cap tests | — |
| S | User-visible usefulness | **HUMAN-ONLY** | None — cannot be automated by definition | Everything in this document exists to collect this |

## Human dogfood script

Use Pace as a real product during real work. Do not manufacture situations a
normal workday already exercises.

1. Start a real task in Pace (voice or typed).
2. Let Pace observe your activity for a normal stretch (an hour or more,
   switching apps as you naturally would).
3. Let a proactive opportunity appear where one naturally would (a long
   focus stretch, an upcoming meeting, a screen error) — do not force one.
4. Accept or reject the suggestion the way you actually would.
5. Perform a real action through Pace (a note, a reminder, an undo).
6. Notice whether Pace's behavior suggests it understood what you were
   doing — right subject, right timing.
7. Change context or application deliberately, the way a real workday does.
8. Return to a previous activity later and notice whether Pace's context
   reflects that continuity or has gone stale.
9. Quit and relaunch Pace (`Cmd+R` from Xcode, or the built app) where safe.
10. Check whether the state after relaunch is coherent — no stale
    approvals, no duplicate actions, no lost context that should have
    survived.
11. If a suggestion is genuinely unwelcome or wrong, reject/undo it — this
    is useful negative-outcome evidence, not a failure of the exercise.
12. If the same context repeats (e.g., you stay in the same app for hours),
    notice whether Pace becomes repetitive or noisy about it.
13. Judge, as yourself: was each suggestion timely? Was it useful? Would
    you have wanted it sooner, later, or not at all?

## Human observation log

One row per meaningful event. Keep entries categorical — do not paste raw
document/message content, credentials, or unrelated personal information
into this log.

| TIME | CONTEXT | WHAT PACE DID | WHAT YOU EXPECTED | USEFUL? | TOO EARLY? | TOO LATE? | REPETITIVE? | WRONG? | MISSING? | PRIVACY CONCERN? | WHAT SHOULD HAVE HAPPENED? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | Y/N/Partial | Y/N | Y/N | Y/N | Y/N | Y/N | Y/N | |

## Seven-day acceptance plan

Normal usage with structured observation — not a full day of scripted
actions. Fill in the observation log above as things happen; a quiet day
with nothing to log is itself a valid, useful result.

**Day 1 — Baseline / normal usage.** Realistic tasks: use Pace exactly as
you normally would, companion mode and proactive nudges on. Observe: does
anything feel different from before this session's changes? Success: no
crashes, no regressions in ordinary use. Failure: any crash, hang, or
obviously wrong action. Evidence: observation log rows, any crash log.

**Day 2 — Proactive companion behavior.** Realistic tasks: a normal
work day with at least one long focus stretch and, if one exists on your
calendar, a real meeting. Observe: does a nudge appear near the 45-minute
focus-fatigue threshold or the 5-minute pre-meeting window? Success: nudges
appear near their documented thresholds and respect active-call/cooldown
restraint. Failure: nudge during a call, nudge that never fires, or a nudge
that fires but makes no sense. Evidence: observation log; note the
timestamp so it can be cross-referenced against `PaceTelemetryLog` if
needed.

**Day 3 — Goal/activity continuity.** Realistic tasks: work across at least
3 different apps over the day, including returning to an earlier one.
Observe: if you had a way to ask Pace "what am I doing," would the answer
be right? (No UI exists yet for this — judge from Pace's behavior/spoken
references, if any.) Success: nothing to report is itself fine — this day is
mostly evidence-gathering for Gap #5. Failure: obviously stale or wrong
activity influencing a nudge. Evidence: observation log.

**Day 4 — Opportunity ranking / repetition.** Realistic tasks: a day with
more app-switching or meeting density than usual, if your schedule allows.
Observe: do you ever get two nudges back-to-back that feel like the same
thing? Does a nudge repeat too often for the same situation? Success: at
most one nudge per situation, no back-to-back repeats. Failure: duplicate or
rapid-repeat nudges for the same category. Evidence: observation log,
noting exact times of any repeats.

**Day 5 — Outcome / feedback.** Realistic tasks: deliberately accept at
least one suggestion and reject/undo at least one other during normal work
(don't force unnatural ones — most days will have both naturally). Observe:
does undo work cleanly? Does declining an approval feel respected (Pace
doesn't re-ask immediately)? Success: accept and reject both behave as
expected, no re-prompting after a decline. Failure: any approval-bypass
feeling, or undo doing the wrong thing. Evidence: observation log.

**Day 6 — Restart / recovery / privacy.** Realistic tasks: quit and
relaunch Pace at least once during the day (from Xcode `Cmd+R`, never
terminal `xcodebuild`). Observe: does everything feel coherent after
relaunch — no duplicate actions, no stuck approval banners? Spot-check (do
not paste contents into the log) whether anything in
`~/Library/Application Support/Pace/*.json` looks like it shouldn't be
there. Success: coherent post-relaunch state, no privacy surprises.
Failure: duplicate action, stuck state, or unexpected persisted content.
Evidence: observation log; a `BLOCKED` note if TCC prevents a spot-check.

**Day 7 — Overall usefulness and product judgment.** Realistic tasks: a
normal day, then a short reflection at the end. Observe: across the whole
week, was Pace net-useful, net-neutral, or net-annoying? What's the one
thing that most needs to change before you'd want a "Now" surface showing
this information at a glance? Success/failure: this day is a judgment call,
not a pass/fail gate — the goal is the reflection itself. Evidence: a short
free-text summary at the end of the observation log.

## Documents test-artifact status

`q_plan_test_*` fixture leakage into the real `~/Documents` was fixed
2026-09-13 (see `docs/knowledge/failed-approaches.md`). The 2,110
already-existing stale directories from before the fix could not be cleaned
up automatically — this session's process lost read/write access to
`~/Documents` (macOS TCC), confirmed via `ls`/`rmdir` both returning
"Operation not permitted" while `stat` on the directory itself still
succeeds. No new `q_plan_test_*` directories have appeared since the fix
(confirmed via repeated `mdfind` counts staying at exactly 2,110 across many
subsequent full-regression runs). Cleanup command for whoever has Full Disk
Access:

```bash
find ~/Documents -maxdepth 1 -type d -name 'q_plan_test_????????-????-????-????-????????????' -print0 | xargs -0 rm -rf
```
