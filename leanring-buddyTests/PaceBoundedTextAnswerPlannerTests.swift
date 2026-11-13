import Foundation
import Testing

@testable import Pace

@MainActor
private final class BoundedAnswerFixturePlanner: BuddyPlannerClient {
    let displayName = "Injected answer fixture"
    let supportsImageInput = false
    var response = "Paris."
    var provisionalChunks: [String] = []
    var failure: (any Error)?
    var beforeReturning: (() async -> Void)?
    var calls = 0
    var receivedSystemPrompt = ""
    var receivedHistoryCount = 0
    var receivedHistory: [(userPlaceholder: String, assistantResponse: String)] = []

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        calls += 1
        receivedSystemPrompt = systemPrompt
        receivedHistoryCount = conversationHistory.count
        receivedHistory = conversationHistory
        for chunk in provisionalChunks { onTextChunk(chunk) }
        if let beforeReturning { await beforeReturning() }
        if let failure { throw failure }
        return (response, 0)
    }
}

@Suite(.serialized)
struct PaceBoundedTextAnswerPlannerTests {
    @Test
    func onlyConfidentSimpleClassifiedAnswersQualify() {
        for intent in PaceIntent.allCases {
            for complexity in [PaceQueryComplexity.simple, .moderate, .complex] {
                for confidence in [0.89, 0.90, 1.0] {
                    let prediction = PaceIntentPrediction(
                        intent: intent, confidence: confidence, complexity: complexity)
                    let purpose = PaceTextAnswerPurpose.classifiedAnswer(
                        prediction: prediction, transcript: "Who invented the telephone?",
                        hasScreenSuggestion: false, hasActiveVisualContext: false)
                    let expectedEligibility = (intent == .chitchat || intent == .pureKnowledge)
                        && complexity == .simple && confidence >= 0.90
                    #expect((purpose == .boundedEverydayAnswer) == expectedEligibility)
                }
            }
        }
    }

