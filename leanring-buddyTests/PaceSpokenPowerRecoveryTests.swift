import Foundation
import Testing
@testable import Pace

@MainActor @Suite(.serialized)
struct PaceSpokenPowerRecoveryTests {
    func savePower(_ name: String, identifier: String, manager: CompanionManager) async throws -> PaceManagedPower {
        let definition = PaceAutomationDefinition(schemaVersion: 1, identifier: identifier, name: name,
            description: "Saved spoken Power fixture", category: "custom", invocationPhrases: ["run power " + name],
            source: .user, executionMode: .deterministicLocal, requiredPreferences: [],
            steps: [.init(toolCalls: [.init(tool: "speak", arguments: ["text": .string("Selected " + name)])])])
        let discovered = await manager.discoverAutomationCatalog()
        _ = try manager.managedPowerStore.commit(.automation(definition), replacing: nil, catalog: discovered.catalog)
        return try manager.managedPowerStore.resolve(name, catalog: await manager.discoverAutomationCatalog().catalog)
    }

    @Test func aMisheardExplicitPowerRequestOffersTheSavedNameWithoutRunningIt() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Run Power Bombs and Boy.", manager: manager)
        await manager.handlePowerCommand(.run("Bombs and Boy."), transcript: "Run Power Bombs and Boy.")
        await manager.currentResponseTask?.value
        #expect(manager.currentTurnHUDState.status == .needsClarification)
        #expect(manager.currentTurnHUDState.options.contains("Bouncing Ball"))
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }
    @Test func observedMishearingsRankTheNearestSavedNameBeforeAnyGeneralAgentRoute() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
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
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        _ = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        for transcript in ["delete power Bouncing Bow", "disable power Bouncing Bow", "update power Bouncing Bow: change it", "Power supply settings", "run power nap", "click the ball", "run a script in terminal", "What is a bouncing ball?"] {
            PacePowerManagerTests().begin(transcript, manager: manager)
            #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(transcript)))
            #expect(manager.pendingSpokenPowerClarification == nil)
        }
        let exact = try manager.managedPowerStore.resolve("Bouncing Ball", catalog: await manager.discoverAutomationCatalog().catalog)
        let exactRequest = "run power " + exact.identifier
        PacePowerManagerTests().begin(exactRequest, manager: manager)
        #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(exactRequest)))
        #expect(manager.pendingSpokenPowerClarification == nil)
        let typed = "Power Bouncing Bow."
        manager.pendingTypedConversationEventIdentifier = manager.acceptConversationRequest(typed, origin: .typed).eventID
        PacePowerManagerTests().begin(typed, manager: manager)
        #expect(!(await manager.handleSpokenPowerRecoveryIfNeeded(typed)))
        #expect(PacePowerCommandParser.parse("run power Bouncing Bow") == .run("Bouncing Bow"))
    }

    @Test func confirmationSurvivesCaptureCancellationButRequiresCurrentExactUnchangedPower() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let power = try await savePower("Bouncing Ball", identifier: "bouncing-ball", manager: manager)
        PacePowerManagerTests().begin("Power Bouncing Bow", manager: manager)
        #expect(await manager.handleSpokenPowerRecoveryIfNeeded("Power Bouncing Bow"))
        let pending = try #require(manager.pendingSpokenPowerClarification)
        manager.cancelActiveTurnTasks()
        #expect(manager.pendingSpokenPowerClarification == pending)
        manager.resolveSpokenPowerClarification(option: "Bouncing Ball", expectedIdentifier: UUID())
        #expect(manager.pendingSpokenPowerClarification == pending)
        manager.pendingSpokenPowerClarification = nil
        manager.pendingIntentClarification = .init(originalTranscript: "older question",
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
        try original.replacingOccurrences(of: "Selected Bouncing Ball", with: "Changed implementation").write(to: artifactURL, atomically: true, encoding: .utf8)
        manager.resolveSpokenPowerClarification(option: "Bouncing Ball", expectedIdentifier: replacementPending.identifier)
        await manager.currentTurnDispatchTask?.value
        await manager.currentResponseTask?.value
        #expect(!speech.spokenTexts.contains("Changed implementation"))
        #expect(!speech.spokenTexts.contains("Selected Bouncing Ball"))
    }

    @Test func oneOfferedPowerNeedsExplicitConfirmationAndRunsExactlyOnce() async throws {
        let (root, manager, _, speech) = try PacePowerManagerTests().fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
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
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
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

}
