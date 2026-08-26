import Foundation

nonisolated enum PaceCompanionPhysicalSceneRequestParser {
    private static let explicitVisualRequestPhrases = [
        "what do you see",
        "what can you see",
        "can you see",
        "look at me",
        "look around",
        "what am i holding",
        "what am i wearing",
        "what is in this room",
        "what is in front of you",
        "what's in front of you",
    ]
    private static let cameraReferencePhrases = [
        "through the camera",
        "using the camera",
        "with the camera",
    ]
    private static let requestLanguagePhrases = [
        "can you",
        "could you",
        "please",
        "look",
        "tell me",
        "show me",
        "what",
        "where",
        "is there",
        "do you",
    ]

    static func requestsCameraContext(_ transcript: String) -> Bool {
        let normalizedTranscript =
            transcript
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if explicitVisualRequestPhrases.contains(where: normalizedTranscript.contains) {
            return true
        }
        return cameraReferencePhrases.contains(where: normalizedTranscript.contains)
            && requestLanguagePhrases.contains(where: normalizedTranscript.contains)
    }
}
