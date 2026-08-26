import Foundation

@MainActor
protocol PacePadOutputDelegate: AnyObject {
    func deliverAssistantResponse(
        turnIdentifier: String,
        spokenText: String,
        usesOffDevicePlanner: Bool
    ) -> Bool

    func deliverProactiveMessage(_ utterance: PaceProactiveUtterance) -> Bool
}

@MainActor
extension CompanionManager {
    @discardableResult
    func submitPacePadTranscript(
        _ transcript: String,
        turnIdentifier: String,
        physicalSceneContext: String?
    ) -> Bool {
        guard voiceState == .idle else { return false }
        activePacePadTurnIdentifier = turnIdentifier
        activePacePadTurnUsesOffDevicePlanner = false
        pendingPacePadPhysicalSceneContext = physicalSceneContext

        // The Mac still owns the complete conversation pipeline, but its
        // speaker stays quiet for an iPad-originated turn because the iPad is
        // the user's selected audio surface for that interaction.
        isChatModeMutedForCurrentTurn = true
        submitChatTranscriptFromDeepLink(transcript)
        return true
    }

    func consumePacePadPhysicalSceneContext() -> String? {
        defer { pendingPacePadPhysicalSceneContext = nil }
        return pendingPacePadPhysicalSceneContext
    }

    func abandonActivePacePadTurn() {
        activePacePadTurnIdentifier = nil
        activePacePadTurnUsesOffDevicePlanner = false
        pendingPacePadPhysicalSceneContext = nil
    }
}
