## Context

Meeting notes today flow through one path: `PaceMeetingModeController.stop()` →
segment → transcribe → `PaceMeetingNotesBuilder.build(...)` → `PaceMeetingNotesJournal`.
`build` uses a single hardcoded `PaceMeetingNotesPrompt.systemPrompt` returning
`{summary, actionItems, decisions}`, parsed by a lenient decoder. Turns are already
captured with timestamps as `PaceMeetingTurnRecord`. Bundled JSON libraries
(`PaceRecipeLibrary`, `PaceSkillLoader`) establish the pattern for this repo:
`Resources/<kind>/*.json` bundled + `~/Library/Application Support/Pace/<kind>/` user
overrides, validated at startup via `PaceToolRegistry.validateForAppStartup`-style checks,
atomic temp-file+rename writes, `PaceFlowStore.slug(for:)` for slugging.

This change generalizes the single prompt into selectable **profiles** and grounds action
items in the already-captured turns. It is meetily-informed but Pace-native: we keep Pace's
JSON-object output contract (not meetily's freeform markdown-table docs) so the panel,
retrieval doc, and lenient decoder keep working.

## Goals / Non-Goals

**Goals:**
- One curated set of note profiles; `general` reproduces current output exactly.
- Profile selection: explicit (panel) → default (Settings) → local inference → `general`.
- Optional transcript grounding on action items, resolved from captured turns.
- Zero new dependencies; zero bytes off-Mac; backward-compatible persistence.

**Non-Goals:**
- Porting meetily's 7 markdown-table templates or its section `format`/`item_format` schema.
- Real-time transcription and multi-speaker diarization (separate, larger efforts).
- Rich per-section freeform output — Pace stays on the structured JSON contract.

## Decisions

- **Profile schema (Pace-native, minimal):** `{ slug, name, description, sections: [{ key,
  title, instruction }], emitsActionItems: Bool, emitsDecisions: Bool }`. The builder renders
  `sections` into the JSON-only prompt and asks the planner for a `sections` map plus the
  existing `actionItems`/`decisions` arrays (gated by the emit flags). Chosen over meetily's
  `format`/`item_format` table hints because Pace renders notes in SwiftUI + a retrieval doc,
  not markdown; table formatting is meetily-frontend-specific noise for us.
- **`general` profile is the compatibility anchor:** it declares a single `summary` section +
  `emitsActionItems`/`emitsDecisions` true, and the builder's prompt rendering for it produces
  the exact current prompt. Guarded by a test asserting identical output shape.
- **Selection precedence in the controller, not the builder:** the builder takes a resolved
  `PaceMeetingNoteProfile` argument (pure, testable). The controller resolves precedence
  (explicit → default pref → inference → general) before calling `build`. Keeps `build` a pure
  function of (transcript, turns, profile, planner).
- **Inference reuses the privacy-pinned local planner** (`makeLocalOnlyPlannerForPrivacyPinnedFeatures()`,
  same pin as skills/meeting notes) with a tiny classify prompt returning one known slug.
  Deterministic fallback to `general` on any failure/unknown slug — never blocks the meeting.
- **Grounding resolution is deterministic, post-synthesis:** the planner is asked to include a
  short `quote` per action item; the builder resolves that quote against `turns` (case/space-
  insensitive substring match, longest-match wins) to attach `{ timestamp, quote }`. No second
  planner call, no fragile offset arithmetic. Unresolved quotes → nil source (still valid).
- **`PaceMeetingActionItem.source` is a new optional `Codable` field** → additive, lenient
  decoder already ignores/defaults missing keys, so old persisted notes decode unchanged.

## Risks / Trade-offs

- [Inference picks the wrong profile] → user can override per-meeting in the panel and pin a
  default in Settings; inference is only tier 3. Default ships as `general` + inference OFF so
  upgrade behavior is unchanged until opt-in.
- [Planner ignores the profile sections / returns old shape] → builder tolerates missing
  section keys (renders what it got); `general` path is unchanged; `synthesisFailed` still
  preserves the transcript.
- [Quote matching false-positive/negative] → grounding is optional and advisory (a jump link),
  never used for correctness; a missed match just yields an ungrounded (still valid) item.
- [Bundled profile JSON drift] → startup validation fails loud for bundled files (same posture
  as recipes/skills); user files fail soft (skipped + logged).

## Migration Plan

- Additive: new files + one optional struct field + new opt-in preferences. Default profile =
  `general`, inference = OFF → existing users and all existing meeting-notes tests are
  unaffected until they opt in. Rollback = revert; persisted notes remain decodable both ways.

## Open Questions

- Initial bundled profile set confirmed: `general`, `standup`, `one-on-one` (easy to extend
  later since profiles are just JSON; `client-call` deferred).
