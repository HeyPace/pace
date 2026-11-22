import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PacePowerManagerTests {
    final class LocalSpeech: BuddyTTSClient {
        var spokenTexts: [String] = []
        var requests: [PaceSpeechRequest] = []
        var stopCount = 0
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var supportsUtteranceCompletion: Bool { true }
        func supportsSpeechProfile(_ profile: PaceSpeechProfile) -> Bool { true }
        var failingUtteranceIndex: Int?
        private var utteranceCount = 0
        struct PlaybackFailure: Error {}
        func speakText(_ text: String) async throws { try Task.checkCancellation(); spokenTexts.append(text) }
        func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws {
            try await speakUtterance(.init(text: text), onStarted: onStarted)
        }
        func speakUtterance(_ request: PaceSpeechRequest, onStarted: @escaping @MainActor () -> Void) async throws {
            try Task.checkCancellation()
            utteranceCount += 1
            if utteranceCount == failingUtteranceIndex { throw PlaybackFailure() }
            requests.append(request)
            spokenTexts.append(request.text)
            onStarted()
        }
        func stopPlayback() { stopCount += 1; isPlaying = false }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }
    final class Author: BuddyPlannerClient {
        let displayName = "Power author fixture"
        let supportsImageInput = false
        var calls = 0
        var suspends = false
        var continuation: CheckedContinuation<Void, Never>?
        var capturedUserPrompts: [String] = []
        var response = #"{"name":"Thank You","description":"Present a dancing original character and speak thank you","category":"custom","invocationPhrases":["thank me"],"steps":[{"toolCalls":[{"tool":"present_media","arguments":{"assetID":"thank-you-dance","durationSeconds":4}}]},{"toolCalls":[{"tool":"speak","arguments":{"text":"thank you"}}]}]}"#
        func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
            calls += 1
            capturedUserPrompts.append(userPrompt)
            if suspends { await withCheckedContinuation { continuation = $0 } }
            return (response, 0)
        }
    }

    private final class NoEmbeddingClient: PaceTextEmbedding, @unchecked Sendable {
        struct Unavailable: Error {}
        func embed(_ texts: [String]) async throws -> [[Float]] { throw Unavailable() }
    }

    func fixture(recordsDerivedMemory: Bool = false) throws -> (URL, CompanionManager, PaceConversationRecorderTests.FixturePersister, LocalSpeech) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pace-power-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (persister, session, recorder) = PaceConversationRecorderTests().makeFixture()
        let defaults = UserDefaults(suiteName: "PacePowerMemoryTests." + UUID().uuidString)!
        let spotlight = PaceSpotlightMemoryIndexer(indexOperation: { _, completion in completion(nil) },
            deleteDomainOperation: { _, completion in completion(nil) }, hasCompletedLegacyCleanup: { true }, markLegacyCleanupComplete: {})
        let manager = CompanionManager(watchModeDefaults: defaults, recordsDerivedConversationMemory: recordsDerivedMemory, persistsDebugTraces: false,
            threadMemoryStore: PaceThreadMemoryStore(fileURL: root.appendingPathComponent("thread.json")),
            memoryStore: PaceMemoryStore(fileURL: root.appendingPathComponent("memory.json")), spotlightMemoryIndexer: spotlight)
        manager.chatSession = session
        manager.conversationRecorder = recorder
        manager.bindVisualExplanationCallbacks()
        manager.threadMemory = PaceThreadMemory(configuration: .init(verbatimWindowSize: 8, sessionIdleThreshold: 1200, summaryMaxTokenEstimate: 400))
        manager.lastIntentRouteForEpisodicExtraction = .screenAction
        manager.lazyEmbeddingScheduler = PaceLazyEmbeddingScheduler(memoryIndex: manager.memoryIndex,
            embeddingClientFactory: { NoEmbeddingClient() }, onEmbeddingsPersisted: {})
        let store = PaceManagedPowerStore(automationDirectoryURL: root.appendingPathComponent("automations"),
            programDirectoryURL: root.appendingPathComponent("programs"), skillDirectoryURL: root.appendingPathComponent("skills"),
            stateDirectoryURL: root.appendingPathComponent("management"), recordsAudit: false)
        manager.managedPowerStore = store
        manager.powerCatalogDiscoveryOverride = {
            let definitions = PaceUserAutomationStore(directoryURL: store.automationDirectoryURL).listValidDefinitions()
            let programs = PaceUserProgramStore(directoryURL: store.programDirectoryURL).listValidPrograms()
            let skills = PaceSkillLoader.listUserSkills(in: store.skillDirectoryURL)
            return PaceDiscoveredAutomationCatalog(catalog: PaceAutomationCatalog(typedDefinitions: definitions,
                recordedFlows: [], skills: skills, shortcutNames: [], programs: programs), typedDefinitions: definitions,
                programs: programs, recordedFlows: [], skills: skills)
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!)
        manager.mediaOverlayController = PaceMediaOverlayController(showsWindows: false, resolveImage: { _ in image })
        let speech = LocalSpeech()
        manager.ttsClient = speech
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        manager.bindPowerToolCallbacks()
        return (root, manager, persister, speech)
    }

    func begin(_ transcript: String, manager: CompanionManager) {
        manager.cancelActiveTurnTasks()
        manager.ttsClient.stopPlayback()
        manager.streamingSentenceTTSPipeline.resetForNewTurn()
        manager.beginConversationRequest(transcript)
        _ = manager.turnLeaseRegistry.beginTurn()
    }

    @Test func createdPowerRunsThroughExistingPipelineAndLogsSpeechExactlyOnce() async throws {
        let (root, manager, persister, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = Author()
        manager.reusableWorkAuthoringPlannerOverride = author
        begin("create power Thank You", manager: manager)
        await manager.handlePowerCommand(.create("called Thank You that presents thank-you-dance for four seconds and says thank you"), transcript: "create power Thank You")
        await manager.currentResponseTask?.value
        #expect(author.calls == 1)
        let discovered = await manager.discoverAutomationCatalog()
        #expect(discovered.typedDefinitions.count == 1)
        begin("run power Thank You", manager: manager)
        let runUserEventIdentifier = try #require(manager.activeConversationUserEvent?.eventID)
        await manager.handlePowerCommand(.run("Thank You"), transcript: "run power Thank You")
        await manager.currentResponseTask?.value
        #expect(manager.mediaOverlayController.isVisible)
        #expect(speech.spokenTexts.filter { $0 == "thank you" }.count == 1)
        #expect(persister.events.values.filter { $0.role == .pace && $0.text == "thank you" }.count == 1)
        #expect(!speech.spokenTexts.contains { $0.contains("Spoke the requested") || $0.contains("Presented local media") })
        #expect(author.calls == 1)
        #expect(persister.events[runUserEventIdentifier]?.deliveryState == .completed)
        begin("a later unrelated question", manager: manager)
        #expect(persister.events[runUserEventIdentifier]?.deliveryState == .completed)
        #expect(persister.events.values.filter { $0.role == .pace && $0.text == "thank you" }.count == 1)
    }

    @Test func authoredJapanesePowerPreservesProfileAndRecordsOneLineWithoutGenericCompletionSpeech() async throws {
        let (root, manager, persister, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let japaneseText = "こんにちは。会えてうれしいです。ありがとうございます。"
        let author = Author()
        author.response = author.response.replacingOccurrences(of: #""text":"thank you""#,
            with: #""text":"こんにちは。会えてうれしいです。ありがとうございます。","profile":"japanese_female""#)
        manager.reusableWorkAuthoringPlannerOverride = author
        begin("create power Thank You", manager: manager)
        await manager.handlePowerCommand(.create("called Thank You that greets in Japanese"), transcript: "create power Thank You")
        await manager.currentResponseTask?.value
        let discovered = await manager.discoverAutomationCatalog()
        let saved = try #require(discovered.typedDefinitions.first)
        #expect(saved.steps[1].toolCalls[0].arguments["profile"] == .string("japanese_female"))
        begin("run power Thank You", manager: manager)
        let speechCountBeforeRun = speech.spokenTexts.count
        await manager.handlePowerCommand(.run("Thank You"), transcript: "run power Thank You")
        await manager.currentResponseTask?.value
        #expect(Array(speech.spokenTexts.dropFirst(speechCountBeforeRun)) == [japaneseText])
        #expect(speech.requests.filter { $0.profile == .japaneseFemale } == [.init(text: japaneseText, profile: .japaneseFemale)])
        #expect(persister.events.values.filter { $0.role == .pace && $0.text == japaneseText }.count == 1)
    }

    @Test func bothMutePathsPreventJapaneseSynthesisAndHistory() async throws {
        let (root, manager, persister, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let request = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale)
        for muteChat in [false, true] {
            begin("greet in Japanese", manager: manager)
            manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(!muteChat)
            manager.chatSession.isChatTTSMuted = muteChat
            let observation = await manager.actionExecutor.speakLocalText?(request)
            #expect(observation?.terminalReason == .managedWorkflowUnavailable)
        }
        #expect(speech.requests.isEmpty)
        #expect(speech.spokenTexts.isEmpty)
        #expect(!persister.events.values.contains { $0.role == .pace && $0.text == request.text })
    }

    @Test func staleAuthoringReplyCannotSaveAfterItsTurnIsCancelled() async throws {
        let (root, manager, _, _) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = Author()
        author.suspends = true
        manager.reusableWorkAuthoringPlannerOverride = author
        begin("create power Thank You", manager: manager)
        await manager.handlePowerCommand(.create("called Thank You"), transcript: "create power Thank You")
        let authoringTask = manager.currentResponseTask
        for _ in 0..<1000 { if author.continuation != nil { break }; await Task.yield() }
        #expect(author.continuation != nil)
        manager.cancelActiveTurnTasks()
        author.continuation?.resume()
        author.continuation = nil
        await authoringTask?.value
        #expect(PaceUserAutomationStore(directoryURL: manager.managedPowerStore.automationDirectoryURL).listValidDefinitions().isEmpty)
    }

    @Test func disabledPowerCannotRunThroughCatalogNaturalAliasOrExplicitSkillRoute() async throws {
        let (root, manager, _, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = Author()
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: author.response))
        let empty = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: empty.catalog)
        begin("disable power Thank You", manager: manager)
        await manager.handlePowerCommand(.setEnabled("Thank You", false), transcript: "disable power Thank You")
        await manager.currentResponseTask?.value
        begin("run power Thank You", manager: manager)
        await manager.handlePowerCommand(.run("Thank You"), transcript: "run power Thank You")
        await manager.currentResponseTask?.value
        #expect(!speech.spokenTexts.contains("thank you"))
        let catalog = await manager.discoverAutomationCatalog()
        let entry = try #require(catalog.catalog.entries.first)
        begin("thank me", manager: manager)
        #expect(!manager.authorizeManagedPower(entry, transcript: "thank me"))
        let skill = try #require(PaceSkillLoader.skillFromForm(name: "Flexible Thanks", stepsText: "Say welcome", trigger: "flexible thanks", notes: nil))
        _ = try manager.managedPowerStore.commit(.skill(skill), catalog: catalog.catalog)
        let withSkill = await manager.discoverAutomationCatalog()
        let power = try manager.managedPowerStore.resolve("skill:flexible-thanks", catalog: withSkill.catalog)
        try manager.managedPowerStore.setEnabled(false, power: power)
        begin("run skill Flexible Thanks", manager: manager)
        manager.handleSkillCommand(.run(slug: skill.slug, name: skill.name), transcript: "run skill Flexible Thanks")
        await manager.currentResponseTask?.value
        #expect(manager.activeSkillRun == nil)
        #expect(!speech.spokenTexts.contains("welcome"))
    }

    @Test func revokedSnapshotFencesLateOutputAndOldMediaCloseCannotCancelAnotherTurn() async throws {
        let (root, manager, _, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: Author().response))
        let empty = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: empty.catalog)
        let discovered = await manager.discoverAutomationCatalog()
        let power = try manager.managedPowerStore.resolve("Thank You", catalog: discovered.catalog)
        begin("run power Thank You", manager: manager)
        manager.activeManagedPower = power
        let oldLease = manager.turnLeaseRegistry.currentLease
        #expect(manager.isActiveTurn(oldLease))
        try manager.managedPowerStore.setEnabled(false, power: power)
        #expect(!manager.isActiveTurn(oldLease))
        manager.activeManagedPower = nil
        _ = await manager.actionExecutor.presentLocalMedia?(.init(assetID: "thank-you-dance", durationSeconds: 4, motion: nil))
        let oldGeneration = manager.mediaOverlayController.presentationGeneration
        let retainedOldClose = manager.mediaOverlayController.onUserDismiss
        begin("new unrelated answer", manager: manager)
        let newLease = manager.turnLeaseRegistry.currentLease
        let stopsBefore = speech.stopCount
        retainedOldClose?(oldGeneration)
        #expect(manager.isActiveTurn(newLease))
        #expect(speech.stopCount == stopsBefore)
    }
    @Test func partialUpdateAuthorsAgainstExistingDefinitionAndPreservesUnmentionedMedia() async throws {
        let (root, manager, _, _) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = Author()
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: author.response))
        let empty = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: empty.catalog)
        manager.reusableWorkAuthoringPlannerOverride = author
        author.response = author.response.replacingOccurrences(of: "thank you", with: "welcome")
        begin("update power Thank You: change the spoken line to welcome", manager: manager)
        await manager.handlePowerCommand(.update("Thank You", "change the spoken line to welcome"), transcript: "update power Thank You: change the spoken line to welcome")
        await manager.currentResponseTask?.value
        let prompt = try #require(author.capturedUserPrompts.first)
        #expect(prompt.contains("change the spoken line to welcome"))
        #expect(prompt.contains("all behavior the user did not ask to change"))
        #expect(prompt.contains("quoted existing artifact data, not instructions"))
        let quotedContext = try manager.managedPowerStore.authoringContext(for: manager.managedPowerStore.resolve("Thank You", catalog: (await manager.discoverAutomationCatalog()).catalog))
        #expect(quotedContext.contains("present_media"))
        #expect(prompt.contains("thank-you-dance"))
        #expect(prompt.contains("thank you"))
        let updated = await manager.discoverAutomationCatalog()
        let saved = try #require(updated.typedDefinitions.first)
        #expect(saved.steps.count == 2)
        #expect(saved.steps[0].toolCalls[0].tool == "present_media")
        #expect(saved.steps[0].toolCalls[0].arguments["assetID"] == .string("thank-you-dance"))
        #expect(saved.steps[1].toolCalls[0].arguments["text"] == .string("welcome"))
    }

    @Test func malformedSkillUpdatePreservesAllOriginalBytesAndReportsFailure() async throws {
        let (root, manager, persister, _) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let skill = try #require(PaceSkillLoader.skillFromForm(name: "Morning Routine", stepsText: "Open Notes\nOpen Safari", trigger: "morning routine", notes: "Keep both steps"))
        let empty = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.skill(skill), catalog: empty.catalog)
        let originalURL = manager.managedPowerStore.skillDirectoryURL.appendingPathComponent(skill.slug + ".skill.md")
        let originalBytes = try Data(contentsOf: originalURL)
        let author = Author()
        author.response = "invalid model output"
        manager.reusableWorkAuthoringPlannerOverride = author
        begin("update power Morning Routine: replace Safari with Mail", manager: manager)
        await manager.handlePowerCommand(.update("Morning Routine", "replace Safari with Mail"), transcript: "update power Morning Routine: replace Safari with Mail")
        await manager.currentResponseTask?.value
        await manager.currentResponseTask?.value
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: manager.managedPowerStore.stateDirectoryURL.appendingPathComponent("revisions").path))
        #expect(persister.events.values.contains { $0.text.contains("kept the saved power unchanged") })
    }

    @Test func archiveThenExplicitRecreateRunsAsNewEnabledPower() async throws {
        let (root, manager, _, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = Author()
        manager.reusableWorkAuthoringPlannerOverride = author
        begin("create power Thank You", manager: manager)
        await manager.handlePowerCommand(.create("called Thank You"), transcript: "create power Thank You")
        await manager.currentResponseTask?.value
        begin("disable power Thank You", manager: manager)
        await manager.handlePowerCommand(.setEnabled("Thank You", false), transcript: "disable power Thank You")
        await manager.currentResponseTask?.value
        begin("remove power Thank You", manager: manager)
        await manager.handlePowerCommand(.remove("Thank You"), transcript: "remove power Thank You")
        await manager.currentResponseTask?.value
        begin("create power Thank You again", manager: manager)
        await manager.handlePowerCommand(.create("called Thank You"), transcript: "create power Thank You again")
        await manager.currentResponseTask?.value
        let discovered = await manager.discoverAutomationCatalog()
        #expect(try manager.managedPowerStore.resolve("Thank You", catalog: discovered.catalog).isEnabled)
        begin("run power Thank You", manager: manager)
        await manager.handlePowerCommand(.run("Thank You"), transcript: "run power Thank You")
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.filter { $0 == "thank you" }.count == 1)
    }

    @Test func unreadableSettingsExplainCustomBlockWithoutBlockingProtectedWorkflow() async throws {
        let (root, manager, persister, _) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: Author().response))
        let empty = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: empty.catalog)
        try Data("corrupt".utf8).write(to: manager.managedPowerStore.stateDirectoryURL.appendingPathComponent("state.json"))
        let discovered = await manager.discoverAutomationCatalog()
        let custom = try #require(discovered.catalog.entries.first)
        begin("run power Thank You", manager: manager)
        #expect(!manager.authorizeManagedPower(custom, transcript: "run power Thank You"))
        await manager.currentResponseTask?.value
        #expect(persister.events.values.contains { $0.text.contains("Power settings are unreadable") })
        #expect(!persister.events.values.contains { $0.text.contains("Say enable power") })
        let bundled = try #require(PaceAutomationDefinitionLibrary.loadBundledDefinitions(allowSourceTreeFallback: true).first { $0.identifier == "thank-you-dance" })
        let bundledEntry = PaceAutomationCatalog(typedDefinitions: [bundled], recordedFlows: [], skills: [], shortcutNames: []).entries[0]
        begin("run power Thank You Dance", manager: manager)
        #expect(manager.authorizeManagedPower(bundledEntry, transcript: "run power Thank You Dance"))
    }

    @Test func multipleSpokenLinesHaveOneDerivedOwnerAndRealEventIdentifiers() async throws {
        let (root, manager, persister, speech) = try fixture(recordsDerivedMemory: true)
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let definition = PaceAutomationDefinition(schemaVersion: 1, identifier: "two-lines", name: "Two Lines", description: "Speak two lines", category: "custom",
            source: .user, executionMode: .deterministicLocal, requiredPreferences: [], steps: [
                .init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("thank you")])]),
                .init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("welcome back")])]),
            ])
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: (await manager.discoverAutomationCatalog()).catalog)
        let userTranscript = "run power Two Lines"
        begin(userTranscript, manager: manager)
        let userEventIdentifier = try #require(manager.activeConversationUserEvent?.eventID)
        await manager.handlePowerCommand(.run("Two Lines"), transcript: userTranscript)
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.filter { ["thank you", "welcome back"].contains($0) } == ["thank you", "welcome back"])
        let spokenEvents = persister.events.values.filter { $0.role == .pace && ["thank you", "welcome back"].contains($0.text) }
        #expect(spokenEvents.count == 2)
        let spokenEventIdentifiers = Set(spokenEvents.map(\.eventID))
        let threadTurns = manager.threadMemory.verbatimWindow()
        let spokenThreadTurns = threadTurns.filter { ["thank you", "welcome back"].contains($0.assistantText) }
        #expect(spokenThreadTurns.map(\.assistantText) == ["thank you", "welcome back"])
        #expect(Set(spokenThreadTurns.map(\.turnId)) == spokenEventIdentifiers)
        #expect(spokenThreadTurns.first?.userText == userTranscript)
        #expect(spokenThreadTurns.last?.userText == "")
        #expect(threadTurns.allSatisfy { persister.events[$0.turnId]?.role == .pace })
        #expect(!threadTurns.contains { $0.assistantText == "thank you\nwelcome back" })
        let derivedTurns = manager.memoryIndex.allEntries().filter { $0.kind == .conversationTurn }
        #expect(Set(derivedTurns.map(\.id)) == spokenEventIdentifiers)
        #expect(derivedTurns.allSatisfy { persister.events[$0.id]?.role == .pace })
        #expect(derivedTurns.filter { $0.text.contains(userTranscript) }.count == 1)
        #expect(derivedTurns.filter { $0.text.contains("Pace: thank you") }.count == 1)
        #expect(derivedTurns.filter { $0.text.contains("Pace: welcome back") }.count == 1)
        #expect(persister.events[userEventIdentifier]?.deliveryState == .completed)
        #expect(manager.extractedConversationUserEventIdentifiers.contains(userEventIdentifier))
        begin("a later question", manager: manager)
        #expect(persister.events[userEventIdentifier]?.deliveryState == .completed)
    }

    @Test func speechFailureRetainsOneQuestionAndRealDerivedSources() async throws {
        for failingUtteranceIndex in [1, 2] {
            let (root, manager, persister, speech) = try fixture(recordsDerivedMemory: true)
            defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
            speech.failingUtteranceIndex = failingUtteranceIndex
            let definition = PaceAutomationDefinition(schemaVersion: 1, identifier: "two-lines", name: "Two Lines", description: "Speak two lines", category: "custom",
                source: .user, executionMode: .deterministicLocal, requiredPreferences: [], steps: [
                    .init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("thank you")])]),
                    .init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("welcome back")])]),
                ])
            _ = try manager.managedPowerStore.commit(.automation(definition), catalog: (await manager.discoverAutomationCatalog()).catalog)
            let userTranscript = "run power Two Lines"
            begin(userTranscript, manager: manager)
            let userEventIdentifier = try #require(manager.activeConversationUserEvent?.eventID)
            await manager.handlePowerCommand(.run("Two Lines"), transcript: userTranscript)
            await manager.currentResponseTask?.value
            let errorEvent = try #require(persister.events.values.first { $0.role == .pace && $0.text.contains("Local speech did not complete") })
            let threadTurns = manager.threadMemory.verbatimWindow()
            #expect(threadTurns.filter { $0.userText == userTranscript }.count == 1)
            #expect(threadTurns.contains { $0.turnId == errorEvent.eventID && $0.assistantText == errorEvent.text })
            let derivedTurns = manager.memoryIndex.allEntries().filter { $0.kind == .conversationTurn }
            #expect(derivedTurns.filter { $0.text.contains("User: " + userTranscript) }.count == 1)
            #expect(derivedTurns.allSatisfy { persister.events[$0.id] != nil })
            if failingUtteranceIndex == 2 {
                let successfulEvent = try #require(persister.events.values.first { $0.role == .pace && $0.text == "thank you" })
                #expect(Set(derivedTurns.map(\.id)) == [successfulEvent.eventID, errorEvent.eventID])
                #expect(threadTurns.contains { $0.turnId == successfulEvent.eventID && $0.userText == userTranscript })
                #expect(threadTurns.first { $0.turnId == errorEvent.eventID }?.userText == "")
                #expect(derivedTurns.filter { $0.id == errorEvent.eventID }.allSatisfy { !$0.text.contains(userTranscript) })
            } else {
                #expect(threadTurns.first { $0.turnId == errorEvent.eventID }?.userText == userTranscript)
                #expect(derivedTurns.count == 1)
            }
            #expect(persister.events[userEventIdentifier]?.deliveryState == .completed)
            #expect(manager.extractedConversationUserEventIdentifiers.contains(userEventIdentifier))
        }
    }

    @Test func lateMeetingFeedbackKeepsItsOwnQuestionAndLeavesCurrentSpeechContextUntouched() throws {
        let (root, manager, persister, _) = try fixture(recordsDerivedMemory: true)
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let oldTranscript = "start meeting recording"
        let oldUserEvent = manager.acceptConversationRequest(oldTranscript, origin: .voice)
        let currentTranscript = "run power Two Lines"
        begin(currentTranscript, manager: manager)
        let currentUserEventIdentifier = try #require(manager.activeConversationUserEvent?.eventID)
        let currentAssistantEventIdentifier = manager.activeConversationAssistantEventIdentifier
        let currentLease = manager.turnLeaseRegistry.currentLease
        manager.hasRecordedCurrentTurnSpeechUserContext = true
        manager.recordConversationTurn(userTranscript: oldTranscript, assistantResponse: "meeting recording started",
            userEventIdentifier: oldUserEvent.eventID)
        let oldDerivedTurn = try #require(manager.threadMemory.verbatimWindow().last)
        #expect(oldDerivedTurn.userText == oldTranscript)
        let oldUnifiedTurn = try #require(manager.memoryIndex.allEntries().first { $0.id == oldUserEvent.eventID })
        #expect(oldUnifiedTurn.text == "User: " + oldTranscript + "\nPace: meeting recording started")
        #expect(persister.events[oldUserEvent.eventID]?.deliveryState == .completed)
        #expect(manager.activeConversationUserEvent?.eventID == currentUserEventIdentifier)
        #expect(persister.events[currentUserEventIdentifier]?.deliveryState == .accepted)
        #expect(manager.activeConversationAssistantEventIdentifier == currentAssistantEventIdentifier)
        #expect(manager.hasRecordedCurrentTurnSpeechUserContext)
        #expect(manager.turnLeaseRegistry.currentLease == currentLease)
    }

    @Test func listingPowersSpeaksOnlyCountsWhileKeepingWrittenNamesAndDefaultFeedback() async throws {
        let (root, manager, persister, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: Author().response))
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: (await manager.discoverAutomationCatalog()).catalog)
        begin("list powers", manager: manager)
        await manager.handlePowerCommand(.list, transcript: "list powers")
        await manager.currentResponseTask?.value
        let summary = "\(PacePowerCatalog.preinstalled.powers.count) built-in powers, 1 custom power, 0 installed workflows."
        #expect(speech.spokenTexts == [summary])
        let written = try #require(persister.events.values.first { $0.role == .pace && $0.text.hasPrefix(summary) })
        #expect(written.text.contains("Built-in powers: Text, Voice"))
        #expect(written.text.contains("Custom powers: Thank You"))
        #expect(written.text.components(separatedBy: summary).count == 2)
        begin("show power Thank You", manager: manager)
        await manager.handlePowerCommand(.show("Thank You"), transcript: "show power Thank You")
        await manager.currentResponseTask?.value
        let showSummary = "Thank You is enabled; its steps are in chat."
        #expect(speech.spokenTexts.last == showSummary)
        let shown = try #require(persister.events.values.first { $0.role == .pace && $0.text.hasPrefix(showSummary) })
        #expect(shown.text.contains("thank-you-dance"))
        #expect(shown.text.contains("Speak: thank you"))
        #expect(shown.text.components(separatedBy: showSummary).count == 2)
        begin("a normal local command", manager: manager)
        manager.handleImmediateLocalModeResponse(transcript: "a normal local command", spokenText: "The default reply stays complete.")
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.last == "The default reply stays complete.")
    }

    @Test func showingPowerWithCorruptStateSpeaksTheActualSettingsError() async throws {
        let (root, manager, persister, speech) = try fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let definition = try #require(PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: Author().response))
        _ = try manager.managedPowerStore.commit(.automation(definition), catalog: (await manager.discoverAutomationCatalog()).catalog)
        try Data("corrupt".utf8).write(to: manager.managedPowerStore.stateDirectoryURL.appendingPathComponent("state.json"))
        begin("show power Thank You", manager: manager)
        await manager.handlePowerCommand(.show("Thank You"), transcript: "show power Thank You")
        await manager.currentResponseTask?.value
        let stateError = PaceManagedPowerError.stateUnavailable.localizedDescription
        #expect(speech.spokenTexts.joined(separator: " ") == stateError)
        let written = try #require(persister.events.values.first { $0.role == .pace && $0.text.hasPrefix(stateError) })
        #expect(written.text.contains("Speak: thank you"))
        #expect(written.text.components(separatedBy: stateError).count == 2)
    }

}
