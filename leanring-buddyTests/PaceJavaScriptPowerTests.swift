import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PaceJavaScriptPowerTests {
    private func program(_ source: String, schemaVersion: Int = 2, identifier: String = "runtime-greeting")
        -> PaceProgramDefinition
    {
        PaceProgramDefinition(
            schemaVersion: schemaVersion, identifier: identifier, name: "Runtime Greeting",
            description: "Compute a local greeting", category: "custom", invocationPhrases: ["greet me now"],
            requiredPreferences: [], nodes: [.javascript(source: source)])
    }

    private func context(hour: Int = 10, weekday: Int = 2) -> PaceProgramContext {
        PaceProgramContext(
            weekday: weekday, localHour: hour, frontmostApplicationBundleIdentifier: "private.app.not-exported")
    }

    private func actions(_ source: String, hour: Int = 10, weekday: Int = 2) async throws -> [PaceParsedAction] {
        guard
            case .executionPlan(let plan) = try await PaceJavaScriptPowerRuntime.compile(
                program(source), context: context(hour: hour, weekday: weekday))
        else {
            Issue.record("Expected a materialized execution plan")
            return []
        }
        return plan.flattenedActions
    }

    private func rejects(_ source: String) async -> Bool {
        do {
            _ = try await actions(source)
            return false
        } catch { return true }
    }

    @Test func sourceRoundTripsWithoutChangingQuotesBackslashesOrUnicode() throws {
        let source = #"pace.speak(["hello", "こんにちは", "a\\b"].join(" ' "));"#
        let original = program(source)
        let decoded = try JSONDecoder().decode(PaceProgramDefinition.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(PaceProgramValidator.validationIssues(for: decoded).isEmpty)
        #expect(PaceProgramValidator.worstCaseExpandedActionSteps(for: decoded) == 50)
        #expect(throws: PaceProgramCompilationError.self) {
            try PaceProgramCompiler.compile(decoded, context: context())
        }
    }

    @Test func schemaTwoRequiresExactlyOneJavaScriptBodyAndSchemaOneCannotAcquireIt() {
        #expect(!PaceProgramValidator.validationIssues(for: program("pace.speak('hello')", schemaVersion: 1)).isEmpty)
        let mixed = PaceProgramDefinition(
            schemaVersion: 2, identifier: "mixed", name: "Mixed", description: "Invalid mixed authority",
            category: "custom",
            invocationPhrases: [], requiredPreferences: [],
            nodes: [
                .javascript(source: "pace.speak('hello')"),
                .action(step: .init(toolCalls: [.init(tool: "open_app", arguments: ["app": .string("Safari")])])),
            ])
        #expect(!PaceProgramValidator.validationIssues(for: mixed).isEmpty)
        let repeated = PaceProgramDefinition(
            schemaVersion: 2, identifier: "repeated", name: "Repeated", description: "Invalid multiple workers",
            category: "custom",
            invocationPhrases: [], requiredPreferences: [],
            nodes: [.repeatTimes(count: 2, nodes: [.javascript(source: "pace.speak('hello')")])])
        #expect(!PaceProgramValidator.validationIssues(for: repeated).isEmpty)
    }

    @Test func sourceBudgetCountsUTF8BytesAndRejectsEmptyBodies() {
        #expect(!PaceProgramValidator.validationIssues(for: program("  ")).isEmpty)
        #expect(!PaceProgramValidator.validationIssues(for: program(String(repeating: "あ", count: 8193))).isEmpty)
        let exact =
            "pace.speak('hello'); //" + String(repeating: "a", count: 24576 - "pace.speak('hello'); //".utf8.count)
        #expect(PaceProgramValidator.validationIssues(for: program(exact)).isEmpty)
    }

    @Test func actualXPCWorkerComputesDifferentGreetingsFromImmutableContext() async throws {
        let source =
            "const parts = ['morning', 'afternoon', 'evening']; const index = context.localHour < 12 ? 0 : context.localHour < 18 ? 1 : 2; pace.speak('Good ' + parts[index] + ', weekday ' + context.weekday + '.');"
        for (hour, expected) in [(8, "morning"), (14, "afternoon"), (21, "evening")] {
            let result = try await actions(source, hour: hour, weekday: 4)
            guard case .speak(let request) = result.first else {
                Issue.record("Expected typed speech")
                return
            }
            #expect(request.text == "Good " + expected + ", weekday 4.")
        }
    }

    @Test func actualXPCWorkerOnlyExposesComputeAndTheTwoFrozenSDKMethods() async throws {
        let source =
            "const absent = [typeof fetch, typeof XMLHttpRequest, typeof require, typeof process, typeof ObjC, typeof $, typeof setTimeout, typeof readFile]; if (absent.some(value => value !== 'undefined')) throw Error('unexpected authority'); if (Object.keys(context).sort().join(',') !== 'localHour,weekday') throw Error('private context leaked'); if (!Object.isFrozen(pace) || !Object.isFrozen(context)) throw Error('mutable SDK'); pace.speak('compute only');"
        let result = try await actions(source)
        #expect(result.count == 1)
        #expect(await rejects("context.localHour = 22; pace.speak('changed');"))
        #expect(await rejects("pace.openURL('https://example.com');"))
        #expect(await rejects("fetch('https://example.com'); pace.speak('fake');"))
    }

    @Test func actualXPCWorkerPreservesTypedSpeechAndMediaArguments() async throws {
        let result = try await actions(
            "pace.speak('こんにちは。', {profile:'japanese_female', englishSubtitle:'Hello.'}); pace.presentMedia('japanese-greeting-woman', {durationSeconds:6, motion:'bob'});"
        )
        #expect(result.count == 2)
        guard case .speak(let speech) = result[0], case .presentMedia(let media) = result[1] else {
            Issue.record("SDK output must compile to canonical typed actions")
            return
        }
        #expect(speech == .init(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello."))
        #expect(media == .init(assetID: "japanese-greeting-woman", durationSeconds: 6, motion: "bob"))
    }

    @Test func actualXPCWorkerRejectsSyntaxThrowAsyncAndInvalidSDKArguments() async {
        for source in [
            "const = ;", "pace.speak('never emitted'); throw Error('failure');",
            "return Promise.resolve('not synchronous');", "pace.speak(42);", "pace.speak('');",
            "pace.speak('hello', {voice:'arbitrary'});", "pace.speak('hello', {profile:'unknown'});",
            "pace.presentMedia('../image');", "pace.presentMedia('thank-you-dance', {durationSeconds:31});",
            "pace.presentMedia('thank-you-dance', {motion:'unknown'});",
            "pace.presentMedia('thank-you-dance', {path:'/tmp/file'});",
            "try { pace.speak(12); } catch {} pace.speak('caught invalid output');",
        ] { #expect(await rejects(source), "Worker accepted invalid source: \(source)") }
    }

    @Test func actualXPCWorkerEnforcesActionAndSerializedOutputCaps() async throws {
        #expect(try await actions("for (let index=0; index<50; index++) pace.speak(String(index));").count == 50)
        #expect(await rejects("for (let index=0; index<51; index++) pace.speak(String(index));"))
        #expect(await rejects("for (let index=0; index<40; index++) pace.speak('a'.repeat(2000));"))
        #expect(await rejects("pace.speak('a'.repeat(2001));"))
    }

    @Test func conditionalPowerCanBeSavedWithoutActionsUnderTheCurrentContext() async throws {
        let source = "if (context.weekday === 1) pace.speak('Sunday greeting');"
        guard
            case .noActionsMatched = try await PaceJavaScriptPowerRuntime.compile(
                program(source), context: context(weekday: 2))
        else {
            Issue.record("A condition that does not match must produce no actions")
            return
        }
        guard
            case .executionPlan(let matchingPlan) = try await PaceJavaScriptPowerRuntime.compile(
                program(source), context: context(weekday: 1))
        else {
            Issue.record("The same saved code must produce actions when its condition matches")
            return
        }
        #expect(matchingPlan.flattenedActions.count == 1)

        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let conditional = program("if (context.localHour < 0) pace.speak('not today');")
        helpers.begin("add a power Weekend Greeting", manager: manager)
        await manager.commitPowerDraft(
            .program(conditional), replacing: nil, transcript: "add a power Weekend Greeting",
            turnLease: manager.turnLeaseRegistry.currentLease)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms().count
                == 1)
        #expect(speech.spokenTexts.contains { $0.contains("Its test produced no actions in the current context") })
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        await manager.currentResponseTask?.value
        #expect(!speech.spokenTexts.contains("not today"))
        #expect(speech.spokenTexts.contains { $0.contains("didn't have any actions for the current conditions") })
    }

    @Test func compilerFailuresDescribeTheValidationProblemInPlainText() {
        let invalidProgram = PaceProgramCompilationError.invalidProgram(["JavaScript requires schemaVersion 2"])
        #expect(invalidProgram.localizedDescription == "JavaScript requires schemaVersion 2")
        let invalidAutomation = PaceAutomationCompilationError.invalidDefinition(["requires a supported tool"])
        #expect(invalidAutomation.localizedDescription == "requires a supported tool")
    }

    @Test func actualXPCWatchdogStopsInfiniteCodeAndNextRunSucceeds() async throws {
        let startedAt = Date()
        #expect(await rejects("while (true) {}"))
        #expect(Date().timeIntervalSince(startedAt) < 4)
        #expect(try await actions("pace.speak('worker recovered');").count == 1)
    }

    @Test func actualXPCCancellationStopsCodeAndNextRunSucceeds() async throws {
        let task = Task { try await actions("while (true) {}") }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled JavaScript returned a plan")
        } catch { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        #expect(try await actions("pace.speak('after cancellation');").count == 1)
    }

    @Test func actualXPCWatchdogAlsoCoversHostileSDKGetters() async throws {
        #expect(await rejects("pace.speak('hello', {get profile() { while(true) {} }});"))
        #expect(try await actions("pace.speak('after hostile getter');").count == 1)
    }

    @Test func addPhrasesAreAnchoredAndBareAddCannotCaptureNormalChat() {
        #expect(PacePowerCommandParser.parse("Add a Power") == .add(""))
        #expect(
            PacePowerCommandParser.parse("Could you please add a power called Greeting that says hello")
                == .add("called Greeting that says hello"))
        #expect(PacePowerCommandParser.parse("add power called Greeting") == .add("called Greeting"))
        #expect(PacePowerCommandParser.parse("How do I add a power?") == nil)
        #expect(PacePowerCommandParser.parse("The page says add a power Greeting") == nil)
        #expect(PacePowerCommandParser.parse("hello, how are you?") == nil)
    }

    @Test func managerAuthorsTestsSavesAndRunsCodeWithoutSpeakingDuringEvaluation() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, persister, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let author = PacePowerManagerTests.Author()
        author.response = try #require(
            String(data: JSONEncoder().encode(program("pace.speak('runtime authored output');")), encoding: .utf8))
        manager.reusableWorkAuthoringPlannerOverride = author
        helpers.begin("add a power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(
            .add("called Runtime Greeting that computes a greeting"), transcript: "add a power Runtime Greeting")
        await manager.currentResponseTask?.value
        let discovered = await manager.discoverAutomationCatalog()
        #expect(discovered.programs.count == 1)
        #expect(author.calls == 1)
        #expect(author.capturedUserPrompts.first?.contains("japanese-greeting-woman") == true)
        #expect(!speech.spokenTexts.contains("runtime authored output"))
        #expect(!manager.mediaOverlayController.isVisible)
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.filter { $0 == "runtime authored output" }.count == 1)
        #expect(persister.events.values.filter { $0.role == .pace && $0.text == "runtime authored output" }.count == 1)
        #expect(author.calls == 1)
    }

    @Test func managerRejectsEntirePlanBeforeAnyEffectWhenLastMediaAssetIsMissing() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let invalid = program("pace.speak('must not speak'); pace.presentMedia('missing-runtime-asset');")
        _ = try manager.managedPowerStore.commit(
            .program(invalid), catalog: (await manager.discoverAutomationCatalog()).catalog)
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        await manager.currentResponseTask?.value
        #expect(!speech.spokenTexts.contains("must not speak"))
        #expect(!manager.mediaOverlayController.isVisible)
        helpers.begin("add a power Invalid Greeting", manager: manager)
        await manager.commitPowerDraft(
            .program(
                program(
                    "pace.speak('must not speak'); pace.presentMedia('missing-runtime-asset');",
                    identifier: "invalid-runtime")),
            replacing: nil, transcript: "add a power Invalid Greeting",
            turnLease: manager.turnLeaseRegistry.currentLease)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms().count
                == 1)
    }

    @Test func managerCancelledAuthoringAndInvalidCodeNeverCommitArtifacts() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let author = PacePowerManagerTests.Author()
        author.response = try #require(
            String(data: JSONEncoder().encode(program("pace.speak('not saved');")), encoding: .utf8))
        author.suspends = true
        manager.reusableWorkAuthoringPlannerOverride = author
        helpers.begin("add a power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.add("called Runtime Greeting"), transcript: "add a power Runtime Greeting")
        let task = manager.currentResponseTask
        for _ in 0..<1000 {
            if author.continuation != nil { break }
            await Task.yield()
        }
        #expect(author.continuation != nil)
        manager.cancelActiveTurnTasks()
        author.continuation?.resume()
        author.continuation = nil
        await task?.value
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms()
                .isEmpty)
        author.suspends = false
        author.response = try #require(
            String(
                data: JSONEncoder().encode(program("pace.speak('must never execute'); throw Error('bad');")),
                encoding: .utf8))
        helpers.begin("add a power Broken", manager: manager)
        await manager.handlePowerCommand(.add("called Broken"), transcript: "add a power Broken")
        await manager.currentResponseTask?.value
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms()
                .isEmpty)
        #expect(!speech.spokenTexts.contains("must never execute"))
    }

    @Test func managerRuntimeRechecksLeaseAndFingerprintBeforeEffects() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let delayed = program(
            "const start = Date.now(); while (Date.now() - start < 400) {} pace.speak('stale output');")
        _ = try manager.managedPowerStore.commit(
            .program(delayed), catalog: (await manager.discoverAutomationCatalog()).catalog)
        let discovered = await manager.discoverAutomationCatalog()
        let saved = try manager.managedPowerStore.resolve("Runtime Greeting", catalog: discovered.catalog)
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        let task = manager.currentResponseTask
        try await Task.sleep(for: .milliseconds(50))
        try Data("changed artifact".utf8).write(to: #require(saved.ownedArtifactURL), options: .atomic)
        await task?.value
        #expect(!speech.spokenTexts.contains("stale output"))
        #expect(!manager.managedPowerExecutionIsAuthorized)
        #expect(manager.voiceState == .idle)
        #expect(manager.currentTurnHUDState.status == .failed)
    }

    @Test func programPreparationExposesStopAndCancellationRestoresIdle() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try manager.managedPowerStore.commit(
            .program(program("while (true) {}")),
            catalog: (await manager.discoverAutomationCatalog()).catalog)
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        let task = manager.currentResponseTask
        #expect(manager.voiceState == .processing)
        try await Task.sleep(for: .milliseconds(50))
        manager.cancelCurrentTurnFromPanel()
        await task?.value
        #expect(manager.voiceState == .idle)
        #expect(!speech.spokenTexts.contains { $0.contains("couldn't run") })
    }

    @Test func revocationDuringExecutionClearsTheOwnedBusyState() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, _) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try manager.managedPowerStore.commit(
            .program(program("pace.speak('first'); pace.speak('must not run');")),
            catalog: (await manager.discoverAutomationCatalog()).catalog)
        let saved = try manager.managedPowerStore.resolve(
            "Runtime Greeting", catalog: (await manager.discoverAutomationCatalog()).catalog)
        let artifact = try #require(saved.ownedArtifactURL)
        var callbackCount = 0
        manager.actionExecutor.speakLocalText = { [weak manager] _ in
            callbackCount += 1
            #expect(manager?.voiceState == .responding)
            try? Data("changed artifact".utf8).write(to: artifact, options: .atomic)
            return .init(toolName: "speak", summary: "Owned test artifact changed")
        }
        helpers.begin("run power Runtime Greeting", manager: manager)
        await manager.handlePowerCommand(.run("Runtime Greeting"), transcript: "run power Runtime Greeting")
        await manager.currentResponseTask?.value
        #expect(callbackCount == 1)
        #expect(manager.voiceState == .idle)
        #expect(manager.currentTurnHUDState.status == .failed)
    }

    @Test func persistedCodeUsesExistingCRUDAndUpdateRetainsRepresentation() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, _) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let first = program("pace.speak('first');")
        _ = try manager.managedPowerStore.commit(
            .program(first), catalog: (await manager.discoverAutomationCatalog()).catalog)
        let discovered = await manager.discoverAutomationCatalog()
        let saved = try manager.managedPowerStore.resolve("Runtime Greeting", catalog: discovered.catalog)
        try manager.managedPowerStore.setEnabled(false, power: saved)
        #expect(!manager.managedPowerStore.isEnabled(saved.identifier))
        try manager.managedPowerStore.setEnabled(true, power: saved)
        let author = PacePowerManagerTests.Author()
        author.response = try #require(
            String(
                data: JSONEncoder().encode(program("pace.speak('updated');", identifier: "ignored-name")),
                encoding: .utf8))
        manager.reusableWorkAuthoringPlannerOverride = author
        helpers.begin("update power Runtime Greeting: say updated", manager: manager)
        await manager.handlePowerCommand(
            .update("Runtime Greeting", "say updated"), transcript: "update power Runtime Greeting: say updated")
        await manager.currentResponseTask?.value
        let programs = PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL)
            .listValidPrograms()
        #expect(programs.count == 1)
        #expect(programs.first?.identifier == first.identifier)
        #expect(programs.first?.nodes == [.javascript(source: "pace.speak('updated');")])
        #expect(author.calls == 1)
        #expect(author.capturedUserPrompts.first?.contains("first") == true)
        let current = try manager.managedPowerStore.resolve(
            "Runtime Greeting", catalog: (await manager.discoverAutomationCatalog()).catalog)
        let archived = try manager.managedPowerStore.archive(current)
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms()
                .isEmpty)
    }

    @Test func pendingDescriptionExpiresAndLeavesQuestionsAndExplicitCommandsAlone() {
        let date = Date()
        let pending = PacePendingPowerDescription(requestedAt: date)
        #expect(
            pending.resolve("A Power called Greeting that says hello", now: date)
                == .description("A Power called Greeting that says hello"))
        #expect(
            pending.resolve("When I run it, show a GIF and greet me", now: date)
                == .description("When I run it, show a GIF and greet me"))
        #expect(
            pending.resolve("It should greet me with the current hour", now: date)
                == .description("It should greet me with the current hour"))
        #expect(pending.resolve("cancel", now: date) == .cancelled)
        #expect(pending.resolve("never mind", now: date) == .cancelled)
        for transcript in [
            "list powers", "add a power called New", "open Safari", "set volume to 30", "what time is it", "hello",
            "import power media /tmp/hello.gif as hello",
            "pause", "mute", "next track", "volume down", "lock my screen", "play some jazz", "tell me a joke",
            "open the folder called Downloads", "play the song named Yesterday", "I want to listen to jazz",
        ] {
            #expect(pending.resolve(transcript, now: date) == .unrelated)
        }
        #expect(pending.resolve("A Power called Greeting", now: date.addingTimeInterval(121)) == .unrelated)
        #expect(pending.resolve("A Power called Greeting", now: date.addingTimeInterval(-1)) == .unrelated)
    }

    @Test func bareAddThenPlainDescriptionAuthorsOnePowerAndRetainsTheRealTranscript() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, persister, _) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let author = PacePowerManagerTests.Author()
        author.response = try #require(
            String(data: JSONEncoder().encode(program("pace.speak('two-turn greeting');")), encoding: .utf8))
        manager.reusableWorkAuthoringPlannerOverride = author
        helpers.begin("Add a Power", manager: manager)
        await manager.handlePowerCommand(.add(""), transcript: "Add a Power")
        await manager.currentResponseTask?.value
        #expect(manager.pendingPowerDescription != nil)
        #expect(
            persister.events.values.contains {
                $0.role == .pace && $0.text.contains("Call it Hello and greet me with a GIF")
            })
        #expect(author.calls == 0)
        let description = "A Power called Runtime Greeting that computes a local greeting"
        helpers.begin(description, manager: manager)
        #expect(manager.handlePendingPowerDescription(description))
        await manager.currentResponseTask?.value
        #expect(author.calls == 1)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms().count
                == 1)
        #expect(manager.pendingPowerDescription == nil)
        #expect(persister.events.values.contains { $0.role == .user && $0.text == description })
        #expect(!persister.events.values.contains { $0.role == .user && $0.text == "add a power " + description })
    }

    @Test func pendingDescriptionCancelsExpiresAndIgnoresUnrelatedCommandsWithoutSaving() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, _) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let author = PacePowerManagerTests.Author()
        manager.reusableWorkAuthoringPlannerOverride = author
        for transcript in [
            "cancel", "list powers", "what time is it?", "hello", "pause", "mute", "next track", "volume down",
            "tell me a joke",
            "open the folder called Downloads", "play the song named Yesterday", "I want to listen to jazz",
        ] {
            helpers.begin("Add a Power", manager: manager)
            await manager.handlePowerCommand(.add(""), transcript: "Add a Power")
            await manager.currentResponseTask?.value
            helpers.begin(transcript, manager: manager)
            _ = manager.handlePendingPowerDescription(transcript)
            await manager.currentResponseTask?.value
            #expect(manager.pendingPowerDescription == nil)
        }
        manager.pendingPowerDescription = .init(requestedAt: Date().addingTimeInterval(-121))
        #expect(!manager.handlePendingPowerDescription("A Power called Expired that says hello"))
        manager.pendingPowerDescription = .init(requestedAt: Date())
        manager.cancelCurrentTurnFromPanel()
        #expect(manager.pendingPowerDescription == nil)
        #expect(author.calls == 0)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms()
                .isEmpty)
    }
}
