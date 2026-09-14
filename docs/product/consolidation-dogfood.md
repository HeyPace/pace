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

## Human dogfood runbook (concrete, single-sitting)

This supersedes the old high-level script below with exact, code-grounded
steps — what to physically do, what the current implementation actually does
(not what would be nice), what to look at, and what to write down. Every
"Expected" line here is read directly out of the shipped code as of
`111368e`, not inferred or aspirational. Use Pace as a real product during
real work — **never manufacture a trigger just to produce a PASS.** A quiet
row with nothing to report is a valid, useful result.

**Prerequisites — check and record these before you start (part of your
baseline):**

- Launch only via Xcode `Cmd+R`. Never `xcodebuild` from a terminal for this
  — it can invalidate the interactive app's TCC grants (CLAUDE.md).
- Settings → Proactive → "Nudge surfaces" has three toggles, **all default
  OFF**: focus-fatigue ("After 45 minutes on the same app…"), calendar
  pre-meeting ("Five-minute heads-up before meetings…"), watch-mode
  observation ("When watch mode spots an error or failed build…"). Enable
  whichever you intend to exercise in section C — note which ones you turned
  on and when.
- The notch panel's "Approve Risky Actions" toggle gates whether an approval
  alert (and therefore any outcome-feedback record) ever appears. Note its
  current state.
- Settings → retrieval sources → "App usage journal" (`appUsageHistory`)
  defaults **ON**; it silently powers the Activity/Goal producer. Note its
  state — if it's off, section B's producer will never fire.
- Calendar pre-meeting nudges additionally need real Calendar (EventKit)
  permission and a genuine event starting within 5 minutes at some point —
  don't create a fake one just to pass; mark that row ENVIRONMENT if you
  don't have one.

### A. Start / baseline

**ACTION:** Quit any previous debug build. Launch fresh from Xcode
(`Cmd+R`). Open the notch panel.
**EXPECTED:** Clean launch, menu-bar icon only (no dock icon), no stuck
approval or undo banner left over from a previous run, permission rows match
what you actually granted.
**OBSERVE:** Menu-bar icon; notch panel; Xcode console for `🧭 Activity-goal
observations restored: N` / `📋 Intervention outcome records restored: N`
(these print only if a non-empty persisted file existed already); the
Proactive/toggle states listed above.
**RECORD:** Launch outcome; restored counts `N` if the lines appeared (this
is your baseline size for the Recovery section later); toggle states.
**PASS:** Clean launch, no crash, nothing stuck.
**FAIL:** Crash on launch; a stuck approval/undo banner inherited from
before; a permission row that's visibly wrong.
**ENVIRONMENT:** An Xcode/toolchain build failure unrelated to app logic
(e.g. a missing Metal Toolchain component) → BLOCKED — ENVIRONMENT, not FAIL.

### B. Activity / goal

