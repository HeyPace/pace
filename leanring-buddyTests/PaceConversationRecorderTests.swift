import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceConversationRecorderTests {
    final class FixturePersister: PaceConversationEventPersisting, PaceChatHistorySource {
        var events: [String: ConversationEvent] = [:]
        var writes: [ConversationEvent] = []

        func upsertConversationEvent(_ event: ConversationEvent) {
            events[event.eventID] = event
            writes.append(event)
        }

        func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
            events.values.sorted { $0.createdAt < $1.createdAt }.map {
                PaceChatHistoryTurn(id: $0.eventID, userText: "", paceText: "",
                    recordedAt: $0.createdAt, conversationEvent: $0)
            }
        }
    }

    final class FixtureSubmitter: PaceChatTranscriptSubmitting {
        weak var recorder: PaceConversationRecorder?
        func submitChatTranscript(_ transcript: String, optimisticMessageIdentifier: String) {
            recorder?.acceptRequest(transcript, origin: .typed, eventIdentifier: optimisticMessageIdentifier)
        }
    }

    final class DismissalTTSClient: BuddyTTSClient {
        var submission: CheckedContinuation<Void, Never>?
        var suspendsSubmissions = false
        private(set) var spokenTexts: [String] = []
        private(set) var stopCount = 0
        private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var isPlaying = false

        func speakText(_ text: String) async throws {
            spokenTexts.append(text)
            try Task.checkCancellation()
            if suspendsSubmissions { await withCheckedContinuation { submission = $0 } }
        }

        func stopPlayback() { stopCount += 1 }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }

    func makeFixture() -> (FixturePersister, PaceChatSession, PaceConversationRecorder) {
        let persister = FixturePersister()
        let submitter = FixtureSubmitter()
        let session = PaceChatSession(historySource: persister, transcriptSubmitter: submitter)
        let recorder = PaceConversationRecorder(persister: persister, chatSession: session)
        submitter.recorder = recorder
        return (persister, session, recorder)
    }

    func makeDismissalFixture() -> (CompanionManager, FixturePersister, DismissalTTSClient) {
        let (persister, session, recorder) = makeFixture()
        let preferences = UserDefaults(suiteName: "PaceExplanationDismissalTests." + UUID().uuidString)!
        let manager = CompanionManager(watchModeDefaults: preferences)
        let client = DismissalTTSClient()
        manager.ttsClient = client
        manager.chatSession = session
        manager.conversationRecorder = recorder
        manager.bindVisualExplanationCallbacks()
        return (manager, persister, client)
    }

    final class ExplanationAutoCloseSleepGate {
        var requestedDurations: [Duration] = []
        var continuations: [CheckedContinuation<Void, Never>] = []

        func wait(_ duration: Duration) async {
            requestedDurations.append(duration)
            await withCheckedContinuation { continuations.append($0) }
        }

        func resumeNext() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }

        func resumeAll() {
            let pendingContinuations = continuations
            continuations.removeAll()
            for continuation in pendingContinuations { continuation.resume() }
        }
    }

    func waitForAutoCloseSleeps(_ count: Int, gate: ExplanationAutoCloseSleepGate) async throws {
        for _ in 0..<1_000 {
            if gate.requestedDurations.count >= count { break }
            await Task.yield()
        }
        try #require(gate.requestedDurations.count >= count)
    }

    @Test func explanationAutoCloseStartsThirtySecondsAfterAudioDrains() async throws {
        let (manager, _, client) = makeDismissalFixture()
        manager.voiceState = .responding
        client.isPlaying = true
        let gate = ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(companionManager: manager,
            waitForExplanationAutoClose: { await gate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            gate.resumeAll()
        }
        let initialDismissalGeneration = manager.diagramOverlayController.dismissalGeneration

        manager.voiceState = .idle
        try await waitForAutoCloseSleeps(1, gate: gate)
        #expect(gate.requestedDurations == [.milliseconds(200)])
        #expect(manager.diagramOverlayController.dismissalGeneration == initialDismissalGeneration)
        client.isPlaying = false
        gate.resumeNext()
        try await waitForAutoCloseSleeps(2, gate: gate)
        #expect(gate.requestedDurations.last == .seconds(30))
        gate.resumeNext()
        for _ in 0..<1_000 {
            if manager.diagramOverlayController.dismissalGeneration > initialDismissalGeneration { break }
            await Task.yield()
        }
        #expect(manager.diagramOverlayController.dismissalGeneration == initialDismissalGeneration + 1)
        #expect(manager.imageOverlayController.dismissalGeneration == 1)
        #expect(client.stopCount == 0)
        #expect(manager.voiceState == .idle)
    }

    @Test func interactingRestartsAutoCloseAndRetiresTheOldCountdown() async throws {
        let (manager, _, client) = makeDismissalFixture()
        let gate = ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(companionManager: manager,
            waitForExplanationAutoClose: { await gate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            gate.resumeAll()
        }
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await waitForAutoCloseSleeps(1, gate: gate)
        panelManager.resetExplanationAutoCloseAfterInteraction()
        try await waitForAutoCloseSleeps(2, gate: gate)
        #expect(gate.requestedDurations == [.seconds(30), .seconds(30)])
        gate.resumeNext()
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.diagramOverlayController.dismissalGeneration == 0)
        gate.resumeNext()
        for _ in 0..<1_000 {
            if manager.diagramOverlayController.dismissalGeneration > 0 { break }
            await Task.yield()
        }
        #expect(manager.diagramOverlayController.dismissalGeneration == 1)
        #expect(client.stopCount == 0)
    }

    @Test func newTurnPreventsThePreviousExplanationFromAutoClosing() async throws {
        let (manager, _, _) = makeDismissalFixture()
        let gate = ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(companionManager: manager,
            waitForExplanationAutoClose: { await gate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            gate.resumeAll()
        }
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await waitForAutoCloseSleeps(1, gate: gate)
        manager.voiceState = .processing
        panelManager.handleExplanationVoiceStateChange(.processing)
        gate.resumeNext()
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.diagramOverlayController.dismissalGeneration == 0)
        #expect(manager.imageOverlayController.dismissalGeneration == 0)
    }

    @Test func autoClosePreservesAnUnsentDraftAndAllowsAnotherThirtySeconds() async throws {
        let (manager, _, _) = makeDismissalFixture()
        let gate = ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(companionManager: manager,
            waitForExplanationAutoClose: { await gate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            gate.resumeAll()
        }
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await waitForAutoCloseSleeps(1, gate: gate)
        manager.chatSession.draftMessageText = "Explain the next part"
        gate.resumeNext()
        try await waitForAutoCloseSleeps(2, gate: gate)
        #expect(gate.requestedDurations == [.seconds(30), .seconds(30)])
        #expect(manager.chatSession.draftMessageText == "Explain the next part")
        #expect(manager.diagramOverlayController.dismissalGeneration == 0)
    }

    @Test func explicitPanelCloseCancelsSpeechQueuedTurnsAndPreservesInterruptedHistory() async {
        let (manager, persister, client) = makeDismissalFixture()
        let lease = manager.turnLeaseRegistry.beginTurn()
        manager.activeConversationUserEvent = manager.acceptConversationRequest("Explain rainbows", origin: .typed)
        manager.activeConversationAssistantEventIdentifier = "rainbow-response"
        manager.voiceState = .responding
        await manager.streamingSentenceTTSPipeline.acceptStreamedText("Light separates into colors.")
        let queuedEvent = manager.acceptConversationRequest("Explain the next part", origin: .typed)
        manager.chatTurnQueue.enqueue(.init(transcript: queuedEvent.text, shouldMuteTTS: false,
            optimisticMessageIdentifier: queuedEvent.eventID))
        manager.queuedChatTurnCount = 1
        let routingTask = Task<Void, Never> {}
        let responseTask = Task<Void, Never> {}
        manager.currentTurnDispatchTask = routingTask
        manager.currentResponseTask = responseTask
        let panelManager = MenuBarPanelManager(companionManager: manager)

        withExtendedLifetime(panelManager) {
            NotificationCenter.default.post(name: .paceDismissPanel, object: PaceExplanationDismissalIntent.automatic)
            #expect(!routingTask.isCancelled)
            #expect(client.stopCount == 0)
            NotificationCenter.default.post(name: .paceDismissPanel, object: PaceExplanationDismissalIntent.userInitiated)
        }

        #expect(routingTask.isCancelled && responseTask.isCancelled)
        #expect(!manager.turnLeaseRegistry.isCurrent(lease))
        #expect(manager.currentTurnDispatchTask == nil && manager.currentResponseTask == nil)
        #expect(manager.voiceState == .idle)
        #expect(manager.chatTurnQueue.isEmpty && manager.queuedChatTurnCount == 0)
        #expect(persister.events[queuedEvent.eventID]?.deliveryState == .cancelled)
        #expect(persister.events["rainbow-response"]?.deliveryState == .interrupted)
        #expect(persister.events["rainbow-response"]?.text == "Light separates into colors.")
        #expect(client.stopCount == 1 && client.lastStopReason == .manualStop)
        await manager.streamingSentenceTTSPipeline.flushFinal(finalSpokenText: "Late speech must stay silent.")
        #expect(client.spokenTexts == ["Light separates into colors."])
        #expect(manager.streamingSentenceTTSPipeline.inFlightStreamedText.isEmpty)
    }

    @Test func visualHandoffsKeepTheTurnButBothUserCloseCallbacksStopIt() {
        let (manager, _, client) = makeDismissalFixture()
        let lease = manager.turnLeaseRegistry.beginTurn()
        let responseTask = Task<Void, Never> {}
        manager.currentResponseTask = responseTask
        manager.voiceState = .responding
        manager.diagramOverlayController.onDidPresent?()
        manager.imageOverlayController.onWillGenerate?()
        manager.diagramOverlayController.dismiss()
        manager.imageOverlayController.dismiss()
        #expect(manager.turnLeaseRegistry.isCurrent(lease))
        #expect(!responseTask.isCancelled && client.stopCount == 0)

        manager.diagramOverlayController.dismiss(intent: .userInitiated)
        #expect(responseTask.isCancelled)
        #expect(manager.voiceState == .idle && client.stopCount == 1)
        manager.imageOverlayController.dismiss(intent: .userInitiated)
        #expect(client.stopCount == 2)
    }

    @Test func presentingAnnotationsAutomaticallyHidesChatWithoutStoppingSpeech() async throws {
        let (manager, _, client) = makeDismissalFixture()
        manager.mascotModeActive = false
        let lease = manager.turnLeaseRegistry.beginTurn()
        manager.voiceState = .responding
        let responseTask = Task<Void, Never> {}
        manager.currentResponseTask = responseTask
        let panelManager = MenuBarPanelManager(companionManager: manager)
        let previousWindowIdentifiers = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        panelManager.showPanelForSmokeTest()
        let panel = try #require(NSApplication.shared.windows.first {
            !previousWindowIdentifiers.contains(ObjectIdentifier($0)) && $0.isVisible
        })
        defer {
            manager.annotationOverlayController.clear(reason: "test cleanup")
            panel.orderOut(nil)
            manager.cancelActiveTurnTasks()
        }
        #expect(panel.isVisible)
        manager.annotationOverlayController.setAnnotations([
            PaceRenderedAnnotation(geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: .default, screenIndex: 1)
        ])
        for _ in 0..<100 {
            if !panel.isVisible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!panel.isVisible)
        #expect(manager.turnLeaseRegistry.isCurrent(lease))
        #expect(!responseTask.isCancelled)
        #expect(manager.voiceState == .responding)
        #expect(client.stopCount == 0)
        withExtendedLifetime(panelManager) {}
    }

    @Test func closingDuringFinalSynthesisCannotRestoreRespondingState() async throws {
        let (manager, _, client) = makeDismissalFixture()
        client.suspendsSubmissions = true
        let lease = manager.turnLeaseRegistry.beginTurn()
        manager.voiceState = .processing
        let finalSpeech = Task { await manager.beginFinalSpeechIfCurrentTurn(spokenText: "The explanation is ready.", turnLease: lease) }
        defer {
            finalSpeech.cancel()
            client.submission?.resume()
            client.submission = nil
        }
        for _ in 0..<1_000 {
            if client.submission != nil { break }
            await Task.yield()
        }
        let submission = try #require(client.submission)

        manager.handleExplanationDismissal(.userInitiated)
        client.submission = nil
        submission.resume()
        #expect(await finalSpeech.value == false)
        #expect(manager.voiceState == .idle)
        #expect(manager.streamingSentenceTTSPipeline.inFlightStreamedText.isEmpty)
        #expect(manager.streamingSentenceTTSPipeline.firstSpokenWordCharacterCount == 0)
    }

    @Test func userCloseThenAcceptedWatchOfferSpeaksWithoutRevivingOldChunks() async {
        let (manager, _, client) = makeDismissalFixture()
        let oldLease = manager.turnLeaseRegistry.beginTurn()
        await manager.streamingSentenceTTSPipeline.acceptStreamedText("The old explanation is finished.")
        manager.handleExplanationDismissal(.userInitiated)
        let observedAt = Date()
        let suggestion = PaceScreenSuggestion(identifier: UUID(), subject: "TCP congestion",
            evidence: "TCP congestion control", offer: "Want an explanation of TCP congestion?",
            sceneIdentity: .init(displayIdentifier: 1, applicationProcessIdentifier: 42,
                applicationBundleIdentifier: "com.apple.Safari"),
            observedAt: observedAt, expiresAt: observedAt.addingTimeInterval(45))
        manager.recordAssistantNarration(suggestion.offer, origin: .proactive,
            eventIdentifier: suggestion.conversationEventIdentifier)
        await manager.speakAcceptedWatchSuggestion(suggestion,
            speechGeneration: manager.watchSuggestionSpeechGeneration)
        await manager.streamingSentenceTTSPipeline.acceptStreamedText("The old reply must never resume.",
            expectedTurnLease: oldLease, currentTurnLease: manager.turnLeaseRegistry.currentLease)

        #expect(client.spokenTexts == ["The old explanation is finished.", suggestion.offer])
        #expect(manager.voiceState == .idle)
        #expect(manager.streamingSentenceTTSPipeline.inFlightStreamedText.isEmpty)
        #expect(manager.chatSession.userFacingMessages.filter { $0.body == suggestion.offer }.count == 1)
    }

    @Test func oldWatchSpeechCompletionCannotRetireANewerReplyMirror() async throws {
        let (manager, _, client) = makeDismissalFixture()
        client.suspendsSubmissions = true
        let observedAt = Date()
        let suggestion = PaceScreenSuggestion(identifier: UUID(), subject: "TCP congestion",
            evidence: "TCP congestion control", offer: "Want an explanation of TCP congestion?",
            sceneIdentity: .init(displayIdentifier: 1, applicationProcessIdentifier: 42,
                applicationBundleIdentifier: "com.apple.Safari"),
            observedAt: observedAt, expiresAt: observedAt.addingTimeInterval(45))
        let speechGeneration = manager.watchSuggestionSpeechGeneration
        let oldSpeech = Task { await manager.speakAcceptedWatchSuggestion(suggestion, speechGeneration: speechGeneration) }
        defer {
            oldSpeech.cancel()
            client.submission?.resume()
            client.submission = nil
            manager.cancelActiveTurnTasks()
        }
        for _ in 0..<1_000 {
            if client.submission != nil { break }
            await Task.yield()
        }
        let oldSubmission = try #require(client.submission)
        manager.cancelWatchSuggestionSpeech()
        manager.streamingSentenceTTSPipeline.resetForNewTurn()
        client.suspendsSubmissions = false
        await manager.streamingSentenceTTSPipeline.acceptStreamedText("This is the new explanation.")
        manager.voiceState = .responding
        client.submission = nil
        oldSubmission.resume()
        await oldSpeech.value

        #expect(manager.streamingSentenceTTSPipeline.inFlightStreamedText == "This is the new explanation.")
        #expect(manager.voiceState == .responding)
        #expect(client.spokenTexts == [suggestion.offer, "This is the new explanation."])
    }

    @Test func sameSecondIdenticalRequestsAndAssistantNarrationsHaveDistinctIdentities() {
        let (persister, session, recorder) = makeFixture()
        let createdAt = Date(timeIntervalSince1970: 1234)
        recorder.acceptRequest("repeat", origin: .voice)
        recorder.acceptRequest("repeat", origin: .typed)
        recorder.record(ConversationEvent(role: .pace, origin: .progress, text: "Working.", createdAt: createdAt))
        recorder.record(ConversationEvent(role: .pace, origin: .assistant, text: "Done.", createdAt: createdAt))
        #expect(persister.events.count == 4)
        session.loadHistory()
        #expect(Set(session.messages.map(\.id)).count == 4)
        #expect(session.messages.filter { $0.body == "repeat" }.count == 2)
    }

    @Test func acceptedTypedRequestSurvivesQueueCancellationAndReload() throws {
        let (persister, session, recorder) = makeFixture()
        session.submitUserMessage("accepted request")
        let userEvent = try #require(persister.events.values.first)
        #expect(session.messages.map(\.id) == [userEvent.eventID])
        recorder.updateDeliveryState(.cancelled, eventIdentifier: userEvent.eventID)
        session.loadHistory()
        #expect(session.messages.map(\.body) == ["accepted request"])
        #expect(persister.events[userEvent.eventID]?.deliveryState == .cancelled)
    }

    @Test func acceptedVoiceRequestSurvivesCancellationWithoutAssistantReply() {
        let (persister, session, recorder) = makeFixture()
        let request = recorder.acceptRequest("voice request", origin: .voice)
        recorder.updateDeliveryState(.cancelled, eventIdentifier: request.eventID)
        session.loadHistory()
        #expect(session.messages.map(\.body) == ["voice request"])
        #expect(persister.events[request.eventID]?.deliveryState == .cancelled)
    }

    @Test func completionDuringHistoryReadConvergesAndDoesNotEraseUpdatedVisiblePrefix() {
        let (persister, session, recorder) = makeFixture()
        let event = ConversationEvent(role: .pace, origin: .assistant, text: "Visible prefix", deliveryState: .interrupted)
        recorder.record(event)
        let staleDiskSnapshot = persister.loadPastTurnsOldestFirst()
        recorder.updateDeliveryState(.completed, eventIdentifier: event.eventID, visibleText: "Visible prefix and final answer.")
        session.applyLoadedHistory(staleDiskSnapshot)
        #expect(session.messages.count == 1)
        #expect(session.messages.first?.id == event.eventID)
        #expect(session.messages.first?.body == "Visible prefix and final answer.")
        session.loadHistory()
        #expect(session.messages.count == 1)
    }

    @Test func assistantOnlyProgressReminderAndFailureAreVisibleWhenMutedWithoutFakeUsers() {
        let (persister, session, recorder) = makeFixture()
        session.isChatTTSMuted = true
        for (origin, text) in [(ConversationEvent.Origin.progress, "Researching."), (.reminder, "Timer finished."), (.failure, "Could not connect.")] {
            recorder.record(ConversationEvent(role: .pace, origin: origin, text: text))
        }
        #expect(session.userFacingMessages.count == 3)
        #expect(persister.events.values.allSatisfy { $0.role == .pace })
        session.loadHistory()
        #expect(session.userFacingMessages.map(\.body) == ["Researching.", "Timer finished.", "Could not connect."])
    }

    @Test func repeatedDeliveryAndInterruptedUpdateUseOriginalEventIdentity() {
        let (persister, session, recorder) = makeFixture()
        let event = ConversationEvent(role: .pace, origin: .assistant, text: "Visible partial")
        recorder.record(event)
        recorder.record(event)
        recorder.updateDeliveryState(.interrupted, eventIdentifier: event.eventID, visibleText: "Visible partial")
        #expect(persister.events.count == 1)
        #expect(persister.events[event.eventID]?.deliveryState == .interrupted)
        session.loadHistory()
        #expect(session.messages.map(\.id) == [event.eventID])
    }

    @Test func draftsAndRawPartialTranscriptsAreNotArchived() {
        let (persister, session, _) = makeFixture()
        session.draftMessageText = "unfinished draft"
        session.submitUserMessage("  ")
        #expect(persister.writes.isEmpty)
        #expect(session.messages.isEmpty)
    }

    @Test func legacyPairWritesInTheSameSecondDoNotOverwriteEachOther() {
        let store = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(store: store, appliesPersistedSourcePreferences: false)
        let now = Date(timeIntervalSince1970: 1234)
        retriever.recordPaceHistory(userTranscript: "same request", assistantResponse: "First answer", now: now)
        retriever.recordPaceHistory(userTranscript: "same request", assistantResponse: "Second answer", now: now)
        retriever.recordPaceHistory(userTranscript: "", assistantResponse: "Reminder", now: now)
        retriever.recordPaceHistory(userTranscript: "", assistantResponse: "Another reminder", now: now)
        #expect(store.documents(withSource: .paceHistory).count == 4)
    }

    @Test func interruptedVisibleTextKeepsPartialSentenceButExcludesThinkingAndToolPayloads() {
        let rawText = "<think>private reasoning</think>Visible partial [CLICK:1,2]"
        let visibleText = StreamingSentenceTTSPipeline.computeSpeakableSafePrefix(from: rawText, requiresCompleteSentence: false)
        #expect(visibleText.contains("Visible partial"))
        #expect(!visibleText.contains("private reasoning"))
        #expect(!visibleText.contains("CLICK"))
    }

    @Test func realAsynchronousDiskReloadAndLiveCompletionConverge() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let indexURL = directoryURL.appendingPathComponent("retrieval-index.json")
        let store = PaceInMemoryRetrievalStore(persistenceURL: indexURL)
        let retriever = PaceLocalRetriever(store: store, appliesPersistedSourcePreferences: false)
        let session = PaceChatSession(historySource: PaceLocalChatHistoryReader(indexURL: indexURL), transcriptSubmitter: FixtureSubmitter())
        let recorder = PaceConversationRecorder(persister: retriever, chatSession: session)
        let request = recorder.acceptRequest("accepted", origin: .typed)
        session.loadHistoryWithoutBlockingInterface()
        let reply = ConversationEvent(turnID: request.eventID, role: .pace, origin: .assistant, text: "Completed while loading.")
        recorder.record(reply)
        for _ in 0..<100 where !session.hasLoadedHistory {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.hasLoadedHistory)
        #expect(session.messages.map(\.id) == [request.eventID, reply.eventID])
        #expect(session.messages.map(\.body) == ["accepted", "Completed while loading."])
    }

    @Test func existingRetrievalStoreRoundTripsTypedEventsAndLegacyPairsWithoutRewriting() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let indexURL = directoryURL.appendingPathComponent("retrieval-index.json")
        let store = PaceInMemoryRetrievalStore(persistenceURL: indexURL)
        let retriever = PaceLocalRetriever(store: store, appliesPersistedSourcePreferences: false)
        let legacyDocument = PaceRetrievalDocument(id: "legacy-turn", source: .paceHistory,
            title: "Recent Pace turn", text: "User: Earlier question\nPace: Earlier answer", modifiedAt: Date(timeIntervalSince1970: 100))
        store.upsertDocuments([legacyDocument])
        let session = PaceChatSession(historySource: PaceLocalChatHistoryReader(indexURL: indexURL), transcriptSubmitter: FixtureSubmitter())
        let recorder = PaceConversationRecorder(persister: retriever, chatSession: session)
        let event = ConversationEvent(role: .pace, origin: .reminder,
            text: "Timer finished. User: literal text remains intact.", createdAt: Date(timeIntervalSince1970: 200))
        recorder.record(event)
        recorder.updateDeliveryState(.interrupted, eventIdentifier: event.eventID)
        session.loadHistory()
        #expect(session.messages.map(\.body) == ["Earlier question", "Earlier answer", event.text])
        #expect(session.messages.last?.id == event.eventID)
        let restoredStore = PaceInMemoryRetrievalStore(persistenceURL: indexURL)
        #expect(restoredStore.documents(withSource: .paceHistory).first { $0.id == "legacy-turn" } == legacyDocument)
        #expect(restoredStore.documents(withSource: .paceHistory).first { $0.id == event.eventID }?.conversationEvent?.deliveryState == .interrupted)
    }
}
