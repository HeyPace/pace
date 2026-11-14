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
            Resume requires the exact sessionID and a new explicit task. Status can omit sessionID to list owned sessions.
            Cancel requires the exact sessionID. Never guess an unrelated workspace or replay an old task.
            Coding runs independently after start; ordinary chat and closing teaching visuals do not cancel it.
            """
        })])

    static func requestsRetainedCoding(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        return text.contains("coding session") || text.contains("coding task")
            || (text.contains("codex session") && ["start", "resume", "continue"].contains { text.contains($0) }
                && text.range(of: #"\b(?:and|to)\b"#, options: .regularExpression) != nil)
            || text.range(of: #"\b(?:work on|fix|implement|change|edit|test|resume|continue)\b.*\b(?:codex|repo|repository)\b"#, options: .regularExpression) != nil
            || text.range(of: #"\b(?:codex|repo|repository)\b.*\b(?:fix|implement|change|edit|test|resume|continue)\b"#, options: .regularExpression) != nil
    }

    static let tools = [PaceLocalToolDefinition(kind: .codingSession, canonicalName: "coding_session", aliases: [],
        schemaExample: #"{"tool":"coding_session","operation":"start","directory":"~/projects/my-app","task":"Fix the failing test"}"#,
        description: "retained Codex coding. operation=start requires directory and task; resume requires sessionID and task; status accepts optional sessionID; cancel requires sessionID. No other fields. Start/resume need action approval and Codex consent. Status/cancel inspect or stop already-owned work.",
        riskLevel: .externalIntegration, executionSummary: "Runs an approved coding task in one fixed workspace with network disabled.",
        observationSummary: "Reports the retained session ID, workspace and actual lifecycle state; canonical progress and final arrive separately.",
        exampleUtterance: "work on ~/projects/my-app with Codex and fix the failing test")]
}
