import Foundation

enum PaceTextAnswerPurpose: Equatable {
    case selectedPlanner
    case boundedEverydayAnswer

    static func classifiedAnswer(
        prediction: PaceIntentPrediction,
        transcript: String,
        hasScreenSuggestion: Bool,
        hasActiveVisualContext: Bool
    ) -> Self {
        guard prediction.route == .chitchatFastPath || prediction.route == .answerDirectly,
            prediction.complexity == .simple,
            prediction.confidence >= PaceIntentPrediction.confidenceEscalationThreshold,
            !hasScreenSuggestion, !hasActiveVisualContext,
            !hasHistoryDependentQuestion(transcript),
            !requiresCurrentOrActionContext(transcript),
            !PaceTeachingPower.prefersVisualExplanation(transcript)
        else { return .selectedPlanner }
        return .boundedEverydayAnswer
    }

    private static func requiresCurrentOrActionContext(_ transcript: String) -> Bool {
        let words = Set(transcript.lowercased().split { $0.isWhitespace || $0.isPunctuation }.map(String.init))
        let contextualWords: Set<String> = [
            "calendar", "email", "emails", "mail", "file", "files", "folder", "folders", "project", "projects",
            "repo", "repository", "coding", "codex", "session", "sessions", "task", "tasks", "code", "edit",
            "open", "click", "type", "run", "cancel", "resume", "status", "screen", "display", "cursor",
            "weather", "news", "today", "tomorrow", "yesterday", "now", "current", "currently", "latest",
            "time", "date", "price", "prices", "stock", "president", "ceo", "remember", "recall", "said",
            "meeting", "meetings", "reminder", "reminders", "research", "search", "browse", "look",
        ]
        return !words.isDisjoint(with: contextualWords)
    }

    private static func hasHistoryDependentQuestion(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let followUpPrefixes = [
            "so ", "then ", "and ", "but ", "also ", "what about ", "how about ",
            "tell me more", "continue", "go on", "remind me", "as before",
        ]
        let contextualWords: Set<String> = [
            "it", "its", "this", "that", "these", "those", "they", "them",
            "he", "she", "him", "her", "his", "hers", "there", "same",
            "previous", "earlier", "above", "again", "my", "mine", "our", "ours",
        ]
        return followUpPrefixes.contains { normalizedTranscript.hasPrefix($0) }
            || normalizedTranscript.split { $0.isWhitespace || $0.isPunctuation }
                .contains { contextualWords.contains(String($0)) }
    }
}

@MainActor
extension BuddyPlannerClientFactory {
    static func makeTextAnswerPlanner(
        purpose: PaceTextAnswerPurpose,
        selectedPlanner: any BuddyPlannerClient,
        tier: PacePlannerTier,
        upstream: PaceLocalCLIUpstream,
        hasAcceptedDirectSpawnConsent: Bool,
        canRunDirectSpawnTurn: Bool,
        everydaySystemPrompt: String,
        everydayQuestion: PaceEverydayQuestion? = nil,
        fastEverydayAnswersEnabled: Bool = false
    ) -> any BuddyPlannerClient {
        guard purpose == .boundedEverydayAnswer,
            tier == .cliDirect, upstream == .codex,
            cliDirectDispatchDecision(
                hasAcceptedDirectSpawnConsent: hasAcceptedDirectSpawnConsent,
                canRunDirectSpawnTurn: canRunDirectSpawnTurn) == .spawnCLI,
            let selectedCodexPlanner = selectedPlanner as? PaceLocalCLIPlannerClient,
            selectedCodexPlanner.allowsBoundedEverydayAnswers
        else { return selectedPlanner }
        if fastEverydayAnswersEnabled, let everydayQuestion {
            return PaceBoundedTextAnswerPlanner(
                everydayClient: PaceOpenAIResponsesEverydayClient(isAuthorized: {
                    PacePlannerTierStore.fastEverydayAnswersEnabled()
                        && PacePlannerTierStore.loadConfiguration().tier == .cliDirect
                        && PacePlannerTierStore.loadConfiguration().cliDirectUpstream == .codex
                        && PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent()
                        && PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date())
                }), question: everydayQuestion, selectedPlanner: selectedPlanner)
        }
        // This factory owns both ends of the completed-turn delivery contract.
        let everydayPlanner = PaceLocalCLIPlannerClient(
            upstream: .codex, modelIdentifier: "gpt-6-luna", codexReasoningEffort: .low,
            codexTextDelivery: .completedTurn, requestTimeout: 10)
        return PaceBoundedTextAnswerPlanner(
            everydayPlanner: everydayPlanner, selectedPlanner: selectedPlanner,
            everydaySystemPrompt: everydaySystemPrompt, textDelivery: .trustedCompletedTurn)
    }
}

