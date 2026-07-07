## Why

Pace's on-device meeting notes synthesize every meeting through one fixed prompt
(`PaceMeetingNotesPrompt` → `{summary, actionItems, decisions}`). A daily standup, a
1:1, and a client call all collapse into the same generic shape, so the notes miss
what actually matters for each (blockers, follow-ups, agreed deliverables) and recall
suffers. Separately, action items are ungrounded free text — the user can't jump back
to where a task was agreed, which undercuts trust in an on-device tool whose whole
pitch is "your data, verifiable."

Studying meetily (18.9k-star OSS meeting assistant) confirmed the gap: its highest-value
feature over Pace is meeting-type-aware note structures, and its templates deliberately
ground action items in transcript segments + timestamps. We are NOT porting meetily's
7 markdown-table corporate templates — we're taking the two ideas that make *Pace* better
and fitting them to Pace's existing planner + turn-timestamp + retrieval model.

## What Changes

- Add a small, curated set of **note profiles** (e.g. `general`, `standup`, `one-on-one`,
  `client-call`) — each a Pace-native prompt shape declaring the sections that matter for
  that meeting type. Profiles live as bundled JSON under `Resources/meeting-note-profiles/`,
  mirroring the existing `Resources/recipes` / `Resources/skills` pattern, validated at
  app startup. Users can drop custom profiles into Application Support (override by slug).
- The notes builder selects a profile per meeting: user-chosen (Settings default + a panel
  picker) with an inferred fallback (the local planner classifies the transcript into a
  profile when the user hasn't pinned one). Inference is a cheap local call; on failure it
  falls back to `general` — never blocks, never fails the meeting.
- **Transcript-grounded action items**: each `PaceMeetingActionItem` gains an optional
  source reference (turn timestamp + short quote) resolved against the already-captured
  `PaceMeetingTurnRecord` list. The panel renders action items with a "jump to transcript"
  affordance; the retrieval document text includes the grounding so recall improves.
- Backward compatible: the default profile reproduces today's `{summary, actionItems,
  decisions}` output byte-for-byte, so existing users and the existing tests see no change
  unless they opt into a profile.

## Capabilities

### New Capabilities
- `meeting-note-profiles`: bundled + user-custom note-profile definitions, profile selection
  (explicit or locally-inferred), and profile-driven notes synthesis in the builder.
- `transcript-grounded-actions`: action items carry an optional transcript source reference
  (timestamp + quote) resolved from captured turns, surfaced in the panel and retrieval doc.

### Modified Capabilities
<!-- No pre-existing openspec specs to modify; meeting-notes behavior lives only in code + docs/prds today. -->

## Impact

- Code: `PaceMeetingNotesBuilder.swift` (profile-driven prompt + grounded action parsing),
  new `PaceMeetingNoteProfile.swift` + `PaceMeetingNoteProfileLibrary.swift` (load/validate,
  mirrors `PaceRecipeLibrary`), `PaceMeetingNotesBuilder`'s `PaceMeetingActionItem` gains a
  `source` field, `PaceUserPreferencesStore.swift` (default profile + inference toggle),
  `PaceGeneralSettingsTab.swift` (profile picker in the meeting-notes subsection),
  `CompanionPanelView.swift` (per-meeting profile picker + grounded action rendering),
  `PaceMeetingNotesJournal.swift` (grounding in journaled text).
- Resources: new bundled `Resources/meeting-note-profiles/*.json`.
- No new dependencies. Fully on-device — profiles bundled, inference is a local planner call,
  zero bytes off the Mac (preserves the `PaceAPIAuditLog` "0 bytes sent" posture).
- Persisted `PaceMeetingNotes` gains an optional field on `PaceMeetingActionItem`; decode
  stays backward-compatible (optional, lenient decoder already in place).
