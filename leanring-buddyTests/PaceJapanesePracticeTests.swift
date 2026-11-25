import Combine
import Foundation
import Testing

@testable import Pace

struct PaceJapanesePracticeContractTests {
    private let response =
        #"{"spokenText":"今日は何をしましたか。","intent":"answer","payload":{"englishSubtitle":"What did you do today?"}}"#

    @Test func practiceCommandsAreExplicitAndSupportBothLanguages() {
        for command in [
            "start Japanese practice", "speak Japanese with English subtitles", "let’s practice Japanese", "日本語で話して",
        ] {
            #expect(PaceConversationLanguageMode.command(command) == .japanesePractice)
        }
        for command in ["stop Japanese practice", "back to English", "英語に戻して。"] {
            #expect(PaceConversationLanguageMode.command(command) == .standard)
        }
        for question in [
            "What is Japanese practice?", "Explain Japanese grammar", "I read about Japanese practice",
            "translate back to English please",
        ] {
            #expect(PaceConversationLanguageMode.command(question) == nil)
        }
    }

    @Test func bilingualContractKeepsTheExistingEnvelopeAndBoundsBothLanguages() throws {
        let reply = try PaceBilingualReply.parse(response)
        #expect(
            reply.speechRequest
                == .init(text: "今日は何をしましたか。", profile: .japaneseFemale, englishSubtitle: "What did you do today?"))
        #expect(reply.englishSubtitle == "What did you do today?")
        for invalid in [
            "こんにちは。", #"{"spokenText":"こんにちは。","intent":"answer","payload":{}}"#,
            response.replacingOccurrences(of: "今日は何をしましたか。", with: "Hello today."),
            response.replacingOccurrences(of: "What did you do today?", with: ""),
            response.replacingOccurrences(of: "What did you do today?", with: String(repeating: "a", count: 4001)),
            response.replacingOccurrences(of: "今日は何をしましたか。", with: String(repeating: "あ", count: 2001)),
            response.replacingOccurrences(
                of: #""englishSubtitle":"What did you do today?""#, with: #""englishSubtitle":12"#),
            response.replacingOccurrences(of: #""intent":"answer""#, with: #""intent":"unknown""#),
        ] { #expect(throws: PaceJapanesePracticeError.self) { try PaceBilingualReply.parse(invalid) } }
        #expect(PaceConversationLanguageMode.standard.applying(to: "unchanged") == "unchanged")
        let prompt = PaceConversationLanguageMode.japanesePractice.applying(to: "existing action rules")
        #expect(prompt.contains("existing action rules") && prompt.contains("gently correct"))
    }

    @Test func subtitleDoesNotChangeExistingToolParsingOrApproval() throws {
        let raw =
            #"{"spokenText":"表示します。","intent":"action","payload":{"englishSubtitle":"I’ll show it.","name":"present_media","args":{"assetID":"thank-you-dance","durationSeconds":4}}}"#
        let reply = try PaceBilingualReply.parse(raw)
        let parsed = PaceActionTagParser.parseActions(from: raw)
        #expect(reply.englishSubtitle == "I’ll show it.")
        #expect(parsed.executionPlan.flattenedActions.count == 1)
        guard case .presentMedia(let media) = parsed.executionPlan.flattenedActions.first else {
            Issue.record("Media action must remain available.")
            return
        }
        #expect(media.assetID == "thank-you-dance")
        #expect(
            PaceActionApprovalRequest(
                approvalSummary: parsed.executionPlan.approvalSummary, requiresActionApproval: true) != nil)
    }

    @Test func historyRoundTripKeepsOneEnglishEventWithImmutableJapaneseSpeech() throws {
        let reply = try PaceBilingualReply.parse(response)
        let event = ConversationEvent(
            role: .pace, origin: .assistant, text: reply.englishSubtitle, speechRequest: reply.speechRequest)
        let decoded = try JSONDecoder().decode(ConversationEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        let oldEvent = ConversationEvent(role: .pace, origin: .assistant, text: "An older reply.")
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldEvent)) as? [String: Any])
        oldJSON.removeValue(forKey: "speechRequest")
        let decodedOldEvent = try JSONDecoder().decode(
            ConversationEvent.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(decodedOldEvent.speechRequest == nil && decodedOldEvent.text == oldEvent.text)
        let row = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: .init(
                id: event.id, role: .pace,
                body: event.text, createdAt: event.createdAt, speechRequest: event.speechRequest))
        #expect(row.isEnglishSubtitle && row.bodyText == reply.englishSubtitle)
    }

    @Test func authoredSpeechSubtitleIsOptionalStrictAndBounded() {
        let valid: [String: PaceMCPJSONValue] = [
            "text": .string("こんにちは。"), "profile": .string("japanese_female"), "englishSubtitle": .string("Hello."),
        ]
        #expect(PaceSpeechRequest.parse(arguments: valid)?.englishSubtitle == "Hello.")
        for invalidSubtitle in [
            PaceMCPJSONValue.null, .number(1), .string(" "), .string(String(repeating: "a", count: 4001)),
        ] {
            var arguments = valid
            arguments["englishSubtitle"] = invalidSubtitle
            #expect(PaceSpeechRequest.parse(arguments: arguments) == nil)
        }
        #expect(PaceSpeechRequest.parse(arguments: ["text": .string("hello")])?.englishSubtitle == nil)
    }

    @MainActor @Test func practiceUnknownConversationDefaultsToTextOnlyButMachineAndKnownRoutesStayIntact() {
        func decide(
            _ transcript: String, mode: PaceConversationLanguageMode = .japanesePractice,
            route: PaceIntentRoute = .fullPipeline, suggestion: Bool = false, visual: Bool = false
        ) -> PaceJapanesePracticeRouting.Decision {
            PaceJapanesePracticeRouting.decision(
                mode: mode, route: route, transcript: transcript,
                hasScreenSuggestion: suggestion, hasActiveVisualContext: visual)
        }
        let greeting = "こんにちは。短く返事してください。"
        #expect(decide(greeting) == .textOnlyConversation)
        for conversation in ["音楽が好きです。", "昨日、音楽をかけて踊りました。", "リマインドしてくれてありがとう。", "音楽かけて踊るのが好きです。"] {
            #expect(decide(conversation) == .textOnlyConversation)
        }
        for request in ["音楽をかけて。", "音楽かけてくれる？", "音楽をかけてください。", "明日の朝にリマインドして。", "リマインドしてくださいね。"] {
            #expect(decide(request) == .normalRouting)
        }
        for ending in ["くれない", "くれませんか", "もらえる", "もらえない", "もらえませんか", "よ", "ちょうだい", "欲しい", "欲しいです", "お願いします"] {
            #expect(decide("音楽をかけて" + ending + "？") == .normalRouting)
            #expect(decide("リマインドして" + ending + "。") == .normalRouting)
        }
        #expect(decide("音楽をかけて。ありがとう。") == .normalRouting)
        #expect(decide("リマインドしてもらえる？よろしく。") == .normalRouting)
        #expect(decide("今日はお茶を飲みました。") == .textOnlyConversation)
        #expect(decide(greeting, mode: .standard) == .normalRouting)
        #expect(decide(greeting, suggestion: true) == .normalRouting)
        #expect(decide(greeting, visual: true) == .normalRouting)
        let knownRoutes: [PaceIntentRoute] = [
            .readScreen, .executeTool, .research, .phoneLargeModel,
            .escalateToLargeModel, .chitchatFastPath, .answerDirectly,
        ]
        for route in knownRoutes {
            #expect(decide(greeting, route: route) == .normalRouting)
        }
        for command in [
            "画面を見て説明して", "ブラウザを開いて", "左のアイコンを押して", "メールを送信して",
            "フォルダを削除して", "日本語のパワーを実行して", "音量を上げて", "サイトを検索して",
            "Click the save button", "Open Chrome", "run power Japanese Greeting", "research this topic",
            "Show the screen", "type this into the terminal", "https://example.com",
            "undo that", "lock", "mission control", "make it better", "音楽をかけて", "リマインドして",
        ] {
            #expect(decide(command) == .normalRouting)
        }
    }

    @Test func multilingualConfigurationNeverReplacesEnglishDefaults() {
        let standard = WhisperKitTranscriptionProvider.LanguageMode.english
        let practice = WhisperKitTranscriptionProvider.LanguageMode.automaticJapaneseEnglish
        #expect(
            standard.modelName == "openai_whisper-base.en" && standard.decodingLanguage == "en"
                && !standard.detectsLanguage)
        #expect(
            practice.modelName == "openai_whisper-base" && practice.decodingLanguage == nil && practice.detectsLanguage)
        #expect(standard.modelFolderURL != practice.modelFolderURL)
        #expect(WhisperKitTranscriptionProvider.modelFolderURL == standard.modelFolderURL)
    }
}

