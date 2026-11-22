import Foundation
import Testing
@testable import Pace

@MainActor @Suite(.serialized)
struct PaceDialogueReplayTests {
    private final class ControlledEnglishSpeech: BuddyTTSClient {
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var supportsUtteranceCompletion: Bool { true }
        func supportsSpeechProfile(_ profile: PaceSpeechProfile) -> Bool { true }
        var requests: [PaceSpeechRequest] = []
        var legacySubmissionCount = 0
        var stopCount = 0
        var completion: CheckedContinuation<Void, Never>?

        func speakText(_ text: String) async throws {
            legacySubmissionCount += 1
            isPlaying = true
        }
        func speakUtterance(_ request: PaceSpeechRequest, onStarted: @escaping @MainActor () -> Void) async throws {
            requests.append(request)
            isPlaying = true
            onStarted()
            await withCheckedContinuation { completion = $0 }
        }
        func finishPlayback() {
            isPlaying = false
            let pendingCompletion = completion
            completion = nil
            pendingCompletion?.resume()
        }
        func stopPlayback() { stopCount += 1; finishPlayback() }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }

    @Test func englishReplayStaysRespondingUntilCompletionAndStopAfterOnsetPreservesHistoryAndDraft() async throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let speech = ControlledEnglishSpeech()
        manager.ttsClient = speech
        PacePowerManagerTests().begin("A question", manager: manager)
        let request = PaceSpeechRequest(text: "Your usual English reply.")
        let originalMessages = manager.chatSession.messages
        let originalEvents = persister.events.count
        manager.chatSession.draftMessageText = "Keep this draft"
        manager.lastSpokenReplyRequest = request
        manager.replayLastSpokenReply()
        for _ in 0..<1000 {
            if speech.completion != nil { break }
            await Task.yield()
        }
        #expect(speech.completion != nil && speech.isPlaying)
        #expect(manager.voiceState == .responding && !manager.canReplayChatSpeech)
        #expect(speech.legacySubmissionCount == 0 && speech.requests == [request])
        speech.finishPlayback()
        await manager.currentResponseTask?.value
        #expect(manager.voiceState == .idle && manager.canReplayChatSpeech)

