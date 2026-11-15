import Foundation

nonisolated struct PaceInitialInspectionPlan: Equatable, Sendable {
    let toolCall: PaceMCPToolCall
    let canonicalEnvelope: String
}

nonisolated enum PaceInitialInspectionPlanResolver {
    struct Context {
        var usesDirectCodex: Bool
        var usesDefaultCodexPlanner: Bool
        var hasAcceptedDirectSpawnConsent: Bool
        var canRunDirectSpawnTurn: Bool
        var isReadMyScreenEnabled: Bool
        var areActionsEnabled: Bool
        var isLocalForegroundTurn: Bool
        var isResearchOrEscalationTurn: Bool
        var hasActiveSkill: Bool
        var hasScreenSuggestion: Bool
        var hasVisualContext: Bool
        var requestsTeaching: Bool

        var isEligible: Bool {
            usesDirectCodex && usesDefaultCodexPlanner
                && hasAcceptedDirectSpawnConsent && canRunDirectSpawnTurn
                && isReadMyScreenEnabled && areActionsEnabled && isLocalForegroundTurn
                && !isResearchOrEscalationTurn && !hasActiveSkill
                && !hasScreenSuggestion && !hasVisualContext && !requestsTeaching
        }
    }

    // Explicit names keep appended instructions, process IDs and history references
    // out of this first-step shortcut. Other targets retain ordinary planning.
    private static let supportedApplicationNames = [
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "safari": "Safari",
        "firefox": "Firefox",
        "arc": "Arc",
        "textedit": "TextEdit",
    ]

    static func resolve(transcript: String, context: Context) -> PaceInitialInspectionPlan? {
        guard context.isEligible else { return nil }
        let normalizedTranscript = normalize(transcript)
        guard
            let applicationName = supportedApplicationNames.first(where: { alias, _ in
                let technicalCommand = "use peekaboo window list with app \(alias)"
                let supportedCommands = [
                    "list \(alias) windows",
                    "list windows for \(alias)",
                    technicalCommand,
                    "read only: \(technicalCommand)",
                ]
                return supportedCommands.contains(normalizedTranscript)
            })?.value
        else { return nil }

        let toolCall = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "window",
            arguments: ["action": .string("list"), "app": .string(applicationName)])
        let envelope: [String: PaceMCPJSONValue] = [
            "spokenText": .string(""),
            "intent": .string("action"),
            "payload": .object([
                "name": .string("MCP.call"),
                "args": .object([
                    "server": .string(toolCall.serverName),
                    "tool": .string(toolCall.toolName),
                    "arguments": .object(toolCall.arguments),
                ]),
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encodedEnvelope = try? encoder.encode(envelope),
            let canonicalEnvelope = String(data: encodedEnvelope, encoding: .utf8)
        else { return nil }
        return PaceInitialInspectionPlan(toolCall: toolCall, canonicalEnvelope: canonicalEnvelope)
    }

    private static func normalize(_ transcript: String) -> String {
        var normalized = transcript.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let lastCharacter = normalized.last, ".!?".contains(lastCharacter) {
            normalized.removeLast()
        }
        return normalized
    }
}
