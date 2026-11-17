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
}