    @Test
    func suggestionsVisualContextAndHistoryDependentQuestionsKeepSelectedPlanner() {
        let prediction = PaceIntentPrediction(intent: .pureKnowledge, confidence: 1)
        for transcript in ["What is that?", "What about France?", "Tell me more", "Why did they do it?", "What did I ask earlier?", "What is my name?", "What is our project?", "How old is he?", "Who is she?", "Is the weather warm there?"] {
            #expect(PaceTextAnswerPurpose.classifiedAnswer(
                prediction: prediction, transcript: transcript,
                hasScreenSuggestion: false, hasActiveVisualContext: false) == .selectedPlanner)
        }
        #expect(PaceTextAnswerPurpose.classifiedAnswer(
            prediction: prediction, transcript: "Who invented the telephone?",
            hasScreenSuggestion: true, hasActiveVisualContext: false) == .selectedPlanner)
        #expect(PaceTextAnswerPurpose.classifiedAnswer(
            prediction: prediction, transcript: "Who invented the telephone?",
            hasScreenSuggestion: false, hasActiveVisualContext: true) == .selectedPlanner)
        #expect(PaceTextAnswerPurpose.classifiedAnswer(
            prediction: prediction, transcript: "How many planets are there?",
            hasScreenSuggestion: false, hasActiveVisualContext: false) == .selectedPlanner)
    }

    @Test func teachingRequestsKeepTheVisualCapableSelectedPlanner() {
        let prediction = PaceIntentPrediction(intent: .pureKnowledge, confidence: 1, complexity: .simple)
        for transcript in ["Explain how the F-35B hovers", "Explain next-token training",
                           "Can you explain how the F-35B hovers?",
                           "How does a jet engine work?", "How do camera ribbon connectors work?",
                           "Teach me gradient descent", "Explain the Brayton cycle",
                           "Show me a rotatable Pi 5 board", "Why does a lift fan help a jet hover?"] {
            #expect(PaceTeachingPower.prefersVisualExplanation(transcript))
            #expect(PaceTextAnswerPurpose.classifiedAnswer(prediction: prediction, transcript: transcript,
                hasScreenSuggestion: false, hasActiveVisualContext: false) == .selectedPlanner)
        }
        for transcript in ["What is seven times nine?", "Who invented the telephone?", "What is the capital of France?",
                           "Explain gravity in one sentence", "Explain the F-35B lift system, text only",
                           "How does a jet engine work without a diagram?"] {
            #expect(!PaceTeachingPower.prefersVisualExplanation(transcript))
            #expect(PaceTextAnswerPurpose.classifiedAnswer(prediction: prediction, transcript: transcript,
                hasScreenSuggestion: false, hasActiveVisualContext: false) == .boundedEverydayAnswer)
        }
    }

    @Test @MainActor
    func factoryRequiresAutomaticCodexSelectionAndCurrentConsent() {
        let automaticCodex = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let fixture = BoundedAnswerFixturePlanner()
        func select(
            purpose: PaceTextAnswerPurpose = .boundedEverydayAnswer,
            selectedPlanner: (any BuddyPlannerClient)? = nil,
            tier: PacePlannerTier = .cliDirect,
            upstream: PaceLocalCLIUpstream = .codex,
            consent: Bool = true,
            available: Bool = true
        ) -> any BuddyPlannerClient {
            BuddyPlannerClientFactory.makeTextAnswerPlanner(
                purpose: purpose, selectedPlanner: selectedPlanner ?? automaticCodex, tier: tier, upstream: upstream,
                hasAcceptedDirectSpawnConsent: consent, canRunDirectSpawnTurn: available, everydaySystemPrompt: "Trusted short prompt")
        }
        #expect(select() is PaceBoundedTextAnswerPlanner)
        #expect(select(purpose: .selectedPlanner) === automaticCodex)
        #expect(select(consent: false) === automaticCodex)
        #expect(select(available: false) === automaticCodex)
        #expect(select(tier: .local) === automaticCodex)
        #expect(select(tier: .directAPI) === automaticCodex)
        #expect(select(tier: .cliBridge) === automaticCodex)
        #expect(select(upstream: .claude) === automaticCodex)
        #expect(select(selectedPlanner: fixture) === fixture)
        for planner in [
            PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: "chosen-model"),
            PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil, isResearchTurn: true),
            PaceLocalCLIPlannerClient(upstream: .claude, modelIdentifier: nil),
        ] {
            #expect(select(selectedPlanner: planner) === planner)
        }
        #expect(BuddyPlannerClientFactory.defaultModelIdentifierForCLIDirect(upstream: .codex) == nil)
    }

    @Test
    func lunaArgumentsAddOnlyExplicitModelAndLowEffort() {
        let defaults = PaceLocalCLIPlannerClient.codexArguments(modelIdentifier: nil, isResearchTurn: false)
        let luna = PaceLocalCLIPlannerClient.codexArguments(
            modelIdentifier: "gpt-6-luna", isResearchTurn: false, reasoningEffort: .low)
        #expect(luna == defaults + ["--model", "gpt-6-luna", "--config", "model_reasoning_effort=\"low\""])
        #expect(defaults.contains("--ignore-user-config"))
        #expect(defaults.contains("read-only"))
        #expect(defaults.contains("web_search=\"disabled\""))
        for tool in ["shell_tool", "hooks", "apps", "browser_use", "computer_use", "multi_agent", "image_generation"] {
            #expect(defaults.contains(tool))
        }
        let explicit = PaceLocalCLIPlannerClient.codexArguments(modelIdentifier: "chosen-model", isResearchTurn: false)
        #expect(explicit == defaults + ["--model", "chosen-model"])
    }

    @Test @MainActor
    func validShortAnswersAreAcceptedAfterBuffering() async throws {
        for answer in ["Yes.", "Paris", "42", "Hello!", "The capital is Paris."] {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.response = answer
            everyday.provisionalChunks = ["provisional text"]
            let selected = BoundedAnswerFixturePlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted base voice and privacy rules", recordDecision: { _ in })
            var chunks: [String] = []
            everyday.beforeReturning = { #expect(chunks.isEmpty) }
            let result = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "Trusted base voice and privacy rules", conversationHistory: [],
                userPrompt: "A synthetic everyday question", onTextChunk: { chunks.append($0) })
            #expect(result.text == answer)
            #expect(chunks == [answer])
            #expect(selected.calls == 0)
            #expect(everyday.receivedSystemPrompt == "Trusted base voice and privacy rules\n\n" + PaceBoundedTextAnswerPlanner.answerInstructions)
            #expect(everyday.receivedSystemPrompt.contains(PaceBoundedTextAnswerPlanner.escalationMarker))
        }
    }

    @Test @MainActor
    func escalationHoldsEveryProvisionalChunkAndFallsBackOnce() async throws {
        for answer in [
            PaceBoundedTextAnswerPlanner.escalationMarker,
            " \n" + PaceBoundedTextAnswerPlanner.escalationMarker + "\n ",
            "", "{\"spokenText\":\"Hello\",\"intent\":\"answer\"}",
            "{malformed", "[CLICK:10,20]", "Sure. [TYPE:hello]", "```json\n{}\n```",
        ] {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.response = answer
            everyday.provisionalChunks = ["I will click", answer]
            let selected = BoundedAnswerFixturePlanner()
            selected.response = "Stronger answer."
            selected.provisionalChunks = ["Stronger", "Stronger answer."]
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted base voice and privacy rules", recordDecision: { _ in })
            var chunks: [String] = []
            let result = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "Original trusted prompt",
                conversationHistory: [("Synthetic previous question", "Synthetic previous answer")],
                userPrompt: "Synthetic new question", onTextChunk: { chunks.append($0) })
            #expect(result.text == "Stronger answer.")
            #expect(chunks == ["Stronger", "Stronger answer."])
            #expect(everyday.calls == 1)
            #expect(everyday.receivedHistoryCount == 1)
            #expect(selected.calls == 1)
            #expect(selected.receivedHistoryCount == 1)
            #expect(selected.receivedSystemPrompt == "Original trusted prompt")
            #expect(everyday.receivedSystemPrompt == "Trusted base voice and privacy rules\n\n" + PaceBoundedTextAnswerPlanner.answerInstructions)
            #expect(everyday.receivedHistory.first?.userPlaceholder == "Synthetic previous question")
            #expect(selected.receivedHistory.first?.assistantResponse == "Synthetic previous answer")
            #expect(planner.lastAnswerSource == .selected)
        }
        #expect(PaceBoundedTextAnswerPlanner.escalationReason(
            for: "The marker PACE_USE_SELECTED_PLANNER is not an answer.") == .unexpectedOutput)
    }

    @Test @MainActor
    func escalationUsesFullDiagramPromptWithTheSameTrustedContextAndHistory() async throws {
        let threadContext = "Synthetic shared thread summary"
        let ambientContext = "Synthetic shared ambient context"
        let shortPrompt = CompanionSystemPrompt.buildTextOnly(
            threadSummaryInjection: threadContext, ambientContextInjection: ambientContext,
            includeInteractiveDiagrams: false)
        let fullPrompt = CompanionSystemPrompt.buildTextOnly(
            threadSummaryInjection: threadContext, ambientContextInjection: ambientContext,
            includeInteractiveDiagrams: true)
        let history: [(userPlaceholder: String, assistantResponse: String)] = [("Prior question", "Prior answer")]
        let everyday = BoundedAnswerFixturePlanner()
        everyday.response = PaceBoundedTextAnswerPlanner.escalationMarker
        let selected = BoundedAnswerFixturePlanner()
        let planner = PaceBoundedTextAnswerPlanner(
            everydayPlanner: everyday, selectedPlanner: selected,
            everydaySystemPrompt: shortPrompt, recordDecision: { _ in })
        _ = try await planner.generateResponseStreaming(
            images: [], systemPrompt: fullPrompt, conversationHistory: history,
            userPrompt: "Synthetic question", onTextChunk: { _ in })
        #expect(fullPrompt != shortPrompt)
        #expect(everyday.receivedSystemPrompt == shortPrompt + "\n\n" + PaceBoundedTextAnswerPlanner.answerInstructions)
        #expect(selected.receivedSystemPrompt == fullPrompt)
        for prompt in [everyday.receivedSystemPrompt, selected.receivedSystemPrompt] {
            #expect(prompt.contains(threadContext))
            #expect(prompt.contains(ambientContext))
        }
        #expect(everyday.receivedHistory.first?.userPlaceholder == history.first?.userPlaceholder)
        #expect(selected.receivedHistory.first?.assistantResponse == history.first?.assistantResponse)
        #expect(planner.lastAnswerSource == .selected)
    }

    @Test @MainActor
    func unavailableAndInvalidTurnsEscalateOnceBeforeAcceptance() async throws {
        let failures: [any Error] = [
            PaceCLIProcessError.emptyResponse, PaceCLIProcessError.timedOut,
            PaceCLIProcessError.failed(1, "Model gpt-6-luna not found"),
            PaceCLIProcessError.failed(1, "Unsupported reasoning effort: low"),
            PaceLocalCLIPlannerError.incompleteCodexTurn,
        ]
        for failure in failures {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.failure = failure
            let selected = BoundedAnswerFixturePlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted short prompt", recordDecision: { _ in })
            let response = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "Full trusted prompt", conversationHistory: [],
                userPrompt: "Synthetic question", onTextChunk: { _ in })
            #expect(response.text == selected.response)
            #expect(everyday.calls == 1)
            #expect(selected.calls == 1)
        }
    }

    @Test @MainActor
    func accountAndSpawnFailuresPropagateWithoutFallback() async {
        let failures: [any Error] = [
            PaceCLIProcessError.failed(1, "Please log in to Codex"),
            PaceCLIProcessError.failed(1, "You have exceeded your usage limit"),
            PaceCLIProcessError.failed(1, "HTTP 401: Unauthorized"),
            PaceCLIProcessError.failed(1, "HTTP 429: Too many requests"),
            PaceLocalCLIPlannerError.rejected(.authentication),
            PaceLocalCLIPlannerError.rejected(.quota),
            PaceLocalCLIPlannerError.spawnFailed(executable: "codex", underlying: "not found"),
            CancellationError(),
        ]
        for failure in failures {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.failure = failure
            let selected = BoundedAnswerFixturePlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted short prompt", recordDecision: { _ in })
            do {
                _ = try await planner.generateResponseStreaming(
                    images: [], systemPrompt: "", conversationHistory: [],
                    userPrompt: "Synthetic question", onTextChunk: { _ in })
                Issue.record("Expected account, spawn, or cancellation failure")
            } catch {
                #expect(String(describing: error) == String(describing: failure))
            }
            #expect(everyday.calls == 1)
            #expect(selected.calls == 0)
        }
    }

    @Test @MainActor
    func trustedCompleteTurnReachesSpeechBeforeReturnAndCannotChangeOrDuplicate() async throws {
        let everyday = BoundedAnswerFixturePlanner()
        everyday.provisionalChunks = ["Paris.", "[CLICK:10,20]"]
        everyday.response = "{\"actions\":[\"different final output\"]}"
        let selected = BoundedAnswerFixturePlanner()
        var decisions: [String] = []
        let planner = PaceBoundedTextAnswerPlanner(
            everydayPlanner: everyday, selectedPlanner: selected,
            everydaySystemPrompt: "Trusted base voice and privacy rules", textDelivery: .trustedCompletedTurn,
            recordDecision: { decisions.append($0) })
        var chunks: [String] = []
        everyday.beforeReturning = {
            #expect(chunks == ["Paris."])
            #expect(selected.calls == 0)
        }
        let result = try await planner.generateResponseStreaming(
            images: [], systemPrompt: "Synthetic prompt", conversationHistory: [],
            userPrompt: "Synthetic question", onTextChunk: { chunks.append($0) })
        #expect(result.text == "Paris.")
        #expect(chunks == ["Paris."])
        #expect(selected.calls == 0)
        #expect(decisions == ["attemptEverydayAnswer", "acceptedEverydayAnswer"])
    }

    @Test @MainActor
    func rejectedCompletedTurnsWaitForReturnBeforeOneFallback() async throws {
        for completedText in [
            PaceBoundedTextAnswerPlanner.escalationMarker, "", " ",
            "{\"spokenText\":\"Structured\"}", "[CLICK:10,20]", "```json\n{}\n```",
        ] {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.provisionalChunks = [completedText, "This later chunk must be ignored."]
            everyday.response = "This different final text must not override rejection."
            let selected = BoundedAnswerFixturePlanner()
            selected.response = "Selected answer."
            selected.provisionalChunks = ["Selected answer."]
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted base voice and privacy rules", textDelivery: .trustedCompletedTurn,
                recordDecision: { _ in })
            var chunks: [String] = []
            everyday.beforeReturning = {
                #expect(chunks.isEmpty)
                #expect(selected.calls == 0)
            }
            let result = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
                onTextChunk: { chunks.append($0) })
            #expect(result.text == "Selected answer.")
            #expect(chunks == ["Selected answer."])
            #expect(selected.calls == 1)
        }
    }

    @Test @MainActor
    func timeoutBeforeAcceptedAnswerEscalatesOnceWithContentFreeReason() async throws {
        let everyday = BoundedAnswerFixturePlanner()
        everyday.provisionalChunks = [PaceBoundedTextAnswerPlanner.escalationMarker]
        everyday.failure = PaceCLIProcessError.timedOut
        let selected = BoundedAnswerFixturePlanner()
        selected.response = "Selected answer."
        var decisions: [String] = []
        let planner = PaceBoundedTextAnswerPlanner(
            everydayPlanner: everyday, selectedPlanner: selected,
            everydaySystemPrompt: "Trusted base voice and privacy rules", textDelivery: .trustedCompletedTurn,
            recordDecision: { decisions.append($0) })
        var chunks: [String] = []
        let result = try await planner.generateResponseStreaming(
            images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
            onTextChunk: { chunks.append($0) })
        #expect(result.text == "Selected answer.")
        #expect(chunks.isEmpty)
        #expect(everyday.calls == 1)
        #expect(selected.calls == 1)
        #expect(decisions == ["attemptEverydayAnswer", "selectedPlannerFallback=timedOut"])
    }

    @Test @MainActor
    func lateProcessErrorsKeepAcceptedAnswerWithoutDuplicateOrFallback() async throws {
        let failures: [any Error] = [
            PaceCLIProcessError.timedOut, PaceCLIProcessError.emptyResponse,
            PaceCLIProcessError.failed(1, "Synthetic failure"), PaceLocalCLIPlannerError.incompleteCodexTurn,
            PaceLocalCLIPlannerError.rejected(.authentication), PaceLocalCLIPlannerError.rejected(.quota),
        ]
        for failure in failures {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.provisionalChunks = ["Accepted answer."]
            everyday.failure = failure
            let selected = BoundedAnswerFixturePlanner()
            var decisions: [String] = []
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted short prompt", textDelivery: .trustedCompletedTurn,
                recordDecision: { decisions.append($0) })
            var chunks: [String] = []
            let result = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
                onTextChunk: { chunks.append($0) })
            #expect(result.text == "Accepted answer.")
            #expect(chunks == ["Accepted answer."])
            #expect(everyday.calls == 1)
            #expect(selected.calls == 0)
            #expect(planner.lastAnswerSource == .everyday)
            #expect(decisions == ["attemptEverydayAnswer", "acceptedEverydayAnswer", "lateProcessErrorAfterAcceptedAnswer"])
        }
    }

    @Test @MainActor
    func textOnlyCallerKeepsAcceptedAnswerInCanonicalHistoryAndVisibleChatAfterCleanupFailure() async throws {
        let (manager, persister, ttsClient) = PaceConversationRecorderTests().makeDismissalFixture()
        manager.localRetriever = PaceLocalRetriever(
            store: PaceInMemoryRetrievalStore(), appliesPersistedSourcePreferences: false)
        // Exercise the manager's state/history boundary without constructing a native overlay window.
        manager.responseOverlayManager.setAnnotationsEnabled(false)
        manager.isWalkingAvatarEnabled = false
        manager.activePlannerTier = .cliDirect
        manager.activePlannerTierCLIDirectUpstream = .codex
        let everyday = BoundedAnswerFixturePlanner()
        everyday.provisionalChunks = ["Accepted answer."]
        everyday.failure = PaceCLIProcessError.timedOut
        let selected = BoundedAnswerFixturePlanner()
        let wrapper = PaceBoundedTextAnswerPlanner(
            everydayPlanner: everyday, selectedPlanner: selected,
            everydaySystemPrompt: "Trusted short prompt", textDelivery: .trustedCompletedTurn,
            recordDecision: { _ in })
        manager.plannerClient = wrapper
        manager.textOnlyPlannerClient = wrapper
        let transcript = "What is two plus two?"
        #expect(!PaceRetrievalContextPolicy.shouldQueryLocalContext(forTranscript: transcript, route: .answerDirectly))
        manager.beginConversationRequest(transcript)
        _ = manager.turnLeaseRegistry.beginTurn()
        manager.handleTextOnlyPlannerFastPath(transcript: transcript)
        await manager.currentResponseTask?.value
        for _ in 0..<10 { await Task.yield() }

        let completedAnswers = persister.events.values.filter { $0.role == .pace && $0.deliveryState == .completed }
        #expect(completedAnswers.count == 1)
        #expect(completedAnswers.first?.text == "Accepted answer.")
        #expect(manager.chatSession.messages.contains { $0.body == "Accepted answer." })
        #expect(!manager.chatSession.messages.contains { $0.body.contains("Planner failed") })
        #expect(manager.currentTurnHUDState == .done("answered"))
        #expect(manager.recentToolCallDebugRecords.first?.spokenText == "Accepted answer.")
        #expect(selected.calls == 0)
        #expect(ttsClient.spokenTexts.joined() == "Accepted answer.")
        #expect(manager.conversationHistory.isEmpty)
        #expect(manager.memoryIndex.allEntries().isEmpty)
    }

    @Test @MainActor
    func cancellationAfterAcceptanceStillPropagatesWithoutFallback() async {
        for cancelTask in [false, true] {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.provisionalChunks = ["Accepted answer."]
            if cancelTask {
                everyday.failure = PaceCLIProcessError.timedOut
                everyday.beforeReturning = { withUnsafeCurrentTask { $0?.cancel() } }
            } else {
                everyday.failure = CancellationError()
            }
            let selected = BoundedAnswerFixturePlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted short prompt", textDelivery: .trustedCompletedTurn,
                recordDecision: { _ in })
            let task = Task { @MainActor in
                var chunks: [String] = []
                do {
                    _ = try await planner.generateResponseStreaming(
                        images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
                        onTextChunk: { chunks.append($0) })
                    Issue.record("Expected cancellation")
                } catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
                #expect(chunks == ["Accepted answer."])
            }
            await task.value
            #expect(selected.calls == 0)
        }
    }

    @Test @MainActor
    func cancellationNeverStartsFallbackOrReleasesProvisionalText() async {
        let everyday = BoundedAnswerFixturePlanner()
        everyday.provisionalChunks = ["Provisional answer"]
        everyday.response = PaceBoundedTextAnswerPlanner.escalationMarker
        everyday.beforeReturning = { withUnsafeCurrentTask { $0?.cancel() } }
        let selected = BoundedAnswerFixturePlanner()
        let planner = PaceBoundedTextAnswerPlanner(
            everydayPlanner: everyday, selectedPlanner: selected,
            everydaySystemPrompt: "Trusted base voice and privacy rules", recordDecision: { _ in })
        let task = Task { @MainActor in
            var chunks: [String] = []
            do {
                _ = try await planner.generateResponseStreaming(
                    images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
                    onTextChunk: { chunks.append($0) })
                Issue.record("Expected cancellation")
            } catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
            #expect(chunks.isEmpty)
        }
        await task.value
        #expect(selected.calls == 0)
    }

    @Test @MainActor
    func cancellationErrorsAndSelectedPlannerFailuresPropagateWithoutRetry() async {
        for cancelEverydayAnswer in [true, false] {
            let everyday = BoundedAnswerFixturePlanner()
            everyday.response = PaceBoundedTextAnswerPlanner.escalationMarker
            if cancelEverydayAnswer { everyday.failure = CancellationError() }
            let selected = BoundedAnswerFixturePlanner()
            selected.failure = PaceCLIProcessError.failed(1, "Synthetic selected-planner failure")
            let planner = PaceBoundedTextAnswerPlanner(
                everydayPlanner: everyday, selectedPlanner: selected,
                everydaySystemPrompt: "Trusted base voice and privacy rules", recordDecision: { _ in })
            do {
                _ = try await planner.generateResponseStreaming(
                    images: [], systemPrompt: "", conversationHistory: [], userPrompt: "Synthetic question",
                    onTextChunk: { _ in })
                Issue.record("Expected the planner failure to propagate")
            } catch is CancellationError {
                #expect(cancelEverydayAnswer)
            } catch PaceCLIProcessError.failed {
                #expect(!cancelEverydayAnswer)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(everyday.calls == 1)
            #expect(selected.calls == (cancelEverydayAnswer ? 0 : 1))
        }
    }
}