There is no "Now" panel yet (Gap #5's UI is deliberately not built) — you
cannot ask Pace "what am I doing" through any UI. This section evidences the
invisible plumbing only, not a user-facing feature.

**ACTION:** Work normally 45-60+ minutes, switching between 2-3 real apps as
you naturally would. At some point, stay continuously frontmost in ONE app
for at least 45 uninterrupted minutes (this stretch doubles as section C's
focus-fatigue trigger).
**EXPECTED (from code):** Every frontmost-app switch silently records one
observation: `subject` = that app's real name, `confidence` = flat 0.5,
kind = `observed`. Nothing is displayed. If you stay in one app for more
than ~30 minutes without switching away, the underlying "current known
activity" silently reverts to unknown internally — observations only fire on
an app switch, never on a timer, and the derivation only trusts evidence
inside a rolling 30-minute freshness window. This is current, expected
behavior, not a bug to report — it does mean a long uninterrupted focus
stretch becomes "invisible" to this signal past 30 minutes.
**OBSERVE:** Nothing live — checkable only via the after-session spot-check
in section E, and indirectly via whether any nudge in section C ever feels
contextually on-target.
**RECORD:** Which real apps you used and roughly when you switched; whether
you did the required 45+ minute single-app stretch and which app.
**PASS/FAIL:** Judged only by section E's structural spot-check, not
anything observed live here.
**ENVIRONMENT:** If "App usage journal" was off (see prerequisites), this
producer never fires — mark ENVIRONMENT, not FAIL.

### C. Opportunity

**ACTION 1 (focus-fatigue):** Reuse section B's 45+ minute single-app
stretch. Stay off active calls during it (Zoom/Teams/FaceTime/Slack Huddle/
Meet frontmost pauses nudges rather than dropping them — see Expected).
**EXPECTED:** Evaluated on a 60-second tick, once you cross 45 continuous
minutes on one app, if you're not on an active call, not in a macOS Focus
mode, haven't typed/clicked in the last 3 seconds, it's been ≥15 minutes
since the last focus-fatigue nudge specifically, and ≥10 minutes since *any*
proactive nudge (the `.balanced`-profile global cooldown — shorter under
Talkative, longer under Reserved), Pace offers a short-break suggestion.
**OBSERVE:** Whether it appears, exact content, exact time relative to your
45-minute mark, whether an active call correctly delayed rather than
silently dropped it.
**RECORD:** Wall-clock time you crossed 45 minutes; time the nudge appeared
(if any); its content; call state at the time.

**ACTION 2 (calendar pre-meeting):** Only if you have a real event starting
within 5 minutes and Calendar permission granted.
**EXPECTED:** A heads-up nudge inside that 5-minute window.
**OBSERVE/RECORD:** Same pattern as Action 1.
**ENVIRONMENT:** No genuine upcoming event or no Calendar permission → mark
ENVIRONMENT; do not fabricate an event.

**ACTION 3 (watch-mode observation):** Only if Watch Mode is on and a real
error/failed build genuinely appears on screen during normal work — don't go
looking for one just to pass this row.
**EXPECTED:** An offer to help, at most once per 90 seconds from this
generator alone (its own per-generator cooldown), still subject to the
cross-category cap/cooldown below.
**OBSERVE/RECORD:** Same pattern.

**Cross-cutting, across whichever of the above actually fired:**
**EXPECTED:** At most one opportunity is ever surfaced at a time (ranking
caps at 1 winner per tick); the same category never repeats within 10
minutes of itself (category cooldown); a candidate that loses out isn't
shown to you at all — there is no evidence-trail UI yet, so you can only
observe "did I get spammed" vs. "did I get one clean suggestion."
**PASS:** Any nudge that did appear matches its documented threshold/
cooldown, reads as sensible for what you were actually doing, was delayed
(not lost) across an active call, and no same-category repeat within 10
minutes.
**FAIL:** A nudge fires during an active call and never arrives afterward;
two same-category nudges within 10 minutes; a nudge unrelated to anything
you were doing; more than one opportunity visibly live at once.
**ENVIRONMENT:** The relevant Settings toggle was off, or no genuine trigger
condition occurred (no real 45-min stretch, no real meeting, no real
on-screen error) — mark ENVIRONMENT for that specific row. Never force one.

### D. Outcome feedback

**Precision note — read before starting:** outcome-feedback telemetry today
records exactly two kinds of event: (1) your decision on a real
action-approval alert (Allow Once vs. Cancel) before Pace executes a
Level-3/irreversible action, and (2) tapping an Undo banner after Pace
executes a reversible action. It does **not** record accept/dismiss of a
proactive nudge from section C — nudge-level acceptance history is
honestly wired as permanently `.unavailable` in the ranking scorer (a
documented design decision — no nudge-level accept/dismiss producer exists
yet). If you only interact with section C's nudges, this section has
nothing real to record: write `ACCEPTANCE HISTORY: UNAVAILABLE` and move on
— that is correct, not a failure.

**ACTION 1 (approval):** Ask Pace (voice/typed) to perform something that
triggers a real approval alert (which actions require approval is decided
by the agent's own runtime risk classification — you can't predict it in
advance; if an alert appears, that's your trigger). Click "Allow Once" once;
on a separate occasion, click "Cancel".
**EXPECTED:** Your decision is recorded as accepted/dismissed — a structural
record only, never shown back to you anywhere yet.
**OBSERVE/RECORD:** What was proposed; which decision you made; whether the
alert text was clear enough to decide confidently.

**ACTION 2 (undo):** Have Pace perform a real reversible mutation, then tap
the Undo banner.
**EXPECTED:** The undo executes cleanly and is recorded.
**OBSERVE/RECORD:** What was undone; whether the reversal was correct and
complete.

**ACTION 3 (decline persistence):** After Cancelling an approval once, ask
for something equivalent again shortly after.
**EXPECTED:** Pace does not silently re-execute without a fresh prompt — no
standing authorization, no automatic reauthorization.
**OBSERVE/RECORD:** Whether a fresh prompt appears again, or whether Pace
silently proceeds (a real defect if so).

**PASS:** Approve/cancel both behave as described; undo actually reverts;
no silent bypass after a decline; honestly-unavailable acceptance history is
reported as such when that's what happened.
**FAIL:** An approval-bypass; undo does the wrong thing or nothing; a crash
in either flow.
**ENVIRONMENT:** `EnableActions` disabled (no actions execute at all) or
"Approve Risky Actions" off (alerts are skipped) — check this deliberately
during baseline if you want to exercise this section; note the toggle state
either way.

### E. Privacy

**ACTION:** After A-D, spot-check without pasting contents:
`~/Library/Application Support/Pace/activity-goal-model.json` and
`~/Library/Application Support/Pace/intervention-outcomes.json` (read-only
inspection of your own files — doesn't touch TCC). Look at field
**structure**, not specific values to remember.
**EXPECTED:** `activity-goal-model.json` entries contain only `subject` (a
running application's display name), a confidence number, timestamps, and an
evidence-kind string — never a window title, document name, URL, or typed/
read text. `intervention-outcomes.json` entries contain only an
`interventionKind`/`outcome` enum, a short `subject` summary already shown to
you in the alert/banner (nothing new), and timestamps — never credentials,
OTPs, payment data, or full document contents.
**OBSERVE:** Field names and value shapes; whether any value looks longer/
richer than a short structural label.
**RECORD:** PASS/FAIL only — never copy actual field values into the log
(per the log's own rule below). If something looks wrong, describe its
*category*, not its literal text.
**PASS:** Both files contain only the structural fields described.
**FAIL:** Any literal password/OTP/payment value, secure-field content, raw
AX internals/identifiers, or full document/message content in either file.
**ENVIRONMENT:** A file doesn't exist because its producer never fired this
session (e.g. no approval was ever triggered) — expected, not a privacy
issue; mark N/A for that file.

### F. Recovery

**ACTION:** Quit Pace and relaunch via Xcode `Cmd+R` (never terminal
`xcodebuild`), only where safe (not mid-action).
**EXPECTED:** The two "restored: N" console lines show counts that grew or
held steady vs. section A's baseline, never shrank unexpectedly; no approval
banner reappears for something already decided; no undo banner reappears for
an already-undone action; nothing from before the quit silently resumes on
its own.
**OBSERVE:** Console restore-count lines; UI state immediately after
relaunch; whether anything auto-continues without your input.
**RECORD:** Restored counts before vs. after; any stuck/duplicate/
re-prompted state.
**PASS:** Coherent post-relaunch state; counts make sense; no stale-approval
reuse; no unauthorized automatic continuation.
**FAIL:** A duplicate action re-executes; an old approval is silently
reused instead of re-prompting; a stuck banner; restored counts don't make
sense given what happened this session.
**ENVIRONMENT:** None expected here by default — a real relaunch defect is a
genuine finding, not environmental, unless it's clearly a known TCC quirk
(e.g. a permission re-prompts once right after a fresh grant) — name the
specific prompt if so.

## Result template (fill in per session)

```
DATE:
BUILD (git HEAD):
SESSION LENGTH:

Prerequisites
Nudge surfaces enabled (focus-fatigue / calendar / watch-mode):
Approve Risky Actions:
App usage journal:

A. Start / baseline
Restored counts (activity-goal / intervention-outcome):
PASS/FAIL:
Notes:

B. Activity/Goal
Apps used + switch times:
45-min single-app stretch (app, start time):
PASS/FAIL (from section E spot-check):
Notes:

C. Opportunity
Scenario (focus-fatigue / calendar / watch-mode):
Observed:
Expected:
Useful?:
Relevant?:
Annoying?:
PASS/FAIL:
Notes:

D. Outcome
Scenario (approval accept / approval cancel / undo / decline-persistence):
Observed:
Expected:
PASS/FAIL:
Notes:
ACCEPTANCE HISTORY: UNAVAILABLE (expected — do not mark as failure)

E. Privacy
activity-goal-model.json PASS/FAIL:
intervention-outcomes.json PASS/FAIL:
Notes (category only, never literal values):

F. Recovery
Restored counts before -> after:
PASS/FAIL:
Notes:

Overall
PASS / PARTIAL / FAIL:
One thing that most needs to change:
```

### Superseded: original high-level script

Kept for reference; the concrete runbook above is more precise and should be
used instead. The intent is the same: use Pace as a real product during real
work, never manufacture a situation just to produce a PASS.

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
