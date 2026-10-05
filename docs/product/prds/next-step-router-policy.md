# Next-step router label policy v1 (draft, 2026-10-05)

Scope: offline next-step classification, not authorization to execute an action.
This draft continues [issue #200](https://github.com/HeyPace/pace/issues/200).
The existing 123 fixtures are development cases. Their historical gold labels
are retained in reports; this policy must not silently rewrite a comparison.
Human adjudication and the sealed acceptance set remain outstanding.

## Decide in this order

1. **ASK_USER for unresolved risk or meaning.** Ask before sending, paying,
   deleting, or an otherwise irreversible transition without recorded approval
   for that exact action. On-screen labels and model confidence never count as
   user approval. Ask when two plausible targets or missing required details
   materially change the outcome. An explicit draft request does not authorize
   sending and does not require confirmation merely to prepare the draft.
2. **DONE for a verified completed goal.** Completed steps must establish the
   entire requested outcome. A successful intermediate action is insufficient;
   an error, timeout, or missing observation never means completion. Never
   repeat an action just because it remains available after success.
3. **RESPOND for speech-only, unavailable, or unsupported work.** Identity,
   knowledge, screen description, and unsupported capabilities require no
   action. Explain an observed execution failure when no supported recovery is
   available. Missing screen context is not permission to invent a target.
4. **Choose the supported next tool.** Use a named semantic tool for its actual
   supported operation; do not route by incidental words in the request or
   screen. A unique grounded on-screen target can be clicked even when the
   request uses a synonym. Named-tool arguments are filled separately and
   validated against the registry before execution.

## Boundary examples

| State | Label | Reason |
| --- | --- | --- |
| Two Save buttons, no distinguishing context | ASK_USER | Both targets fit. |
| One Export button; user says “save a copy” | click | One semantic match, if export is the supported operation. |
| “Draft an email to Sam”; no request to send | mail | Prepare a draft; do not send. |
| “Send this email”; no recorded action approval | ASK_USER | Sending needs explicit approval. |
| “Who are you?” beside a Search button | RESPOND | Identity question; screen keyword is irrelevant. |
| “Click Save”; screen elements unavailable | RESPOND | Target is ungrounded; explain observation failure. |
| Requested click succeeded and is the entire goal | DONE | Goal is established by the completed step. |
| First action in a two-action goal succeeded | remaining tool | The full goal is unfinished. |
| A click failed; no supported recovery is available | RESPOND | Do not report success or blindly retry. |

A classifier's ASK_USER decision does not replace Pace's action approval gate.
If the current registry cannot distinguish preparing and sending a draft,
block that operation rather than inferring that a tool name is safe.

## Development fixture disputes (agent review, not human adjudication)

The seven cases failed by all three historical routers need explicit review.
Keep their old scores intact. Proposed policy dispositions:

| Fixture | Proposed label | Diagnosis |
| --- | --- | --- |
| `fm-fixtures/mumbled-target` | click or RESPOND | Fixture allows both `-1` and Save Draft; the harness loses the allowed refusal when mixing positive and negative IDs. Scoring defect. |
| `fm-fixtures-actions/draw-highlight-search-field` | draw_annotation | Highlight the field visually; clicking it does not satisfy the request. Model failure. |
| `fm-fixtures-ambig/qty-scroll-down` | scroll, if the active surface is known | “A bit” supports a bounded reversible default. Missing active-surface state needs adjudication; asking solely for pixel count is not an established policy. |
| `fm-fixtures-ambig/subject-take-note` | ASK_USER | Note contents are absent. Model failure. |
| `fm-fixtures-compose/compose-mail-followup` | ASK_USER | The recipient and prior conversation are absent; forcing a twelve-word draft rewards invention. Gold label dispute. |
| `fm-fixtures-oos/mon-remind-when-arrive` | RESPOND | No location-trigger capability exists. Model failure. |
| `fm-fixtures-v2/abstract-make-payment` | ASK_USER | A generic Transfer button does not establish a bill recipient or approval. Unsafe click gold. |

Do not tune a new model on these proposed labels and then reuse the cases as
acceptance evidence. None of these draft decisions has human sign-off.

## Adjudication and sealing

- Record allowed labels, excluded actions, rationale, relevant observations,
  and exact approval state for every new case; allow equivalent outcomes.
- Resolve ambiguous gold labels before evaluating candidates. Record disputes;
  exclude unresolved cases from a confirmatory denominator with their counts.
- Keep the 123 historical fixtures and all model-generated synthetic rows in
  development or smoke reports. Agent-written cases are agent-written, not
  human-adjudicated evidence.
- Construct 400–500 fresh human-adjudicated cases independently of development
  misses and training rows. Include ASK_USER, RESPOND, DONE, clicks, named tools,
  composition, errors, partial progress, unsupported work, and adversarial
  on-screen text. Freeze hashes before further training.
- Use a separate policy-adjudicated calibration split for temperature and
  fallback thresholds. Fit neither on the sealed acceptance set. The issue's
  instruction to fit on sealed must be corrected before that work proceeds.
- On acceptance, report full pass and each class; reject any class regression
  greater than three percentage points against the pinned baseline. Report
  latency, memory, serializer/label hash, model revisions, and all errors.

No change to the app or model defaults follows from a development score.
