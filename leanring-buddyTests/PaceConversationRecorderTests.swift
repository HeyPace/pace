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

    func makeFixture() -> (FixturePersister, PaceChatSession, PaceConversationRecorder) {
        let persister = FixturePersister()
        let submitter = FixtureSubmitter()
        let session = PaceChatSession(historySource: persister, transcriptSubmitter: submitter)
        let recorder = PaceConversationRecorder(persister: persister, chatSession: session)
        submitter.recorder = recorder
        return (persister, session, recorder)
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
