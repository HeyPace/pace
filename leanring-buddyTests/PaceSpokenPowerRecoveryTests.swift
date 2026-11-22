import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PaceSpokenPowerRecoveryTests {
    func savePower(_ name: String, identifier: String, manager: CompanionManager, invocationPhrases: [String]? = nil)
        async throws -> PaceManagedPower
    {
        let definition = PaceAutomationDefinition(
            schemaVersion: 1, identifier: identifier, name: name,
            description: "Saved spoken Power fixture", category: "custom",
            invocationPhrases: invocationPhrases ?? ["run power " + name],
            source: .user, executionMode: .deterministicLocal, requiredPreferences: [],
            steps: [.init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("Selected " + name)])])])
        let discovered = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), replacing: nil, catalog: discovered.catalog)
        return try manager.managedPowerStore.resolve(name, catalog: await manager.discoverAutomationCatalog().catalog)
    }

    @Test func unfamiliarNamesRecoverWithoutMatchingOrdinaryRequests() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        var powers: [PaceManagedPower] = []
        for (name, identifier) in [
            ("Meeting Digest", "meeting-digest"), ("Café Notes", "cafe-notes"),
            ("Daily Brief", "daily-brief"), ("Daily Breeze", "daily-breeze"), ("Go", "go-power"),
            ("Weekly Forecast", "weekly-forecast"), ("Invoice Summary", "invoice-summary"),
            ("Inbox Sweep", "inbox-sweep"),
        ] {
            powers.append(try await savePower(name, identifier: identifier, manager: manager))
        }
        for (transcript, expected) in [
            ("Power meeting dye jest", ["Meeting Digest"]),
            ("Power cafe note", ["Café Notes"]),
            ("Power weekly fore cast", ["Weekly Forecast"]),
            ("Power invoice summa ree", ["Invoice Summary"]),
            ("Power daily bree", ["Daily Brief", "Daily Breeze"]),
            ("Run meeting digest through the summarizer", []),
            ("Run daily brief and send it to everyone", []),
            ("Run power get", []),
            ("Power washing the driveway", []),
        ] {
            let target = transcript == "Run power get" ? "get" : nil
            let candidates = PaceSpokenPowerRecovery.candidates(
                for: transcript, powers: powers, explicitRunTarget: target)
            #expect(Set(candidates.map(\.name)) == Set(expected), "Unexpected matches for \(transcript)")
        }
    }

    @Test func aMisheardExplicitPowerRequestOffersTheSavedNameWithoutRunningIt() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Run Power Bombs and Boy.", manager: manager)
        await manager.handlePowerCommand(.run("Bombs and Boy."), transcript: "Run Power Bombs and Boy.")
        await manager.currentResponseTask?.value
        #expect(manager.currentTurnHUDState.status == .needsClarification)
        #expect(manager.currentTurnHUDState.options.contains("Run Bouncing Ball"))
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }
    @Test func observedMishearingsRankTheNearestSavedNameBeforeAnyGeneralAgentRoute() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        _ = try await savePower("Bounce Coach", identifier: "bounce-coach", manager: manager)
        #expect(manager.buddyDictationManager.additionalContextualPhrases?().contains("Bouncing Ball") == true)
        for transcript in ["Run Power Bombs and Boy.", "Power Bouncing Bow.", "Run, forward, bounce and board."] {
            manager.pendingSpokenPowerClarification = nil
            PacePowerManagerTests().begin(transcript, manager: manager)
            #expect(await manager.handleSpokenPowerRecoveryIfNeeded(transcript))
            #expect(manager.pendingSpokenPowerClarification?.candidates.map(\.name) == ["Bouncing Ball"])
            #expect(manager.currentTurnHUDState.title == "Did you mean Bouncing Ball?")
            await manager.currentResponseTask?.value
        }
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }

    @Test func nearMatchesNeverInterceptTypedMutationSystemOrUnrelatedRequests() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        for transcript in [
            "delete power Bouncing Bow", "disable power Bouncing Bow", "update power Bouncing Bow: change it",
            "Power supply settings", "run power nap", "click the ball", "run a script in terminal",
            "What is a bouncing ball?",
        ] {
            PacePowerManagerTests().begin(transcript, manager: manager)
            #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(transcript)))
            #expect(manager.pendingSpokenPowerClarification == nil)
        }
        for transcript in [
            "run automation Bouncing Ball", "run shortcut Bouncing Ball", "run the Bouncing Ball skill",
            "run flow Bouncing Ball", "run power weather report",
        ] {
            PacePowerManagerTests().begin(transcript, manager: manager)
            #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(transcript)))
            #expect(manager.pendingSpokenPowerClarification == nil)
        }
        let exact = try manager.managedPowerStore.resolve(
            "Bouncing Ball", catalog: await manager.discoverAutomationCatalog().catalog)
        let exactRequest = "run power " + exact.identifier
        PacePowerManagerTests().begin(exactRequest, manager: manager)
        #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(exactRequest)))
        #expect(manager.pendingSpokenPowerClarification == nil)
        let typed = "Power Bouncing Bow."
        manager.pendingTypedConversationEventIdentifier =
            manager.acceptConversationRequest(typed, origin: .typed).eventID
        PacePowerManagerTests().begin(typed, manager: manager)
        #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(typed)))
        #expect(PacePowerCommandParser.parse("run power Bouncing Bow") == .run("Bouncing Bow"))
    }

    @Test func confirmationSurvivesCaptureCancellationButRequiresCurrentExactUnchangedPower() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let power = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Power Bouncing Bow", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("Power Bouncing Bow"))
        let pending = try #require(manager.pendingSpokenPowerClarification)
        manager.cancelActiveTurnTasks()
        #expect(manager.pendingSpokenPowerClarification == pending)
        manager.resolveSpokenPowerClarification(option: "Bouncing Ball", expectedIdentifier: UUID())
        #expect(manager.pendingSpokenPowerClarification == pending)
        manager.pendingSpokenPowerClarification = nil
        manager.pendingIntentClarification = .init(
            originalTranscript: "older question",
            clarification: .init(question: "Choose", options: ["Bouncing Ball"]))
        manager.resolveClarification(option: "Bouncing Ball", powerClarificationIdentifier: pending.identifier)
        #expect(manager.pendingIntentClarification != nil)
        #expect(manager.pendingTypedConversationEventIdentifier == nil)
        manager.pendingIntentClarification = nil
        manager.pendingSpokenPowerClarification = pending
        try manager.managedPowerStore.setEnabled(false, power: power)
        PacePowerManagerTests().begin("yes", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("yes"))
        await manager.currentResponseTask?.value
        #expect(manager.pendingSpokenPowerClarification == nil)
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
        try manager.managedPowerStore.setEnabled(true, power: power)
        PacePowerManagerTests().begin("Power Bouncing Bow", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("Power Bouncing Bow"))
        let replacementPending = try #require(manager.pendingSpokenPowerClarification)
        let artifactURL = try #require(power.ownedArtifactURL)
        let original = try String(contentsOf: artifactURL, encoding: .utf8)
        try original.replacingOccurrences(of: "Selected Bouncing Ball", with: "Changed implementation").write(
            to: artifactURL, atomically: true, encoding: .utf8)
        manager.resolveSpokenPowerClarification(
            option: "Bouncing Ball", expectedIdentifier: replacementPending.identifier)
        await manager.currentTurnDispatchTask?.value
        await manager.currentResponseTask?.value
        #expect(!speech.spokenTexts.contains("Changed implementation"))
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }

    @Test func oneOfferedPowerNeedsExplicitConfirmationAndRunsExactlyOnce() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Power Bouncing Bow", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("Power Bouncing Bow"))
        await manager.currentResponseTask?.value
        PacePowerManagerTests().begin("yes", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("yes"))
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.filter { $0 == "Selected Bouncing Ball" }.count == 1)
        #expect(manager.pendingSpokenPowerClarification == nil)
    }

    @Test func ambiguityExpiryCancellationAndUnrelatedRepliesDoNotRunAnything() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let first = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        let second = try await savePower("Bouncing Bell", identifier: "bouncing-bell", manager: manager)
        let now = Date(timeIntervalSince1970: 1000)
        let pending = PacePendingSpokenPowerClarification(candidates: [first, second], createdAt: now)
        for response in ["yes", "yes please", "go ahead", "yes run it"] {
            #expect(pending.resolve(response, now: now) == .needsSelection)
            let single = PacePendingSpokenPowerClarification(candidates: [first], createdAt: now)
            #expect(single.resolve(response, now: now) == .selected(first))
        }
        #expect(pending.resolve("second one", now: now) == .selected(second))
        #expect(pending.resolve("cancel", now: now) == .cancelled)
        #expect(pending.resolve("what is the weather", now: now) == .unrelated)
        #expect(pending.resolve("first", now: now.addingTimeInterval(61)) == .expired)
        for response in ["yes", "cancel", "what is the weather"] {
            manager.pendingSpokenPowerClarification = .init(candidates: [first], createdAt: now)
            PacePowerManagerTests().begin(response, manager: manager)
            let handled = await manager.handleSpokenPowerRecoveryIfNeeded(response, now: now.addingTimeInterval(61))
            #expect(handled == (response != "what is the weather"))
            #expect(manager.pendingSpokenPowerClarification == nil)
            await manager.currentResponseTask?.value
        }
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }

    @Test func confirmationControlsAndPunctuationNeverSelectTheWrongPower() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let yesPower = try await savePower("Yes", identifier: "yes-power", manager: manager)
        let cancelPower = try await savePower("Cancel", identifier: "cancel-power", manager: manager)
        let now = Date()
        let controls = PacePendingSpokenPowerClarification(candidates: [yesPower, cancelPower], createdAt: now)
        #expect(controls.resolve("yes", now: now) == .needsSelection)
        #expect(controls.resolve("Cancel", now: now) == .cancelled)
        #expect(controls.resolve("Run Cancel", now: now) == .selected(cancelPower))
        let first = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        let second = try await savePower("Bouncing-Ball", identifier: "bouncing-hyphen", manager: manager)
        let pending = PacePendingSpokenPowerClarification(candidates: [first, second], createdAt: now)
        #expect(pending.options[0] != pending.options[1])
        #expect(pending.resolve(pending.options[1], now: now) == .selected(second))
        #expect(pending.resolve("Bouncing Ball", now: now) == .needsSelection)
        let single = PacePendingSpokenPowerClarification(candidates: [first], createdAt: now)
        #expect(single.resolve("run Bouncing Ball", now: now) == .selected(first))
        #expect(single.resolve("run the Bouncing Ball", now: now) == .selected(first))
    }

    @Test func aTypedYesConfirmsAnExistingVoiceQuestionWithoutFuzzyMatchingTypedCommands() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Power Bouncing Bow", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("Power Bouncing Bow"))
        await manager.currentResponseTask?.value
        manager.pendingTypedConversationEventIdentifier =
            manager.acceptConversationRequest("yes", origin: .typed).eventID
        PacePowerManagerTests().begin("yes", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("yes"))
        await manager.currentResponseTask?.value
        #expect(speech.spokenTexts.filter { $0 == "Selected Bouncing Ball" }.count == 1)
    }

    private final class CountingIntentClassifier: PaceIntentClassifying {
        var calls = 0
        func classify(_ transcript: String) async -> PaceIntentPrediction {
            calls += 1
            return .init(intent: .chitchat, confidence: 1)
        }
        func classify(_ transcript: String, conversationHistory: [(userTranscript: String, assistantResponse: String)])
            async -> PaceIntentPrediction
        {
            await classify(transcript)
        }
    }

    @Test func realTranscriptDispatchConsumesMisheardPowersBeforeTheClassifier() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        _ = try await savePower("Bounce Coach", identifier: "bounce-coach", manager: manager)
        let classifier = CountingIntentClassifier()
        manager.intentClassifier = classifier
        for transcript in ["Run Power Bombs and Boy.", "Power Bouncing Bow.", "Run, forward, bounce and board."] {
            manager.pendingSpokenPowerClarification = nil
            PacePowerManagerTests().begin(transcript, manager: manager)
            await manager.sendTranscriptToPlannerWithScreenshotAsync(
                transcript: transcript,
                turnLease: manager.turnLeaseRegistry.currentLease)
            await manager.currentResponseTask?.value
            #expect(classifier.calls == 0)
            #expect(manager.currentTurnHUDState.title == "Did you mean Bouncing Ball?")
            #expect(manager.pendingSpokenPowerClarification?.candidates.map(\.name) == ["Bouncing Ball"])
        }
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }

    @Test func exactInvocationAliasesKeepTheirExistingRoute() async throws {
        let (root, manager, _, _) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await savePower(
            "Bouncing Ball", identifier: "bouncing-ball", manager: manager,
            invocationPhrases: ["Run Bouncing Ball"])
        PacePowerManagerTests().begin("Run Bouncing Ball", manager: manager)
        #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded("Run Bouncing Ball")))
        #expect(manager.pendingSpokenPowerClarification == nil)
    }

    @Test func exactOfferedLabelsOwnTheConfirmationBeforeOtherNamespaces() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        for (name, identifier) in [("Skill Tracker", "skill-tracker"), ("Daily Shortcut", "daily-shortcut")] {
            let power = try await savePower(name, identifier: identifier, manager: manager)
            manager.offerSpokenPowerClarification([power], transcript: "Near match")
            await manager.currentResponseTask?.value
            let label = "Run " + name
            manager.pendingTypedConversationEventIdentifier =
                manager.acceptConversationRequest(label, origin: .typed).eventID
            PacePowerManagerTests().begin(label, manager: manager)
            #expect(await manager.handleSpokenPowerRecoveryIfNeeded(label))
            await manager.currentResponseTask?.value
            #expect(speech.spokenTexts.filter { $0 == "Selected " + name }.count == 1)
            #expect(manager.pendingSpokenPowerClarification == nil)
        }
    }

}