@MainActor @Suite(.serialized)
struct PaceJapanesePracticeManagerTests {
    private final class Planner: BuddyPlannerClient {
        let displayName = "Practice fixture"
        let supportsImageInput = false
        var calls = 0
        var emitsUnsafePartial = true
        var capturedSystemPrompt = ""
        var imageCounts: [Int] = []
        var response =
            #"{"spokenText":"今日は何をしましたか。","intent":"answer","payload":{"englishSubtitle":"What did you do today?"}}"#
        func generateResponseStreaming(
            images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void
        ) async throws -> (text: String, duration: TimeInterval) {
            calls += 1
            imageCounts.append(images.count)
            capturedSystemPrompt = systemPrompt
            if emitsUnsafePartial { onTextChunk("This partial English prose must never be spoken in practice.") }
            onTextChunk(response)
            return (response, 0)
        }
    }

    @Test func onePlannerReplyShowsEnglishAndSpeaksJapaneseExactlyOnceAndReplaysItsProfile() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("I had tea today", manager: manager)
        let planner = Planner()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.handleTextOnlyPlannerFastPath(transcript: "I had tea today")
        await manager.currentResponseTask?.value
        #expect(planner.calls == 1 && planner.capturedSystemPrompt.contains("englishSubtitle"))
        #expect(speech.spokenTexts == ["今日は何をしましたか。"])
        #expect(
            speech.requests == [
                .init(text: "今日は何をしましたか。", profile: .japaneseFemale, englishSubtitle: "What did you do today?")
            ])
        let replies = persister.events.values.filter { $0.role == .pace }
        #expect(replies.count == 1 && replies.first?.text == "What did you do today?")
        #expect(replies.first?.speechRequest?.profile == .japaneseFemale)
        #expect(manager.chatSession.messages.filter { $0.role == .pace }.map(\.body) == ["What did you do today?"])
        manager.replayLastSpokenReply()
        await manager.currentResponseTask?.value
        #expect(speech.requests.count == 2 && speech.requests.last?.profile == .japaneseFemale)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        manager.setJapanesePracticeEnabled(false)
        #expect(manager.conversationLanguageMode == .standard)
        #expect(!manager.buddyDictationManager.usesJapanesePracticeTranscription)
        #expect(manager.buddyDictationManager.japanesePracticePreparationStatus.isEmpty)
        PacePowerManagerTests().begin("Back in English", manager: manager)
        planner.response = "Your usual English voice is back."
        planner.emitsUnsafePartial = false
        manager.handleTextOnlyPlannerFastPath(transcript: "Back in English")
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.last == "Your usual English voice is back.")
    }

    private final class UnknownConversationClassifier: PaceIntentClassifying {
        var calls = 0
        func classify(_ transcript: String) async -> PaceIntentPrediction {
            calls += 1
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
        func classify(
            _ transcript: String,
            conversationHistory: [(userTranscript: String, assistantResponse: String)]
        ) async -> PaceIntentPrediction {
            await classify(transcript)
        }
    }

    @Test func typedUnknownJapaneseGreetingUsesOneSelectedPlannerWithoutCapturingEvenWithReadMyScreenOn() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let transcript = "こんにちは。短く返事してください。"
        let planner = Planner()
        planner.response =
            #"{"spokenText":"こんにちは。お元気ですか。","intent":"answer","payload":{"englishSubtitle":"Hello. How are you?"}}"#
        let classifier = UnknownConversationClassifier()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.intentClassifier = classifier
        manager.activePlannerTier = .local
        manager.fastEverydayAnswersEnabled = false
        manager.conversationLanguageMode = .japanesePractice
        manager.useLocalVLMForScreenContext = true
        manager.isOverlayVisible = true
        var captureAttempts = 0
        manager.ambientContextStore.start()
        defer { manager.ambientContextStore.stop() }
        #expect(!manager.ambientContextStore.ambientPromptFragment.isEmpty)
        manager.captureScreensForPlanner = {
            captureAttempts += 1
            throw NSError(domain: "PracticeGreetingCaptureFixture", code: 1)
        }
        manager.submitChatTranscriptFromDeepLink(transcript)
        await manager.currentTurnDispatchTask?.value
        await manager.currentResponseTask?.value
        #expect(manager.useLocalVLMForScreenContext)
        #expect(classifier.calls == 1 && planner.calls == 1)
        #expect(planner.imageCounts == [0] && captureAttempts == 0)
        #expect(planner.capturedSystemPrompt.contains("englishSubtitle"))
        #expect(!planner.capturedSystemPrompt.contains("<ambient_context>"))
        #expect(speech.requests.isEmpty)
        #expect(manager.chatSession.messages.filter { $0.role == .pace }.map(\.body) == ["Hello. How are you?"])
        #expect(persister.events.values.filter { $0.role == .pace }.map(\.text) == ["Hello. How are you?"])
        #expect(persister.events.values.contains { $0.origin == .typed && $0.text == transcript })
        #expect(manager.voiceState == .idle)
    }

    @Test func practiceUnknownDeterministicCommandsAndClarificationKeepTheirActualManagerRoutes() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let classifier = PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
        let planner = Planner()
        manager.intentClassifier = classifier
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.isOverlayVisible = true
        manager.fastEverydayAnswersEnabled = false
        manager.conversationLanguageMode = .japanesePractice
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        manager.useLocalVLMForScreenContext = false
        var captureAttempts = 0
        manager.captureScreensForPlanner = {
            captureAttempts += 1
            throw NSError(domain: "UnexpectedPracticeCommandCapture", code: 1)
        }
        for transcript in ["undo that", "lock", "mission control"] {
            let prediction = await classifier.classify(transcript, conversationHistory: [])
            #expect(prediction.route == .fullPipeline)
            let parsed = try #require(PaceFastActionCommandParser.parse(transcript: transcript))
            manager.recentActionResults = []
            manager.submitChatTranscriptFromDeepLink(transcript)
            await manager.currentTurnDispatchTask?.value
            await manager.currentResponseTask?.value
            #expect(
                manager.recentActionResults.contains {
                    $0.status == .planned && $0.detail.contains(parsed.executionPlan.approvalSummary)
                })
            #expect(manager.recentActionResults.contains { $0.status == .skipped })
        }
        manager.submitChatTranscriptFromDeepLink("make it better")
        await manager.currentTurnDispatchTask?.value
        await manager.currentResponseTask?.value
        #expect(manager.pendingIntentClarification?.originalTranscript == "make it better")
        #expect(manager.currentTurnHUDState.status == .needsClarification)
        #expect(planner.calls == 0 && captureAttempts == 0)
        manager.useLocalVLMForScreenContext = true
        for transcript in ["音楽をかけて", "リマインドして"] {
            let prediction = await classifier.classify(transcript, conversationHistory: [])
            #expect(prediction.route == .fullPipeline)
            let previousCaptureAttempts = captureAttempts
            manager.submitChatTranscriptFromDeepLink(transcript)
            await manager.currentTurnDispatchTask?.value
            await manager.currentResponseTask?.value
            // The injected capture fails before any screen or planner work; reaching it proves normal routing.
            #expect(captureAttempts > previousCaptureAttempts && planner.calls == 0)
        }
    }

    @Test func practiceMathRoutesThroughTheSelectedBilingualPlannerAndSpeaksJapanese() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let transcript = "What is seven times nine?"
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin(transcript, manager: manager)
        let planner = Planner()
        planner.response =
            #"{"spokenText":"七かける九は六十三です。","intent":"answer","payload":{"englishSubtitle":"Seven times nine is sixty-three."}}"#
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.intentClassifier = PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
        manager.activePlannerTier = .local
        manager.useLocalVLMForScreenContext = false
        await manager.sendTranscriptToPlannerWithScreenshotAsync(
            transcript: transcript, turnLease: manager.turnLeaseRegistry.currentLease)
        await manager.currentResponseTask?.value
        #expect(planner.calls == 1 && planner.capturedSystemPrompt.contains("englishSubtitle"))
        #expect(
            speech.requests == [
                .init(
                    text: "七かける九は六十三です。", profile: .japaneseFemale,
                    englishSubtitle: "Seven times nine is sixty-three.")
            ])
        #expect(speech.spokenTexts == ["七かける九は六十三です。"])
        let assistantEvents = persister.events.values.filter { $0.role == .pace }
        #expect(assistantEvents.count == 1 && assistantEvents.first?.text == "Seven times nine is sixty-three.")
        #expect(manager.currentTurnHUDState.status != .failed)
    }

    @Test func unreadyPracticeShortcutPreservesRespondingTurnAndRetriesFailedPreparation() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.buddyDictationManager.usesJapanesePracticeTranscription = false
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        var preparationAttempts = 0
        var captureCueCount = 0
        manager.playCaptureAcknowledgementCue = { captureCueCount += 1 }
        manager.buddyDictationManager.prepareJapanesePracticeOverride = {
            preparationAttempts += 1
            throw WhisperKitTranscriptionProviderError(message: "Fixture multilingual model unavailable")
        }
        manager.buddyDictationManager.usesJapanesePracticeTranscription = true
        manager.isTranscriptionModelReady = true
        manager.voiceState = .responding
        let activeHUD = PaceTurnHUDState.acting("Reading your current answer")
        manager.currentTurnHUDState = activeHUD
        let activeTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        manager.currentResponseTask = activeTask
        let lease = manager.turnLeaseRegistry.currentLease
        let stopCount = speech.stopCount
        manager.handleShortcutTransition(.pressed)
        manager.handleShortcutTransition(.released)
        #expect(manager.voiceState == .responding && !activeTask.isCancelled)
        #expect(manager.turnLeaseRegistry.isCurrent(lease) && speech.stopCount == stopCount)
        #expect(manager.pendingKeyboardShortcutStartTask == nil && manager.transcriptSafetyTask == nil)
        #expect(manager.currentTurnHUDState == activeHUD)
        #expect(manager.buddyDictationManager.japanesePracticePreparationStatus.contains("Preparing"))
        for _ in 0..<1000 {
            if case .failed = manager.buddyDictationManager.japanesePracticeMicrophoneReadiness { break }
            await Task.yield()
        }
        #expect(preparationAttempts == 1)
        manager.handleShortcutTransition(.pressed)
        manager.handleShortcutTransition(.released)
        #expect(manager.currentTurnHUDState == activeHUD)
        #expect(
            manager.buddyDictationManager.japanesePracticePreparationStatus.contains("Preparing")
                || manager.buddyDictationManager.japanesePracticePreparationStatus.contains("Fixture multilingual"))
        for _ in 0..<1000 {
            if preparationAttempts == 2 { break }
            await Task.yield()
        }
        #expect(preparationAttempts == 2 && !activeTask.isCancelled)
        #expect(manager.currentTurnHUDState == activeHUD)
        #expect(manager.voiceState == .responding && speech.spokenTexts.isEmpty)
        #expect(captureCueCount == 0)
        manager.cancelCurrentTurnFromPanel()
        #expect(activeTask.isCancelled)
        await activeTask.value
    }

    @Test func taggedJapaneseReplyKeepsEnglishHistoryAndReplaysNormalizedSpeech() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("Say hello", manager: manager)
        let planner = Planner()
        planner.response =
            #"{"spokenText":"こんにちは。 [POINT:42,84:greeting:desktop] [DONE]","intent":"answer","payload":{"englishSubtitle":"Hello."}}"#
        let originalPoint = PaceTagParsers.parsePointingCoordinates(
            from:
                PaceTagParsers.parseAndStripDoneSignal(
                    from: PaceActionTagParser.parseActions(from: planner.response).spokenText
                ).strippedText)
        #expect(originalPoint.coordinate?.x == 42 && originalPoint.coordinate?.y == 84)
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.handleTextOnlyPlannerFastPath(transcript: "Say hello")
        await manager.currentResponseTask?.value
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        #expect(speech.requests == [request])
        let replies = persister.events.values.filter { $0.role == .pace }
        #expect(replies.count == 1 && replies.first?.text == "Hello." && replies.first?.speechRequest == request)
        manager.replayLastSpokenReply()
        await manager.currentResponseTask?.value
        #expect(speech.requests == [request, request])
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
    }

    @Test func validatedMismatchFailsVisiblyButWrittenOperationalAcknowledgementStaysQuiet() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("Hello", manager: manager)
        await manager.streamingSentenceTTSPipeline.flushFinal(finalSpokenText: "Showing the animation.")
        #expect(speech.requests.isEmpty && manager.currentTurnHUDState.status != .failed)
        let lease = manager.turnLeaseRegistry.currentLease
        try manager.prepareBilingualReplyIfNeeded(
            #"{"spokenText":"こんにちは。","intent":"answer","payload":{"englishSubtitle":"Hello."}}"#, turnLease: lease)
        let succeeded = await manager.beginFinalSpeechIfCurrentTurn(
            spokenText: "違う文章。", turnLease: lease, purpose: .assistantReply)
        #expect(!succeeded && manager.currentTurnHUDState.status == .failed)
        #expect(manager.currentTurnHUDState.detail?.contains("did not match") == true)
        #expect(manager.voiceState == .idle && speech.requests.isEmpty)
        var playbackFailures = 0
        manager.streamingSentenceTTSPipeline.onPlaybackFailure = { playbackFailures += 1 }
        await manager.streamingSentenceTTSPipeline.flushFinal(finalSpokenText: "違う文章。")
        #expect(playbackFailures == 1 && speech.requests.isEmpty)
    }

    @Test func validBilingualActionKeepsOperationalFeedbackWrittenOnlyAndPreservesItsHUD() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("Show the greeting", manager: manager)
        let response =
            #"{"spokenText":"あいさつを表示します。","intent":"action","payload":{"name":"present_media","args":{"assetID":"japanese-greeting-woman","durationSeconds":6},"englishSubtitle":"I’ll show the greeting."}}"#
        #expect(PaceActionTagParser.parseActions(from: response).actions.count == 1)
        let lease = manager.turnLeaseRegistry.currentLease
        try manager.prepareBilingualReplyIfNeeded(response, turnLease: lease)
        manager.recordConversationTurn(userTranscript: "Show the greeting", assistantResponse: "あいさつを表示します。")
        #expect(
            persister.events.values.contains {
                $0.role == .pace && $0.text == "I’ll show the greeting." && $0.speechRequest != nil
            })
        let delivered = await manager.beginFinalSpeechIfCurrentTurn(
            spokenText: "あいさつを表示します。", turnLease: lease, purpose: .assistantReply)
        #expect(delivered && speech.spokenTexts == ["あいさつを表示します。"])
        let japaneseReplayRequest = PaceSpeechRequest(
            text: "あいさつを表示します。", profile: .japaneseFemale,
            englishSubtitle: "I’ll show the greeting.")
        #expect(manager.lastSpokenReplyRequest == japaneseReplayRequest)
        let feedback = try #require(
            PaceActionExecutionObservation.formatForUserFeedback([
                .init(
                    toolName: "present_media", summary: "Presented local media fixture.",
                    userFacingSummary: "Presented the requested local media.")
            ]))
        let cases: [(String, PaceTurnHUDState)] = [
            (feedback, .acting("Presenting the greeting")),
            (
                "Stopped because the next action was denied. Earlier actions may have completed; the full request remains unverified.",
                .failed("Action denied; request not verified")
            ),
            (
                "Stopped after 2 steps before verifying the full request. Please check the current result before continuing.",
                .failed("Step limit reached; request not verified")
            ),
        ]
        for (writtenFeedback, expectedHUD) in cases {
            manager.currentTurnHUDState = expectedHUD
            manager.voiceState = .processing
            let eventCount = persister.events.count
            let continued = await manager.deliverPostActionFeedbackIfCurrentTurn(writtenFeedback, turnLease: lease)
            #expect(continued && manager.currentTurnHUDState == expectedHUD)
            #expect(manager.voiceState == .processing && persister.events.count == eventCount + 1)
            #expect(speech.spokenTexts == ["あいさつを表示します。"])
            #expect(manager.lastSpokenReplyRequest == japaneseReplayRequest)
        }
        #expect(!persister.events.values.contains { $0.origin == .failure })
        await manager.deliverCodingForegroundReply(
            "Coding session stopped before completing the request.",
            transcript: "", turnLease: lease, failed: true)
        #expect(manager.voiceState == .idle)
        #expect(manager.currentTurnHUDState == .failed("Coding session stopped before completing the request."))
        #expect(speech.spokenTexts == ["あいさつを表示します。"])
        #expect(!persister.events.values.contains { $0.origin == .failure })

        manager.conversationLanguageMode = .standard
        PacePowerManagerTests().begin("Back to normal", manager: manager)
        let standardDelivered = await manager.deliverPostActionFeedbackIfCurrentTurn(
            feedback,
            turnLease: manager.turnLeaseRegistry.currentLease)
        #expect(standardDelivered && speech.spokenTexts.last == feedback)
        #expect(manager.lastSpokenReplyRequest == PaceSpeechRequest(text: feedback))
        manager.voiceState = .idle
        manager.replayLastSpokenReply()
        await manager.currentResponseTask?.value
        #expect(Array(speech.spokenTexts.suffix(2)) == [feedback, feedback])
    }

    @Test(.timeLimit(.minutes(1))) func unsupportedTypedPracticeCommandReturnsIdleAndDrainsTheFollowingQueuedTurn()
        async throws
    {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            manager.queuedChatTurnDrainTask?.cancel()
            manager.queuedChatTurnDrainCancellable?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        let speech = PaceConversationRecorderTests.DismissalTTSClient()
        manager.ttsClient = speech
        manager.streamingSentenceTTSPipeline = StreamingSentenceTTSPipeline(ttsClient: speech)
        let planner = Planner()
        planner.emitsUnsafePartial = false
        planner.response = "63."
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.intentClassifier = PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
        manager.activePlannerTier = .local
        manager.fastEverydayAnswersEnabled = false
        manager.useLocalVLMForScreenContext = false
        let (states, stateContinuation) = AsyncStream<CompanionVoiceState>.makeStream()
        let stateObservation = manager.$voiceState.sink { stateContinuation.yield($0) }
        defer {
            stateObservation.cancel()
            stateContinuation.finish()
        }
        manager.isOverlayVisible = true
        manager.bindQueuedChatTurnDrainObservation()
        manager.voiceState = .processing
        manager.submitChatTranscriptFromDeepLink("start Japanese practice")
        manager.submitChatTranscriptFromDeepLink("What is seven times nine?")
        #expect(manager.queuedChatTurnCount == 2)
        manager.voiceState = .idle
        manager.drainNextQueuedChatTurnIfPossible()
        for await state in states {
            if state == .idle, manager.voiceState == .idle, manager.queuedChatTurnCount == 0 { break }
        }
        #expect(manager.conversationLanguageMode == .standard)
        #expect(manager.voiceState == .idle && manager.queuedChatTurnCount == 0)
        #expect(speech.spokenTexts.isEmpty)
        #expect(manager.chatSession.messages.contains { $0.role == .pace && $0.body.contains("63") })
        #expect(planner.calls == 1)
        #expect(
            persister.events.values.contains {
                $0.role == .pace && $0.text.contains("needs the local Kokoro Japanese voice")
            })
    }

    @Test func invalidPracticeReplyFailsVisiblyWithoutSpeakingEnglishOrJSON() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("Hello", manager: manager)
        let planner = Planner()
        planner.response = "An English reply without subtitles."
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.handleTextOnlyPlannerFastPath(transcript: "Hello")
        await manager.currentResponseTask?.value
        #expect(manager.currentTurnHUDState.status == .failed)
        #expect(speech.spokenTexts.isEmpty)
        #expect(manager.chatSession.messages.contains { $0.body.contains("English subtitles") })
    }

    @Test func practiceFastActionStillExecutesAndKeepsItsEnglishAcknowledgementSilent() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.conversationLanguageMode = .japanesePractice
        PacePowerManagerTests().begin("Show the animation", manager: manager)
        manager.requiresActionApproval = false
        var presented = 0
        manager.actionExecutor.presentLocalMedia = { _ in
            presented += 1
            return .init(toolName: "present_media", summary: "Presented")
        }
        let plan = PaceActionExecutionPlan.serial(actions: [
            .presentMedia(.init(assetID: "thank-you-dance", durationSeconds: 4, motion: nil))
        ])
        manager.handleFastLocalActionPath(
            transcript: "Show the animation",
            fastActionParseResult: .init(spokenText: "Showing the animation.", executionPlan: plan))
        await manager.currentResponseTask?.value
        #expect(presented == 1)
        #expect(speech.spokenTexts.isEmpty)
    }

    @Test func bundledGreetingSubtitleUsesTheSameEnglishHistoryEntryOutsidePractice() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        PacePowerManagerTests().begin("show me the Japanese greeting", manager: manager)
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        let observation = await manager.actionExecutor.speakLocalText?(request)
        #expect(observation?.terminalReason == nil)
        #expect(speech.requests == [request])
        let replies = persister.events.values.filter { $0.role == .pace }
        #expect(replies.count == 1 && replies.first?.text == "Hello.")
        #expect(replies.first?.speechRequest == request)
        #expect(manager.lastSpokenReplyRequest == request)
        #expect(manager.conversationLanguageMode == .standard)
    }

    @Test func muteAndStopKeepPracticeSpeechSilentAndRetainEnglishSubtitles() async throws {
        let speech = PacePowerManagerTests.LocalSpeech()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: speech)
        let reply = try PaceBilingualReply.parse(
            #"{"spokenText":"こんにちは。","intent":"answer","payload":{"englishSubtitle":"Hello."}}"#)
        pipeline.setConversationLanguageModeForCurrentTurn(.japanesePractice)
        await pipeline.acceptStreamedText("English should never escape.")
        await pipeline.flushFinal(finalSpokenText: "Another English status.")
        #expect(speech.spokenTexts.isEmpty && pipeline.inFlightStreamedText.isEmpty)
        pipeline.setBilingualReplyForCurrentTurn(reply)
        pipeline.setMutedForCurrentTurn(true)
        await pipeline.flushFinal(finalSpokenText: reply.speechRequest.text)
        #expect(speech.spokenTexts.isEmpty && pipeline.inFlightStreamedText == "Hello.")
        pipeline.resetForNewTurn()
        pipeline.setConversationLanguageModeForCurrentTurn(.japanesePractice)
        pipeline.setBilingualReplyForCurrentTurn(reply)
        pipeline.stopForUserDismissal()
        await pipeline.flushFinal(finalSpokenText: reply.speechRequest.text)
        #expect(speech.spokenTexts.isEmpty)
    }
}

struct PaceJapanesePracticeSpeechFixtureTests {
    private struct Fixture: Decodable {
        let filePath: String
        let expectedFragment: String
    }
    private static var manifestPath: String? {
        ProcessInfo.processInfo.environment["PACE_LANGUAGE_PRACTICE_FIXTURE_MANIFEST"]
    }

    @Test(.enabled(if: PaceJapanesePracticeSpeechFixtureTests.manifestPath != nil))
    func multilingualLocalRuntimeRecognizesJapaneseAndEnglishFixtures() async throws {
        let manifest = try #require(Self.manifestPath)
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        try #require(fixtures.count >= 2)
        let provider = WhisperKitTranscriptionProvider(languageMode: .automaticJapaneseEnglish)
        for fixture in fixtures {
            let recognized = try await provider.transcribeAudioFile(URL(fileURLWithPath: fixture.filePath))
            print("Practice speech fixture recognized: \(recognized)")
            #expect(recognized.localizedCaseInsensitiveContains(fixture.expectedFragment))
        }
    }
}