        manager.replayChatSpeech(request)
        for _ in 0..<1000 {
            if speech.completion != nil { break }
            await Task.yield()
        }
        #expect(speech.completion != nil && manager.voiceState == .responding)
        let replayTask = manager.currentResponseTask
        let stopCount = speech.stopCount
        manager.cancelCurrentTurnFromPanel()
        await replayTask?.value
        #expect(speech.stopCount > stopCount && !speech.isPlaying)
        #expect(manager.voiceState == .idle)
        #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEvents)
        #expect(manager.chatSession.draftMessageText == "Keep this draft")
    }

    @Test func closingMessageAndNotchReplayPreservesCompletedCanonicalEventsIncludingSpeechMetadata() async throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        let speech = ControlledEnglishSpeech()
        defer { speech.stopPlayback(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        manager.ttsClient = speech
        manager.streamingSentenceTTSPipeline = StreamingSentenceTTSPipeline(ttsClient: speech)
        manager.conversationLanguageMode = .japanesePractice
        let reply = try PaceBilingualReply.parse(#"{"spokenText":"こんにちは。","intent":"answer","payload":{"englishSubtitle":"Hello."}}"#)
        for (usesNotchDelegate, usesStop) in [(false, false), (true, false), (false, true), (true, true)] {
            PacePowerManagerTests().begin("Greet me", manager: manager)
            manager.activeBilingualReply = reply
            manager.recordConversationTurn(userTranscript: "Greet me", assistantResponse: reply.speechRequest.text)
            manager.voiceState = .idle
            let completedUser = try #require(manager.activeConversationUserEvent)
            let completedAssistantIdentifier = try #require(manager.lastConversationAssistantEventIdentifier)
            #expect(persister.events[completedUser.eventID]?.deliveryState == .completed)
            #expect(persister.events[completedAssistantIdentifier]?.deliveryState == .completed)
            #expect(persister.events[completedAssistantIdentifier]?.speechRequest == reply.speechRequest)
            let originalEvents = persister.events
            let originalMessages = manager.chatSession.messages
            manager.chatSession.draftMessageText = "Keep my next question"
            manager.lastSpokenReplyRequest = reply.speechRequest
            if usesNotchDelegate { manager.replayLastSpokenReply() }
            else { manager.replayChatSpeech(reply.speechRequest) }
            for _ in 0..<1000 {
                if speech.completion != nil { break }
                await Task.yield()
            }
            #expect(speech.completion != nil && speech.isPlaying && manager.voiceState == .responding)
            let replayTask = manager.currentResponseTask
            #expect(manager.activeConversationUserEvent?.eventID == completedUser.eventID)
            if usesStop { manager.cancelCurrentTurnFromPanel() }
            else { manager.handleExplanationDismissal(.userInitiated) }
            await replayTask?.value
            #expect(!speech.isPlaying && manager.voiceState == .idle)
            #expect(speech.requests.last == reply.speechRequest)
            #expect(persister.events == originalEvents && manager.chatSession.messages == originalMessages)
            #expect(manager.chatSession.draftMessageText == "Keep my next question")
        }
    }

    @Test func postActionNotchReplayPreservesAcceptedUserAndCompletedFeedbackOnCloseOrNewInput() async throws {
        for closesReplay in [true, false] {
            let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
            let speech = ControlledEnglishSpeech()
            defer { speech.stopPlayback(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
            PacePowerManagerTests().begin("Perform the task", manager: manager)
            let originalUser = try #require(manager.activeConversationUserEvent)
            #expect(await manager.deliverPostActionFeedbackIfCurrentTurn("The local task finished.",
                turnLease: manager.turnLeaseRegistry.currentLease))
            manager.voiceState = .idle
            let feedbackIdentifier = try #require(manager.lastConversationAssistantEventIdentifier)
            #expect(persister.events[originalUser.eventID]?.deliveryState == .accepted)
            #expect(persister.events[feedbackIdentifier]?.deliveryState == .completed)
            let originalEvents = persister.events
            manager.chatSession.draftMessageText = "Keep this next question"
            manager.ttsClient = speech
            manager.streamingSentenceTTSPipeline = StreamingSentenceTTSPipeline(ttsClient: speech)
            manager.replayLastSpokenReply()
            for _ in 0..<1000 {
                if speech.completion != nil { break }
                await Task.yield()
            }
            #expect(speech.completion != nil && manager.voiceState == .responding)
            let replayTask = manager.currentResponseTask
            if closesReplay {
                manager.handleExplanationDismissal(.userInitiated)
                await replayTask?.value
                #expect(persister.events == originalEvents)
            }
            PacePowerManagerTests().begin("A new normal request", manager: manager)
            await replayTask?.value
            #expect(originalEvents.allSatisfy { persister.events[$0.key] == $0.value })
            #expect(!manager.replayPreservesOriginalConversationHistory)
            let nextUser = try #require(manager.activeConversationUserEvent)
            manager.updateAssistantStreamingText("The next answer has started.")
            manager.voiceState = .responding
            manager.handleExplanationDismissal(.userInitiated)
            #expect(persister.events[nextUser.eventID]?.deliveryState == .cancelled)
            #expect(persister.events.values.contains { $0.text == "The next answer has started." && $0.deliveryState == .interrupted })
            #expect(originalEvents.allSatisfy { persister.events[$0.key] == $0.value })
            #expect(manager.chatSession.draftMessageText == "Keep this next question")
        }
    }

    @Test func restoredHistoryReplayClearsProtectionEvenWithoutAnActiveRequest() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        manager.replayChatSpeech(.init(text: "A restored reply."))
        let replayTask = manager.currentResponseTask
        #expect(manager.activeConversationUserEvent == nil && manager.replayPreservesOriginalConversationHistory)
        manager.interruptConversationRequest()
        #expect(!manager.replayPreservesOriginalConversationHistory)
        manager.cancelCurrentTurnFromPanel()
        await replayTask?.value
        manager.beginConversationRequest("A fresh request")
        #expect(!manager.replayPreservesOriginalConversationHistory)
    }

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

    @Test func notchReplayCannotReplaceARunningTurnOrBreakStopCancellation() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("Keep working", manager: manager)
        let originalEvents = persister.events.count
        manager.lastSpokenReplyText = "An earlier reply."
        manager.voiceState = .responding
        let activeTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        manager.currentResponseTask = activeTask
        manager.replayLastSpokenReply()
        #expect(!activeTask.isCancelled && speech.spokenTexts.isEmpty)
        manager.cancelCurrentTurnFromPanel()
        #expect(activeTask.isCancelled)
        await activeTask.value
        #expect(manager.voiceState == .idle && speech.spokenTexts.isEmpty)
        #expect(persister.events.count == originalEvents)
    }

    @Test func sessionMuteAndBusyTurnPreventReplayWhileAutomaticMuteAllowsExplicitReplay() async throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        PacePowerManagerTests().begin("A question", manager: manager)
        let originalMessages = manager.chatSession.messages
        let originalEvents = persister.events.count
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        manager.chatSession.isChatTTSMuted = true
        #expect(!manager.canReplayChatSpeech)
        manager.replayChatSpeech(request)
        #expect(speech.requests.isEmpty && speech.spokenTexts.isEmpty)

        manager.chatSession.isChatTTSMuted = false
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(true)
        #expect(manager.canReplayChatSpeech)
        manager.replayChatSpeech(request)
        await manager.currentResponseTask?.value
        #expect(speech.requests.count == 1)

        manager.voiceState = .listening
        manager.replayChatSpeech(request)
        #expect(speech.requests.count == 1 && manager.voiceState == .listening)
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