/// Confined to classified everyday text answers. The main planner retains its concrete type.
@MainActor
final class PaceBoundedTextAnswerPlanner: BuddyPlannerClient {
    enum TextDelivery {
        case bufferedUntilReturn
        case trustedCompletedTurn
    }

    @MainActor
    private final class CompletedTurnAnswer {
        var receivedText: String?
        var acceptedText: String?
    }

    enum AnswerSource: Equatable {
        case everyday
        case selected
    }

    private(set) var lastAnswerSource: AnswerSource?
    let everydaySystemPrompt: String

    enum EscalationReason: String {
        case requestedStrongerPlanner
        case emptyAnswer
        case unexpectedOutput
        case timedOut
        case unavailable
    }

    static let escalationMarker = "PACE_USE_SELECTED_PLANNER"
    static let answerInstructions = """
        Answer this everyday question with brief plain text. Never emit actions, tools, JSON, diagrams, images, or control tags.
        If answering reliably needs deeper reasoning, research, screen context, or prior conversation, return exactly PACE_USE_SELECTED_PLANNER as your entire response.
        """

    var displayName: String { "\(everydayClient == nil ? "Codex" : "OpenAI Responses") everyday answer → \(selectedPlanner.displayName)" }
    let supportsImageInput = false
    private let everydayPlanner: (any BuddyPlannerClient)?
    private let everydayClient: (any PaceEverydayAnswerClient)?
    private let everydayQuestion: PaceEverydayQuestion?
    private let selectedPlanner: any BuddyPlannerClient
    private let textDelivery: TextDelivery
    private let recordDecision: (String) -> Void

    init(
        everydayPlanner: any BuddyPlannerClient,
        selectedPlanner: any BuddyPlannerClient,
        everydaySystemPrompt: String,
        textDelivery: TextDelivery = .bufferedUntilReturn,
        recordDecision: @escaping (String) -> Void = { reason in
            PaceAPIAuditLog.shared.record(
                subsystem: "planner.routing", operation: "text.answer.selection", target: "codex",
                durationMilliseconds: 0, outcome: "ok",
                detail: "model=gpt-6-luna effort=low selectedModel=cli-default selectedEffort=cli-default selection=classifiedSimpleAnswer decision=\(reason)")
        }
    ) {
        self.everydayClient = nil
        self.everydayQuestion = nil
        self.everydayPlanner = everydayPlanner
        self.selectedPlanner = selectedPlanner
        self.everydaySystemPrompt = everydaySystemPrompt
        self.textDelivery = textDelivery
        self.recordDecision = recordDecision
    }

    init(everydayClient: any PaceEverydayAnswerClient, question: PaceEverydayQuestion,
         selectedPlanner: any BuddyPlannerClient, recordDecision: @escaping (String) -> Void = { reason in
        PaceAPIAuditLog.shared.record(subsystem: "planner.routing", operation: "text.answer.selection",
            target: "openai.responses", durationMilliseconds: 0, outcome: "ok",
            detail: "model=gpt-6-luna effort=none route=currentQuestionOnly decision=\(reason)")
    }) {
        self.everydayClient = everydayClient
        self.everydayQuestion = question
        self.everydayPlanner = nil
        self.selectedPlanner = selectedPlanner
        self.everydaySystemPrompt = PaceOpenAIResponsesEverydayClient.instructions
        self.textDelivery = .bufferedUntilReturn
        self.recordDecision = recordDecision
    }

