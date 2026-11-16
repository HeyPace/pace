import AVFoundation
import Combine
import Foundation
import Testing
@testable import Pace

@MainActor @Suite(.serialized)
struct PaceCaptureAcknowledgementTests {
    private final class RecordingPlanner: BuddyPlannerClient {
        let displayName = "Capture finalization fixture"
        let supportsImageInput = false
        var calls = 0
        func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
            calls += 1
            let reply = "This provisional command must not be submitted."
            onTextChunk(reply)
            return (reply, 0)
        }
    }

    private func buffer(frameCount: AVAudioFrameCount = 128) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) { samples[index] = 0 }
        }
        return buffer
    }

    @Test func processedPCMAcknowledgesOnlyOnceAfterTapRemovalAndKeepsRecognizedWords() async throws {
        let gate = PaceCaptureAcknowledgementGate()
        let identifier = UUID()
        gate.begin(identifier)
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<128 { samples[index] = 0 }
            }
            gate.receivedProcessedBuffer(buffer, captureIdentifier: identifier)
        }.value
        var callbacks: [String] = []
        var receipt: PaceCapturedAudio?
        let outcome = gate.stop(identifier, recognizedText: " こんにちは。 ", removeTap: {
            callbacks.append("tap removed")
        }, acknowledge: {
            callbacks.append("captured")
            receipt = $0
        })
        #expect(callbacks == ["tap removed", "captured"])
        #expect(receipt == PaceCapturedAudio(captureIdentifier: identifier, frameCount: 128, recognizedText: "こんにちは。"))
        #expect(outcome == receipt.map { .captured($0) })
        let duplicate = gate.stop(identifier, recognizedText: "", removeTap: {
            callbacks.append("duplicate tap removal")
        }, acknowledge: { _ in callbacks.append("duplicate receipt") })
        #expect(duplicate == .ignored && callbacks.count == 2)
    }

    @Test func rejectedEmptyAndCancelledCaptureNeverClaimReceipt() throws {
        let gate = PaceCaptureAcknowledgementGate()
        let identifier = UUID()
        var tapRemovals = 0
        var receipts = 0
        func stop() -> PaceCaptureStopOutcome {
            gate.stop(identifier, recognizedText: "", removeTap: { tapRemovals += 1 },
                acknowledge: { _ in receipts += 1 })
        }
        // Readiness/permission rejection never starts a capture identity or receives PCM.
        #expect(stop() == .ignored && tapRemovals == 0 && receipts == 0)
        gate.begin(identifier)
        gate.receivedProcessedBuffer(try buffer(frameCount: 0), captureIdentifier: identifier)
        #expect(stop() == .empty && tapRemovals == 1 && receipts == 0)
        gate.begin(identifier)
        gate.receivedProcessedBuffer(try buffer(), captureIdentifier: identifier)
        gate.cancel(identifier)
        #expect(stop() == .ignored && tapRemovals == 1 && receipts == 0)
    }

    @Test func oldFinalPartialBufferAndReleaseCannotMutateNextCapture() throws {
        let gate = PaceCaptureAcknowledgementGate()
        let oldIdentifier = UUID()
        let newIdentifier = UUID()
        var draft = ""
        var submitted: [String] = []
        gate.begin(oldIdentifier)
        gate.receivedProcessedBuffer(try buffer(), captureIdentifier: oldIdentifier)
        _ = gate.stop(oldIdentifier, recognizedText: "old words", removeTap: {}, acknowledge: { _ in })
        gate.begin(newIdentifier)
        gate.deliverRecognitionResult(for: newIdentifier) { draft = "new provisional words" }
        gate.deliverRecognitionResult(for: oldIdentifier) { draft = "stale partial"; submitted.append("stale final") }
        gate.receivedProcessedBuffer(try buffer(), captureIdentifier: oldIdentifier)
        var staleCallbacks = 0
        #expect(gate.stop(oldIdentifier, recognizedText: "old", removeTap: { staleCallbacks += 1 },
            acknowledge: { _ in staleCallbacks += 1 }) == .ignored)
        #expect(draft == "new provisional words" && submitted.isEmpty && staleCallbacks == 0)
        // Old PCM does not make a new, otherwise empty capture successful.
        #expect(gate.stop(newIdentifier, recognizedText: draft, removeTap: {}, acknowledge: { _ in staleCallbacks += 1 }) == .empty)
        #expect(staleCallbacks == 0)
        gate.cancel(newIdentifier)
        gate.deliverRecognitionResult(for: newIdentifier) { submitted.append("cancelled final") }
        #expect(submitted.isEmpty)
    }

    @Test func currentFinalCanArriveAfterReceiptWithoutCreatingAnotherAcknowledgement() throws {
        let gate = PaceCaptureAcknowledgementGate()
        let identifier = UUID()
        gate.begin(identifier)
        gate.receivedProcessedBuffer(try buffer(), captureIdentifier: identifier)
        var receipts = 0
        var finalWords = ""
        _ = gate.stop(identifier, recognizedText: "provisional", removeTap: {}, acknowledge: { _ in receipts += 1 })
        gate.deliverRecognitionResult(for: identifier) { finalWords = "final recognized words" }
        #expect(receipts == 1 && finalWords == "final recognized words")
    }

    @Test func authoritativeEmptyFinalReplacesProvisionalCommandBeforeFinalization() {
        let manager = PacePushToTalkManager()
        for finalResult in ["", " \n "] {
            manager.handlePartialTranscriptUpdate("Delete the selected file")
            #expect(manager.latestRecognizedText == "Delete the selected file")
            manager.handleFinalTranscriptUpdate(finalResult)
            #expect(manager.hasReceivedFinalTranscript)
            #expect(manager.latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(manager.latestRecognizedText == finalResult)
        }
        manager.handleFinalTranscriptUpdate("Keep the selected file")
        #expect(manager.latestRecognizedText == "Keep the selected file")
    }

    @Test func bothModesShowReceiptPreserveDraftAndHistoryAndRespectBothMutes() throws {
        let (root, manager, persister, speech) = try PacePowerManagerTests().fixture()
        defer { manager.voiceStateCancellable?.cancel(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        manager.bindVoiceStateObservation()
        manager.voiceStateCancellable?.cancel()
        var cueCount = 0
        manager.playCaptureAcknowledgementCue = { cueCount += 1 }
        manager.chatSession.draftMessageText = "Keep this typed draft"
        let originalMessages = manager.chatSession.messages
        let originalEventCount = persister.events.count
        for mode in [PaceConversationLanguageMode.standard, .japanesePractice] {
            manager.conversationLanguageMode = mode
            manager.voiceState = .listening
            manager.liveSpeechDraft = "Recognized provisional words"
            manager.buddyDictationManager.onAudioCaptured?(.init(captureIdentifier: UUID(), frameCount: 128,
                recognizedText: "Recognized provisional words"))
            #expect(manager.currentTurnHUDState.detail == "Audio captured")
            #expect(manager.liveSpeechDraft == "Recognized provisional words")
        }
        #expect(cueCount == 2)
        manager.chatSession.isChatTTSMuted = true
        manager.buddyDictationManager.onAudioCaptured?(.init(captureIdentifier: UUID(), frameCount: 128, recognizedText: ""))
        manager.chatSession.isChatTTSMuted = false
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(true)
        manager.buddyDictationManager.onAudioCaptured?(.init(captureIdentifier: UUID(), frameCount: 128, recognizedText: ""))
        #expect(cueCount == 2 && speech.spokenTexts.isEmpty)
        #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEventCount)
        #expect(manager.chatSession.draftMessageText == "Keep this typed draft")
        manager.buddyDictationManager.onNoSpeechRecognized?()
        #expect(manager.currentTurnHUDState.detail == "No speech recognized. Try again.")
        #expect(manager.voiceState == .idle && cueCount == 2)
        #expect(manager.liveSpeechDraft.isEmpty && manager.lastPartialTranscriptFromActiveDictation == nil)
    }

    @Test func releaseWithoutRecordingIsTruthfulAndDoesNotDisturbRespondingTurn() throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        var cueCount = 0
        manager.playCaptureAcknowledgementCue = { cueCount += 1 }
        manager.currentTurnHUDState = .listening
        manager.voiceState = .listening
        manager.handleShortcutTransition(.released)
        #expect(manager.currentTurnHUDState.detail == "No audio captured. Try again.")
        #expect(manager.voiceState == .idle && manager.transcriptSafetyTask == nil)
        let activeHUD = PaceTurnHUDState.acting("Current answer")
        manager.currentTurnHUDState = activeHUD
        manager.voiceState = .responding
        manager.handleShortcutTransition(.released)
        #expect(manager.currentTurnHUDState == activeHUD && manager.voiceState == .responding)
        #expect(cueCount == 0 && persister.events.isEmpty)
    }

    @Test func emptyAndSpeculativelyConsumedFinalsDisarmFallbackWhilePreservingActiveReply() async throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer { manager.voiceStateCancellable?.cancel(); manager.transcriptSafetyTask?.cancel(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let planner = RecordingPlanner()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.isOverlayVisible = true
        manager.intentClassifier = PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        manager.fastEverydayAnswersEnabled = false
        manager.useLocalVLMForScreenContext = false
        manager.captureScreensForPlanner = { throw NSError(domain: "UnexpectedCaptureFinalization", code: 1) }
        manager.playCaptureAcknowledgementCue = {}
        manager.bindVoiceStateObservation()
        manager.voiceStateCancellable?.cancel()
        let activeHUD = PaceTurnHUDState.acting("Current speculative answer")
        var submitted = 0
        for finalTranscript in ["", "Open Music."] {
            manager.voiceState = .responding
            manager.currentTurnHUDState = activeHUD
            manager.liveSpeechDraft = "Keep the current reply display"
            manager.handleAudioCaptured(.init(captureIdentifier: UUID(), frameCount: 128, recognizedText: "open Music"))
            manager.lastPartialTranscriptFromActiveDictation = "open Music"
            manager.scheduleTranscriptSafetyFallback()
            let safetyTask = try #require(manager.transcriptSafetyTask)
            manager.buddyDictationManager.deliverFinalDictationTranscript(
                finalDraftText: finalTranscript, finalTranscriptText: finalTranscript, shouldSubmitFinalDraft: true,
                speculativeTranscriptExecutedThisSession: "open Music", submitDraftText: { _ in submitted += 1 })
            #expect(manager.transcriptArrivedSinceRelease && manager.transcriptSafetyTask == nil)
            #expect(manager.lastPartialTranscriptFromActiveDictation == nil && safetyTask.isCancelled)
            await safetyTask.value
            #expect(manager.voiceState == .responding && manager.currentTurnHUDState == activeHUD)
            #expect(manager.liveSpeechDraft == "Keep the current reply display")
        }
        // The no-speech callback must also disarm terminal bookkeeping independently of the UI guard.
        manager.transcriptArrivedSinceRelease = false
        manager.lastPartialTranscriptFromActiveDictation = "old provisional command"
        manager.scheduleTranscriptSafetyFallback()
        let safetyTask = try #require(manager.transcriptSafetyTask)
        manager.buddyDictationManager.onNoSpeechRecognized?()
        await safetyTask.value
        #expect(manager.transcriptArrivedSinceRelease && manager.transcriptSafetyTask == nil)
        #expect(manager.lastPartialTranscriptFromActiveDictation == nil && safetyTask.isCancelled)
        #expect(manager.voiceState == .responding && manager.currentTurnHUDState == activeHUD)
        #expect(submitted == 0 && planner.calls == 0 && persister.events.isEmpty)
    }

    @Test func ordinaryUnreadyModelRetainsItsRejectionCauseAfterReleaseWithoutCaptureCue() throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        manager.isTranscriptionModelReady = false
        manager.buddyDictationManager.usesJapanesePracticeTranscription = false
        manager.fastEverydayAnswersEnabled = false
        manager.useLocalVLMForScreenContext = false
        manager.activePlannerTier = .local
        var cueCount = 0
        manager.playCaptureAcknowledgementCue = { cueCount += 1 }
        manager.handleShortcutTransition(.pressed)
        let rejectedHUD = manager.currentTurnHUDState
        #expect(rejectedHUD.status != .listening && rejectedHUD.detail == "speech model still loading…")
        manager.handleShortcutTransition(.released)
        #expect(manager.currentTurnHUDState == rejectedHUD && manager.voiceState == .idle)
        #expect(cueCount == 0 && manager.transcriptSafetyTask == nil)
        #expect(manager.pendingKeyboardShortcutStartTask == nil && !manager.buddyDictationManager.isDictationInProgress)
    }

    @Test func explicitStopAndCloseCancelCaptureFinalizationWithoutRevivingUncommittedWords() async throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer { manager.transcriptSafetyTask?.cancel(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let planner = RecordingPlanner()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.isOverlayVisible = true
        manager.fastEverydayAnswersEnabled = false
        manager.useLocalVLMForScreenContext = false
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        manager.conversationRecorder.record(ConversationEvent(role: .pace, origin: .assistant, text: "Already completed reply."))
        let originalMessages = manager.chatSession.messages
        let originalEventCount = persister.events.count
        manager.chatSession.draftMessageText = "Keep this typed draft"
        for closesSurface in [false, true] {
            manager.voiceState = .processing
            manager.liveSpeechDraft = "uncommitted voice words"
            manager.lastPartialTranscriptFromActiveDictation = "open Music"
            manager.transcriptArrivedSinceRelease = false
            manager.scheduleTranscriptSafetyFallback()
            let safetyTask = try #require(manager.transcriptSafetyTask)
            let pendingStartTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            manager.pendingKeyboardShortcutStartTask = pendingStartTask
            if closesSurface { manager.handleExplanationDismissal(.userInitiated) }
            else { manager.cancelCurrentTurnFromPanel() }
            await safetyTask.value
            await pendingStartTask.value
            #expect(safetyTask.isCancelled && pendingStartTask.isCancelled)
            #expect(manager.transcriptSafetyTask == nil && manager.pendingKeyboardShortcutStartTask == nil)
            #expect(manager.transcriptArrivedSinceRelease && manager.lastPartialTranscriptFromActiveDictation == nil)
            #expect(manager.liveSpeechDraft.isEmpty && manager.voiceState == .idle)
            #expect(manager.chatSession.messages == originalMessages && persister.events.count == originalEventCount)
            #expect(manager.chatSession.draftMessageText == "Keep this typed draft" && planner.calls == 0)
        }
    }

    @Test func cancellingOldFinalizationTimerCannotOverwriteNextCaptureFeedback() async throws {
        let (root, manager, persister, _) = try PacePowerManagerTests().fixture()
        defer { manager.transcriptSafetyTask?.cancel(); manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        manager.transcriptArrivedSinceRelease = false
        manager.scheduleTranscriptSafetyFallback()
        let oldSafetyTask = try #require(manager.transcriptSafetyTask)
        manager.resetCaptureTranscriptFeedback()
        manager.voiceState = .listening
        manager.currentTurnHUDState = .listening
        manager.liveSpeechDraft = "new provisional words"
        await oldSafetyTask.value
        #expect(oldSafetyTask.isCancelled && manager.transcriptSafetyTask == nil)
        #expect(manager.currentTurnHUDState == .listening && manager.voiceState == .listening)
        #expect(manager.liveSpeechDraft == "new provisional words" && persister.events.isEmpty)
    }
}
