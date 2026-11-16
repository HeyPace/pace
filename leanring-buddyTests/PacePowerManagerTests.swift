import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PacePowerManagerTests {
    final class LocalSpeech: BuddyTTSClient {
        var spokenTexts: [String] = []
        var stopCount = 0
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var supportsUtteranceCompletion: Bool { true }
        func speakText(_ text: String) async throws { try Task.checkCancellation(); spokenTexts.append(text) }
        func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws {
            try Task.checkCancellation()
            spokenTexts.append(text)
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

    func fixture() throws -> (URL, CompanionManager, PaceConversationRecorderTests.FixturePersister, LocalSpeech) {
        let (manager, persister, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pace-power-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        _ = manager.actionExecutor.presentLocalMedia?(.init(assetID: "thank-you-dance", durationSeconds: 4, motion: nil))
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

}
