import Combine
import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PaceRequestFeedbackTests {
    @Test func voiceAsksOnlyForThePermissionItsActiveProviderUses() {
        #expect(
            PaceChatVoiceAction.missingPermission(microphoneAllowed: false, speechRequired: true, speechAllowed: false)
                == .allowMicrophone)
        #expect(
            PaceChatVoiceAction.missingPermission(microphoneAllowed: true, speechRequired: true, speechAllowed: false)
                == .allowSpeechRecognition)
        #expect(
            PaceChatVoiceAction.missingPermission(microphoneAllowed: true, speechRequired: false, speechAllowed: false)
                == nil)
        #expect(
            PaceChatVoiceAction.missingPermission(microphoneAllowed: true, speechRequired: true, speechAllowed: true)
                == nil)
    }

    @Test func missingCaptureAndShortcutPermissionsDoNotBlockChatOrMicrophoneButton() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.hasAccessibilityPermission = false
        manager.hasScreenRecordingPermission = false
        manager.hasScreenContentPermission = false
        manager.hasMicrophonePermission = true
        manager.hasSpeechRecognitionPermission = true
        manager.isTranscriptionModelReady = false
        #expect(PaceChatVoiceAction.resolve(for: manager) == .checkVoiceModel)
        manager.isTranscriptionModelReady = true
        #expect(PaceChatVoiceAction.resolve(for: manager) == .start)
        #expect(manager.nativePanelPresentation.signalState == .ready)
        #expect(
            !PaceDialogueTranscriptModel.showsCurrentTurnStatus(
                state: manager.nativePanelPresentation.signalState, hasFailure: false))
        manager.hasMicrophonePermission = false
        manager.currentTurnHUDState = .failed("Could not open the file")
        #expect(PaceChatVoiceAction.resolve(for: manager) == .allowMicrophone)
        #expect(manager.nativePanelPresentation.signalState == .failed)
        manager.currentTurnHUDState = .clarification(question: "Which file?", options: ["First", "Second"])
        #expect(manager.nativePanelPresentation.signalState == .blocked)
        #expect(manager.currentTurnHUDState.options.count == 2)
    }

    @Test func requestDetailsStayWithTheirOwnerAndGlobalFailuresRemainReachable() {
        #expect(!PaceChatRequestLocation.conversation(nil).showsDetails(in: "thread", hasFailure: true))
        #expect(!PaceChatRequestLocation.conversation("other").showsDetails(in: "thread", hasFailure: false))
        #expect(PaceChatRequestLocation.conversation("thread").showsDetails(in: "thread", hasFailure: false))
        #expect(PaceChatRequestLocation.unowned.showsDetails(in: "thread", hasFailure: true))
    }

    @Test func openingQueuedWorkKeepsAnotherChatsQueueAndDraftIntact() throws {
        let (directory, manager, _, _) = try PacePowerManagerTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = manager.chatSession
        let root = manager.acceptConversationRequest("Parent", origin: .typed)
        let child = manager.acceptConversationRequest("Reply", origin: .typed, threadRootID: root.id)
        let main = manager.acceptConversationRequest("Main request", origin: .typed)
        for event in [child, main] {
            manager.chatTurnQueue.enqueue(
                .init(transcript: event.text, shouldMuteTTS: true, optimisticMessageIdentifier: event.id))
        }
        session.draftMessageText = "Main draft"
        #expect(manager.firstQueuedLocationOutsideCurrentChat == .conversation(root.id))
        session.navigate(to: root.id)
        #expect(manager.firstQueuedLocationOutsideCurrentChat == .conversation(nil))
        #expect(manager.queuedRequestIDsInCurrentChat == [child.id])
        manager.cancelQueuedChatTurns(eventIdentifiers: manager.queuedRequestIDsInCurrentChat)
        session.returnToMainChat()
        #expect(manager.queuedRequestIDsInCurrentChat == [main.id])
        #expect(session.draftMessageText == "Main draft")
    }

    @Test func physicalMicWingRoutesToVoiceInsteadOfTheChatCatchAll() {
        #expect(
            PaceNotchTapAction.resolve(
                point: CGPoint(x: 20, y: 16), surfaceWidth: 273,
                housingWidth: 185, housingHeight: 32) == .microphone)
        #expect(
            PaceNotchTapAction.resolve(
                point: CGPoint(x: 250, y: 16), surfaceWidth: 273,
                housingWidth: 185, housingHeight: 32) == .conversation)
        #expect(
            PaceNotchTapAction.resolve(
                point: CGPoint(x: 20, y: 45), surfaceWidth: 273,
                housingWidth: 185, housingHeight: 32) == .conversation)
    }
    @Test func preparationAndTranscriptionDoNotClaimSpeechWasUnderstood() {
        let start = Date(timeIntervalSince1970: 100)
        let preparing = PaceRequestFeedback.resolve(
            state: .listening, hudDetail: nil,
            isPreparing: true, isFinalizing: false, startedAt: start, now: start.addingTimeInterval(2))
        #expect(preparing.title == "Starting microphone…")
        #expect(preparing.showsSpinner && preparing.elapsedLabel == "2s")
        let transcribing = PaceRequestFeedback.resolve(
            state: .understanding, hudDetail: "Audio captured",
            isPreparing: false, isFinalizing: true, startedAt: start, now: start.addingTimeInterval(4))
        #expect(transcribing.title == "Transcribing…")
        #expect(transcribing.detail?.contains("Audio received") == true)
        let failed = PaceRequestFeedback.resolve(
            state: .failed, hudDetail: "Microphone denied",
            isPreparing: true, isFinalizing: true, startedAt: start, now: start.addingTimeInterval(5))
        #expect(failed.title == "Needs attention" && failed.detail == "Microphone denied")
        #expect(!failed.showsSpinner && failed.elapsedLabel == nil)
    }

    @Test func waitingWorkShowsRealElapsedTimeWithoutFakeCompletionOrPercentages() {
        let start = Date(timeIntervalSince1970: 100)
        let working = PaceRequestFeedback.resolve(
            state: .understanding, hudDetail: "Heard you · Working…",
            isPreparing: false, isFinalizing: false, startedAt: start, now: start.addingTimeInterval(74))
        #expect(working.title == "Still working…" && working.elapsedLabel == "1m 14s")
        let ready = PaceRequestFeedback.resolve(
            state: .ready, hudDetail: nil,
            isPreparing: false, isFinalizing: false, startedAt: start, now: start.addingTimeInterval(100))
        #expect(ready.elapsedLabel == nil && !ready.showsSpinner)
    }

    @Test func microphoneButtonStartsAndStopsOnePressWithoutRequestingChatFocus() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        var transitions = 0
        let observation = manager.globalPushToTalkShortcutMonitor.shortcutTransitionPublisher.sink { _ in
            transitions += 1
        }
        manager.handleMicrophoneButtonTapped()
        #expect(manager.currentDictationTrigger == .microphoneButton)
        #expect(manager.globalPushToTalkShortcutMonitor.isSimulatedPressActive)
        manager.handleMicrophoneButtonTapped()
        #expect(!manager.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed)
        #expect(transitions == 2)
        withExtendedLifetime(observation) {}
    }

    @Test func rejectedVoiceStartStillShowsPassiveFeedbackAndNeverClaimsCapture() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.isOverlayVisible = true
        manager.isTranscriptionModelReady = false
        manager.conversationLanguageMode = .standard
        var presentations: [PaceConversationPanelPresentationIntent] = []
        let observation = manager.conversationPanelPresentationRequests.sink { presentations.append($0) }
        manager.handleShortcutTransition(.pressed)
        #expect(presentations == [.preview])
        #expect(presentations.allSatisfy { !$0.requestsKeyboardFocus })
        #expect(manager.currentRequestStartedAt == nil)
        #expect(manager.currentTurnHUDState.status == .failed)
        #expect(!manager.buddyDictationManager.isDictationInProgress)
        manager.handleShortcutTransition(.cancelled)
        #expect(manager.currentTurnHUDState.status == .failed)
        withExtendedLifetime(observation) {}
    }

    @Test func captureFailureIsImmediatelyVisibleAndCannotBeReplacedByGenericSilence() throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.voiceStateCancellable?.cancel()
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.bindVoiceStateObservation()
        manager.voiceStateCancellable?.cancel()
        manager.currentTurnHUDState = .understanding("Starting microphone…")
        manager.voiceState = .processing
        var presentations: [PaceConversationPanelPresentationIntent] = []
        let observation = manager.conversationPanelPresentationRequests.sink { presentations.append($0) }
        manager.buddyDictationManager.reportCaptureFailure("Microphone access is unavailable. Open voice setup.")
        #expect(manager.currentTurnHUDState.detail == "Microphone access is unavailable. Open voice setup.")
        #expect(manager.voiceState == .idle && presentations == [.preview])
        manager.buddyDictationManager.onNoSpeechRecognized?()
        #expect(manager.currentTurnHUDState.detail == "Microphone access is unavailable. Open voice setup.")
        #expect(persister.events.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @Test func backgroundPreparationErrorCannotFailAnUnrelatedRequestAndClockResets() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.voiceStateCancellable?.cancel()
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        manager.bindVoiceStateObservation()
        manager.voiceStateCancellable?.cancel()
        manager.currentTurnHUDState = .understanding("Working")
        manager.voiceState = .processing
        #expect(manager.currentRequestStartedAt != nil)
        manager.buddyDictationManager.lastErrorMessage = "Background Japanese model preparation failed"
        #expect(manager.voiceState == .processing && manager.currentTurnHUDState.status == .understanding)
        manager.voiceState = .idle
        #expect(manager.currentRequestStartedAt == nil)
        manager.voiceState = .processing
        #expect(manager.currentRequestStartedAt != nil)
    }

    @Test func completedForegroundReplyReappearsPassivelyButCancelledAndRemoteRepliesDoNot() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        var presentations: [PaceConversationPanelPresentationIntent] = []
        let observation = manager.conversationPanelPresentationRequests.sink { presentations.append($0) }
        PacePowerManagerTests().begin("Feedback check", manager: manager)
        let identifier = try #require(manager.activeConversationUserEvent?.eventID)
        manager.recordConversationTurn(userTranscript: "Feedback check", assistantResponse: "Received.")
        #expect(presentations == [.preview])
        manager.interruptConversationRequest()
        manager.recordConversationTurn(
            userTranscript: "Feedback check", assistantResponse: "Late output", userEventIdentifier: identifier)
        #expect(presentations == [.preview])
        PacePowerManagerTests().begin("Remote check", manager: manager)
        manager.activePacePadTurnIdentifier = "remote-feedback-fixture"
        manager.recordConversationTurn(userTranscript: "Remote check", assistantResponse: "Remote response.")
        #expect(presentations == [.preview])
        withExtendedLifetime(observation) {}
    }
}
