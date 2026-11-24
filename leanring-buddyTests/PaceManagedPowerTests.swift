import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceManagedPowerTests {
    private func fixture() throws -> (URL, PaceManagedPowerStore) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "pace-power-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            PaceManagedPowerStore(
                automationDirectoryURL: root.appendingPathComponent("automations"),
                programDirectoryURL: root.appendingPathComponent("programs"),
                skillDirectoryURL: root.appendingPathComponent("skills"),
                stateDirectoryURL: root.appendingPathComponent("management"), recordsAudit: false)
        )
    }
    private func catalog(_ store: PaceManagedPowerStore) -> PaceAutomationCatalog {
        PaceAutomationCatalog(
            typedDefinitions: PaceUserAutomationStore(directoryURL: store.automationDirectoryURL)
                .listValidDefinitions(),
            recordedFlows: [], skills: PaceSkillLoader.listUserSkills(in: store.skillDirectoryURL), shortcutNames: [],
            programs: PaceUserProgramStore(directoryURL: store.programDirectoryURL).listValidPrograms())
    }
    private func thankYou(_ text: String = "thank you", identifier: String = "thank-you", name: String = "Thank You")
        -> PaceAutomationDefinition
    {
        PaceAutomationDefinition(
            schemaVersion: 1, identifier: identifier, name: name,
            description: "Show an original dancing character and speak.", category: "custom",
            invocationPhrases: ["thank me"], source: .user, executionMode: .deterministicLocal, requiredPreferences: [],
            steps: [
                .init(toolCalls: [
                    .init(
                        tool: "present_media",
                        arguments: ["assetID": .string("thank-you-dance"), "durationSeconds": .number(4)])
                ]),
                .init(toolCalls: [.init(tool: "speak", arguments: ["text": .string(text)])]),
            ])
    }

    @Test func installationCapabilityQuestionDoesNotStartCreatingAPower() {
        for text in [
            "What can you build and install?", "What can Pace build and install for animations?",
            "what can u build and install immediatley",
        ] {
            #expect(PacePowerCommandParser.asksWhatPaceCanBuildAndInstall(text))
            #expect(PacePowerCommandParser.parse(text) == nil)
        }
        let request = "Add a Power called Juggling Girl that shows a juggling loop"
        #expect(!PacePowerCommandParser.asksWhatPaceCanBuildAndInstall(request))
        #expect(PacePowerCommandParser.parse(request) == .add("called Juggling Girl that shows a juggling loop"))
    }

    @Test func speechRequestStrictlyValidatesTheBoundedProfileContract() {
        #expect(PaceSpeechRequest.parse(arguments: ["text": .string("hello")]) == .init(text: "hello"))
        #expect(
            PaceSpeechRequest.parse(arguments: ["text": .string("こんにちは。"), "profile": .string("japanese_female")])
                == .init(text: "こんにちは。", profile: .japaneseFemale))
        let invalidArguments: [[String: PaceMCPJSONValue]] = [
            [:], ["text": .string(" \n")], ["text": .string(String(repeating: "a", count: 2001))],
            ["text": .number(12)], ["text": .string("hello"), "profile": .number(1)],
            ["text": .string("hello"), "profile": .null],
            ["text": .string("hello"), "profile": .string("unknown")],
            ["text": .string("hello"), "voice": .string("jf_alpha")],
            ["text": .string("hello"), "language": .string("j")],
            ["text": .string("hello"), "model": .string("kokoro")],
            ["text": .string("hello"), "endpoint": .string("http://127.0.0.1")],
        ]
        for arguments in invalidArguments { #expect(PaceSpeechRequest.parse(arguments: arguments) == nil) }
        #expect(PaceSpeechRequest.parse(arguments: ["text": .string(String(repeating: "a", count: 2000))]) != nil)
    }

    @Test func plannerSingleAndMultipleCallsPreserveMediaAndSpeechProfiles() throws {
        let mediaArguments: [String: PaceMCPJSONValue] = [
            "assetID": .string("japanese-greeting-woman"), "durationSeconds": .number(6),
        ]
        let speechArguments: [String: PaceMCPJSONValue] = [
            "text": .string("こんにちは。"), "profile": .string("japanese_female"),
        ]
        let calls: [PaceMCPJSONValue] = [
            .object(["name": .string("present_media"), "args": .object(mediaArguments)]),
            .object(["name": .string("speak"), "args": .object(speechArguments)]),
        ]
        let expected: [PaceParsedAction] = [
            .presentMedia(.init(assetID: "japanese-greeting-woman", durationSeconds: 6, motion: nil)),
            .speak(.init(text: "こんにちは。", profile: .japaneseFemale)),
        ]
        for (index, call) in calls.enumerated() {
            let response: PaceMCPJSONValue = .object([
                "spokenText": .string(""), "intent": .string("action"), "payload": call,
            ])
            let text = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
            #expect(
                PaceActionTagParser.parseActions(from: text).executionPlan.flattenedActions.map(\.approvalDescription)
                    == [expected[index].approvalDescription])
        }
        let response: PaceMCPJSONValue = .object([
            "spokenText": .string(""), "intent": .string("action"), "payload": .object(["calls": .array(calls)]),
        ])
        let text = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(
            PaceActionTagParser.parseActions(from: text).executionPlan.flattenedActions.map(\.approvalDescription)
                == expected.map(\.approvalDescription))
        let legacy = PaceActionTagParser.parseActions(
            from:
                #"<tool_calls>[{"tool":"present_media","arguments":{"assetID":"japanese-greeting-woman","durationSeconds":6}},{"tool":"speak","text":"こんにちは。","profile":"japanese_female"}]</tool_calls>"#
        )
        #expect(legacy.executionPlan.flattenedActions.map(\.approvalDescription) == expected.map(\.approvalDescription))
        for invalid in [
            #"{"tool":"speak","text":12}"#,
            #"{"tool":"speak","arguments":{"text":"hello"},"profile":null}"#,
            #"{"tool":"speak","text":"hello","steps":null}"#,
            #"{"tool":"speak","text":"hello","arguments":false}"#,
        ] {
            #expect(
                PaceActionTagParser.parseActions(from: "<tool_calls>[" + invalid + "]</tool_calls>").executionPlan
                    .flattenedActions.isEmpty)
        }
    }

    @Test func plannerMediaAndSpeechRejectInvalidArgumentsInSingleAndMultipleCalls() throws {
        let calls: [PaceMCPJSONValue] = [
            .object([
                "name": .string("speak"), "args": .object(["text": .string("hello"), "profile": .string("unknown")]),
            ]),
            .object(["name": .string("speak"), "args": .object(["text": .number(12)])]),
            .object([
                "name": .string("present_media"),
                "args": .object([
                    "assetID": .string("japanese-greeting-woman"), "durationSeconds": .number(6),
                    "path": .string("/tmp/image.gif"),
                ]),
            ]),
            .object([
                "name": .string("present_media"),
                "args": .object(["assetID": .string("japanese-greeting-woman"), "durationSeconds": .number(31)]),
            ]),
        ]
        for call in calls {
            for payload in [call, .object(["calls": .array([call])])] {
                let response: PaceMCPJSONValue = .object([
                    "spokenText": .string(""), "intent": .string("action"), "payload": payload,
                ])
                let text = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
                #expect(PaceActionTagParser.parseActions(from: text).executionPlan.flattenedActions.isEmpty)
            }
        }
    }

    @Test func typedAutomationAndProgramKeepProfileThroughSavedJSONAndCompilation() throws {
        let step = PaceAutomationStep(toolCalls: [
            .init(
                tool: "speak",
                arguments: [
                    "text": .string("こんにちは。"), "profile": .string("japanese_female"),
                    "englishSubtitle": .string("Hello."),
                ])
        ])
        let definition = PaceAutomationDefinition(
            schemaVersion: 1, identifier: "japanese-greeting", name: "Japanese greeting",
            description: "A Japanese greeting.", category: "custom", invocationPhrases: ["greet in Japanese"],
            source: .user, executionMode: .deterministicLocal, requiredPreferences: [], steps: [step])
        let decoded = try JSONDecoder().decode(PaceAutomationDefinition.self, from: JSONEncoder().encode(definition))
        let actions = try PaceAutomationCompiler.compile(decoded).flattenedActions
        #expect(actions.count == 1)
        guard case .speak(let request) = actions.first else {
            Issue.record("Compiled speech must retain its typed request.")
            return
        }
        #expect(request == .init(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello."))
        let program = PaceProgramDefinition(
            schemaVersion: 1, identifier: "japanese-program", name: "Japanese program",
            description: "A Japanese greeting.", category: "custom", invocationPhrases: ["greet in Japanese"],
            requiredPreferences: [],
            nodes: [.repeatTimes(count: 2, nodes: [.action(step: step)])])
        let decodedProgram = try JSONDecoder().decode(PaceProgramDefinition.self, from: JSONEncoder().encode(program))
        #expect(decodedProgram == program)
        #expect(PaceProgramValidator.validationIssues(for: decodedProgram).isEmpty)
        #expect(decodedProgram.nodes == [.repeatTimes(count: 2, nodes: [.action(step: step)])])
    }

    @Test func commandsAreAnchoredAndPreserveExactMutationTargets() {
        let knownSavedNames: Set<String> = ["Settings Backup", "Mode Switch", "Options Review"]
        #expect(PacePowerCommandParser.parse("list powers") == .list)
        #expect(PacePowerCommandParser.parse("Can you create a power called Thank You") == .create("called Thank You"))
        #expect(PacePowerCommandParser.parse("Could you please list powers?") == .list)
        #expect(PacePowerCommandParser.parse("Can you explain how to create a power?") == nil)
        #expect(PacePowerCommandParser.parse("disable power nap") == nil)
        #expect(PacePowerCommandParser.parse("enable power saving mode") == nil)
        #expect(PacePowerCommandParser.parse("disable power nap on battery") == nil)
        #expect(PacePowerCommandParser.parse("show power consumption by app") == nil)
        #expect(
            PacePowerCommandParser.parse("show power Settings Backup", isKnownSavedPowerName: knownSavedNames.contains)
                == .show("Settings Backup"))
        #expect(
            PacePowerCommandParser.parse("disable power Mode Switch", isKnownSavedPowerName: knownSavedNames.contains)
                == .setEnabled("Mode Switch", false))
        #expect(
            PacePowerCommandParser.parse("remove power Options Review", isKnownSavedPowerName: knownSavedNames.contains)
                == .remove("Options Review"))
        #expect(PacePowerCommandParser.parse("show power consumption") == nil)
        #expect(PacePowerCommandParser.parse("disable power automation:nap") == .setEnabled("automation:nap", false))
        #expect(PacePowerCommandParser.parse("show my powers") == .list)
        #expect(
            PacePowerCommandParser.parse("create a power called Thank You that says thank you")
                == .create("called Thank You that says thank you"))
        #expect(
            PacePowerCommandParser.parse("update power Thank You: say welcome") == .update("Thank You", "say welcome"))
        #expect(
            PacePowerCommandParser.parse("disable power automation:thank-you")
                == .setEnabled("automation:thank-you", false))
        #expect(PacePowerCommandParser.parse("run the Thank You power") == .run("Thank You"))
        #expect(
            PacePowerCommandParser.parse("update power automation:thank-you: say welcome")
                == .update("automation:thank-you", "say welcome"))
        #expect(
            PacePowerCommandParser.parse("import power media /tmp/dance.gif as my-dance")
                == .importMedia("/tmp/dance.gif", "my-dance"))
        #expect(PacePowerCommandParser.parse("remove power similar to Thank You") == .remove("similar to Thank You"))
        #expect(PacePowerCommandParser.parse("The screen says delete power Thank You") == nil)
        #expect(PacePowerCommandParser.parse("how do I create power workflows?") == nil)
        #expect(PacePowerCommandParser.parse("update power Thank You") == nil)
    }

    @Test func savedPowerLifecycleSurvivesRestartAndArchivesOnlyItsOwnedArtifact() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = catalog(store)
        #expect(try store.commit(.automation(thankYou()), catalog: empty) == "Thank You")
        let saved = try store.resolve("Thank You", catalog: catalog(store))
        #expect(saved.identifier == "automation:thank-you")
        #expect(saved.isUserOwned && saved.isEnabled)
        try store.setEnabled(false, power: saved)
        let restarted = PaceManagedPowerStore(
            automationDirectoryURL: store.automationDirectoryURL, programDirectoryURL: store.programDirectoryURL,
            skillDirectoryURL: store.skillDirectoryURL, stateDirectoryURL: store.stateDirectoryURL, recordsAudit: false)
        #expect(!restarted.isEnabled(saved.identifier))
        try restarted.setEnabled(true, power: saved)
        _ = try restarted.commit(.automation(thankYou("welcome")), replacing: saved, catalog: catalog(store))
        let updated = try store.resolve(saved.identifier, catalog: catalog(store))
        #expect(updated.fingerprint != saved.fingerprint)
        let revisionRootURL = store.stateDirectoryURL.appendingPathComponent("revisions")
        let revisions = try FileManager.default.contentsOfDirectory(
            at: revisionRootURL, includingPropertiesForKeys: nil)
        #expect(revisions.count == 1)
        let oldBytes = try Data(contentsOf: revisions[0].appendingPathComponent("thank-you.json"))
        #expect(PaceManagedPowerStore.fingerprint(oldBytes) == saved.fingerprint)
        let definitions = PaceUserAutomationStore(directoryURL: store.automationDirectoryURL).listValidDefinitions()
        #expect(definitions.first?.steps.last?.toolCalls.first?.arguments["text"] == .string("welcome"))
        let historyURL = root.appendingPathComponent("history.jsonl")
        let assetURL = root.appendingPathComponent("assets.gif")
        try Data("history".utf8).write(to: historyURL)
        try Data("asset".utf8).write(to: assetURL)
        let archiveURL = try store.archive(updated)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(updated.ownedArtifactURL).path))
        #expect(try String(contentsOf: historyURL, encoding: .utf8) == "history")
        #expect(try String(contentsOf: assetURL, encoding: .utf8) == "asset")
        #expect(catalog(store).entries.isEmpty)
        #expect(restarted.isEnabled(saved.identifier))
    }

    @Test func staleUpdateCannotOverwriteNewerContentAndDoesNotCollideWithItself() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        let snapshot = try store.resolve("Thank You", catalog: catalog(store))
        _ = try store.commit(.automation(thankYou("welcome")), replacing: snapshot, catalog: catalog(store))
        #expect(throws: PaceManagedPowerError.self) {
            try store.commit(.automation(thankYou("stale reply")), replacing: snapshot, catalog: catalog(store))
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: store.stateDirectoryURL.appendingPathComponent("revisions").path
            ).count == 1)
        let live = PaceUserAutomationStore(directoryURL: store.automationDirectoryURL).listValidDefinitions()[0]
        #expect(live.steps.last?.toolCalls.first?.arguments["text"] == .string("welcome"))
    }

    @Test func namesIdentifiersAndCompiledPowersAreProtectedFromAccidentalOverwrite() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        #expect(throws: PaceManagedPowerError.self) {
            try store.commit(.automation(thankYou()), catalog: catalog(store))
        }
        #expect(throws: PaceManagedPowerError.self) {
            try store.commit(.automation(thankYou(identifier: "other", name: "Thank You")), catalog: catalog(store))
        }
        #expect(throws: PaceManagedPowerError.self) {
            try store.commit(.automation(thankYou(identifier: "voice", name: "Voice")), catalog: catalog(store))
        }
        #expect(throws: PaceManagedPowerError.self) {
            try store.resolve("similar to Thank You", catalog: catalog(store))
        }
        _ = try store.commit(
            .automation(thankYou(identifier: "look-alike", name: "automation:thank-you")), catalog: catalog(store))
        #expect(try store.resolve("automation:thank-you", catalog: catalog(store)).name == "Thank You")
        let builtIn = try store.resolve("pace.voice", catalog: catalog(store))
        #expect(!builtIn.isUserOwned)
        #expect(!builtIn.capabilities.contains("disable"))
        #expect(throws: PaceManagedPowerError.self) { try store.setEnabled(false, power: builtIn) }
        #expect(throws: PaceManagedPowerError.self) { try store.archive(builtIn) }
    }

    @Test func corruptStateFailsClosedAndArchivePreservesTheArtifact() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        let snapshot = try store.resolve("Thank You", catalog: catalog(store))
        try store.setEnabled(false, power: snapshot)
        let stateURL = store.stateDirectoryURL.appendingPathComponent("state.json")
        try Data("broken state".utf8).write(to: stateURL)
        #expect(!store.isEnabled(snapshot.identifier))
        #expect(throws: (any Error).self) { try store.archive(snapshot) }
        #expect(FileManager.default.fileExists(atPath: try #require(snapshot.ownedArtifactURL).path))
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == "broken state")
    }

    @Test func symlinksCannotTurnDisabledArtifactsIntoEnabledOrOwnedWork() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        let savedCatalog = catalog(store)
        let snapshot = try store.resolve("Thank You", catalog: savedCatalog)
        try store.setEnabled(false, power: snapshot)
        let originalURL = try #require(snapshot.ownedArtifactURL)
        let outsideURL = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: originalURL, to: outsideURL)
        try FileManager.default.createSymbolicLink(at: originalURL, withDestinationURL: outsideURL)
        let unsafe = try store.resolve("Thank You", catalog: savedCatalog)
        #expect(!unsafe.isEnabled && !unsafe.isUserOwned)
        #expect(throws: PaceManagedPowerError.self) { try store.archive(snapshot) }
        #expect(try Data(contentsOf: outsideURL) == Data(contentsOf: originalURL))
    }

    @Test func symlinkedParentCannotRedirectCreateOrStateWrites() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.automationDirectoryURL, withDestinationURL: outside)
        #expect(throws: PaceManagedPowerError.self) {
            try store.commit(.automation(thankYou()), catalog: catalog(store))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.createSymbolicLink(at: store.stateDirectoryURL, withDestinationURL: outside)
        #expect(!store.isEnabled("automation:thank-you"))
    }

    @Test func skillSlugCollisionCannotSilentlyOverwriteDifferentNames() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(
            PaceSkillLoader.skillFromForm(name: "Morning!", stepsText: "Open Notes", trigger: nil, notes: nil))
        let second = PaceSkillFile(
            name: "Different name", slug: first.slug, description: "Different", category: "custom",
            requiredPreferences: [], trigger: nil,
            steps: [.init(instruction: "Open Safari", toolCall: nil)], notes: nil)
        try PaceSkillLoader.save(first, to: store.skillDirectoryURL)
        #expect(throws: PaceManagedPowerError.self) { try PaceSkillLoader.save(second, to: store.skillDirectoryURL) }
        #expect(PaceSkillLoader.listUserSkills(in: store.skillDirectoryURL) == [first])
    }

    @Test func expressiveCompilationRejectsURLsPathsUnboundedDurationsAndSpeechExtras() throws {
        let plan = try PaceAutomationCompiler.compile(thankYou())
        #expect(plan.flattenedActions.count == 2)
        let invalidArguments: [[String: PaceMCPJSONValue]] = [
            ["assetID": .string("https://example.com/dance.gif"), "durationSeconds": .number(4)],
            ["assetID": .string("../../secret"), "durationSeconds": .number(4)],
            ["assetID": .string("thank-you-dance"), "durationSeconds": .number(300)],
            ["assetID": .string("thank-you-dance"), "durationSeconds": .number(0)],
            ["assetID": .string("thank-you-dance"), "durationSeconds": .number(4), "path": .string("/tmp/anything")],
        ]
        for arguments in invalidArguments { #expect(PaceMediaPresentationRequest.parse(arguments: arguments) == nil) }
        let valid = PaceActionTagParser.parseActions(
            from: #"<tool_calls>[{"tool":"speak","text":"thank you"}]</tool_calls>"#)
        #expect(valid.executionPlan.flattenedActions.count == 1)
        let invalid = PaceActionTagParser.parseActions(
            from: #"<tool_calls>[{"tool":"speak","text":"thank you","command":"shell"}]</tool_calls>"#)
        #expect(invalid.executionPlan.flattenedActions.isEmpty)
    }

    @Test func expressiveExecutionPresentsBeforeSpeechAndRevocationStopsRemainingActions() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        var events: [String] = []
        var authorized = true
        executor.managedPowerExecutionCheck = { authorized }
        executor.presentLocalMedia = { request in
            events.append("visible:" + request.assetID)
            return .init(toolName: "present_media", summary: "Presented")
        }
        executor.speakLocalText = { request in
            events.append("speech:" + request.text)
            return .init(toolName: "speak", summary: "Completed")
        }
        let plan = try PaceAutomationCompiler.compile(thankYou())
        _ = await executor.executeActionPlan(plan, screenCaptures: [])
        #expect(events == ["visible:thank-you-dance", "speech:thank you"])
        events = []
        executor.presentLocalMedia = { request in
            events.append("visible:" + request.assetID)
            authorized = false
            return .init(toolName: "present_media", summary: "Presented")
        }
        let observations = await executor.executeActionPlan(plan, screenCaptures: [])
        #expect(events == ["visible:thank-you-dance"])
        #expect(observations.last?.stopsActionPlan == true)
    }

    @Test func speechFailureIsTerminalAndNeverReportedAsSuccessful() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        executor.speakLocalText = { _ in
            .init(toolName: "speak", summary: "Playback failed", terminalReason: .managedWorkflowUnavailable)
        }
        let receipt = await executor.executeActionPlan(
            .serial(actions: [.speak(.init(text: "thank you")), .speak(.init(text: "never reached"))]),
            screenCaptures: [])
        #expect(receipt.count == 1)
        #expect(receipt[0].stopsActionPlan)
        #expect(receipt[0].summary == "Playback failed")
    }

    @Test func mediaGenerationFencesOldTimersAndDismissalIsIdempotentWithoutWindows() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!)
        let presenter = PaceMediaOverlayController(showsWindows: false, resolveImage: { _ in image })
        var dismissedGenerations: [UUID] = []
        let recordDismissal: (UUID) -> Void = { dismissedGenerations.append($0) }
        let request = PaceMediaPresentationRequest(assetID: "thank-you-dance", durationSeconds: 4, motion: nil)
        #expect(!presenter.present(request, onDismiss: recordDismissal).stopsActionPlan)
        let oldGeneration = presenter.presentationGeneration
        #expect(!presenter.present(request, onDismiss: recordDismissal).stopsActionPlan)
        let currentGeneration = presenter.presentationGeneration
        presenter.finishPresentation(ifGenerationMatches: oldGeneration)
        presenter.dismissPresentation(ifGenerationMatches: oldGeneration, cancelOwnedRun: true)
        #expect(presenter.isVisible)
        #expect(dismissedGenerations.isEmpty)
        presenter.dismiss(cancelOwnedRun: true)
        presenter.dismiss(cancelOwnedRun: true)
        #expect(!presenter.isVisible)
        #expect(dismissedGenerations == [currentGeneration])
    }
    @Test func programmedAndFlexiblePowersUpdateInPlaceAndArchiveTheirOriginalFormats() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = PaceProgramDefinition(
            schemaVersion: 1, identifier: "programmed-thanks", name: "Programmed Thanks",
            description: "A bounded program", category: "custom",
            invocationPhrases: [], requiredPreferences: [],
            nodes: [.repeatTimes(count: 1, nodes: [.action(step: thankYou().steps[1])])])
        _ = try store.commit(.program(program), catalog: catalog(store))
        let savedProgram = try store.resolve("program:programmed-thanks", catalog: catalog(store))
        let changedProgram = PaceProgramDefinition(
            schemaVersion: 1, identifier: "ignored-new-id", name: "Ignored new name", description: "Updated program",
            category: "custom",
            invocationPhrases: [], requiredPreferences: [],
            nodes: [.repeatTimes(count: 1, nodes: [.action(step: thankYou("welcome").steps[1])])])
        _ = try store.commit(.program(changedProgram), replacing: savedProgram, catalog: catalog(store))
        let updatedProgram = try store.resolve(savedProgram.identifier, catalog: catalog(store))
        #expect(updatedProgram.name == savedProgram.name)
        let archivedProgram = try store.archive(updatedProgram)
        #expect(archivedProgram.pathExtension == "json")
        let skill = try #require(
            PaceSkillLoader.skillFromForm(
                name: "Flexible Thanks", stepsText: "Say thank you", trigger: "flexible thanks", notes: nil))
        _ = try store.commit(.skill(skill), catalog: catalog(store))
        let savedSkill = try store.resolve("skill:flexible-thanks", catalog: catalog(store))
        let changedSkill = PaceSkillFile(
            name: "Ignored rename", slug: "ignored-new-id", description: "Updated skill", category: "custom",
            requiredPreferences: [], trigger: "flexible thanks",
            steps: [.init(instruction: "Say welcome", toolCall: nil)], notes: nil)
        _ = try store.commit(.skill(changedSkill), replacing: savedSkill, catalog: catalog(store))
        let updatedSkill = try store.resolve(savedSkill.identifier, catalog: catalog(store))
        #expect(try store.contentSummary(updatedSkill).contains("Say welcome"))
        let archivedSkill = try store.archive(updatedSkill)
        #expect(archivedSkill.lastPathComponent == "flexible-thanks.skill.md")
        #expect(catalog(store).entries.isEmpty)
    }

    @Test func mediaImportCopiesValidatedContentAndRejectsTamperingCollisionsAndFakeTypes() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = PaceLocalMediaCatalog(importedDirectoryURL: root.appendingPathComponent("media"))
        let gifURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("leanring-buddy/Resources/media/thank-you-dance.gif")
        try media.importAsset(from: gifURL, identifier: "custom-dance")
        let ownedURL = try #require(media.resourceURL(for: "custom-dance"))
        #expect(media.authoringAssetIdentifiers().contains("custom-dance"))
        #expect(ownedURL.path.hasPrefix(root.path))
        #expect(try Data(contentsOf: ownedURL) == Data(contentsOf: gifURL))
        #expect(throws: PaceManagedPowerError.self) { try media.importAsset(from: gifURL, identifier: "custom-dance") }
        #expect(throws: PaceManagedPowerError.self) {
            try media.importAsset(from: gifURL, identifier: "thank-you-dance")
        }
        #expect(throws: PaceManagedPowerError.self) { try media.importAsset(from: gifURL, identifier: "../unsafe") }
        let fakeURL = root.appendingPathComponent("fake.gif")
        try Data("this is not an image".utf8).write(to: fakeURL)
        #expect(throws: PaceManagedPowerError.self) { try media.importAsset(from: fakeURL, identifier: "fake") }
        try Data("tampered".utf8).write(to: ownedURL)
        #expect(media.resourceURL(for: "custom-dance") == nil)
        #expect(!media.authoringAssetIdentifiers().contains("custom-dance"))
        #expect(media.resourceURL(for: "https://example.com/remote.gif") == nil)
    }

    @Test func bundledThankYouStarterUsesCanonicalMediaThenSpeechAndIsReadRunProtected() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = PaceAutomationDefinitionLibrary.loadBundledDefinitions(allowSourceTreeFallback: true)
        let starter = try #require(definitions.first { $0.identifier == "thank-you-dance" })
        #expect(
            starter.invocationPhrases == [
                "show me the thank you dance", "play my thank you dance", "run my thank you dance",
            ])
        let plan = try PaceAutomationCompiler.compile(starter)
        #expect(plan.flattenedActions.count == 2)
        guard case .presentMedia(let media) = plan.flattenedActions[0],
            case .speak(let speech) = plan.flattenedActions[1]
        else {
            Issue.record("Bundled starter must present media before speech")
            return
        }
        #expect(media.assetID == "thank-you-dance" && media.durationSeconds == 4)
        #expect(speech == .init(text: "thank you"))
        let bundledCatalog = PaceAutomationCatalog(
            typedDefinitions: [starter], recordedFlows: [], skills: [], shortcutNames: [])
        let power = try store.resolve("Thank You Dance", catalog: bundledCatalog)
        #expect(!power.isUserOwned)
        #expect(power.capabilities.contains("run"))
        #expect(!power.capabilities.contains("disable"))
        #expect(throws: PaceManagedPowerError.self) { try store.archive(power) }
    }

    @Test func bundledJapaneseGreetingHasSeparateAliasesMediaAndExplicitSpeechProfile() throws {
        let definitions = PaceAutomationDefinitionLibrary.loadBundledDefinitions(allowSourceTreeFallback: true)
        let starter = try #require(definitions.first { $0.identifier == "japanese-greeting" })
        #expect(starter.name == "Japanese Greeting")
        #expect(
            starter.invocationPhrases == [
                "show me the Japanese greeting", "play my Japanese greeting", "run my Japanese greeting",
            ])
        let plan = try PaceAutomationCompiler.compile(starter)
        #expect(plan.flattenedActions.count == 2)
        guard case .presentMedia(let media) = plan.flattenedActions[0],
            case .speak(let speech) = plan.flattenedActions[1]
        else {
            Issue.record("Japanese greeting must present media before speech")
            return
        }
        #expect(media.assetID == "japanese-greeting-woman" && media.durationSeconds == 6)
        #expect(
            speech
                == .init(
                    text: "こんにちは。会えてうれしいです。ありがとうございます。", profile: .japaneseFemale,
                    englishSubtitle: "Hello. It’s lovely to see you. Thank you."))
    }

    @Test func macOSSystemTemporaryAliasesWorkWhileManagedChildLinksRemainRejected() throws {
        let systemLinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: "/var")
        #expect(["private/var", "/private/var"].contains(systemLinkDestination))
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-power-alias-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = PaceManagedPowerStore(
            automationDirectoryURL: temporaryRoot.appendingPathComponent("automations"),
            programDirectoryURL: temporaryRoot.appendingPathComponent("programs"),
            skillDirectoryURL: temporaryRoot.appendingPathComponent("skills"),
            stateDirectoryURL: temporaryRoot.appendingPathComponent("management"), recordsAudit: false)
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        let saved = try store.resolve("Thank You", catalog: catalog(store))
        try store.setEnabled(false, power: saved)
        #expect(!store.isEnabled(saved.identifier))
    }

    @Test func removingUserSkillShadowRestoresBundledAuthorityAndClearsOwnedState() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = try #require(
            PaceSkillLoader.skillFromForm(
                name: "Daily Ritual", stepsText: "Open Notes", trigger: "daily ritual", notes: nil))
        _ = try store.commit(.skill(user), catalog: catalog(store))
        let owned = try store.resolve("skill:daily-ritual", catalog: catalog(store))
        try store.setEnabled(false, power: owned)
        _ = try store.archive(owned)
        let bundled = PaceSkillFile(
            name: "Daily Ritual", slug: "daily-ritual", description: "Bundled default", category: "bundled",
            requiredPreferences: [], trigger: "daily ritual",
            steps: [.init(instruction: "Read the default ritual", toolCall: nil)], notes: nil)
        let bundledCatalog = PaceAutomationCatalog(
            typedDefinitions: [], recordedFlows: [], skills: [bundled], shortcutNames: [])
        let restored = try store.resolve("skill:daily-ritual", catalog: bundledCatalog)
        #expect(!restored.isUserOwned && !restored.isManagedUserArtifact)
        #expect(restored.isEnabled && restored.managementStateError == nil)
        #expect(store.isEnabled(owned.identifier))
        #expect(throws: PaceManagedPowerError.self) { try store.setEnabled(false, power: restored) }
    }

    @Test func corruptStateBlocksOnlyManagedUserArtifactsAndReportsTheReason() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        try Data("corrupt".utf8).write(to: store.stateDirectoryURL.appendingPathComponent("state.json"))
        let custom = try #require(catalog(store).entries.first)
        let bundled = PaceAutomationCatalogEntry(
            name: "Bundled", description: "Bundled default", category: "custom", source: .bundled,
            executionMode: .deterministicLocal, invocationPhrases: [],
            reference: .typedDefinition(identifier: "bundled"))
        let shortcut = PaceAutomationCatalogEntry(
            name: "Shortcut", description: "Provider owned", category: "custom", source: .shortcuts,
            executionMode: .externalOpaque, invocationPhrases: [], reference: .shortcut(name: "Shortcut"))
        let flow = PaceAutomationCatalogEntry(
            name: "Recorded", description: "Existing replay controls", category: "custom", source: .recordedFlow,
            executionMode: .deterministicReplay, invocationPhrases: [], reference: .recordedFlow(name: "Recorded"))
        let entries = store.list(catalog: PaceAutomationCatalog(entries: [custom, bundled, shortcut, flow]))
        let user = try #require(entries.first { $0.identifier == "automation:thank-you" })
        #expect(!user.isEnabled && user.managementStateError?.contains("unreadable") == true)
        #expect(
            entries.filter { !$0.isManagedUserArtifact }.allSatisfy { $0.isEnabled && $0.managementStateError == nil })
    }

    @Test func newExplicitCreateClearsOnlyItsOwnLegacyDisabledLifecycle() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.stateDirectoryURL, withIntermediateDirectories: true)
        let legacyState = ["disabledIdentifiers": ["automation:thank-you", "owned:automation:other"]]
        let stateURL = store.stateDirectoryURL.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: legacyState).write(to: stateURL)
        #expect(!store.isEnabled("automation:thank-you"))
        #expect(throws: (any Error).self) {
            try store.commit(.automation(thankYou(identifier: "../bad")), catalog: catalog(store))
        }
        #expect(!store.isEnabled("automation:thank-you"))
        _ = try store.commit(.automation(thankYou()), catalog: catalog(store))
        #expect(store.isEnabled("automation:thank-you"))
        #expect(!store.isEnabled("automation:other"))
    }

    @Test func canonicalUnicodeAutomationsProgramsAndSkillsRemainLoadableAndManageable() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = PaceFlowStore.slug(for: "Café Notes")
        let legacy = thankYou(identifier: identifier, name: "Café Notes")
        try FileManager.default.createDirectory(at: store.automationDirectoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(
            to: store.automationDirectoryURL.appendingPathComponent(identifier + ".json"))
        #expect(
            PaceUserAutomationStore(directoryURL: store.automationDirectoryURL).listValidDefinitions().map(\.identifier)
                == [identifier])
        let saved = try store.resolve("automation:" + identifier, catalog: catalog(store))
        try store.setEnabled(false, power: saved)
        try store.setEnabled(true, power: saved)
        _ = try store.commit(
            .automation(thankYou("welcome", identifier: identifier, name: "Café Notes")), replacing: saved,
            catalog: catalog(store))
        let updated = try store.resolve(saved.identifier, catalog: catalog(store))
        _ = try store.archive(updated)
        let skill = try #require(
            PaceSkillLoader.skillFromForm(name: "中文提醒", stepsText: "Say thank you", trigger: nil, notes: nil))
        _ = try store.commit(.skill(skill), catalog: catalog(store))
        let savedSkill = try store.resolve("skill:" + skill.slug, catalog: catalog(store))
        #expect(savedSkill.isUserOwned)
        try store.setEnabled(false, power: savedSkill)
        try store.setEnabled(true, power: savedSkill)
        _ = try store.archive(savedSkill)
        let program = PaceProgramDefinition(
            schemaVersion: 1, identifier: PaceFlowStore.slug(for: "Café Program"), name: "Café Program",
            description: "Unicode program", category: "custom",
            invocationPhrases: [], requiredPreferences: [],
            nodes: [.repeatTimes(count: 1, nodes: [.action(step: thankYou().steps[1])])])
        _ = try store.commit(.program(program), catalog: catalog(store))
        let savedProgram = try store.resolve("program:" + program.identifier, catalog: catalog(store))
        #expect(savedProgram.isUserOwned)
        _ = try store.archive(savedProgram)
        for invalidIdentifier in ["../secret", "a/b", "a\\b", ".hidden", "a..b", "a--b", "-a", "a-"] {
            #expect(!PaceManagedPowerStore.safeIdentifier(invalidIdentifier))
        }
    }

    @Test func savedPowersWithOrdinaryFeaturePrefixesRemainManageableByName() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [
            "Settings Backup", "Mode Switch", "Options Review", "Settings", "Nap", "Saving Mode", "Nap on battery",
        ] {
            _ = try store.commit(
                .automation(thankYou(identifier: PaceFlowStore.slug(for: name), name: name)), catalog: catalog(store))
            #expect(
                PacePowerCommandParser.parse("show power " + name, isKnownSavedPowerName: store.hasExactSavedPowerName)
                    == .show(name))
            #expect(
                PacePowerCommandParser.parse("run power " + name, isKnownSavedPowerName: store.hasExactSavedPowerName)
                    == .run(name))
            #expect(
                PacePowerCommandParser.parse(
                    "enable power " + name, isKnownSavedPowerName: store.hasExactSavedPowerName)
                    == .setEnabled(name, true))
            #expect(
                PacePowerCommandParser.parse(
                    "remove power " + name, isKnownSavedPowerName: store.hasExactSavedPowerName) == .remove(name))
            guard
                case .setEnabled(let target, false) = PacePowerCommandParser.parse(
                    "disable power " + name, isKnownSavedPowerName: store.hasExactSavedPowerName)
            else {
                Issue.record("Saved name must remain available to exact command parsing")
                continue
            }
            let saved = try store.resolve(target, catalog: catalog(store))
            try store.setEnabled(false, power: saved)
            #expect(!store.isEnabled(saved.identifier))
            _ = try store.archive(saved)
        }
        #expect(catalog(store).entries.isEmpty)
    }

    @Test func spokenTargetPunctuationFallsBackOnlyAfterExactNameOrIdentifierMatches() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (identifier, name) in [("greeting", "Greeting"), ("punctuated-greeting", "Greeting!"), ("nap", "Nap")] {
            _ = try store.commit(.automation(thankYou(identifier: identifier, name: name)), catalog: catalog(store))
        }
        #expect(try store.resolve("Greeting.", catalog: catalog(store)).identifier == "automation:greeting")
        #expect(try store.resolve("Greeting!", catalog: catalog(store)).identifier == "automation:punctuated-greeting")
        #expect(try store.resolve("Greeting!.", catalog: catalog(store)).identifier == "automation:punctuated-greeting")
        #expect(try store.resolve("automation:greeting.", catalog: catalog(store)).identifier == "automation:greeting")
        for (transcript, expectedTarget) in [
            ("run power Greeting.", "Greeting."), ("show power Greeting?", "Greeting?"),
            ("disable power automation:greeting.", "automation:greeting."),
        ] {
            let command = try #require(
                PacePowerCommandParser.parse(transcript, isKnownSavedPowerName: store.hasExactSavedPowerName))
            let target: String
            switch command {
            case .run(let value), .show(let value), .setEnabled(let value, _): target = value
            default:
                Issue.record("Expected an exact management target")
                continue
            }
            #expect(target == expectedTarget)
            #expect(try store.resolve(target, catalog: catalog(store)).identifier == "automation:greeting")
        }
        let napCommand = PacePowerCommandParser.parse(
            "disable power Nap.", isKnownSavedPowerName: store.hasExactSavedPowerName)
        #expect(napCommand == .setEnabled("Nap.", false))
        #expect(try store.resolve("Nap.", catalog: catalog(store)).identifier == "automation:nap")
        #expect(PacePowerCommandParser.parse("disable power nap.") == nil)
        #expect(throws: PaceManagedPowerError.self) { try store.resolve("Greeting similar", catalog: catalog(store)) }
    }

}
