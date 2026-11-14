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
    private final class SuspendedPlanner: BuddyPlannerClient {
        let displayName = "Suspended teaching fixture"
        let supportsImageInput = false
        var completion: CheckedContinuation<String, Error>?
        var userPrompt = ""
        var provisionalText = "A provisional explanation must stay silent."
        func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
            self.userPrompt = userPrompt
            onTextChunk(provisionalText)
            let response = try await withCheckedThrowingContinuation { completion = $0 }
            return (response, 0)
        }
        func fail() {
            let pending = completion
            completion = nil
            pending?.resume(throwing: URLError(.cannotLoadFromNetwork))
        }
        func resolve(_ response: String) {
            let pending = completion
            completion = nil
            pending?.resume(returning: response)
        }
    }
    private final class Speech: BuddyTTSClient {
        var supportsUtteranceCompletion = true
        var spokenTexts: [String] = []
        private(set) var stopCount = 0
        var exactTexts: [String] = []
        var completion: CheckedContinuation<Void, Error>?
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        func speakText(_ text: String) async throws { spokenTexts.append(text) }
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
    private func fixture(derivedMemory: Bool = false, directSpawnAvailable: Bool? = nil) throws -> (CompanionManager, PaceConversationRecorderTests.FixturePersister, Speech) {
        let (persister, session, recorder) = PaceConversationRecorderTests().makeFixture()
        let preferences = UserDefaults(suiteName: "PaceTeachingManagerTests." + UUID().uuidString)!
        let availabilityOverride: (() -> Bool)? = directSpawnAvailable.map { available in { available } }
        let manager = CompanionManager(watchModeDefaults: preferences, recordsDerivedConversationMemory: derivedMemory,
            persistsDebugTraces: false, diagramOverlayController: PaceDiagramOverlayController(showsWindows: false),
            threadMemoryStore: PaceThreadMemoryStore(fileURL: nil),
            teachingPreviewDirectSpawnAvailability: availabilityOverride)
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
    private func startTextTurn(_ manager: CompanionManager, muted: Bool, remoteID: String? = nil,
                               transcript: String = "Explain next-token training") {
        manager.isChatModeMutedForCurrentTurn = false
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(muted)
        manager.activePacePadTurnIdentifier = remoteID
        manager.beginConversationRequest(transcript)
        _ = manager.turnLeaseRegistry.beginTurn()
        manager.handleTextOnlyPlannerFastPath(transcript: transcript)
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
        #expect(speech.spokenTexts.count == previousCount)
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

    @Test func unsupportedManualVoicePlayIsDisabledWithoutChangingTheSelectedVoice() async throws {
        let (manager, _, speech) = try fixture()
        speech.supportsUtteranceCompletion = false
        startTextTurn(manager, muted: false)
        await manager.currentResponseTask?.value
        let initialCount = speech.spokenTexts.count
        let initialStopCount = speech.stopCount
        manager.diagramOverlayController.toggleLessonPlayback()
        manager.playTeachingLessonFromControls()
        await manager.currentResponseTask?.value
        #expect(manager.ttsClient === speech)
        #expect(speech.spokenTexts.count == initialCount)
        #expect(speech.stopCount == initialStopCount)
        #expect(!manager.diagramOverlayController.isLessonPlaybackActive)
        #expect(!manager.diagramOverlayController.lessonSupportsGuidedSpeech)
    }

    @Test func unsupportedVoiceKeepsVisualNavigationQuietAfterItsOrdinaryAnswer() async throws {
        let (manager, _, speech) = try fixture()
        speech.supportsUtteranceCompletion = false
        startTextTurn(manager, muted: false)
        await manager.currentResponseTask?.value
        let initialCount = speech.spokenTexts.count
        manager.diagramOverlayController.moveLesson(by: 1)
        manager.diagramOverlayController.moveLesson(by: 1)
        manager.diagramOverlayController.toggleLessonPlayback()
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.count == initialCount)
        #expect(speech.exactTexts.isEmpty)
        #expect(manager.diagramOverlayController.lessonStepIndex == 2)
        #expect(manager.diagramOverlayController.lessonPlaybackState == .paused)
    }

    private func prepareEarlyPreviewTurn(directSpawnAvailable: Bool = true, derivedMemory: Bool = false) throws -> (
        CompanionManager, PaceConversationRecorderTests.FixturePersister, Speech, SuspendedPlanner
    ) {
        let (manager, persister, speech) = try fixture(derivedMemory: derivedMemory,
            directSpawnAvailable: directSpawnAvailable)
        manager.activePlannerTier = .cliDirect
        manager.activePlannerTierCLIDirectUpstream = .codex
        let planner = SuspendedPlanner()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        return (manager, persister, speech, planner)
    }

    private func twoStepResponse(template: PaceFigureScene.Template) throws -> String {
        var document = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: template))
        document.lesson = .init(steps: Array(try #require(document.lesson).steps.prefix(2)))
        return try Planner(document: document).response
    }

    @Test func earlyPreviewIsUsefulBeforePlannerCompletesWithoutSpeechOrAssistantHistory() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
        try await waitUntil { planner.completion != nil }
        let preview = try #require(manager.diagramOverlayController.document)
        #expect(preview.figure?.template == .liftSystem)
        #expect(preview.nodes == PaceTeachingTemplateCatalog.liftSystem.nodes)
        #expect(preview.lesson == nil)
        #expect(manager.diagramOverlayController.selectedNodeID == "lift-fan")
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(persister.events.values.filter { $0.role == .pace }.isEmpty)
        #expect(!planner.userPrompt.contains("active_pace_diagram"))
        let responseTask = manager.currentResponseTask
        manager.cancelCurrentTurnFromPanel()
        planner.resolve(try twoStepResponse(template: .liftSystem))
        await responseTask?.value
    }

    @Test func matchingAuthoredLessonSpeaksAndRecordsEachStepExactlyOnce() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn(derivedMemory: true)
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
        let responseTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.extractedConversationUserEventIdentifiers.insert(user.eventID)
        planner.resolve(try twoStepResponse(template: .liftSystem))
        for expectedCount in 1...2 {
            try await waitUntil { speech.exactTexts.count == expectedCount && speech.completion != nil }
            let completion = speech.completion
            speech.completion = nil
            completion?.resume()
        }
        await responseTask?.value
        #expect(speech.exactTexts == Array(PaceTeachingTemplateCatalog.liftSystem.explanations.prefix(2).map { $0.detail }))
        #expect(speech.spokenTexts.isEmpty)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 2)
        #expect(persister.writes.filter { $0.eventID == user.eventID && $0.deliveryState == .completed }.count == 1)
        #expect(manager.conversationHistory.count == 1)
        #expect(manager.conversationHistory.first?.assistantResponse ==
            PaceTeachingTemplateCatalog.liftSystem.explanations.prefix(2).map { $0.label + "\n" + $0.detail }.joined(separator: "\n\n"))
    }

    @Test func mutedPreviewAndItsFinalLessonStayQuietAndKeepOneWrittenAnswer() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn(derivedMemory: true)
        startTextTurn(manager, muted: true, transcript: "Explain the Pi 5 camera connector")
        let responseTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        #expect(manager.diagramOverlayController.document?.lesson == nil)
        #expect(manager.diagramOverlayController.selectedNodeID == "board")
        #expect(persister.events.values.filter { $0.role == .pace }.isEmpty)
        let user = try #require(manager.activeConversationUserEvent)
        manager.extractedConversationUserEventIdentifiers.insert(user.eventID)
        planner.resolve(try twoStepResponse(template: .piCamera))
        await responseTask?.value
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 2)
        #expect(manager.conversationHistory.count == 1)
        #expect(manager.conversationHistory.first?.assistantResponse ==
            PaceTeachingTemplateCatalog.piCamera.explanations.prefix(2).map { $0.label + "\n" + $0.detail }.joined(separator: "\n\n"))
    }

    @Test func remoteTurnWaitsForAuthoredLessonAndNeverSpeaksOnMac() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn()
        let remote = RemoteOutput()
        manager.pacePadOutputDelegate = remote
        startTextTurn(manager, muted: true, remoteID: "remote-preview", transcript: "Explain the Pi 5 camera connector")
        let responseTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        #expect(manager.diagramOverlayController.document == nil)
        #expect(persister.events.values.filter { $0.role == .pace }.isEmpty)
        planner.resolve(try twoStepResponse(template: .piCamera))
        await responseTask?.value
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(remote.responses.count == 1)
        #expect(remote.responses.first?.text.isEmpty == false)
    }

    @Test func manualPreviewExplorationKeepsItsExactViewAndDeliversAuthoredAnswerOnce() async throws {
        for muted in [false, true] {
            for interaction in ["selection", "orbit", "controls", "replacement", "outerSpeech", "outerAcknowledgement"] {
                let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn(derivedMemory: true)
                startTextTurn(manager, muted: muted, transcript: "Explain how the F-35B hovers")
                let responseTask = manager.currentResponseTask
                try await waitUntil { planner.completion != nil }
                let user = try #require(manager.activeConversationUserEvent)
                manager.extractedConversationUserEventIdentifiers.insert(user.eventID)
                if interaction == "selection" { manager.diagramOverlayController.selectNode(id: "engine") }
                else if interaction == "controls" { manager.diagramOverlayController.setControlDeflection(0.6) }
                else if interaction == "replacement" {
                    var replacement = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .piCamera))
                    replacement.lesson = nil
                    manager.diagramOverlayController.present(replacement)
                } else { manager.diagramOverlayController.pauseLesson() }
                let preview = manager.diagramOverlayController.document
                let selectedNodeID = manager.diagramOverlayController.selectedNodeID
                let controlDeflection = manager.diagramOverlayController.controlDeflection
                let playbackGeneration = manager.diagramOverlayController.lessonPlaybackGeneration
                let revision = manager.diagramOverlayController.revision
                var response = try twoStepResponse(template: .liftSystem)
                var expectedAnswer = try #require(PaceActionTagParser.parseActions(from: response).actions.first.flatMap {
                    if case .showDiagram(let document) = $0 { return document.lesson?.writtenExplanation }
                    return nil
                })
                if interaction == "outerSpeech" || interaction == "outerAcknowledgement" {
                    var envelope = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
                    if interaction == "outerSpeech" {
                        expectedAnswer = "The lift fan and rear nozzle balance the aircraft in hover."
                        var payload = try #require(envelope["payload"] as? [String: Any])
                        var arguments = try #require(payload["args"] as? [String: Any])
                        arguments.removeValue(forKey: "lesson")
                        payload["args"] = arguments
                        envelope["payload"] = payload
                        envelope["spokenText"] = expectedAnswer
                    } else {
                        envelope["spokenText"] = "Let's look at it."
                    }
                    response = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
                }
                planner.resolve(response)
                await responseTask?.value
                #expect(manager.diagramOverlayController.document == preview)
                #expect(manager.diagramOverlayController.selectedNodeID == selectedNodeID)
                #expect(manager.diagramOverlayController.controlDeflection == controlDeflection)
                #expect(manager.diagramOverlayController.lessonPlaybackGeneration == playbackGeneration)
                #expect(manager.diagramOverlayController.revision == revision)
                #expect(manager.pendingTeachingPreviewOwnership == nil)
                #expect(speech.exactTexts.isEmpty)
                #expect(speech.spokenTexts == (muted ? [] : [expectedAnswer]))
                #expect(persister.events[user.eventID]?.deliveryState == .completed)
                #expect(persister.events.values.filter { $0.role == .pace }.map(\.text) == [expectedAnswer])
                #expect(manager.conversationHistory.map(\.assistantResponse) == [expectedAnswer])
            }
        }
    }

    @Test func closingPreviewCancelsLateAnswerWithoutSpeechOrHistory() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
        let responseTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        manager.diagramOverlayController.dismiss(intent: .userInitiated)
        planner.resolve(try twoStepResponse(template: .liftSystem))
        await responseTask?.value
        #expect(manager.diagramOverlayController.document == nil)
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        #expect(persister.events[user.eventID]?.deliveryState == .cancelled)
        #expect(persister.events.values.filter { $0.role == .pace }.isEmpty)
    }

    @Test func plannerFailureAndPanelCancelWithdrawOnlyUnmodifiedOwnedPreview() async throws {
        for ending in ["failure", "panel"] {
            for interaction in ["untouched", "selection", "newerFigure"] {
                let (manager, _, speech, planner) = try prepareEarlyPreviewTurn()
                startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
                let responseTask = manager.currentResponseTask
                try await waitUntil { planner.completion != nil }
                if interaction == "selection" { manager.diagramOverlayController.selectNode(id: "engine") }
                if interaction == "newerFigure" {
                    manager.diagramOverlayController.present(PaceTeachingArrayIllustration.nextTokenExample)
                }
                let currentDocument = manager.diagramOverlayController.document
                let selectedNodeID = manager.diagramOverlayController.selectedNodeID
                if ending == "panel" { manager.cancelCurrentTurnFromPanel() }
                planner.fail()
                await responseTask?.value
                #expect(manager.pendingTeachingPreviewOwnership == nil)
                #expect(manager.diagramOverlayController.document == (interaction == "untouched" ? nil : currentDocument))
                if interaction != "untouched" { #expect(manager.diagramOverlayController.selectedNodeID == selectedNodeID) }
                #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
            }
        }
    }

    @Test func oldThrowingPlannerCannotClearOrDismissANewerPendingPreview() async throws {
        let (manager, persister, speech, oldPlanner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
        let oldTask = manager.currentResponseTask
        try await waitUntil { oldPlanner.completion != nil }
        manager.cancelCurrentTurnFromPanel()
        let newPlanner = SuspendedPlanner()
        manager.plannerClient = newPlanner
        manager.textOnlyPlannerClient = newPlanner
        startTextTurn(manager, muted: false, transcript: "Explain the Pi5 camera connector")
        let newTask = manager.currentResponseTask
        try await waitUntil { newPlanner.completion != nil }
        let newLease = manager.turnLeaseRegistry.currentLease
        let newUser = try #require(manager.activeConversationUserEvent)
        let newPreview = manager.diagramOverlayController.document
        #expect(manager.foregroundOffDeviceTurnInFlight && manager.isOffDeviceTurnInFlight)
        oldPlanner.fail()
        await oldTask?.value
        #expect(manager.pendingTeachingPreviewOwnership?.turnLease == newLease)
        #expect(manager.foregroundOffDeviceTurnInFlight && manager.isOffDeviceTurnInFlight)
        #expect(manager.diagramOverlayController.document == newPreview)
        #expect(persister.events[newUser.eventID]?.deliveryState == .accepted)
        #expect(manager.turnLeaseRegistry.isCurrent(newLease))
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
        manager.cancelCurrentTurnFromPanel()
        #expect(!manager.foregroundOffDeviceTurnInFlight)
        newPlanner.resolve("Done.")
        await newTask?.value
    }

    @Test func latePreviewResponseCannotReplaceOrCancelANewerTurn() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
        let oldTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        let oldUser = try #require(manager.activeConversationUserEvent)
        manager.interruptConversationRequest()
        let replacement = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .piCamera))
        manager.diagramOverlayController.present(replacement)
        let presentedReplacement = try #require(manager.diagramOverlayController.document)
        manager.beginConversationRequest("New question")
        let newLease = manager.turnLeaseRegistry.beginTurn()
        let newUser = try #require(manager.activeConversationUserEvent)
        planner.resolve(try twoStepResponse(template: .liftSystem))
        await oldTask?.value
        #expect(manager.turnLeaseRegistry.isCurrent(newLease))
        #expect(manager.activeConversationUserEvent?.eventID == newUser.eventID)
        #expect(persister.events[newUser.eventID]?.deliveryState == .accepted)
        #expect(persister.events[oldUser.eventID]?.deliveryState == .cancelled)
        #expect(manager.diagramOverlayController.document == presentedReplacement)
        #expect(speech.exactTexts.isEmpty && speech.spokenTexts.isEmpty)
    }

    @Test func deniedConsentExistingVisualAndOtherPlannerDoNotCreateEarlyPreview() async throws {
        for blockedReason in ["consent", "visual", "planner"] {
            let (manager, _, _, planner) = try prepareEarlyPreviewTurn(directSpawnAvailable: blockedReason != "consent")
            if blockedReason == "visual" {
                manager.diagramOverlayController.present(PaceTeachingArrayIllustration.nextTokenExample)
            }
            if blockedReason == "planner" { manager.activePlannerTierCLIDirectUpstream = .claude }
            let original = manager.diagramOverlayController.document
            startTextTurn(manager, muted: true, transcript: "Explain how the F-35B hovers")
            let responseTask = manager.currentResponseTask
            try await waitUntil { planner.completion != nil }
            #expect(manager.diagramOverlayController.document == original)
            manager.cancelCurrentTurnFromPanel()
            planner.resolve("Done.")
            await responseTask?.value
        }
    }

    @Test func narrowPreviewMatcherRejectsContextAmbiguityAndShortFactualRequests() {
        for transcript in ["Explain how the F-35B hovers, text only", "Explain the Pi5 camera in one sentence",
            "Explain how this F-35B hovers", "Explain the F-35B on my screen", "Explain that Pi5 camera connector",
            "Explain F-35B hovering and the Pi5 camera", "What is the F-35B hover speed?", "Explain Pi camera",
            "Explain F-35 hovering", "Explain the Pi4 camera connector", "Explain the Pi5 board", "Explain the Pi5 camera from earlier", "Explain the F-35B hover in two steps and open Safari",
            "Explain the Pi5 camera briefly and take a screenshot", "Explain the F-35B hover in 13 steps"] {
            #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: transcript) == nil)
        }
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain how the F-35B hovers") == .liftSystem)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "How does the F35B hover?") == .liftSystem)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain the F-35B vertical lift system") == .liftSystem)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain the Raspberry Pi 5 camera connector") == .piCamera)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Show me how to connect a camera to a Pi5") == .piCamera)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain how the F-35B hovers in two steps") == .liftSystem)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain the Pi5 camera in 2 brief steps") == .piCamera)
        #expect(PaceTeachingPower.earlyNativePreviewTemplate(for: "Explain the Pi5 camera briefly") == .piCamera)
    }

    @Test func contextualTextOnlyAndSuggestionTurnsNeverReceiveEarlyPreview() async throws {
        for transcript in ["Explain how the F-35B hovers, text only", "Explain the Pi5 camera in one sentence",
                           "Explain this F-35B on screen", "Explain the F-35B hover and Pi5 camera"] {
            let (manager, _, _, planner) = try prepareEarlyPreviewTurn()
            startTextTurn(manager, muted: true, transcript: transcript)
            let responseTask = manager.currentResponseTask
            try await waitUntil { planner.completion != nil }
            #expect(manager.diagramOverlayController.document == nil)
            manager.cancelCurrentTurnFromPanel()
            planner.resolve("Done.")
            await responseTask?.value
        }
        let (manager, _, _, planner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: true, transcript: "Explain how the F-35B hovers")
        let responseTask = manager.currentResponseTask
        let now = Date()
        manager.activeConversationScreenSuggestionContext = .followUp(.init(identifier: UUID(),
            subject: "F-35B", evidence: "F-35B on a visible page", offer: "Explain the F-35B?",
            sceneIdentity: .init(displayIdentifier: 1, applicationProcessIdentifier: 1,
                                 applicationBundleIdentifier: "test.fixture"),
            observedAt: now, expiresAt: now.addingTimeInterval(60)))
        try await waitUntil { planner.completion != nil }
        #expect(manager.diagramOverlayController.document == nil)
        manager.cancelCurrentTurnFromPanel()
        planner.resolve("Done.")
        await responseTask?.value
    }

    @Test func untouchedPreviewAllowsTheAuthoredPlanIncludingItsDismissal() async throws {
        let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn()
        startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers in two steps")
        let responseTask = manager.currentResponseTask
        try await waitUntil { planner.completion != nil }
        let user = try #require(manager.activeConversationUserEvent)
        var authoredDocument = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .liftSystem))
        authoredDocument.lesson = nil
        var arguments = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(authoredDocument)) as? [String: Any])
        arguments["tool"] = "show_diagram"
        let data = try JSONSerialization.data(withJSONObject: [[arguments], [["tool": "dismiss_diagram"]]])
        let answer = "The nozzle turns engine thrust downward."
        let response = answer + " <tool_calls>" + String(decoding: data, as: UTF8.self) + "</tool_calls>"
        #expect(PaceActionTagParser.parseActions(from: response).executionPlan.flattenedActions.count == 2)
        planner.resolve(response)
        await responseTask?.value
        #expect(manager.diagramOverlayController.document == nil)
        #expect(manager.pendingTeachingPreviewOwnership == nil)
        #expect(persister.events[user.eventID]?.deliveryState == .completed)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        #expect(speech.exactTexts.isEmpty)
        #expect(speech.spokenTexts == [answer])
    }

    @Test func untouchedPreviewYieldsToUnmatchedAndCustomAuthoredVisuals() async throws {
        let customDocument = PaceDiagramDocument(title: "Custom body", summary: "A custom replacement.",
            nodes: [.init(id: "body", label: "Body", detail: "A custom solid.", x: 0, y: 0,
                          width: 220, height: 130, shape: nil, role: nil, subtitle: nil)], connections: [],
            figure: .init(parts: [.init(id: "body-solid", nodeID: "body", geometry: .box,
                                       position: [0, 0, 0], size: [1, 1, 1])]))
        #expect(customDocument.validationIssue == nil)
        for var authoredDocument in [try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .piCamera)),
                                    customDocument] {
            authoredDocument.lesson = nil
            let (manager, persister, speech, planner) = try prepareEarlyPreviewTurn(derivedMemory: true)
            startTextTurn(manager, muted: false, transcript: "Explain how the F-35B hovers")
            let responseTask = manager.currentResponseTask
            try await waitUntil { planner.completion != nil }
            let user = try #require(manager.activeConversationUserEvent)
            manager.extractedConversationUserEventIdentifiers.insert(user.eventID)
            let initialDismissalGeneration = manager.diagramOverlayController.dismissalGeneration
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(Planner(document: authoredDocument).response.utf8)) as? [String: Any])
            let answer = "Here is the authored explanation."
            envelope["spokenText"] = answer
            planner.resolve(String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self))
            await responseTask?.value
            #expect(manager.diagramOverlayController.document == authoredDocument)
            #expect(manager.diagramOverlayController.dismissalGeneration == initialDismissalGeneration + 1)
            #expect(manager.pendingTeachingPreviewOwnership == nil)
            #expect(persister.events[user.eventID]?.deliveryState == .completed)
            #expect(persister.events.values.filter { $0.role == .pace }.map(\.text) == [answer])
            #expect(speech.exactTexts.isEmpty)
            #expect(speech.spokenTexts == [answer])
            #expect(manager.conversationHistory.map(\.assistantResponse) == [answer])
        }
    }

}
