import Foundation
import Testing

@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceTeachingManagerTests {
    private final class Planner: BuddyPlannerClient {
        let displayName = "Teaching fixture"
        let supportsImageInput = false
        let response: String
        init(document: PaceDiagramDocument) throws {
            let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
            response = String(decoding: try JSONSerialization.data(withJSONObject: [
                "spokenText": "", "intent": "action",
                "payload": ["name": "show_diagram", "args": arguments]
            ]), as: UTF8.self)
        }
        func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
            (response, 0)
        }
    }
    private final class Speech: BuddyTTSClient {
        var supportsUtteranceCompletion = true
        var spokenTexts: [String] = []
        var holdsStandardSpeech = false
        private(set) var stopCount = 0
        var exactTexts: [String] = []
        var completion: CheckedContinuation<Void, Error>?
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        func speakText(_ text: String) async throws { spokenTexts.append(text); isPlaying = holdsStandardSpeech }
        func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws {
            exactTexts.append(text)
            isPlaying = true
            onStarted()
            try await withCheckedThrowingContinuation { completion = $0 }
            isPlaying = false
        }
        func stopPlayback() {
            stopCount += 1
            let previous = completion
            completion = nil
            isPlaying = false
            previous?.resume(throwing: CancellationError())
        }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }
    private final class RemoteOutput: PacePadOutputDelegate {
        var responses: [(id: String, text: String)] = []
        func deliverAssistantResponse(turnIdentifier: String, spokenText: String, usesOffDevicePlanner: Bool) -> Bool {
            responses.append((turnIdentifier, spokenText)); return true
        }
        func deliverProactiveMessage(_ utterance: PaceProactiveUtterance) -> Bool { false }
    }
    private func fixture(derivedMemory: Bool = false) throws -> (CompanionManager, PaceConversationRecorderTests.FixturePersister, Speech) {
        let (persister, session, recorder) = PaceConversationRecorderTests().makeFixture()
        let preferences = UserDefaults(suiteName: "PaceTeachingManagerTests." + UUID().uuidString)!
        let manager = CompanionManager(watchModeDefaults: preferences, recordsDerivedConversationMemory: derivedMemory,
            persistsDebugTraces: false, diagramOverlayController: PaceDiagramOverlayController(showsWindows: false),
            threadMemoryStore: PaceThreadMemoryStore(fileURL: nil))
        manager.threadMemory = PaceThreadMemory(configuration: .default)
        manager.chatSession = session
        manager.conversationRecorder = recorder
        let speech = Speech()
        manager.ttsClient = speech
        manager.localRetriever = PaceLocalRetriever(store: PaceInMemoryRetrievalStore(), appliesPersistedSourcePreferences: false)
        manager.responseOverlayManager.setAnnotationsEnabled(false)
        manager.isWalkingAvatarEnabled = false
        manager.bindVisualExplanationCallbacks()
        let planner = try Planner(document: PaceTeachingArrayIllustration.nextTokenExample)
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        return (manager, persister, speech)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<3_000 { if predicate() { return }; await Task.yield() }
        #expect(predicate()); throw CancellationError()
    }
    private func startTextTurn(_ manager: CompanionManager, muted: Bool, remoteID: String? = nil) {
        manager.isChatModeMutedForCurrentTurn = false
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(muted)
        manager.activePacePadTurnIdentifier = remoteID
        manager.beginConversationRequest("Explain next-token training")
        _ = manager.turnLeaseRegistry.beginTurn()
        manager.handleTextOnlyPlannerFastPath(transcript: "Explain next-token training")
    }

    @Test func mutedQueuedChatUsesAuthoritativePipelineMuteAndKeepsWrittenAnswer() async throws {
        let (manager, persister, speech) = try fixture()
        startTextTurn(manager, muted: true)
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(manager.streamingSentenceTTSPipeline.isMutedForCurrentTurn)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
        let user = try #require(manager.activeConversationUserEvent)
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
        let writtenSteps = persister.events.values.filter { $0.role == .pace }
        #expect(writtenSteps.count == PaceTeachingArrayIllustration.nextTokenExample.lesson?.steps.count)
        for step in try #require(PaceTeachingArrayIllustration.nextTokenExample.lesson).steps {
            #expect(writtenSteps.contains { $0.text == step.narration })
        }
    }

    @Test func iPadLessonNeverSpeaksOnMacAndDeliversCompleteNonemptyTextOnce() async throws {
        let (manager, persister, speech) = try fixture()
        let remote = RemoteOutput()
        manager.pacePadOutputDelegate = remote
        startTextTurn(manager, muted: true, remoteID: "ipad-teaching")
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(remote.responses.count == 1)
        #expect(remote.responses.first?.id == "ipad-teaching")
        #expect(remote.responses.first?.text.contains("Shift the target by one") == true)
        #expect(remote.responses.first?.text.contains("Adjust the shared model") == true)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 6)
        #expect(manager.activePacePadTurnIdentifier == nil)
        manager.chatSession.isChatTTSMuted = false
        manager.playTeachingLessonFromControls()
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
    }

    @Test func activeNavigationRetainsHostingLeaseAndFinalizesOriginExactlyOnce() async throws {
        let (manager, persister, speech) = try fixture()
        startTextTurn(manager, muted: false)
        let hostTask = manager.currentResponseTask
        let hostLease = manager.turnLeaseRegistry.currentLease
        try await waitUntil { speech.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.diagramOverlayController.moveLesson(by: 1)
        try await waitUntil { speech.exactTexts.count == 2 }
        #expect(manager.turnLeaseRegistry.isCurrent(hostLease))
        #expect(persister.events[user.eventID]?.deliveryState == .accepted)
        manager.diagramOverlayController.pauseLesson()
        await hostTask?.value
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
        #expect(persister.writes.filter { $0.eventID == user.eventID && $0.deliveryState == .completed }.count == 1)
        #expect(speech.spokenTexts.isEmpty)
    }

    @Test func immediatePlayWaitsForPausedHostFinalizationAndUsesLiveChatMute() async throws {
        let (manager, persister, speech) = try fixture()
        startTextTurn(manager, muted: false)
        try await waitUntil { speech.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.diagramOverlayController.pauseLesson()
        manager.chatSession.isChatTTSMuted = true
        manager.diagramOverlayController.toggleLessonPlayback()
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.count == 1)
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
        #expect(persister.writes.filter { $0.eventID == user.eventID && $0.deliveryState == .completed }.count == 1)
    }

    @Test func nonPreciseVoiceKeepsNormalSpeechAndManualSteps() async throws {
        let (manager, _, speech) = try fixture()
        speech.supportsUtteranceCompletion = false
        startTextTurn(manager, muted: false)
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.isEmpty)
        #expect(!speech.spokenTexts.joined().isEmpty)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
        #expect(!manager.diagramOverlayController.lessonSupportsGuidedSpeech)
        let previousCount = speech.spokenTexts.count
        manager.playTeachingLessonFromControls()
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.count == previousCount + 1)
        #expect(manager.diagramOverlayController.lessonStepIndex == 0)
    }

    @Test func writtenLessonStepsDoNotEvictThreadPairsOrReserveSummaries() throws {
        let (manager, persister, _) = try fixture(derivedMemory: true)
        let now = Date()
        for index in 0..<4 {
            _ = manager.threadMemory.record(userTurn: "Question \(index)", assistantTurn: "Answer \(index)",
                turnId: "existing-\(index)", now: now)
        }
        let before = manager.threadMemory.snapshot(now: now)
        for step in try #require(PaceTeachingArrayIllustration.nextTokenExample.lesson).steps {
            manager.diagramOverlayController.onWrittenLessonStep?(step)
        }
        let after = manager.threadMemory.snapshot(now: now)
        #expect(after.verbatimWindow == before.verbatimWindow)
        #expect(after.nextSummaryVersionToAssign == before.nextSummaryVersionToAssign)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 6)
    }
    @Test func aCompleteLessonAddsOneDerivedPairWithoutEvictingThreeRecentExchanges() async throws {
        let (manager, _, speech) = try fixture(derivedMemory: true)
        speech.supportsUtteranceCompletion = false
        let now = Date()
        for index in 0..<3 {
            _ = manager.threadMemory.record(userTurn: "Recent question \(index)", assistantTurn: "Recent answer \(index)",
                turnId: "recent-\(index)", now: now)
        }
        startTextTurn(manager, muted: true)
        let user = try #require(manager.activeConversationUserEvent)
        manager.extractedConversationUserEventIdentifiers.insert(user.eventID)
        await manager.currentResponseTask?.value
        let snapshot = manager.threadMemory.snapshot(now: now)
        #expect(snapshot.verbatimWindow.count == 4)
        #expect(snapshot.verbatimWindow.prefix(3).map(\.turnId) == ["recent-0", "recent-1", "recent-2"])
        #expect(snapshot.verbatimWindow.last?.assistantText.contains("Adjust the shared model") == true)
        #expect(snapshot.nextSummaryVersionToAssign == 1)
    }

    @Test func cancellingPendingReplayDoesNotCreateASecondPlaybackOwner() async throws {
        let (manager, persister, speech) = try fixture()
        startTextTurn(manager, muted: false)
        try await waitUntil { speech.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.diagramOverlayController.pauseLesson()
        manager.diagramOverlayController.toggleLessonPlayback()
        #expect(manager.diagramOverlayController.lessonPlaybackState == .starting)
        manager.diagramOverlayController.toggleLessonPlayback()
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.count == 1)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
    }

    @Test func unmutedPreciseReplayActuallyRestartsAfterHostFinalizesExactlyOnce() async throws {
        let (manager, persister, speech) = try fixture()
        startTextTurn(manager, muted: false)
        try await waitUntil { speech.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.diagramOverlayController.pauseLesson()
        manager.diagramOverlayController.toggleLessonPlayback()
        try await waitUntil { speech.exactTexts.count == 2 && speech.completion != nil }
        #expect(speech.exactTexts[0] == speech.exactTexts[1])
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
        #expect(persister.writes.filter { $0.eventID == user.eventID && $0.deliveryState == .completed }.count == 1)
        manager.diagramOverlayController.pauseLesson()
        await manager.currentResponseTask?.value
        #expect(speech.exactTexts.count == 2)
        #expect(persister.writes.filter { $0.eventID == user.eventID && $0.deliveryState == .completed }.count == 1)
    }

    @Test func nonPreciseManualReadIsStoppedByNextWithoutAutomaticProgress() async throws {
        let (manager, _, speech) = try fixture()
        speech.supportsUtteranceCompletion = false
        startTextTurn(manager, muted: false)
        await manager.currentResponseTask?.value
        let initialCount = speech.spokenTexts.count
        speech.holdsStandardSpeech = true
        manager.diagramOverlayController.toggleLessonPlayback()
        try await waitUntil { speech.spokenTexts.count == initialCount + 1 && speech.isPlaying }
        #expect(manager.diagramOverlayController.isLessonPlaybackActive)
        let stopsBeforeNext = speech.stopCount
        manager.diagramOverlayController.moveLesson(by: 1)
        await manager.currentResponseTask?.value
        #expect(speech.stopCount == stopsBeforeNext + 1)
        #expect(!speech.isPlaying)
        #expect(speech.spokenTexts.count == initialCount + 1)
        #expect(manager.diagramOverlayController.lessonStepIndex == 1)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
    }

    @Test func repeatedPlayPausesNonPreciseReadInsteadOfQueuingAnotherRead() async throws {
        let (manager, _, speech) = try fixture()
        speech.supportsUtteranceCompletion = false
        startTextTurn(manager, muted: false)
        await manager.currentResponseTask?.value
        let initialCount = speech.spokenTexts.count
        speech.holdsStandardSpeech = true
        manager.diagramOverlayController.toggleLessonPlayback()
        try await waitUntil { speech.spokenTexts.count == initialCount + 1 && speech.isPlaying }
        let stopsBeforePause = speech.stopCount
        manager.diagramOverlayController.toggleLessonPlayback()
        await manager.currentResponseTask?.value
        #expect(speech.stopCount == stopsBeforePause + 1)
        #expect(!speech.isPlaying)
        #expect(speech.spokenTexts.count == initialCount + 1)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
    }

}
