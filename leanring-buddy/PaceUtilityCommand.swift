import Foundation

nonisolated enum PaceUtilityCommand: Equatable {
    case speak(text: String, useKokoro: Bool)
    case transcribeAudio(path: String)
    case checkUpdates

    static func parse(_ transcript: String) -> Self? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if ["check for updates", "check pace for updates", "update check"].contains(normalized) {
            return .checkUpdates
        }
        for prefix in ["read aloud using kokoro ", "say aloud using kokoro ", "read aloud ", "say aloud "] {
            if normalized.hasPrefix(prefix) {
                let speech = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !speech.isEmpty else { return nil }
                return .speak(text: speech, useKokoro: prefix.contains("kokoro"))
            }
        }
        for prefix in ["transcribe audio ", "transcribe file "] {
            if normalized.hasPrefix(prefix) {
                let path = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
                return .transcribeAudio(path: path)
            }
        }
        return nil
    }
}

extension CompanionManager {
    func handleUtilityCommand(_ command: PaceUtilityCommand, transcript: String, turnLease: PaceTurnLease) async {
        defer { if turnLeaseRegistry.isCurrent(turnLease) { voiceState = .idle } }

        switch command {
        case .checkUpdates:
            let started = PaceAutoUpdateController.shared.checkForUpdatesManually()
            await publishCommandFeedback(
                transcript: transcript,
                spokenText: started ? "Checking for Pace updates." : "An update check is already in progress."
            )
        case .speak(let text, let useKokoro):
            responseOverlayManager.showOverlayAndBeginStreaming()
            responseOverlayManager.updateStreamingText(text)
            do {
                let client: any BuddyTTSClient
                if useKokoro {
                    try await PaceTTSSidecarLauncher.ensureReadyForCommand()
                    if ossCommandSpeechClient == nil { ossCommandSpeechClient = LocalServerTTSClient() }
                    client = ossCommandSpeechClient!
                } else {
                    client = ttsClient
                }
                try await client.speakText(text)
                while client.isPlaying {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let response: String
                if useKokoro, let localClient = client as? LocalServerTTSClient, localClient.hasObservedSidecarOutage {
                    response = "Kokoro was unavailable; used the system voice."
                } else {
                    response = "Read aloud: " + text
                }
                recordConversationTurn(userTranscript: transcript, assistantResponse: response)
                responseOverlayManager.updateStreamingText(response)
                currentTurnHUDState = .done(response)
            } catch {
                ossCommandSpeechClient?.stopPlayback()
                if Task.isCancelled { return }
                await publishCommandFeedback(
                    transcript: transcript, spokenText: "Could not read aloud: " + error.localizedDescription)
            }
            responseOverlayManager.finishStreaming()
        case .transcribeAudio(let path):
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let text = try await PaceAudioFileTranscriber.transcribeAudioFile(at: fileURL)
                guard isActiveTurn(turnLease) else { return }
                await publishCommandFeedback(
                    transcript: transcript, spokenText: text.isEmpty ? "No speech detected in that audio file." : text)
            } catch {
                guard isActiveTurn(turnLease) else { return }
                await publishCommandFeedback(
                    transcript: transcript, spokenText: "Could not transcribe audio: " + error.localizedDescription)
            }
        }
    }
}
