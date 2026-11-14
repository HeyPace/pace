import Foundation

nonisolated enum PaceCodingPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.coding", title: "Coding",
        summary: "Retained, workspace-scoped Codex coding sessions with progress, resume and explicit cancel.",
        permissionsUsed: [.offDevicePlanning, .externalTools], tools: tools,
        promptContributions: [.init(order: 95, applies: { $0.turnKind != .research }, render: { _ in
            """
            Retained coding uses coding_session, separately from codex_session which only opens Warp.
            For a request to work on a repository, ask for its explicit existing directory if missing. Start with
            {"tool":"coding_session","operation":"start","directory":"/absolute/workspace","task":"the requested coding task"}.
            Resume requires the owned sessionID and a new explicit task. Use the supplied owned-session metadata to resolve an unambiguous spoken workspace or the only resumable session. If multiple sessions fit, ask which workspace; never invent an ID. Status can omit sessionID to list owned sessions.
            Cancel requires the exact sessionID. Never guess an unrelated workspace or replay an old task.
            Coding runs independently after start; ordinary chat and closing teaching visuals do not cancel it.
            """
        })])

    static func requestsRetainedCoding(_ transcript: String) -> Bool {
        var text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let courtesyPrefixes = ["please ", "can you ", "could you ", "would you "]
        while let prefix = courtesyPrefixes.first(where: text.hasPrefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let terminalIntentText = text.replacingOccurrences(of: #"(\"|')(?:~/|/).*?\1|(?:^|\s)(?:~/|/)[^\s]+"#, with: " ", options: .regularExpression)
        if text.hasPrefix("open ") || text.hasPrefix("launch ")
            || terminalIntentText.range(of: #"\bwarp\b"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^(?:resume|continue) (?:the |my |that )?coding (?:task|session)\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^start (?:a )?(?:retained )?coding (?:task|session)\b"#, options: .regularExpression) != nil { return true }
        let hasExplicitPath = text.range(of: #"(?:^|[\s\"'])(?:~/|/)[^\s]+"#, options: .regularExpression) != nil
        guard hasExplicitPath else { return false }
        return text.range(of: #"^work on\s.+\bwith codex\b"#, options: .regularExpression) != nil
            || text.range(of: #"^start (?:a )?retained codex session\b"#, options: .regularExpression) != nil
            || text.range(of: #"^use codex to\s"#, options: .regularExpression) != nil
            || text.range(of: #"^start coding in\s"#, options: .regularExpression) != nil
    }

    static let tools = [PaceLocalToolDefinition(kind: .codingSession, canonicalName: "coding_session", aliases: [],
        schemaExample: #"{"tool":"coding_session","operation":"start","directory":"~/projects/my-app","task":"Fix the failing test"}"#,
        description: "retained Codex coding. operation=start requires directory and task; resume requires sessionID and task; status accepts optional sessionID; cancel requires sessionID. No other fields. Start/resume need action approval and Codex consent. Status/cancel inspect or stop already-owned work.",
        riskLevel: .externalIntegration, executionSummary: "Runs an approved coding task in one fixed workspace with network disabled.",
        observationSummary: "Reports the retained session ID, workspace and actual lifecycle state; canonical progress and final arrive separately.",
        exampleUtterance: "work on ~/projects/my-app with Codex and fix the failing test")]
}