    func resetForNewTurn() {
        everydayPlanner?.resetForNewTurn()
        selectedPlanner.resetForNewTurn()
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try Task.checkCancellation()
        let startedAt = Date()
        lastAnswerSource = nil
        recordDecision("attemptEverydayAnswer")
        let completedTurnAnswer = CompletedTurnAnswer()
        let everydayResponseText: String
        var failureEscalationReason: EscalationReason?
        do {
            // Only the factory's completed-turn client may deliver before process exit.
            if let everydayClient, let everydayQuestion {
                everydayResponseText = try await everydayClient.answer(everydayQuestion)
            } else if let everydayPlanner {
            let response = try await everydayPlanner.generateResponseStreaming(
                images: [], systemPrompt: everydaySystemPrompt + "\n\n" + Self.answerInstructions,
                conversationHistory: conversationHistory, userPrompt: userPrompt,
                onTextChunk: { completeTurnText in
                    guard self.textDelivery == .trustedCompletedTurn,
                        completedTurnAnswer.receivedText == nil, !Task.isCancelled
                    else { return }
                    completedTurnAnswer.receivedText = completeTurnText
                    guard Self.escalationReason(for: completeTurnText) == nil else { return }
                    completedTurnAnswer.acceptedText = completeTurnText
                    self.lastAnswerSource = .everyday
                    self.recordDecision("acceptedEverydayAnswer")
                    onTextChunk(completeTurnText)
                })
            everydayResponseText = completedTurnAnswer.receivedText ?? response.text
            } else { throw PaceEverydayAnswerError.invalidResponse }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let acceptedText = completedTurnAnswer.acceptedText {
                // Speech and canonical history share this sealed completed-turn answer even if CLI cleanup fails.
                recordDecision("lateProcessErrorAfterAcceptedAnswer")
                return (acceptedText, Date().timeIntervalSince(startedAt))
            }
            guard let reason = Self.escalationReason(forFailure: error) else { throw error }
            everydayResponseText = ""
            failureEscalationReason = reason
        }
        try Task.checkCancellation()
        if let acceptedText = completedTurnAnswer.acceptedText {
            return (acceptedText, Date().timeIntervalSince(startedAt))
        }
        guard let reason = failureEscalationReason ?? Self.escalationReason(for: everydayResponseText) else {
            lastAnswerSource = .everyday
            recordDecision("acceptedEverydayAnswer")
            onTextChunk(everydayResponseText)
            return (everydayResponseText, Date().timeIntervalSince(startedAt))
        }
        recordDecision("selectedPlannerFallback=\(reason.rawValue)")
        try Task.checkCancellation()
        let response = try await selectedPlanner.generateResponseStreaming(
            images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
            userPrompt: userPrompt, onTextChunk: onTextChunk)
        try Task.checkCancellation()
        lastAnswerSource = .selected
        return (response.text, Date().timeIntervalSince(startedAt))
    }

    private static func escalationReason(forFailure error: any Error) -> EscalationReason? {
        switch error {
        case PaceEverydayAnswerError.missingKey: return .unavailable
        case PaceEverydayAnswerError.invalidResponse: return .unexpectedOutput
        case PaceEverydayAnswerError.httpFailure(let status): return status == 429 || status >= 500 ? .unavailable : nil
        case let error as URLError:
            if error.code == .timedOut { return .timedOut }
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code) ? .unavailable : nil
        case PaceCLIProcessError.emptyResponse: return .emptyAnswer
        case PaceCLIProcessError.timedOut: return .timedOut
        case PaceCLIProcessError.failed(_, let stderrExcerpt):
            return PaceCLIRejectionCategory.classify(stderrExcerpt) == nil ? .unavailable : nil
        case PaceLocalCLIPlannerError.incompleteCodexTurn: return .unexpectedOutput
        case PaceLocalCLIPlannerError.nonZeroExit(_, _, let stderrExcerpt):
            return PaceCLIRejectionCategory.classify(stderrExcerpt) == nil ? .unavailable : nil
        default: return nil
        }
    }

    static func escalationReason(for response: String) -> EscalationReason? {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedResponse == escalationMarker { return .requestedStrongerPlanner }
        if trimmedResponse.isEmpty { return .emptyAnswer }
        if trimmedResponse.hasPrefix("{") || trimmedResponse.hasPrefix("[")
            || trimmedResponse.contains("```") || trimmedResponse.contains(escalationMarker)
            || trimmedResponse.range(of: #"\[[A-Z_]+(?:[:\]])|</?(?:tool|action|function)[_a-z]*\b"#,
                options: .regularExpression) != nil
            || !PaceActionTagParser.parseActions(from: trimmedResponse).actions.isEmpty
        {
            return .unexpectedOutput
        }
        return nil
    }
}
