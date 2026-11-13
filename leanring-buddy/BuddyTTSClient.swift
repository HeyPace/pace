//
//  BuddyTTSClient.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends. Two conformers:
//  LocalTTSClient (AVSpeechSynthesizer, always available) and
//  LocalServerTTSClient (loopback OpenAI-compatible /v1/audio/speech —
//  Kokoro by default — which itself falls back to LocalTTSClient
//  whenever the sidecar is unavailable).
//

import Foundation

/// Why TTS playback ended. Read by `CompanionManager` to include in the
/// paceHistory log line for an interrupted turn — barge-in flips
/// `lastStopReason` to `.userBargeIn`, manual stop (the overlay's stop
/// button) flips it to `.manualStop`, normal completion is
/// `.naturalCompletion`. Wave 1c only differentiates barge-in vs
/// natural completion at the call site; the third case keeps the API
/// honest for the existing manual-stop path.
enum PaceTTSStopReason: Equatable {
    case naturalCompletion
    case userBargeIn
    case manualStop
}

@MainActor
protocol BuddyTTSClient: AnyObject {
    /// Accepts text into the backend queue. Legacy backends return at enqueue or
    /// confirmed startup; use speakUtterance for exact onset and completion.
    func speakText(_ text: String) async throws

    /// Waits for this utterance to finish. The callback marks confirmed audio onset.
    func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws

    /// Whether speech audio is currently being played out of the device.
    var isPlaying: Bool { get }

    /// Stops any in-progress speech immediately. Safe to call when
    /// nothing is playing.
    func stopPlayback()

    /// Why playback last ended. Set by the client on every stop path —
    /// natural delegate callback, `stopPlayback()`, or the barge-in
    /// drain path. Defaults to `.naturalCompletion` before any
    /// playback has happened. Read by `CompanionManager` when
    /// journaling an interrupted turn.
    var lastStopReason: PaceTTSStopReason { get }

    /// Sets the next stop reason. Called by the streaming pipeline's
    /// barge-in drain just before `stopPlayback()` so the manager's
    /// post-stop read sees `.userBargeIn` instead of `.manualStop`.
    /// Implementations store the value and propagate it on the next
    /// stop event.
    func recordExpectedStopReason(_ reason: PaceTTSStopReason)
}

enum PaceUtterancePlaybackError: Error { case completionUnavailable, playbackFailed }

extension BuddyTTSClient {
    /// Optional backends must implement actual utterance events before guided autoplay can use them.
    func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws {
        throw PaceUtterancePlaybackError.completionUnavailable
    }
}

nonisolated enum PaceSpeechProvider {
    case apple
    case localServer
    case bundledQwen3
}

enum BuddyTTSClientFactory {
    nonisolated static func selectedProvider(configuredProvider: String?, useBundledQwen3: Bool) -> PaceSpeechProvider {
        if useBundledQwen3 { return .bundledQwen3 }
        return configuredProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apple"
            ? .apple : .localServer
    }

    @MainActor
    static func makeDefault() -> any BuddyTTSClient {
        // Bundled Qwen3 TTS trumps the configured Kokoro-sidecar
        // path when the user has opted in AND TTSKit is linked. This
        // drops the Python sidecar dependency from the setup story.
        let selectedProvider = selectedProvider(
            configuredProvider: AppBundleConfiguration.stringValue(forKey: "TTSProvider"),
            useBundledQwen3: PaceBundledModelsSettings.isUsingQwen3TTSInProcess()
        )
        if selectedProvider == .bundledQwen3 {
            print("🔊 TTS: using bundled Qwen3 TTS (TTSKit in-process)")
            return PaceQwen3TTSClient()
        }

        // Apple speech is the dependable zero-setup default. Kokoro remains
        // available when `TTSProvider=localServer` is chosen explicitly.
        if selectedProvider == .apple {
            print("🔊 TTS: using local AVSpeechSynthesizer")
            return LocalTTSClient()
        }
        return LocalServerTTSClient()
    }
}
