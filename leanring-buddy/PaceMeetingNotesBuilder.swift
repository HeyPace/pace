//
//  PaceMeetingNotesBuilder.swift
//  leanring-buddy
//
//  Drives the active planner to produce structured meeting notes from a
//  transcript. Takes a transcript + a `BuddyPlannerClient` conformer,
//  returns a `PaceMeetingNotes` value. Uses a focused JSON-only prompt
//  (`PaceMeetingNotesPrompt`) so the meeting-notes planner call stays
//  cheap and schema-stable. A lenient JSON decoder ignores unknown
//  fields and treats missing action items as an empty array (not a
//  crash). On planner failure, returns the raw transcript as the
//  "summary" with `synthesisFailed: true` so the artifact is still
//  saved and recallable. On an empty transcript, returns empty notes
//  without calling the planner.
//
//  See docs/prds/on-device-meeting-notes.md for the full spec.
//

import Foundation

// MARK: - Notes value types

/// A lightweight transcript-line record for the transcript view. This
/// is a pure value type derived from `PaceMeetingTurn` + its transcribed
/// text — it deliberately does NOT carry the audio sample range, which
/// belongs to the capture layer, not the notes artifact.
nonisolated struct PaceMeetingTurnRecord: Equatable, Codable, Sendable {
    let start: Date
    let end: Date
    let speaker: String
    let text: String

    init(start: Date, end: Date, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// Where in the transcript an action item was agreed. Grounding is
/// optional — profiles that don't request it, planners that don't
/// return a quote, and quotes that don't resolve to a captured turn all
/// yield a nil `source` on the action item. `timestamp` is optional so
/// notes rehydrated from the retrieval journal (which may not preserve
/// the exact time) still decode cleanly.
nonisolated struct PaceMeetingActionItemSource: Equatable, Codable, Sendable {
    /// When in the meeting the action was agreed (best-effort). Non-nil
    /// when resolved from a captured turn; may be nil after journal
    /// rehydration.
    let timestamp: Date?
    /// Short verbatim snippet from the transcript identifying where the
    /// action was agreed.
    let quote: String

    init(timestamp: Date?, quote: String) {
        self.timestamp = timestamp
        self.quote = quote
    }
}

/// A single action item extracted from the meeting transcript.
nonisolated struct PaceMeetingActionItem: Equatable, Codable, Sendable {
    let text: String
    let owner: String?
    let due: String?
    /// Optional transcript grounding (timestamp + quote). See
    /// `PaceMeetingActionItemSource`. Optional so decode stays
    /// backward-compatible with notes persisted before grounding.
    let source: PaceMeetingActionItemSource?

    init(text: String, owner: String? = nil, due: String? = nil, source: PaceMeetingActionItemSource? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
        self.source = source
    }
}

/// The full structured notes artifact for one meeting. Codable +
/// Equatable so it can be persisted and compared in tests.
nonisolated struct PaceMeetingNotes: Equatable, Codable, Sendable {
    let meetingID: UUID
    let startedAt: Date
    let endedAt: Date
    let title: String
    let transcript: String
    let turns: [PaceMeetingTurnRecord]
    let summary: String
    let actionItems: [PaceMeetingActionItem]
    let decisions: [String]
    let synthesisFailed: Bool

    init(
        meetingID: UUID,
        startedAt: Date,
        endedAt: Date,
        title: String,
        transcript: String,
        turns: [PaceMeetingTurnRecord],
        summary: String,
        actionItems: [PaceMeetingActionItem],
        decisions: [String],
        synthesisFailed: Bool
    ) {
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.transcript = transcript
        self.turns = turns
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.synthesisFailed = synthesisFailed
    }
}

// MARK: - Planner JSON schema

/// The JSON shape the planner is asked to return. Unknown fields are
/// ignored by the lenient decoder; `actionItems` defaults to an empty
/// array when the key is missing.
private struct PaceMeetingNotesPlannerResponse: Decodable {
    let summary: String?
    let actionItems: [PaceMeetingNotesPlannerActionItem]?
    let decisions: [String]?
}

private struct PaceMeetingNotesPlannerActionItem: Decodable {
    let text: String?
    let owner: String?
    let due: String?
    /// Optional short verbatim transcript snippet the planner is asked
    /// to include (grounding profiles only). Resolved against captured
    /// turns to attach a `PaceMeetingActionItemSource`.
    let quote: String?
}

// MARK: - Prompt

/// Focused, JSON-only prompt for meeting-notes synthesis. No persona
/// prose — keeps the call cheap and the schema stable. The planner is
/// instructed to return ONLY a JSON object, no markdown fences.
nonisolated enum PaceMeetingNotesPrompt {
    static let systemPrompt = """
    You are a meeting-notes transcription assistant. Read the meeting \
    transcript and produce structured notes as JSON. Return ONLY a JSON \
    object with this exact shape, no markdown fences, no commentary:
    {"summary": string, "actionItems": [{"text": string, "owner": string|null, "due": string|null}], "decisions": [string]}
    Rules:
    - summary: 2-4 sentences capturing the key points of the meeting.
    - actionItems: concrete tasks agreed during the meeting. Omit if none.
    - decisions: explicit decisions made. Omit if none.
    - If the transcript is too short or unclear, return empty arrays and a brief summary.
    - Do NOT include attendees or any field not listed above.
    """
}

// MARK: - Builder

/// Drives the active planner to produce structured notes from a
/// transcript. Pure-ish: takes a transcript + a `BuddyPlannerClient`
/// conformer, returns a `PaceMeetingNotes` value.
nonisolated enum PaceMeetingNotesBuilder {
    /// Build structured notes from a transcript.
    ///
    /// - Parameters:
    ///   - transcript: The full joined, post-dictation-cleanup transcript.
    ///   - turns: The per-turn records for the transcript view.
    ///   - meetingID: The meeting's unique identifier.
    ///   - startedAt: When the meeting started.
    ///   - endedAt: When the meeting ended.
    ///   - title: User-supplied or generated meeting title.
    ///   - profile: The note profile shaping synthesis. Defaults to
    ///     `.general`, whose rendered prompt is byte-for-byte identical
    ///     to the legacy prompt, so existing callers are unaffected.
    ///   - planner: A `BuddyPlannerClient` conformer (real or mock).
    /// - Returns: `PaceMeetingNotes`. On empty transcript → empty notes
    ///   with no planner call. On planner failure or malformed JSON →
    ///   `synthesisFailed: true` with the transcript preserved as the
    ///   summary.
    @MainActor
    static func build(
        transcript: String,
        turns: [PaceMeetingTurnRecord],
        meetingID: UUID,
        startedAt: Date,
        endedAt: Date,
        title: String,
        profile: PaceMeetingNoteProfile = .general,
        planner: BuddyPlannerClient
    ) async -> PaceMeetingNotes {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty transcript → empty notes, no planner call.
        guard !trimmedTranscript.isEmpty else {
            return PaceMeetingNotes(
                meetingID: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title,
                transcript: "",
                turns: turns,
                summary: "",
                actionItems: [],
                decisions: [],
                synthesisFailed: false
            )
        }

        // Call the planner with the focused JSON-only prompt.
        let plannerResult: (text: String, duration: TimeInterval)?
        do {
            plannerResult = try await planner.generateResponseStreaming(
                images: [],
                systemPrompt: profile.renderSystemPrompt(),
                conversationHistory: [],
                userPrompt: trimmedTranscript,
                onTextChunk: { _ in }
            )
        } catch {
            // Planner threw → synthesis failed, transcript preserved.
            return PaceMeetingNotes(
                meetingID: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title,
                transcript: trimmedTranscript,
                turns: turns,
                summary: trimmedTranscript,
                actionItems: [],
                decisions: [],
                synthesisFailed: true
            )
        }

        guard let plannerText = plannerResult?.text else {
            return failedNotes(
                transcript: trimmedTranscript,
                turns: turns,
                meetingID: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title
            )
        }

        // Lenient JSON decode: strip markdown fences if present, ignore
        // unknown fields, default missing arrays to empty.
        let jsonString = Self.stripMarkdownFences(from: plannerText)
        guard let jsonData = jsonString.data(using: .utf8) else {
            return failedNotes(
                transcript: trimmedTranscript,
                turns: turns,
                meetingID: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title
            )
        }

        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(PaceMeetingNotesPlannerResponse.self, from: jsonData) else {
            return failedNotes(
                transcript: trimmedTranscript,
                turns: turns,
                meetingID: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title
            )
        }

        let actionItems = (response.actionItems ?? []).compactMap { item -> PaceMeetingActionItem? in
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return PaceMeetingActionItem(
                text: text,
                owner: item.owner?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                due: item.due?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                source: resolveSource(quote: item.quote, turns: turns)
            )
        }

        let decisions = (response.decisions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let summary = (response.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return PaceMeetingNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            transcript: trimmedTranscript,
            turns: turns,
            summary: summary.isEmpty ? trimmedTranscript : summary,
            actionItems: actionItems,
            decisions: decisions,
            synthesisFailed: false
        )
    }

    // MARK: - Grounding

    /// Resolve an action item's planner-supplied `quote` against the
    /// captured turns into a `PaceMeetingActionItemSource`. Matching is
    /// case- and whitespace-insensitive substring containment; when
    /// multiple turns contain the quote, the turn with the longest text
    /// (most specific match) wins. Returns nil when there's no quote or
    /// no matching turn — grounding is always optional.
    static func resolveSource(quote: String?, turns: [PaceMeetingTurnRecord]) -> PaceMeetingActionItemSource? {
        guard let rawQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuote.isEmpty else {
            return nil
        }
        let needle = normalizedForMatch(rawQuote)
        guard !needle.isEmpty else { return nil }

        let match = turns
            .filter { normalizedForMatch($0.text).contains(needle) }
            .max { $0.text.count < $1.text.count }

        guard let match else {
            // No turn contains the quote — keep the quote text (still
            // useful for lexical recall) but without a timestamp.
            return PaceMeetingActionItemSource(timestamp: nil, quote: rawQuote)
        }
        return PaceMeetingActionItemSource(timestamp: match.start, quote: rawQuote)
    }

    /// Lowercase + collapse internal whitespace so quote matching is
    /// robust to punctuation-free transcripts and spacing differences.
    private static func normalizedForMatch(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Helpers

    private static func failedNotes(
        transcript: String,
        turns: [PaceMeetingTurnRecord],
        meetingID: UUID,
        startedAt: Date,
        endedAt: Date,
        title: String
    ) -> PaceMeetingNotes {
        PaceMeetingNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            transcript: transcript,
            turns: turns,
            summary: transcript,
            actionItems: [],
            decisions: [],
            synthesisFailed: true
        )
    }

    /// Strips ```json ... ``` markdown fences if the planner wrapped its
    /// output despite being told not to.
    static func stripMarkdownFences(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // Remove opening fence (with optional language tag).
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            } else {
                trimmed = String(trimmed.dropFirst(3))
            }
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
