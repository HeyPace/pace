import Foundation
import Testing
@testable import Pace

@MainActor @Suite(.serialized)
struct PaceDialogueReplayTests {
    @Test func selectedReplyReplaysItsOwnSpeechWithoutAddingHistoryOrChangingDraft() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("Greet me", manager: manager)
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        manager.conversationRecorder.record(ConversationEvent(eventID: "selected-reply", turnID: manager.activeConversationUserEvent?.eventID,
            role: .pace, origin: .assistant, text: "Hello.", speechRequest: request))
        let selectedMessage = try #require(manager.chatSession.messages.first { $0.id == "selected-reply" })
        let selectedSpeech = try #require(selectedMessage.speechRequest)
        #expect(selectedMessage.turnIdentifier == manager.activeConversationUserEvent?.eventID)
        #expect(selectedMessage.origin == .assistant)
        let originalMessages = manager.chatSession.messages
        let originalEvents = persister.events.count
        manager.chatSession.draftMessageText = "Keep my next question"
        manager.replayChatSpeech(selectedSpeech)
        #expect(manager.voiceState == .responding)
        await manager.currentResponseTask?.value
        #expect(speech.requests == [request])
        #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEvents)
        #expect(manager.chatSession.draftMessageText == "Keep my next question")
        #expect(manager.voiceState == .idle)
    }

    @Test func bothMutePathsAndBusyTurnPreventReplayAudioAndHistory() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("A question", manager: manager)
        let originalMessages = manager.chatSession.messages
        let originalEvents = persister.events.count
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        for sessionMute in [true, false] {
            manager.chatSession.isChatTTSMuted = sessionMute
            manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(!sessionMute)
            #expect(!manager.canReplayChatSpeech)
            manager.replayChatSpeech(request)
            await manager.currentResponseTask?.value
        }
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(false)
        manager.voiceState = .listening
        manager.replayChatSpeech(request)
        #expect(speech.requests.isEmpty && speech.spokenTexts.isEmpty)
        #expect(manager.voiceState == .listening)
        #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEvents)
    }

    @Test func mutingImmediatelyAfterReplayClickPreventsItsScheduledAudio() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("A question", manager: manager)
        let eventCount = persister.events.count
        manager.replayChatSpeech(.init(text: "こんにちは。", profile: .japaneseFemale))
        manager.chatSession.isChatTTSMuted = true
        await manager.currentResponseTask?.value
        #expect(speech.requests.isEmpty && speech.spokenTexts.isEmpty)
        #expect(manager.voiceState == .idle && persister.events.count == eventCount)
    }

    @Test func stopCancelsScheduledReplayBeforeAudioAndDoesNotAppendMessages() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("A question", manager: manager)
        let originalMessages = manager.chatSession.messages
        let originalEvents = persister.events.count
        let stopCount = speech.stopCount
        manager.replayChatSpeech(.init(text: "こんにちは。", profile: .japaneseFemale))
        let replayTask = manager.currentResponseTask
        manager.cancelCurrentTurnFromPanel()
        await replayTask?.value
        #expect(speech.stopCount > stopCount)
        #expect(speech.requests.isEmpty && speech.spokenTexts.isEmpty)
        #expect(manager.voiceState == .idle)
        #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEvents)
    }
}
